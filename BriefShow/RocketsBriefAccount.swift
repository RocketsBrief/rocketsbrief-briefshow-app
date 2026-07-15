import Foundation
import Security
import Combine

enum RocketsBriefConfig {
    static let supabaseURL = "https://gzbkpnogeegyntoznzzn.supabase.co"
    static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imd6Ymtwbm9nZWVneW50b3puenpuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODEwOTc3MzksImV4cCI6MjA5NjY3MzczOX0.oWImudetcwAemwZTRRERWRNPQ4PmCRRhZVHRwnY7mhY"
    static let profileIconBaseURL = "https://rocketsbrief.com/profile-icons"

    static let profileIconKeys = [
        "blue-planet", "yellow-planet", "orange-planet", "planet-ring",
        "space-capsule", "satelite", "burning-comet", "asteroid",
        "galaxy", "space-helmet"
    ]
}

struct RocketsBriefSession: Codable {
    var accessToken: String
    var refreshToken: String
    var userId: String
    var email: String
    var name: String
    var avatarKey: String
}

enum KeychainStore {
    private static let service = "com.rocketsbrief.briefshow.session"
    private static let account = "rocketsbrief-session"

    static func save(_ session: RocketsBriefSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var newItem = query
        newItem[kSecValueData as String] = data
        SecItemAdd(newItem as CFDictionary, nil)
    }

    static func load() -> RocketsBriefSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(RocketsBriefSession.self, from: data)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class AccountManager: ObservableObject {
    static let shared = AccountManager()

    @Published private(set) var session: RocketsBriefSession?
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var pendingConfirmationEmail: String?

    private init() {
        session = KeychainStore.load()
        if session != nil {
            Task { await refreshSessionIfNeeded() }
        }
    }

    var isSignedIn: Bool {
        session != nil
    }

    func signUp(name: String, email: String, password: String) async {
        errorMessage = nil
        pendingConfirmationEmail = nil
        isBusy = true
        defer { isBusy = false }

        guard let url = URL(string: "\(RocketsBriefConfig.supabaseURL)/auth/v1/signup") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(RocketsBriefConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")

        let body: [String: Any] = [
            "email": email,
            "password": password,
            "data": ["name": name, "source": "briefshow_app"]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
                errorMessage = message ?? equalizedSignupErrorMessage(data)
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorMessage = "Unexpected response from server."
                return
            }

            if json["access_token"] as? String != nil {
                await performAuthRequest(request, fallbackName: name)
                return
            }

            pendingConfirmationEmail = email
        } catch {
            errorMessage = "Couldn't reach RocketsBrief. Check your internet connection."
        }
    }

    private func equalizedSignupErrorMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["msg"] as? String {
            return message
        }
        return "Sign up failed. Please try again."
    }

    func signIn(email: String, password: String) async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }

        guard let url = URL(string: "\(RocketsBriefConfig.supabaseURL)/auth/v1/token?grant_type=password") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(RocketsBriefConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")

        let body: [String: Any] = ["email": email, "password": password]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        await performAuthRequest(request, fallbackName: nil)
    }

    func signOut() {
        session = nil
        KeychainStore.clear()
    }

    func refreshSessionIfNeeded() async {
        guard let current = session else { return }
        guard let url = URL(string: "\(RocketsBriefConfig.supabaseURL)/auth/v1/token?grant_type=refresh_token") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(RocketsBriefConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": current.refreshToken])

        await performAuthRequest(request, fallbackName: current.name, existingAvatarKey: current.avatarKey)
    }

    private func performAuthRequest(_ request: URLRequest, fallbackName: String?, existingAvatarKey: String? = nil) async {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
                errorMessage = message ?? "Sign in failed. Check your email and password."
                if existingAvatarKey == nil {
                    signOut()
                }
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String,
                  let refreshToken = json["refresh_token"] as? String,
                  let user = json["user"] as? [String: Any],
                  let userId = user["id"] as? String,
                  let email = user["email"] as? String
            else {
                errorMessage = "Unexpected response from server."
                return
            }

            let metadata = user["user_metadata"] as? [String: Any]
            let name = (metadata?["name"] as? String) ?? fallbackName ?? email

            let avatarKey: String
            if let existingAvatarKey {
                avatarKey = existingAvatarKey
            } else {
                avatarKey = await fetchOrAssignAvatarKey(userId: userId, accessToken: accessToken)
            }

            let newSession = RocketsBriefSession(
                accessToken: accessToken,
                refreshToken: refreshToken,
                userId: userId,
                email: email,
                name: name,
                avatarKey: avatarKey
            )

            session = newSession
            KeychainStore.save(newSession)
        } catch {
            errorMessage = "Couldn't reach RocketsBrief. Check your internet connection."
        }
    }

    private func fetchOrAssignAvatarKey(userId: String, accessToken: String) async -> String {
        guard let url = URL(string: "\(RocketsBriefConfig.supabaseURL)/rest/v1/user_profile_settings?user_id=eq.\(userId)&select=avatar_key") else {
            return RocketsBriefConfig.profileIconKeys[0]
        }

        var request = URLRequest(url: url)
        request.setValue(RocketsBriefConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        if let (data, _) = try? await URLSession.shared.data(for: request),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let key = rows.first?["avatar_key"] as? String {
            return key
        }

        let randomKey = RocketsBriefConfig.profileIconKeys.randomElement() ?? RocketsBriefConfig.profileIconKeys[0]
        await upsertAvatarKey(userId: userId, accessToken: accessToken, avatarKey: randomKey)
        return randomKey
    }

    private func upsertAvatarKey(userId: String, accessToken: String, avatarKey: String) async {
        guard let url = URL(string: "\(RocketsBriefConfig.supabaseURL)/rest/v1/user_profile_settings") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(RocketsBriefConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["user_id": userId, "avatar_key": avatarKey])

        _ = try? await URLSession.shared.data(for: request)
    }
}

struct RemoteAppConfig: Codable {
    var appKey: String
    var latestVersion: String
    var downloadUrl: String?
    var releaseNotes: String?
    var isLocked: Bool
    var lockMessage: String?

    enum CodingKeys: String, CodingKey {
        case appKey = "app_key"
        case latestVersion = "latest_version"
        case downloadUrl = "download_url"
        case releaseNotes = "release_notes"
        case isLocked = "is_locked"
        case lockMessage = "lock_message"
    }
}

@MainActor
final class AppRemoteStatus: ObservableObject {
    static let shared = AppRemoteStatus()

    @Published var config: RemoteAppConfig?
    @Published var checkFailed = false

    private init() {}

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var isUpdateAvailable: Bool {
        guard let latest = config?.latestVersion else { return false }
        return latest.compare(currentVersion, options: .numeric) == .orderedDescending
    }

    var isLocked: Bool {
        config?.isLocked ?? false
    }

    func refresh() async {
        guard let url = URL(string: "\(RocketsBriefConfig.supabaseURL)/rest/v1/app_config?app_key=eq.briefshow&select=*") else { return }

        var request = URLRequest(url: url)
        request.setValue(RocketsBriefConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let rows = try JSONDecoder().decode([RemoteAppConfig].self, from: data)
            config = rows.first
            checkFailed = false
        } catch {
            checkFailed = true
        }
    }
}
