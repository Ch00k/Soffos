import Foundation

/// Stateless client for controlling Sonos players. Transport and queue commands
/// must target a group's coordinator; volume can target any player.
public struct SonosClient: Sendable {
    let soap: SOAPClient

    public init(session: URLSession = .shared) {
        soap = SOAPClient(session: session)
    }

    // MARK: Topology

    /// Reads the whole household's groups from any one player.
    public func groups(via base: URL) async throws -> [SonosGroup] {
        let out = try await soap.call(base, .zoneGroupTopology, "GetZoneGroupState")
        guard let state = out["ZoneGroupState"] else {
            throw SonosError.invalidResponse("GetZoneGroupState had no ZoneGroupState")
        }
        return try Parsing.zoneGroups(state)
    }

    // MARK: Transport (coordinator only)

    public func transportState(_ coordinator: SonosPlayer) async throws -> TransportState {
        let out = try await soap.call(coordinator.baseURL, .avTransport, "GetTransportInfo", ["InstanceID": "0"])
        return TransportState(rawValue: out["CurrentTransportState"] ?? "") ?? .unknown
    }

    public func positionInfo(_ coordinator: SonosPlayer) async throws -> PositionInfo {
        let out = try await soap.call(coordinator.baseURL, .avTransport, "GetPositionInfo", ["InstanceID": "0"])
        return PositionInfo(
            trackNumber: Int(out["Track"] ?? "") ?? 0,
            duration: Parsing.seconds(out["TrackDuration"]),
            elapsed: Parsing.seconds(out["RelTime"]),
            trackURI: out["TrackURI"] ?? "",
            metadata: Parsing.didlItems(out["TrackMetaData"] ?? "", relativeTo: coordinator.baseURL).first
        )
    }

    /// The group's current source URI. It starts with `x-rincon-queue:` when
    /// the queue is playing; TV, line-in and radio use other schemes.
    public func currentSourceURI(_ coordinator: SonosPlayer) async throws -> String {
        let out = try await soap.call(coordinator.baseURL, .avTransport, "GetMediaInfo", ["InstanceID": "0"])
        return out["CurrentURI"] ?? ""
    }

    public func playMode(_ coordinator: SonosPlayer) async throws -> PlayMode {
        let out = try await soap.call(coordinator.baseURL, .avTransport, "GetTransportSettings", ["InstanceID": "0"])
        return PlayMode(sonosValue: out["PlayMode"] ?? "NORMAL")
    }

    public func setPlayMode(_ coordinator: SonosPlayer, _ mode: PlayMode) async throws {
        try await soap.call(coordinator.baseURL, .avTransport, "SetPlayMode", ["InstanceID": "0", "NewPlayMode": mode.sonosValue])
    }

    public func play(_ coordinator: SonosPlayer) async throws {
        try await soap.call(coordinator.baseURL, .avTransport, "Play", ["InstanceID": "0", "Speed": "1"])
    }

    public func pause(_ coordinator: SonosPlayer) async throws {
        try await soap.call(coordinator.baseURL, .avTransport, "Pause", ["InstanceID": "0"])
    }

    public func next(_ coordinator: SonosPlayer) async throws {
        try await soap.call(coordinator.baseURL, .avTransport, "Next", ["InstanceID": "0"])
    }

    public func previous(_ coordinator: SonosPlayer) async throws {
        try await soap.call(coordinator.baseURL, .avTransport, "Previous", ["InstanceID": "0"])
    }

    public func seek(_ coordinator: SonosPlayer, to seconds: TimeInterval) async throws {
        try await soap.call(coordinator.baseURL, .avTransport, "Seek", [
            "InstanceID": "0", "Unit": "REL_TIME", "Target": Parsing.hms(seconds),
        ])
    }

    // MARK: Volume

    public func volume(_ player: SonosPlayer) async throws -> Int {
        let out = try await soap.call(player.baseURL, .renderingControl, "GetVolume", ["InstanceID": "0", "Channel": "Master"])
        return Int(out["CurrentVolume"] ?? "") ?? 0
    }

    public func setVolume(_ player: SonosPlayer, _ volume: Int) async throws {
        try await soap.call(player.baseURL, .renderingControl, "SetVolume", [
            "InstanceID": "0", "Channel": "Master", "DesiredVolume": String(min(100, max(0, volume))),
        ])
    }

    public func groupVolume(_ coordinator: SonosPlayer) async throws -> Int {
        let out = try await soap.call(coordinator.baseURL, .groupRenderingControl, "GetGroupVolume", ["InstanceID": "0"])
        return Int(out["CurrentVolume"] ?? "") ?? 0
    }

    /// Sets the group volume. Sonos scales each member proportionally.
    public func setGroupVolume(_ coordinator: SonosPlayer, _ volume: Int) async throws {
        // Snapshot first so the proportions between members are preserved.
        try await soap.call(coordinator.baseURL, .groupRenderingControl, "SnapshotGroupVolume", ["InstanceID": "0"])
        try await soap.call(coordinator.baseURL, .groupRenderingControl, "SetGroupVolume", [
            "InstanceID": "0", "DesiredVolume": String(min(100, max(0, volume))),
        ])
    }

    public func groupMute(_ coordinator: SonosPlayer) async throws -> Bool {
        let out = try await soap.call(coordinator.baseURL, .groupRenderingControl, "GetGroupMute", ["InstanceID": "0"])
        return out["CurrentMute"] == "1"
    }

    public func setGroupMute(_ coordinator: SonosPlayer, _ muted: Bool) async throws {
        try await soap.call(coordinator.baseURL, .groupRenderingControl, "SetGroupMute", [
            "InstanceID": "0", "DesiredMute": muted ? "1" : "0",
        ])
    }

    // MARK: Queue (coordinator only)

    /// Reads up to `count` queue items starting at 0-based `start`. Pages
    /// through as needed, since firmware caps items per request (100 or 1000).
    public func queue(_ coordinator: SonosPlayer, start: Int = 0, count: Int = 300) async throws -> QueuePage {
        var items: [QueueItem] = []
        var total = 0
        var updateID = ""
        while items.count < count {
            let offset = start + items.count
            let out = try await soap.call(coordinator.baseURL, .contentDirectory, "Browse", [
                "ObjectID": "Q:0",
                "BrowseFlag": "BrowseDirectChildren",
                "Filter": "dc:title,res,dc:creator,upnp:artist,upnp:album,upnp:albumArtURI",
                "StartingIndex": String(offset),
                "RequestedCount": String(count - items.count),
                "SortCriteria": "",
            ])
            total = Int(out["TotalMatches"] ?? "") ?? 0
            updateID = out["UpdateID"] ?? ""
            let page = Parsing.didlItems(out["Result"] ?? "", relativeTo: coordinator.baseURL)
            items += page.enumerated().map { QueueItem(position: offset + $0.offset + 1, metadata: $0.element) }
            if page.isEmpty || offset + page.count >= total { break }
        }
        return QueuePage(items: items, totalMatches: total, updateID: updateID)
    }

    /// Switches the group's source to its queue and plays from `position` (1-based).
    public func playFromQueue(_ coordinator: SonosPlayer, position: Int) async throws {
        try await soap.call(coordinator.baseURL, .avTransport, "SetAVTransportURI", [
            "InstanceID": "0",
            "CurrentURI": "x-rincon-queue:\(coordinator.id)#0",
            "CurrentURIMetaData": "",
        ])
        try await soap.call(coordinator.baseURL, .avTransport, "Seek", [
            "InstanceID": "0", "Unit": "TRACK_NR", "Target": String(position),
        ])
        try await play(coordinator)
    }

    public func clearQueue(_ coordinator: SonosPlayer) async throws {
        try await soap.call(coordinator.baseURL, .avTransport, "RemoveAllTracksFromQueue", ["InstanceID": "0"])
    }

    public func removeFromQueue(_ coordinator: SonosPlayer, position: Int) async throws {
        try await soap.call(coordinator.baseURL, .avTransport, "RemoveTrackFromQueue", [
            "InstanceID": "0", "ObjectID": "Q:0/\(position)", "UpdateID": "0",
        ])
    }

    /// Adds a URI to the queue. `position` 0 appends. Returns the 1-based
    /// position of the first added track and how many tracks were added.
    @discardableResult
    public func addToQueue(
        _ coordinator: SonosPlayer,
        uri: String,
        metadata: String,
        position: Int = 0,
        asNext: Bool = false
    ) async throws -> (first: Int, count: Int) {
        let out = try await soap.call(coordinator.baseURL, .avTransport, "AddURIToQueue", [
            "InstanceID": "0",
            "EnqueuedURI": uri,
            "EnqueuedURIMetaData": metadata,
            "DesiredFirstTrackNumberEnqueued": String(position),
            "EnqueueAsNext": asNext ? "1" : "0",
        ])
        return (Int(out["FirstTrackNumberEnqueued"] ?? "") ?? 1, Int(out["NumTracksAdded"] ?? "") ?? 1)
    }
}
