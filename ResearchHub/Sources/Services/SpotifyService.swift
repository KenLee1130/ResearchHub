#if os(iOS)
import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit
import HubCore

/// 連 Spotify 帳號，查「某段時間聽了哪些歌」。
///
/// 用 Spotify Web API 的 Authorization Code + PKCE：不需要 client secret，
/// 使用者在 developer.spotify.com 建一個 app、把 Client ID 貼進設定即可。
/// refresh token 存鑰匙圈；access token 只放記憶體（一小時過期，用 refresh token 換新的）。
/// 只要兩個唯讀權限：最近播放、正在播放。
@MainActor
@Observable
final class SpotifyService: NSObject {
    static let shared = SpotifyService()

    /// 要在 Spotify app 設定裡登記的 Redirect URI（一字不差）
    static let redirectURI = "researchhub://spotify-callback"
    private static let scopes = "user-read-recently-played user-read-currently-playing"
    private static let clientIDKey = "spotify.clientID"

    var clientID: String {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespaces), forKey: Self.clientIDKey) }
    }
    private(set) var isConnected = false
    private(set) var isConnecting = false
    var lastError: String?

    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessTokenExpiry: Date = .distantPast
    @ObservationIgnored private var authSession: ASWebAuthenticationSession?

    override private init() {
        clientID = UserDefaults.standard.string(forKey: Self.clientIDKey) ?? ""
        super.init()
        isConnected = Keychain.read() != nil
    }

    var isConfigured: Bool { !clientID.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: - 連結 / 中斷

    func connect() async {
        guard isConfigured, !isConnecting else { return }
        isConnecting = true
        lastError = nil
        defer { isConnecting = false }

        let verifier = Self.randomVerifier()
        let challenge = Self.challenge(for: verifier)
        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: Self.scopes),
        ]
        do {
            let callback = try await authenticate(url: comps.url!)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let err = items.first(where: { $0.name == "error" })?.value {
                lastError = err == "access_denied" ? L("你在 Spotify 取消了授權") : err
                return
            }
            guard let code = items.first(where: { $0.name == "code" })?.value else {
                lastError = L("Spotify 沒有回傳授權碼")
                return
            }
            try await requestToken([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": Self.redirectURI,
                "client_id": clientID,
                "code_verifier": verifier,
            ])
            isConnected = true
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            // 使用者自己關掉登入頁，不算錯
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disconnect() {
        Keychain.delete()
        accessToken = nil
        accessTokenExpiry = .distantPast
        isConnected = false
    }

    private func authenticate(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("researchhub")) { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? URLError(.badServerResponse)) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authSession = session
            session.start()
        }
    }

    // MARK: - Token

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
    }

    private func requestToken(_ form: [String: String]) async throws {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            if (response as? HTTPURLResponse)?.statusCode == 400, form["grant_type"] == "refresh_token" {
                disconnect()   // refresh token 被撤銷：要重新連結
            }
            throw SpotifyError.token(String(data: data, encoding: .utf8) ?? "")
        }
        accessToken = token.access_token
        accessTokenExpiry = Date.now.addingTimeInterval(TimeInterval(token.expires_in - 60))
        if let refresh = token.refresh_token { Keychain.save(refresh) }
    }

    private func validAccessToken() async throws -> String {
        if let accessToken, accessTokenExpiry > .now { return accessToken }
        guard let refresh = Keychain.read() else { throw SpotifyError.notConnected }
        try await requestToken(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        guard let accessToken else { throw SpotifyError.notConnected }
        return accessToken
    }

    // MARK: - 查歌

    /// [start, end] 這段時間聽了哪些歌（舊到新）。Spotify 只留最近 50 首，所以很長的一段只拿得到後面的。
    func tracks(from start: Date, to end: Date) async throws -> [SpotifyTrack] {
        let token = try await validAccessToken()
        let afterMs = Int64(start.timeIntervalSince1970 * 1000)
        var recentReq = URLRequest(url: URL(string:
            "https://api.spotify.com/v1/me/player/recently-played?limit=50&after=\(afterMs)")!)
        recentReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var currentReq = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
        currentReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        async let recent = URLSession.shared.data(for: recentReq)
        async let current = URLSession.shared.data(for: currentReq)
        let (recentData, recentResp) = try await recent
        guard (recentResp as? HTTPURLResponse)?.statusCode == 200 else {
            throw SpotifyError.api((recentResp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let list = SpotifyListening.recentlyPlayed(recentData, from: start, to: end)
        // 正在播的那首（查不到就算了）
        let nowPlaying = (try? await current).flatMap { data, resp -> SpotifyTrack? in
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return SpotifyListening.currentlyPlaying(data, at: end)
        }
        return SpotifyListening.merge(list, current: nowPlaying)
    }

    enum SpotifyError: LocalizedError {
        case notConnected, token(String), api(Int)
        var errorDescription: String? {
            switch self {
            case .notConnected: return L("還沒連結 Spotify")
            case .token(let body): return L("Spotify 登入失敗：\(body)")
            case .api(let code): return L("Spotify 回應錯誤（\(code)）")
            }
        }
    }

    // MARK: - PKCE

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - 鑰匙圈（只存 refresh token）

    private enum Keychain {
        static let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ResearchHub.spotify",
            kSecAttrAccount as String: "refreshToken",
        ]

        static func save(_ token: String) {
            delete()
            var add = query
            add[kSecValueData as String] = Data(token.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }

        static func read() -> String? {
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        static func delete() {
            SecItemDelete(query as CFDictionary)
        }
    }
}

extension SpotifyService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return key }
            // 按「連結」一定是從畫面上的某個 scene 按的，所以至少有一個
            return ASPresentationAnchor(windowScene: scenes[0])
        }
    }
}
#endif
