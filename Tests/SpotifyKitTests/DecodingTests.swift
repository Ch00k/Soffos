import Foundation
import Testing
@testable import SpotifyKit

@Suite struct DecodingTests {
    let decoder = SpotifyAPI.decoder

    /// Decodes playlists whose track count is under `items` or `tracks`, with or without images, and drops null entries.
    @Test func playlistPageAcceptsItemsOrTracksTotalAndSkipsNulls() throws {
        let json = """
        {"items":[
          null,
          {"id":"p1","name":"Mine","uri":"spotify:playlist:p1","images":[],"owner":{"id":"me","display_name":"Me"},"items":{"total":12}},
          {"id":"p2","name":"Other","uri":"spotify:playlist:p2","images":null,"owner":{"id":"x"},"tracks":{"total":3}}
        ],"total":3,"offset":0,"limit":50,"next":null}
        """
        let page = try decoder.decode(Paging<SpotifyPlaylist>.self, from: Data(json.utf8))
        #expect(page.items.map(\.id) == ["p1", "p2"])
        #expect(page.items.map(\.trackCount) == [12, 3])
        #expect(page.items[0].owner.displayName == "Me")
        #expect(page.items.map(\.collaborative) == [false, false])
    }

    /// Decodes playlist entries keyed `item` or `track` and drops podcast episodes and null entries.
    @Test func playlistEntriesUseItemOrTrackAndDropEpisodes() throws {
        let track = #"{"id":"t1","name":"Song","uri":"spotify:track:t1","duration_ms":200000,"artists":[{"id":"a","name":"Artist","uri":"spotify:artist:a"}],"album":{"id":"al","name":"Album","uri":"spotify:album:al","images":[{"url":"https://i.scdn.co/image/x","width":300,"height":300}]},"is_local":false}"#
        let episode = #"{"id":"e1","name":"Ep","uri":"spotify:episode:e1","duration_ms":1}"#
        let json = """
        {"items":[{"item":\(track)},{"track":\(track)},{"item":\(episode)},{"item":null}],"total":4,"offset":0,"limit":50,"next":null}
        """
        let page = try decoder.decode(Paging<PlaylistEntry>.self, from: Data(json.utf8))
        #expect(page.items.count == 2)
        let t = page.items[0].track
        #expect(t.isPlayable)
        #expect(t.artistNames == "Artist")
        #expect(t.album?.images.best()?.absoluteString == "https://i.scdn.co/image/x")
    }

    /// Marks local-file tracks as unplayable and identifies them by URI since they have no ID.
    @Test func localTracksAreNotPlayable() throws {
        let json = #"{"id":null,"name":"Local","uri":"spotify:local:Artist:Album:Local:180","duration_ms":180000,"artists":[{"id":null,"name":"Artist","uri":null}],"is_local":true}"#
        let track = try decoder.decode(SpotifyTrack.self, from: Data(json.utf8))
        #expect(!track.isPlayable)
        #expect(track.stableID == track.uri)
    }

    /// Decodes recently-played timestamps that carry fractional seconds.
    @Test func recentlyPlayedDatesWithFractionalSeconds() throws {
        let json = #"{"items":[{"track":{"id":"t","name":"S","uri":"spotify:track:t","duration_ms":1,"artists":[]},"played_at":"2026-11-02T21:14:03.512Z"}]}"#
        let page = try decoder.decode(CursorPage<PlayHistory>.self, from: Data(json.utf8))
        #expect(page.items.count == 1)
    }

    /// Generates a 64-character verifier, a base64url challenge and an authorize URL with S256 and the redirect URI.
    @Test func pkceChallengeIsBase64URL() {
        let pkce = PKCE()
        #expect(pkce.verifier.count == 64)
        #expect(!pkce.challenge.contains("=") && !pkce.challenge.contains("+") && !pkce.challenge.contains("/"))
        let url = pkce.authorizeURL(clientID: "abc", redirectURI: "soffos://callback", scopes: ["a", "b"])
        #expect(url.absoluteString.contains("code_challenge_method=S256"))
        #expect(url.absoluteString.contains("redirect_uri=soffos://callback"))
    }
}
