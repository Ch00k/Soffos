import AppKit
import AuthenticationServices
import Foundation
import Observation
import SpotifyKit

@Observable
@MainActor
final class SpotifyStore {
    static let redirectScheme = "soffos"
    static let redirectURI = "\(redirectScheme)://callback"

    private(set) var isSignedIn = false
    private(set) var isSigningIn = false
    private(set) var user: SpotifyUser?
    var lastError: String?
    /// A short confirmation shown briefly, e.g. "Added to Road Trip".
    private(set) var notice: String?

    // Library caches, loaded on demand by the views.
    private(set) var playlists: [SpotifyPlaylist]?
    private(set) var albums: [SpotifyAlbum]?
    private(set) var artists: [SpotifyArtist]?
    private(set) var likedSongs: [SpotifyTrack]?
    private(set) var recent: [SpotifyTrack]?

    /// Dev builds keep the tokens in a file: each rebuild changes the binary
    /// a Keychain item is tied to (the dev certificate has no Team ID), and
    /// macOS then asks for the keychain password.
    let tokens = SpotifyTokenStore(storage: AppIdentity.isDev
        ? .file(AppIdentity.supportDirectory.appendingPathComponent("spotify-tokens.json"))
        : .keychain(service: "\(AppIdentity.bundleID).spotify"))
    private let settings: AppSettings
    private let log: AppLog
    @ObservationIgnored private var authSession: ASWebAuthenticationSession?
    @ObservationIgnored private let presentationProvider = AuthPresentationProvider()

    init(settings: AppSettings, log: AppLog) {
        self.settings = settings
        self.log = log
    }

    var api: SpotifyAPI {
        SpotifyAPI(tokens: tokens, clientID: settings.spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var hasClientID: Bool { !settings.spotifyClientID.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Playlists the user can add tracks to: their own and collaborative ones.
    var editablePlaylists: [SpotifyPlaylist] {
        guard let user else { return [] }
        return (playlists ?? []).filter { $0.owner.id == user.id || $0.collaborative }
    }

    func restore() async {
        isSignedIn = await tokens.isSignedIn
        guard isSignedIn else { return }
        do {
            user = try await api.me()
        } catch SpotifyAuthError.notSignedIn {
            isSignedIn = false
        } catch {
            log.error("Spotify: \(error.localizedDescription)")
        }
    }

    // MARK: Auth

    func signIn() async {
        guard hasClientID else {
            lastError = SpotifyAuthError.missingClientID.localizedDescription
            return
        }
        let clientID = settings.spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let pkce = PKCE()
        let url = pkce.authorizeURL(clientID: clientID, redirectURI: Self.redirectURI, scopes: SpotifyAPI.scopes)

        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let callback = try await authenticate(url: url)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

            if let error = value("error") { throw SpotifyAuthError.tokenExchange(error) }
            guard value("state") == pkce.state, let code = value("code") else {
                throw SpotifyAuthError.tokenExchange("invalid callback")
            }
            try await tokens.exchange(code: code, pkce: pkce, clientID: clientID, redirectURI: Self.redirectURI)
            isSignedIn = true
            user = try await api.me()
            log.info("Signed in to Spotify as \(user?.displayName ?? user?.id ?? "?")")
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // The user closed the sheet.
        } catch {
            lastError = error.localizedDescription
            log.error("Spotify sign-in: \(error.localizedDescription)")
        }
    }

    func signOut() async {
        await tokens.signOut()
        isSignedIn = false
        user = nil
        playlists = nil
        albums = nil
        artists = nil
        likedSongs = nil
        recent = nil
        log.info("Signed out of Spotify")
    }

    private func authenticate(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // @Sendable keeps the handler off the main actor: the session calls it on a background queue.
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.redirectScheme) { @Sendable callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: error ?? SpotifyAuthError.tokenExchange("no callback"))
                }
            }
            session.presentationContextProvider = presentationProvider
            session.prefersEphemeralWebBrowserSession = false
            authSession = session
            session.start()
        }
    }

    // MARK: Playlist editing

    func addToPlaylist(trackURI: String, trackTitle: String, playlist: SpotifyPlaylist) async {
        do {
            try await api.addToPlaylist(playlist.id, uris: [trackURI])
            log.info("Added \(trackURI) to playlist \(playlist.name)")
            show("Added “\(trackTitle)” to \(playlist.name)")
        } catch SpotifyAPIError.http(let status, let message) where status == 403 {
            lastError = "Spotify refused to modify “\(playlist.name)” (\(message)). Only playlists you own or collaborate on can be changed."
            log.error("Add to playlist 403: \(message)")
        } catch {
            lastError = "Couldn't add to \(playlist.name): \(error.localizedDescription)"
            log.error("Add to playlist: \(error.localizedDescription)")
        }
    }

    private func show(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notice == message { notice = nil }
        }
    }

    // MARK: Library

    func loadPlaylists(force: Bool = false) async {
        guard force || playlists == nil else { return }
        await load("playlists") { api in
            self.playlists = try await api.all { try await api.myPlaylists(offset: $0) }
        }
    }

    func loadAlbums(force: Bool = false) async {
        guard force || albums == nil else { return }
        await load("albums") { api in
            self.albums = try await api.all { try await api.savedAlbums(offset: $0) }.map(\.album)
        }
    }

    func loadArtists(force: Bool = false) async {
        guard force || artists == nil else { return }
        await load("artists") { api in
            self.artists = try await api.followedArtists()
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func loadLikedSongs(force: Bool = false) async {
        guard force || likedSongs == nil else { return }
        await load("liked songs") { api in
            self.likedSongs = try await api.all(cap: 5000) { try await api.savedTracks(offset: $0) }.map(\.track)
        }
    }

    func loadRecent(force: Bool = false) async {
        guard force || recent == nil else { return }
        await load("recently played") { api in
            self.recent = try await api.recentlyPlayed().map(\.track)
        }
    }

    private func load(_ what: String, _ body: (SpotifyAPI) async throws -> Void) async {
        guard isSignedIn else { return }
        do {
            try await body(api)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            log.error("Spotify \(what): \(error.localizedDescription)")
            lastError = "Couldn't load \(what): \(error.localizedDescription)"
        }
    }
}

final class AuthPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
        }
    }
}
