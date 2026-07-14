import Foundation
import Security

private struct StringError: Error {
    enum Kind { case unauthorized, rateLimited, other }
    let message: String
    var kind: Kind = .other
}

enum ClaudeLimitsReader {
    private static let service = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Read-only: uses the access token the Claude CLI already stored in the
    /// login keychain. We never refresh or write back — refresh tokens are
    /// single-use, so rotating one here would invalidate the CLI's own token
    /// and log the user out.
    ///
    /// We do NOT trust the stored `expiresAt`: observed tokens keep working
    /// well past that timestamp, so authority is the server's response — 401
    /// means re-login is actually needed, 200 means the token is live.
    static func fetch() -> ClaudeLimits {
        var out = ClaudeLimits()
        guard let creds = readKeychainCredentials() else {
            out.state = .notLoggedIn
            return out
        }
        switch callUsage(token: creds.accessToken) {
        case .failure(let e):
            switch e.kind {
            case .unauthorized: out.state = .stale
            case .rateLimited: out.state = .rateLimited
            case .other: out.state = .error(e.message)
            }
        case .success(let json):
            out.fiveHour = parseWindow(json["five_hour"])
            out.sevenDay = parseWindow(json["seven_day"])
            out.state = (out.fiveHour == nil && out.sevenDay == nil) ? .error("no limit data") : .ok
        }
        return out
    }

    // MARK: - Keychain

    private struct Credentials { var accessToken: String; var expiresAt: Date? }

    private static func readKeychainCredentials() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let exp = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(accessToken: token, expiresAt: exp)
    }

    // MARK: - HTTP

    private static func callUsage(token: String) -> Result<[String: Any], StringError> {
        var req = URLRequest(url: usageURL, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Match the CLI's client fingerprint so the edge treats us the same.
        req.setValue("claude-cli/2.1.202 (external, cli)", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], StringError> = .failure(StringError(message: "no response"))
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { result = .failure(StringError(message: err.localizedDescription)); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data else { result = .failure(StringError(message: "empty (\(code))")); return }
            guard code == 200 else {
                switch code {
                case 401: result = .failure(StringError(message: "auth expired", kind: .unauthorized))
                case 429: result = .failure(StringError(message: "rate limited", kind: .rateLimited))
                default:  result = .failure(StringError(message: "HTTP \(code)"))
                }
                return
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                result = .success(obj)
            } else {
                result = .failure(StringError(message: "bad JSON"))
            }
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 12)
        return result
    }

    // MARK: - Parsing

    private static let iso = ISO8601DateFormatter()

    private static func parseWindow(_ raw: Any?) -> LimitWindow? {
        guard let d = raw as? [String: Any] else { return nil }
        guard let util = (d["utilization"] as? Double) ?? (d["utilization"] as? Int).map(Double.init)
        else { return nil }
        let reset = (d["resets_at"] as? String).flatMap { iso.date(from: $0) }
        return LimitWindow(usedPercent: util, resetsAt: reset)
    }
}
