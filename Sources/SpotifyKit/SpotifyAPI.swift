import Foundation

public enum SpotifyAPIError: Error, LocalizedError {
    case http(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case let .http(status, message): "Spotify API error \(status): \(message)"
        }
    }
}

/// Read-only Spotify Web API client covering what a Sonos controller needs:
/// search, library, playlists, albums and artists.
///
/// Works within Spotify's Development Mode limits: search is capped at 10
/// results per type, an artist's albums at 10 per page, playlist contents
/// come from `/items`, and only playlists the user owns return their tracks.
public struct SpotifyAPI: Sendable {
    public static let scopes = [
        "user-read-private",
        "user-library-read",
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-read-recently-played",
        "user-follow-read",
        "playlist-modify-public",
        "playlist-modify-private",
    ]

    public let tokens: SpotifyTokenStore
    public let clientID: String
    private let session: URLSession
    private static let base = URL(string: "https://api.spotify.com/v1/")!

    public init(tokens: SpotifyTokenStore, clientID: String, session: URLSession = .shared) {
        self.tokens = tokens
        self.clientID = clientID
        self.session = session
    }

    // MARK: Endpoints

    public func me() async throws -> SpotifyUser {
        try await get("me")
    }

    public enum SearchType: String, CaseIterable, Sendable { case track, album, artist, playlist }

    public func search(_ query: String, types: [SearchType] = SearchType.allCases, limit: Int = 10) async throws -> SearchResults {
        try await get("search", [
            "q": query,
            "type": types.map(\.rawValue).joined(separator: ","),
            "limit": String(min(limit, 10)),
        ])
    }

    public func myPlaylists(offset: Int = 0) async throws -> Paging<SpotifyPlaylist> {
        try await get("me/playlists", ["limit": "50", "offset": String(offset)])
    }

    public func savedAlbums(offset: Int = 0) async throws -> Paging<SavedAlbum> {
        try await get("me/albums", ["limit": "50", "offset": String(offset)])
    }

    public func savedTracks(offset: Int = 0) async throws -> Paging<SavedTrack> {
        try await get("me/tracks", ["limit": "50", "offset": String(offset)])
    }

    public func followedArtists() async throws -> [SpotifyArtist] {
        struct FollowedArtists: Decodable { let artists: CursorPage<SpotifyArtist> }
        let followed: FollowedArtists = try await get("me/following", ["type": "artist", "limit": "50"])
        return followed.artists.items
    }

    public func recentlyPlayed() async throws -> [PlayHistory] {
        let page: CursorPage<PlayHistory> = try await get("me/player/recently-played", ["limit": "50"])
        return page.items
    }

    public func playlist(_ id: String) async throws -> SpotifyPlaylist {
        try await get("playlists/\(id)")
    }

    /// Only works for playlists the user owns or collaborates on.
    public func playlistItems(_ id: String, offset: Int = 0) async throws -> Paging<PlaylistEntry> {
        try await get("playlists/\(id)/items", ["limit": "50", "offset": String(offset)])
    }

    public func album(_ id: String) async throws -> SpotifyAlbum {
        try await get("albums/\(id)")
    }

    public func albumTracks(_ id: String, offset: Int = 0) async throws -> Paging<SpotifyTrack> {
        try await get("albums/\(id)/tracks", ["limit": "50", "offset": String(offset)])
    }

    public func artist(_ id: String) async throws -> SpotifyArtist {
        try await get("artists/\(id)")
    }

    public func artistAlbums(_ id: String, offset: Int = 0) async throws -> Paging<SpotifyAlbum> {
        try await get("artists/\(id)/albums", ["include_groups": "album,single,compilation", "limit": "10", "offset": String(offset)])
    }

    /// Appends tracks to a playlist the user owns or collaborates on.
    public func addToPlaylist(_ playlistID: String, uris: [String]) async throws {
        let body = try JSONEncoder().encode(["uris": uris])
        _ = try await send("POST", "playlists/\(playlistID)/items", body: body)
    }

    /// Loads every page of a paged endpoint, up to `cap` items.
    public func all<Item>(
        cap: Int = 2000,
        isolation: isolated (any Actor)? = #isolation,
        _ page: (Int) async throws -> Paging<Item>
    ) async throws -> [Item] {
        var items: [Item] = []
        var offset = 0
        while true {
            let p = try await page(offset)
            items += p.items
            offset = p.offset + p.limit
            if p.next == nil || p.items.isEmpty || items.count >= cap { return items }
        }
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        try Self.decoder.decode(T.self, from: try await send("GET", path, query: query))
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil) async throws -> Data {
        var components = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        let url = components.url!

        for attempt in 0..<3 {
            var request = URLRequest(url: url)
            request.httpMethod = method
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.setValue("Bearer \(try await tokens.accessToken(clientID: clientID))", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200..<300:
                return data
            case 401 where attempt == 0:
                await tokens.invalidateAccessToken()
            case 429 where attempt < 2:
                let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1
                try await Task.sleep(for: .seconds(min(wait, 10)))
            default:
                throw SpotifyAPIError.http(status: http?.statusCode ?? 0, message: Self.errorMessage(data))
            }
        }
        throw SpotifyAPIError.http(status: 0, message: "retries exhausted")
    }

    private static func errorMessage(_ data: Data) -> String {
        struct Envelope: Decodable { struct E: Decodable { let message: String? }; let error: E? }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message
            ?? String(decoding: data.prefix(300), as: UTF8.self)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
        }
        return decoder
    }()
}
