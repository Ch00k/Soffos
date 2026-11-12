import Foundation
import Observation
import SonosKit

/// User settings, persisted as JSON in ~/Library/Application Support/<app name>.
@Observable
@MainActor
final class AppSettings {
    var spotifyClientID: String = "" { didSet { save() } }
    /// The Spotify service number that last worked on Sonos, tried first next time.
    var spotifyRegion: SpotifyOnSonos.Region = .global { didSet { save() } }
    var lastGroupID: String? { didSet { save() } }

    @ObservationIgnored private var loading = false

    private struct Stored: Codable {
        var spotifyClientID: String?
        var spotifyRegion: SpotifyOnSonos.Region?
        var lastGroupID: String?
    }

    private static var fileURL: URL {
        AppIdentity.supportDirectory.appendingPathComponent("settings.json")
    }

    init() {
        loading = true
        defer { loading = false }
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        spotifyClientID = stored.spotifyClientID ?? ""
        spotifyRegion = stored.spotifyRegion ?? .global
        lastGroupID = stored.lastGroupID
    }

    private func save() {
        guard !loading else { return }
        let stored = Stored(
            spotifyClientID: spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines),
            spotifyRegion: spotifyRegion,
            lastGroupID: lastGroupID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(stored).write(to: Self.fileURL, options: .atomic)
    }
}
