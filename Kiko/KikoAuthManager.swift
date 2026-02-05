import Combine
import SwiftUI

@MainActor
class KikoAuthManager: NSObject, ObservableObject {

    static let shared = KikoAuthManager()

    @Published var authToken: String? = nil
    @Published var isAuthenticated = false
    @Published var isAuthenticating = false
    @Published var lastError: Error? = nil
    @Published var areaId: String? = nil
    @Published var areaName: String? = nil
    @Published var isPremium = false
    @Published var email = ""
    @Published var password = ""
    @Published var sessionCookie: String? = nil

    private let authKey = "bcd151073c03b352e1ef2fd66c32209da9ca0afa"
    private let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    override private init() {
        super.init()
        self.email = UserDefaults.standard.string(forKey: "radiko_email") ?? ""
        self.password = UserDefaults.standard.string(forKey: "radiko_password") ?? ""
    }

    private var authTask: Task<Void, Never>?

    func authenticate(forceRefresh: Bool = false) async {
        // If a task is already running, wait for it to finish
        if let task = authTask {
            if !forceRefresh {
                // If we don't strictly need a forced refresh, just wait for the current one
                await task.value
                return
            } else {
                // If we DO need a forced refresh, we might need to cancel the existing one or just run a new one after?
                // For simplicity, let's allow a new task if forceRefresh is requested,
                // but strictly speaking, we should just ensure a fresh run.
                // If the current task is running, it might arguably be "fresh enough", but if forceRefresh comes from a failure,
                // we assume the current state (even if just refreshed) might be bad?
                // No, usually forceRefresh means "I tried, failed, now I want to ensure a clean slate".
            }
        }

        let task = Task {
            isAuthenticating = true
            lastError = nil

            if forceRefresh {
                print("Force refresh requested. Clearing session and token.")
                // Only clear session cookie if we have credentials to re-login,
                // otherwise we might lose a persistent session?
                // Actually, if we have email/pass, we can always get a new cookie.
                if !email.isEmpty && !password.isEmpty {
                    self.sessionCookie = nil
                }
                self.authToken = nil
                self.isAuthenticated = false
            }

            do {
                // 0. Login check (if email/pass provided but no session)
                if !email.isEmpty && !password.isEmpty && sessionCookie == nil {
                    try await login()
                }

                // 1. Auth1
                let (token, partialKey) = try await performAuth1()

                // 2. Auth2
                try await performAuth2(token: token, partialKey: partialKey)

                self.authToken = token
                self.isAuthenticated = true
                print(
                    "Successfully authenticated with Radiko. Token: \(token.prefix(5))..., AreaID: \(self.areaId ?? "nil")"
                )
            } catch {
                self.lastError = error
                self.isAuthenticated = false
                print("❌ Authentication failed: \(error)")
                let nsError = error as NSError
                print("Error Domain: \(nsError.domain), Code: \(nsError.code)")
                print("Error UserInfo: \(nsError.userInfo)")
            }

            isAuthenticating = false
            self.authTask = nil
        }

        self.authTask = task
        await task.value
    }

    func login() async throws {
        let url = URL(string: "https://radiko.jp/ap/member/webapi/member/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.addValue("https://radiko.jp/", forHTTPHeaderField: "Referer")

        request.addValue("pc_html5", forHTTPHeaderField: "X-Radiko-App")
        request.addValue("0.0.1", forHTTPHeaderField: "X-Radiko-App-Version")
        request.addValue("pc", forHTTPHeaderField: "X-Radiko-Device")
        request.addValue("dummy_user", forHTTPHeaderField: "X-Radiko-User")
        request.addValue("pc_html5_key", forHTTPHeaderField: "X-Radiko-App-Key")

        let escapedMail = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let escapedPass =
            password.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let body = "mail=\(escapedMail)&pass=\(escapedPass)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return }

        if httpResponse.statusCode == 200 {
            // Extract all cookies from Set-Cookie headers using HTTPCookie
            if let headerFields = httpResponse.allHeaderFields as? [String: String],
                let url = httpResponse.url
            {
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
                // Combine into a single "key=value; key2=value2" string
                let cookieString = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                self.sessionCookie = cookieString

                // Save credentials on successful login
                UserDefaults.standard.set(self.email, forKey: "radiko_email")
                UserDefaults.standard.set(self.password, forKey: "radiko_password")

                if let sessionToken = cookies.first(where: { $0.name == "radiko_session" })?.value {
                    print("✅ Found radiko_session: \(sessionToken.prefix(5))...")
                }
                if let sslToken = cookies.first(where: { $0.name == "ssl_token" })?.value {
                    print("✅ Found ssl_token: \(sslToken.prefix(5))...")
                }
            } else {
                print("⚠️ No Set-Cookie headers found in login response")
            }

            // Verify login status and Premium status
            try await loginCheck()
        } else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            print("Login failed body: \(body)")
            print("Login failed with status: \(httpResponse.statusCode)")
            throw NSError(
                domain: "RadikoAuth", code: 3, userInfo: [NSLocalizedDescriptionKey: "Login failed"]
            )
        }
    }

    func loginCheck() async throws {
        let url = URL(string: "https://radiko.jp/ap/member/webapi/member/login/check")!
        var request = URLRequest(url: url)
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue("pc_html5", forHTTPHeaderField: "X-Radiko-App")
        request.addValue("0.0.1", forHTTPHeaderField: "X-Radiko-App-Version")
        request.addValue("pc", forHTTPHeaderField: "X-Radiko-Device")
        request.addValue("dummy_user", forHTTPHeaderField: "X-Radiko-User")
        request.addValue("pc_html5_key", forHTTPHeaderField: "X-Radiko-App-Key")
        if let session = sessionCookie {
            request.addValue(session, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(
                domain: "RadikoAuth", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Login check failed"])
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let status = json["status"] as? String ?? ""
            let isPaid = json["paid_member"] as? String == "1"

            if status == "200" && isPaid {
                self.isPremium = true
                print("Confirmed Premium status")
            } else {
                self.isPremium = false
                print("Confirmed Non-Premium status (\(status), paid=\(isPaid))")
            }
        }
    }

    private func performAuth1() async throws -> (String, String) {
        let url = URL(string: "https://radiko.jp/v2/api/auth1")!
        var request = URLRequest(url: url)
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue("pc_html5", forHTTPHeaderField: "X-Radiko-App")
        request.addValue("0.0.1", forHTTPHeaderField: "X-Radiko-App-Version")
        request.addValue("pc", forHTTPHeaderField: "X-Radiko-Device")
        request.addValue("dummy_user", forHTTPHeaderField: "X-Radiko-User")
        request.addValue("pc_html5_key", forHTTPHeaderField: "X-Radiko-App-Key")

        if let session = sessionCookie {
            request.addValue(session, forHTTPHeaderField: "Cookie")
        }

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let headers = httpResponse.allHeaderFields
        let token =
            headers.first { ($0.key as? String)?.lowercased() == "x-radiko-authtoken" }?.value
            as? String ?? ""
        let lenStr =
            headers.first { ($0.key as? String)?.lowercased() == "x-radiko-keylength" }?.value
            as? String ?? "0"
        let offStr =
            headers.first { ($0.key as? String)?.lowercased() == "x-radiko-keyoffset" }?.value
            as? String ?? "0"

        guard let length = Int(lenStr), let offset = Int(offStr), !token.isEmpty else {
            throw NSError(
                domain: "RadikoAuth", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to get auth headers"])
        }

        // Key Calculation
        let longKey = authKey + authKey
        let start = longKey.index(longKey.startIndex, offsetBy: offset)
        let end = longKey.index(start, offsetBy: length)
        let partialKey = Data(String(longKey[start..<end]).utf8).base64EncodedString()

        return (token, partialKey)
    }

    private func performAuth2(token: String, partialKey: String) async throws {
        let url = URL(string: "https://radiko.jp/v2/api/auth2")!
        var request = URLRequest(url: url)
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue("pc_html5", forHTTPHeaderField: "X-Radiko-App")
        request.addValue("0.0.1", forHTTPHeaderField: "X-Radiko-App-Version")
        request.addValue("pc", forHTTPHeaderField: "X-Radiko-Device")
        request.addValue("dummy_user", forHTTPHeaderField: "X-Radiko-User")
        request.addValue("pc_html5_key", forHTTPHeaderField: "X-Radiko-App-Key")
        request.addValue(token, forHTTPHeaderField: "X-Radiko-AuthToken")
        request.addValue(partialKey, forHTTPHeaderField: "X-Radiko-PartialKey")

        if let session = sessionCookie {
            request.addValue(session, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status != 200 {
            throw NSError(
                domain: "RadikoAuth", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Auth2 failed with status \(status)"])
        }

        if let body = String(data: data, encoding: .utf8) {
            print("Auth2 Response Body: \(body)")
            // Usually format is "JP13,東京都,tokyo,Japan"
            let components = body.components(separatedBy: ",")
            if let area = components.first {
                let name = components.count > 1 ? components[1] : nil
                DispatchQueue.main.async {
                    self.areaId = area
                    self.areaName = name
                }
                print("✅ Auth2 AreaID: \(area), Name: \(name ?? "nil")")
            } else {
                print("⚠️ Failed to parse area ID from body: \(body)")
            }
        } else {
            print("⚠️ Failed to decode Auth2 response body")
        }

        // Log headers to see if we get any useful info
        if let httpResponse = response as? HTTPURLResponse {
            print("Auth2 Headers: \(httpResponse.allHeaderFields)")
        }
    }
}
