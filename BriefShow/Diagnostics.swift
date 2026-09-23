import Foundation
import AppKit
import Combine

/// ⚠️ WHAT THE APP WAS DOING WHEN IT STOPPED ANSWERING, sent home.
///
/// Asked for on 23.09 after a real shoot took three times as long as in
/// Lightroom: *„da se informacije posalju u supabase dok radim na kompanijskom
/// kompu pa posle kad dodjem kuci ti da vidis i proveris u cemu je problem"*.
/// The freezes he reports — the crop that locks until Escape, the whole app
/// slowing after a while — happen on his machines and his folders, and this
/// Mac (8 GB, different photos) does not reproduce them on demand.
///
/// Two kinds of row:
/// - **hang**: the main thread did not answer for ≥ 250 ms. A watchdog thread
///   posts a block to the main queue and times the reply, so the number is
///   exactly how long a click would have waited. Stored with the context that
///   was current when it began: key window, the last input event, the tool
///   and file open in Create, and the process's memory.
/// - **heartbeat**: every five minutes — memory, CPU time, uptime. "It gets
///   slower after a while" is a curve; this is its x axis.
///
/// ⚠️ OPT-IN, off by default (`diagnostics.sendToRocketsBrief`, the toggle is
/// in the profile card). The client chose numbers PLUS file names on 23.09;
/// that is fine for his own machines and is NOT something to switch on for
/// every studio that installs the app. The pixels of a photo are never sent.
/// A local copy is always written to Application Support/Diagnostics, so a
/// freeze on a Mac with no network is still on disk.
///
/// Table: `briefshow_diagnostics` in the RocketsBrief project, insert-only for
/// the anon key — see Tools/diagnostics.sql.
final class Diagnostics {
    static let shared = Diagnostics()
    static let enabledKey = "diagnostics.sendToRocketsBrief"

    /// A main-thread stall shorter than this is not logged.
    static let hangThreshold: TimeInterval = 0.25
    private static let probeInterval: TimeInterval = 0.1
    private static let heartbeatInterval: TimeInterval = 300
    private static let uploadInterval: TimeInterval = 60
    private static let maxQueued = 500

    private let lock = NSLock()
    private var queue: [[String: Any]] = []

    // Context — written on the main thread, read by the watchdog.
    private var keyWindowTitle = ""
    private var lastEvent = ""
    private var createTool = ""
    private var createFile = ""
    private var activity = ""
    /// A hang logged while the app was in the background is usually App Nap
    /// or a sleeping Mac, not something the client waited on.
    private var appActive = true

    private let launchedAt = Date()
    private let sessionID = UUID().uuidString
    private var started = false
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    var isSendingEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - Context

    func setCreateFile(_ url: URL?) {
        lock.lock(); createFile = url?.lastPathComponent ?? ""; lock.unlock()
    }

    func setCreateTool(_ tool: String) {
        lock.lock(); createTool = tool; lock.unlock()
    }

    /// A named piece of work that is known to be long (an export, a batch).
    /// Cleared with `nil`. Lets a hang be read as "during the export" rather
    /// than guessed at.
    func setActivity(_ name: String?) {
        lock.lock(); activity = name ?? ""; lock.unlock()
    }

    private func context() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return ["window": keyWindowTitle, "event": lastEvent, "tool": createTool,
                "file": createFile, "activity": activity, "active": appActive]
    }

    // MARK: - Start

    /// Called once, from the main thread, at launch.
    func start() {
        guard !started else { return }
        started = true

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            let title = (note.object as? NSWindow)?.title ?? ""
            self?.lock.lock(); self?.keyWindowTitle = title; self?.lock.unlock()
        })

        for (name, active) in [(NSApplication.didBecomeActiveNotification, true),
                               (NSApplication.didResignActiveNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.lock.lock(); self?.appActive = active; self?.lock.unlock()
            })
        }

        // The last input, by KIND only. Never the characters of a key press —
        // a preset name or a folder name being typed is nobody's business;
        // a shortcut (⌘ held) is recorded by key code, which is what tells
        // ⌘A from ⌘E.
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown,
                       .keyDown, .scrollWheel]
        ) { [weak self] event in
            self?.record(event)
            return event
        }

        let watchdog = Thread { [weak self] in self?.watch() }
        watchdog.name = "C4S diagnostics watchdog"
        watchdog.qualityOfService = .utility
        watchdog.start()

        Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.enqueue(kind: "heartbeat", durationMs: nil)
        }
        Timer.scheduledTimer(withTimeInterval: Self.uploadInterval, repeats: true) { [weak self] _ in
            self?.upload()
        }
        enqueue(kind: "launch", durationMs: nil)
    }

    private func record(_ event: NSEvent) {
        let name: String
        switch event.type {
        case .leftMouseDown: name = "mouseDown"
        case .leftMouseDragged: name = "drag"
        case .leftMouseUp: name = "mouseUp"
        case .rightMouseDown: name = "rightClick"
        case .scrollWheel: name = "scroll"
        case .keyDown:
            let command = event.modifierFlags.contains(.command)
            name = command ? "⌘key\(event.keyCode)" : "key\(event.keyCode)"
        default: name = "other"
        }
        lock.lock()
        // Consecutive drags collapse into one entry; the interesting part is
        // WHAT was being dragged, which is the window and tool beside it.
        lastEvent = name
        lock.unlock()
    }

    // MARK: - Watchdog

    private func watch() {
        while true {
            Thread.sleep(forTimeInterval: Self.probeInterval)
            let answered = DispatchSemaphore(value: 0)
            let sent = Date()
            // Captured BEFORE waiting: after a long hang, the context is
            // whatever the unfrozen app did next.
            let before = context()
            DispatchQueue.main.async { answered.signal() }
            if answered.wait(timeout: .now() + Self.hangThreshold) == .success {
                continue
            }
            answered.wait()
            let ms = Int(Date().timeIntervalSince(sent) * 1000)
            enqueue(kind: "hang", durationMs: ms, context: before)
        }
    }

    // MARK: - Rows

    private func enqueue(kind: String, durationMs: Int?, context given: [String: Any]? = nil) {
        let ctx = given ?? context()
        var row: [String: Any] = [
            "session_id": sessionID,
            "kind": kind,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "machine": Self.machineDescription,
            "uptime_s": Int(Date().timeIntervalSince(launchedAt)),
            "memory_mb": Self.footprintMB(),
            "cpu_s": Self.cpuSeconds(),
            "window": ctx["window"] ?? "",
            "event": ctx["event"] ?? "",
            "tool": ctx["tool"] ?? "",
            "file_name": ctx["file"] ?? "",
            "activity": ctx["activity"] ?? "",
            "app_active": ctx["active"] ?? true,
            "created_at": ISO8601DateFormatter().string(from: Date()),
        ]
        if let durationMs { row["duration_ms"] = durationMs }
        if let email = UserDefaults.standard.string(forKey: Self.accountEmailKey) {
            row["account_email"] = email
        }

        writeLocal(row)

        lock.lock()
        queue.append(row)
        if queue.count > Self.maxQueued { queue.removeFirst(queue.count - Self.maxQueued) }
        lock.unlock()
    }

    /// Set by the account layer when a session exists, so rows from two
    /// studios are never mixed up. Stored by AccountManager.
    static let accountEmailKey = "diagnostics.accountEmail"

    // MARK: - Upload

    private func upload() {
        guard isSendingEnabled else {
            // Nothing leaves the Mac. The local file still has it all.
            lock.lock(); queue.removeAll(); lock.unlock()
            return
        }
        lock.lock()
        let batch = queue
        queue.removeAll()
        lock.unlock()
        guard !batch.isEmpty,
              let url = URL(string: "\(RocketsBriefConfig.supabaseURL)/rest/v1/briefshow_diagnostics"),
              let body = try? JSONSerialization.data(withJSONObject: batch) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(RocketsBriefConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(RocketsBriefConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error != nil || !(200..<300).contains(status) else { return }
            // Offline or refused: put the rows back for the next minute.
            guard let self else { return }
            self.lock.lock()
            self.queue.insert(contentsOf: batch, at: 0)
            if self.queue.count > Self.maxQueued { self.queue.removeLast(self.queue.count - Self.maxQueued) }
            self.lock.unlock()
        }.resume()
    }

    /// Last chance at quit — best effort, the local file has it regardless.
    func flushAtQuit() {
        enqueue(kind: "quit", durationMs: nil)
        upload()
    }

    // MARK: - Local copy

    private static let localURL: URL? = {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return nil }
        let folder = support.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("diagnostics.jsonl")
    }()

    private let fileQueue = DispatchQueue(label: "C4S diagnostics file", qos: .utility)

    private func writeLocal(_ row: [String: Any]) {
        fileQueue.async {
            guard let url = Self.localURL,
                  var line = try? JSONSerialization.data(withJSONObject: row) else { return }
            line.append(0x0A)
            // Capped at 5 MB: the newest half is kept.
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
               size > 5_000_000,
               let data = try? Data(contentsOf: url) {
                try? data.suffix(2_500_000).write(to: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                try? line.write(to: url)
            }
        }
    }

    // MARK: - Machine numbers

    private static let machineDescription: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let ramGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(String(cString: model)) \(arch) \(ramGB)GB \(ProcessInfo.processInfo.activeProcessorCount)c macOS \(os)"
    }()

    /// The number Activity Monitor calls "Memory".
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / 1_048_576)
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return (user + system).rounded()
    }
}
