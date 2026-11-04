import Foundation

/// Builds the queue entries Sonos needs to play Spotify content from its own
/// linked Spotify account, so audio streams straight from Spotify to the
/// speakers and not through this Mac.
///
/// Uses the "share link" scheme also used by SoCo: the item is identified by
/// an encoded `spotify:` URI plus a service descriptor. Requires Spotify to be
/// added as a service in the Sonos app.
public enum SpotifyOnSonos {
    /// The Sonos service number for Spotify. Which one works depends on the
    /// account's region; 2311 is the default and 3079 is used for some US
    /// accounts.
    public enum Region: Int, CaseIterable, Sendable, Codable {
        case global = 2311
        case us = 3079

        public var other: Region { self == .global ? .us : .global }
    }

    public enum Kind: String, Sendable {
        case track, album, playlist, episode, show
    }

    public struct Entry: Sendable, Equatable {
        public let uri: String
        public let metadata: String
    }

    /// The Spotify track URI behind a Sonos track URI, e.g.
    /// `x-sonos-spotify:spotify%3atrack%3aABC?sid=12&flags=8224&sn=1` -> `spotify:track:ABC`.
    /// Nil when the current track isn't from Spotify.
    public static func spotifyTrackURI(fromSonosURI sonosURI: String) -> String? {
        let decoded = sonosURI.removingPercentEncoding ?? sonosURI
        guard let range = decoded.range(of: #"spotify:track:[A-Za-z0-9]+"#, options: .regularExpression) else { return nil }
        return String(decoded[range])
    }

    /// `spotify:album:abc` -> queue URI and DIDL metadata.
    public static func entry(for spotifyURI: String, title: String = "", region: Region) -> Entry? {
        let parts = spotifyURI.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", let kind = Kind(rawValue: String(parts[1])) else { return nil }

        let encoded = spotifyURI.replacingOccurrences(of: ":", with: "%3a")
        let (prefix, key, upnpClass): (String, String, String) = switch kind {
        case .album: ("x-rincon-cpcontainer:1004206c", "00040000", "object.container.album.musicAlbum")
        case .playlist, .show: ("x-rincon-cpcontainer:1006206c", "1006206c", "object.container.playlistContainer")
        case .track: ("", "00032020", "object.item.audioItem.musicTrack")
        case .episode: ("", "00032020", "object.item.audioItem.podcast")
        }

        let sn = region.rawValue
        let metadata = """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
        xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" \
        xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">\
        <item id="\(key)\(encoded)" restricted="true">\
        <dc:title>\(XML.escape(title))</dc:title>\
        <upnp:class>\(upnpClass)</upnp:class>\
        <desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON\(sn)_X_#Svc\(sn)-0-Token</desc>\
        </item></DIDL-Lite>
        """
        return Entry(uri: prefix + encoded, metadata: metadata)
    }
}

extension SonosClient {
    public struct SpotifyEnqueueResult: Sendable {
        /// 1-based queue position of the first added track.
        public let firstPosition: Int
        /// Number of tracks added (an album or playlist expands to many).
        public let count: Int
        /// The region that worked. Remember it for next time.
        public let region: SpotifyOnSonos.Region
    }

    /// Queues a Spotify track, album or playlist. If Sonos rejects the
    /// preferred region's service number, retries with the other one.
    public func enqueueSpotify(
        _ spotifyURI: String,
        title: String,
        on coordinator: SonosPlayer,
        position: Int = 0,
        asNext: Bool = false,
        preferredRegion: SpotifyOnSonos.Region
    ) async throws -> SpotifyEnqueueResult {
        var firstError: Error?
        for region in [preferredRegion, preferredRegion.other] {
            guard let entry = SpotifyOnSonos.entry(for: spotifyURI, title: title, region: region) else {
                throw SonosError.invalidResponse("Unsupported Spotify URI \(spotifyURI)")
            }
            do {
                let added = try await addToQueue(coordinator, uri: entry.uri, metadata: entry.metadata, position: position, asNext: asNext)
                return SpotifyEnqueueResult(firstPosition: added.first, count: added.count, region: region)
            } catch let error as SonosError where error.upnpCode != nil {
                firstError = firstError ?? error
            }
        }
        throw firstError ?? SonosError.invalidResponse("enqueue failed")
    }
}
