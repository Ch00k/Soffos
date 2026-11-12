import CryptoKit
import Foundation
import Security

/// OAuth tokens for the Spotify Web API.
public struct SpotifyTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    var isExpiringSoon: Bool { expiresAt.timeIntervalSinceNow < 60 }
}

public enum SpotifyAuthError: Error, LocalizedError {
    case notSignedIn
    case missingClientID
    case tokenExchange(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in to Spotify"
        case .missingClientID: "Set your Spotify Client ID in Settings first"
        case let .tokenExchange(detail): "Spotify sign-in failed: \(detail)"
        }
    }
}

/// Authorization Code with PKCE. No client secret is needed, so the app can
/// be distributed as-is: each user registers their own Spotify app and pastes
/// its Client ID.
public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String
    public let state: String

    public init() {
        let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        verifier = String((0..<64).map { _ in charset.randomElement()! })
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        state = UUID().uuidString
    }

    public func authorizeURL(clientID: String, redirectURI: String, scopes: [String]) -> URL {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            .init(name: "scope", value: scopes.joined(separator: " ")),
        ]
        return components.url!
    }
}

/// Owns the tokens: refreshes them when they're about to expire and
/// persists them in `storage`.
public actor SpotifyTokenStore {
    private let storage: TokenStorage
    private var tokens: SpotifyTokens?
    private var refreshTask: Task<SpotifyTokens, Error>?
    private let session: URLSession

    public init(storage: TokenStorage, session: URLSession = .shared) {
        self.storage = storage
        self.session = session
        tokens = storage.read().flatMap { try? JSONDecoder().decode(SpotifyTokens.self, from: $0) }
    }

    public var isSignedIn: Bool { tokens != nil }

    public func exchange(code: String, pkce: PKCE, clientID: String, redirectURI: String) async throws {
        let new = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": pkce.verifier,
        ], previous: nil)
        store(new)
    }

    /// A valid access token, refreshing if needed. Concurrent callers share
    /// one refresh request.
    public func accessToken(clientID: String) async throws -> String {
        guard let current = tokens else { throw SpotifyAuthError.notSignedIn }
        if !current.isExpiringSoon { return current.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }

        let task = Task {
            try await tokenRequest([
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
                "client_id": clientID,
            ], previous: current)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let new = try await task.value
            store(new)
            return new.accessToken
        } catch SpotifyAuthError.tokenExchange(let detail) where detail.contains("invalid_grant") {
            // The refresh token was revoked, so sign out.
            signOut()
            throw SpotifyAuthError.notSignedIn
        }
    }

    /// Forces a refresh on the next request (after a 401).
    public func invalidateAccessToken() {
        tokens?.expiresAt = .distantPast
    }

    public func signOut() {
        tokens = nil
        storage.delete()
    }

    private func store(_ new: SpotifyTokens) {
        tokens = new
        if let data = try? JSONEncoder().encode(new) {
            storage.write(data)
        }
    }

    private func tokenRequest(_ form: [String: String], previous: SpotifyTokens?) async throws -> SpotifyTokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.formEncoded.utf8)

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SpotifyAuthError.tokenExchange(String(decoding: data, as: UTF8.self))
        }
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
        }
        let r = try JSONDecoder().decode(Response.self, from: data)
        guard let refresh = r.refresh_token ?? previous?.refreshToken else {
            throw SpotifyAuthError.tokenExchange("no refresh token returned")
        }
        return SpotifyTokens(
            accessToken: r.access_token,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(r.expires_in)
        )
    }
}

/// Where the tokens are persisted.
public enum TokenStorage: Sendable {
    /// A generic password in the login Keychain.
    case keychain(service: String)
    /// A JSON file readable only by the user.
    case file(URL)

    func read() -> Data? {
        switch self {
        case let .keychain(service): Self.keychainRead(service: service)
        case let .file(url): try? Data(contentsOf: url)
        }
    }

    func write(_ data: Data) {
        switch self {
        case let .keychain(service):
            Self.keychainWrite(data, service: service)
        case let .file(url):
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func delete() {
        switch self {
        case let .keychain(service): Self.keychainDelete(service: service)
        case let .file(url): try? FileManager.default.removeItem(at: url)
        }
    }

    private static func keychainRead(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "tokens",
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func keychainWrite(_ data: Data, service: String) {
        keychainDelete(service: service)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "tokens",
            kSecValueData as String: data,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func keychainDelete(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "tokens",
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension [String: String] {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }
}
