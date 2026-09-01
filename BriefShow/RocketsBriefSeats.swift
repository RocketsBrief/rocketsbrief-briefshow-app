import Foundation
import AppKit
import Combine
import IOKit

/// One stable id per Mac, for the "one email, one computer" rule.
///
/// Deliberately NOT the random UUID `DeviceCheckIn` keeps in UserDefaults:
/// that one is per-installation, so reinstalling the app (or wiping the
/// preferences plist) hands the same Mac a brand new identity, and the
/// client would silently burn a second seat on the same machine. The
/// IOKit platform UUID is the machine, and it survives reinstalls,
/// updates and folder moves.
///
/// The UserDefaults fallback only exists because a sandbox denial would
/// otherwise leave the app with no id at all; if it ever kicks in, the
/// seat is still enforced, just per-installation instead of per-Mac.
enum MachineIdentity {
    private static let fallbackDefaultsKey = "briefshow.seatDeviceID"

    static let deviceID: String = {
        if let hardware = hardwareUUID(), !hardware.isEmpty {
            return hardware
        }

        if let existing = UserDefaults.standard.string(forKey: fallbackDefaultsKey) {
            return existing
        }

        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: fallbackDefaultsKey)
        return generated
    }()

    /// Shown in the admin panel next to the seat, so the client can tell
    /// which of the 22 Macs is which without reading UUIDs.
    static var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )

        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let property = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )

        return property?.takeRetainedValue() as? String
    }
}

/// What the server said about this Mac's seat.
private struct SeatVerdict {
    /// `false` ONLY when the server explicitly said this Mac lost its
    /// seat. Anything else — offline, RPC missing, 500 — is `true`, see
    /// the fail-open note on `SeatManager`.
    let isActive: Bool
    let deviceLimit: Int
    let seatsUsed: Int
}

/// Enforces "one email, one computer" (and the per-email exceptions) by
/// claiming a seat on sign-in and then checking, on a heartbeat, that the
/// seat is still ours.
///
/// **The count lives on the server, not here.** The app never decides how
/// many Macs an email may use; it asks `briefshow_seat_heartbeat` and
/// does what it is told. That is what lets a limit be changed from
/// RocketsBrief (raise a client from 1 to 3 Macs, say) without shipping an
/// app update, and it is why a patched client can't grant itself seats —
/// the eviction happens in Postgres, inside a SECURITY DEFINER function.
///
/// **Fail-open, on purpose.** A photographer on location with no signal
/// must keep working. Only an explicit `"ok": false` from the server signs
/// anyone out; every failure that is merely a failure (no network, DNS
/// down, RPC not deployed yet, 5xx) leaves the session exactly as it was.
/// The cost of that choice is that pulling a Mac's cable delays its
/// eviction until it is back online — which is the right trade for a paid
/// tool, and the seat is already gone on the server the moment the second
/// Mac signs in either way.
@MainActor
final class SeatManager: ObservableObject {
    static let shared = SeatManager()

    /// How many Macs this email is allowed, as last reported by the
    /// server, and how many are currently claimed. Nil until the first
    /// successful heartbeat. Shown in the profile modal.
    @Published private(set) var deviceLimit: Int?
    @Published private(set) var seatsUsed: Int?

    private static let heartbeatInterval: TimeInterval = 120

    private var heartbeatTimer: Timer?
    private var isChecking = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in await SeatManager.shared.heartbeat() }
        }
    }

    /// Called once, from the app's first window. Starts the repeating
    /// check here rather than in a view so it keeps running no matter
    /// which window the client happens to have open (ShowGrid, the
    /// BriefShow editor, LumenoLab, or a full-screen slideshow).
    func start() {
        guard heartbeatTimer == nil else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { _ in
            Task { @MainActor in await SeatManager.shared.heartbeat() }
        }
        // Otherwise the check stops for as long as a menu is open or a
        // slider is being dragged — both of which are normal here.
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer

        Task { await heartbeat() }
    }

    /// Take this Mac's seat, evicting whichever Mac is oldest if the
    /// email is already at its limit. Called right after a successful
    /// sign-in — claiming is what makes THIS Mac the newest seat, so a
    /// client who signs in on a second computer keeps the second one and
    /// loses the first, which is the way round they expect.
    func claimSeat() async {
        guard let verdict = await callHeartbeat(claiming: true) else { return }
        apply(verdict)
    }

    /// Ask whether this Mac still holds its seat. Signs out locally if it
    /// doesn't.
    func heartbeat() async {
        guard AccountManager.shared.isSignedIn, !isChecking else { return }

        isChecking = true
        defer { isChecking = false }

        guard let verdict = await callHeartbeat(claiming: false) else { return }
        apply(verdict)
    }

    /// Give the seat back on an explicit sign-out, so the client doesn't
    /// have to wait for an eviction to reuse this Mac.
    func releaseSeat(session: RocketsBriefSession) async {
        guard let request = rpcRequest(
            named: "briefshow_seat_release",
            accessToken: session.accessToken,
            body: ["p_device_id": MachineIdentity.deviceID]
        ) else { return }

        _ = try? await URLSession.shared.data(for: request)
    }

    private func apply(_ verdict: SeatVerdict) {
        deviceLimit = verdict.deviceLimit
        seatsUsed = verdict.seatsUsed

        guard !verdict.isActive else { return }

        AccountManager.shared.forceSignOut(
            message: verdict.deviceLimit == 1
                ? "You were signed out here because this account was signed in on another computer. One account, one computer — sign in again to move it back to this Mac."
                : "You were signed out here because this account is now signed in on \(verdict.deviceLimit) other computers. Sign in again to move a seat back to this Mac."
        )
    }

    /// Returns nil for every "we don't actually know" outcome — see the
    /// fail-open note on the class.
    private func callHeartbeat(claiming: Bool) async -> SeatVerdict? {
        guard let session = AccountManager.shared.session else { return nil }

        let body: [String: Any] = [
            "p_device_id": MachineIdentity.deviceID,
            "p_device_name": MachineIdentity.deviceName,
            "p_app_version": AppRemoteStatus.shared.currentVersion,
            "p_claim": claiming
        ]

        guard let request = rpcRequest(
            named: "briefshow_seat_heartbeat",
            accessToken: session.accessToken,
            body: body
        ) else { return nil }

        guard var (data, response) = try? await URLSession.shared.data(for: request) else {
            return nil
        }

        // A Supabase access token lasts an hour; this heartbeat outlives
        // that by design, so the first 401 is expected rather than a
        // problem. Refresh once and retry — WITHOUT this, every session
        // older than an hour would stop reporting in, and the app would
        // never learn it had lost its seat.
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            await AccountManager.shared.refreshSessionIfNeeded()

            guard let refreshed = AccountManager.shared.session,
                  let retry = rpcRequest(
                      named: "briefshow_seat_heartbeat",
                      accessToken: refreshed.accessToken,
                      body: body
                  ),
                  let result = try? await URLSession.shared.data(for: retry)
            else { return nil }

            (data, response) = result
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isActive = json["ok"] as? Bool
        else {
            return nil
        }

        return SeatVerdict(
            isActive: isActive,
            deviceLimit: (json["device_limit"] as? Int) ?? 1,
            seatsUsed: (json["seats_used"] as? Int) ?? 1
        )
    }

    private func rpcRequest(named function: String, accessToken: String, body: [String: Any]) -> URLRequest? {
        guard let url = URL(string: "\(RocketsBriefConfig.supabaseURL)/rest/v1/rpc/\(function)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(RocketsBriefConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // An offline Mac should fall through to "we don't know" quickly
        // instead of leaving a request hanging for the default 60s.
        request.timeoutInterval = 15

        return request
    }
}
