import Foundation

/// A single Sonos player ("room").
public struct SonosPlayer: Identifiable, Hashable, Sendable {
    /// The player's UUID, e.g. `RINCON_000E58XXXXXX01400`.
    public let id: String
    public let roomName: String
    /// `http://<ip>:1400`
    public let baseURL: URL

    public init(id: String, roomName: String, baseURL: URL) {
        self.id = id
        self.roomName = roomName
        self.baseURL = baseURL
    }

    public var host: String { baseURL.host ?? "?" }
}

/// A group of players that play in sync. Commands go to the coordinator.
public struct SonosGroup: Identifiable, Hashable, Sendable {
    /// Keyed by the coordinator's UUID, which (unlike Sonos's own group ID)
    /// survives members joining and leaving.
    public var id: String { coordinator.id }
    public let coordinator: SonosPlayer
    /// All players in the group, coordinator first.
    public let members: [SonosPlayer]

    public init(coordinator: SonosPlayer, members: [SonosPlayer]) {
        self.coordinator = coordinator
        self.members = [coordinator] + members.filter { $0.id != coordinator.id }
            .sorted { $0.roomName.localizedStandardCompare($1.roomName) == .orderedAscending }
    }

    public var name: String {
        members.count == 1 ? coordinator.roomName : "\(coordinator.roomName) + \(members.count - 1)"
    }

    public var longName: String {
        members.map(\.roomName).joined(separator: ", ")
    }
}

public enum TransportState: String, Sendable {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case stopped = "STOPPED"
    case transitioning = "TRANSITIONING"
    case unknown

    public var isPlaying: Bool { self == .playing || self == .transitioning }
}

public struct PlayMode: Hashable, Sendable {
    public enum Repeat: Sendable { case off, all, one }
    public var shuffle: Bool
    public var `repeat`: Repeat

    public init(shuffle: Bool = false, repeat: Repeat = .off) {
        self.shuffle = shuffle
        self.repeat = `repeat`
    }

    init(sonosValue: String) {
        switch sonosValue {
        case "REPEAT_ALL": self.init(shuffle: false, repeat: .all)
        case "REPEAT_ONE": self.init(shuffle: false, repeat: .one)
        case "SHUFFLE_NOREPEAT": self.init(shuffle: true, repeat: .off)
        case "SHUFFLE": self.init(shuffle: true, repeat: .all)
        case "SHUFFLE_REPEAT_ONE": self.init(shuffle: true, repeat: .one)
        default: self.init()
        }
    }

    var sonosValue: String {
        switch (shuffle, `repeat`) {
        case (false, .off): "NORMAL"
        case (false, .all): "REPEAT_ALL"
        case (false, .one): "REPEAT_ONE"
        case (true, .off): "SHUFFLE_NOREPEAT"
        case (true, .all): "SHUFFLE"
        case (true, .one): "SHUFFLE_REPEAT_ONE"
        }
    }
}

/// Track metadata parsed from a DIDL-Lite item.
public struct TrackMetadata: Hashable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var albumArtURL: URL?
    /// Non-nil for radio streams: the "now playing" text.
    public var streamContent: String?

    public init(title: String, artist: String? = nil, album: String? = nil, albumArtURL: URL? = nil, streamContent: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtURL = albumArtURL
        self.streamContent = streamContent
    }
}

public struct PositionInfo: Sendable {
    /// 1-based index in the queue (0 when nothing is queued).
    public var trackNumber: Int
    public var duration: TimeInterval
    public var elapsed: TimeInterval
    public var trackURI: String
    public var metadata: TrackMetadata?
}

public struct QueueItem: Identifiable, Hashable, Sendable {
    /// 1-based queue position.
    public let position: Int
    public let metadata: TrackMetadata
    public var id: Int { position }
}

public struct QueuePage: Sendable {
    public let items: [QueueItem]
    public let totalMatches: Int
    /// Changes whenever the queue's contents change.
    public let updateID: String
}
