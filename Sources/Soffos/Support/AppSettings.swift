import Foundation
import Observation
import SonosKit

/// User settings, persisted as JSON in ~/Library/Application Support/<app name>.
@Observable
@MainActor
final class AppSettings {
    var spotifyClientID: String = "" { didSet { save() } }
    var spotifyRegion: SpotifyOnSonos.Region = .global { didSet { save() } }
    /// Optional IP/host of any Sonos player, for networks where SSDP
    /// multicast doesn't get through (VLANs, some mesh routers).
    var manualPlayerHost: String = "" { didSet { save() } }
    var lastGroupID: String? { didSet { save() } }

    @ObservationIgnored private var loading = false

    private struct Stored: Codable {
        var spotifyClientID: String?
        var spotifyRegion: SpotifyOnSonos.Region?
        var manualPlayerHost: String?
        var lastGroupID: String?
    }

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent(AppIdentity.name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    init() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        spotifyClientID = stored.spotifyClientID ?? ""
        spotifyRegion = stored.spotifyRegion ?? .global
        manualPlayerHost = stored.manualPlayerHost ?? ""
        lastGroupID = stored.lastGroupID
    }

    private func save() {
        guard !loading else { return }
        let stored = Stored(
            spotifyClientID: spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines),
            spotifyRegion: spotifyRegion,
            manualPlayerHost: manualPlayerHost.trimmingCharacters(in: .whitespacesAndNewlines),
            lastGroupID: lastGroupID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(stored).write(to: Self.fileURL, options: .atomic)
    }
}
