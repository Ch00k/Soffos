import Foundation

public struct SpotifyImage: Decodable, Hashable, Sendable {
    public let url: URL
    public let width: Int?
    public let height: Int?
}

extension [SpotifyImage] {
    /// The smallest image at least `minWidth` wide, or the largest available.
    public func best(minWidth: Int = 300) -> URL? {
        let sorted = self.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        return (sorted.first { ($0.width ?? 0) >= minWidth } ?? sorted.last)?.url
    }
}

public struct SpotifyArtistRef: Decodable, Hashable, Sendable, Identifiable {
    public let id: String?
    public let name: String
    public let uri: String?
}

public struct SpotifyArtist: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let uri: String
    public let images: [SpotifyImage]?
    public let genres: [String]?
}

public struct SpotifyAlbum: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let uri: String
    public let images: [SpotifyImage]
    public let artists: [SpotifyArtistRef]
    public let releaseDate: String?
    public let totalTracks: Int?
    public let albumType: String?

    public var year: String? { releaseDate.map { String($0.prefix(4)) } }
    public var artistNames: String { artists.map(\.name).joined(separator: ", ") }
}

public struct SpotifyTrack: Decodable, Hashable, Sendable, Identifiable {
    public let id: String?
    public let name: String
    public let uri: String
    public let durationMs: Int
    public let artists: [SpotifyArtistRef]
    /// Missing on tracks nested inside an album response.
    public let album: SpotifyAlbumRef?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let explicit: Bool?
    public let isLocal: Bool?

    public var stableID: String { id ?? uri }
    public var artistNames: String { artists.map(\.name).joined(separator: ", ") }
    public var duration: TimeInterval { TimeInterval(durationMs) / 1000 }
    /// Local files can't be streamed by Sonos.
    public var isPlayable: Bool { !(isLocal ?? false) && uri.hasPrefix("spotify:track:") }
}

public struct SpotifyAlbumRef: Decodable, Hashable, Sendable {
    public let id: String?
    public let name: String
    public let uri: String?
    public let images: [SpotifyImage]
}

public struct SpotifyUserRef: Decodable, Hashable, Sendable {
    public let id: String
    public let displayName: String?
}

public struct SpotifyPlaylist: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let uri: String
    public let images: [SpotifyImage]?
    public let owner: SpotifyUserRef
    public let description: String?
    public let trackCount: Int?
    public let collaborative: Bool

    enum CodingKeys: String, CodingKey { case id, name, uri, images, owner, description, items, tracks, collaborative }
    struct Total: Decodable { let total: Int? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        uri = try c.decode(String.self, forKey: .uri)
        images = try c.decodeIfPresent([SpotifyImage].self, forKey: .images)
        owner = try c.decode(SpotifyUserRef.self, forKey: .owner)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        collaborative = (try? c.decodeIfPresent(Bool.self, forKey: .collaborative)) ?? false
        // February 2026 renamed `tracks` to `items`. Accept either.
        let total = (try? c.decodeIfPresent(Total.self, forKey: .items)) ?? (try? c.decodeIfPresent(Total.self, forKey: .tracks))
        trackCount = total?.total
    }
}

public struct SpotifyUser: Decodable, Hashable, Sendable {
    public let id: String
    public let displayName: String?
    public let images: [SpotifyImage]?
}

/// A page of results. Spotify sometimes returns `null` or unparseable
/// entries (e.g. deleted playlists, podcast episodes in a track list), so
/// those are dropped rather than failing the whole page.
public struct Paging<Item: Decodable & Sendable>: Decodable, Sendable {
    public let items: [Item]
    public let total: Int
    public let offset: Int
    public let limit: Int
    public let next: URL?

    enum CodingKeys: String, CodingKey { case items, total, offset, limit, next }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([Lossy<Item>].self, forKey: .items).compactMap(\.value)
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? items.count
        offset = try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? items.count
        next = try c.decodeIfPresent(URL.self, forKey: .next)
    }
}

struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

public struct SavedTrack: Decodable, Sendable { public let track: SpotifyTrack }
public struct SavedAlbum: Decodable, Sendable { public let album: SpotifyAlbum }

public struct PlaylistEntry: Decodable, Sendable {
    public let track: SpotifyTrack

    enum CodingKeys: String, CodingKey { case item, track }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // February 2026 renamed `track` to `item`.
        if let item = try? c.decode(SpotifyTrack.self, forKey: .item) {
            track = item
        } else {
            track = try c.decode(SpotifyTrack.self, forKey: .track)
        }
    }
}

public struct PlayHistory: Decodable, Sendable {
    public let track: SpotifyTrack
    public let playedAt: Date
}

public struct SearchResults: Decodable, Sendable {
    public let tracks: Paging<SpotifyTrack>?
    public let albums: Paging<SpotifyAlbum>?
    public let artists: Paging<SpotifyArtist>?
    public let playlists: Paging<SpotifyPlaylist>?
}

struct CursorPage<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]

    enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([Lossy<Item>].self, forKey: .items).compactMap(\.value)
    }
}
