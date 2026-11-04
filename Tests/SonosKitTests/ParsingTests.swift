import Foundation
import Testing
@testable import SonosKit

@Suite struct ParsingTests {
    /// Parses a topology with satellites, a hidden member and a bridge; only visible rooms remain, coordinator first, groups sorted by name.
    @Test func zoneGroupsSkipsHiddenMembersAndPutsCoordinatorFirst() throws {
        let xml = """
        <ZoneGroupState><ZoneGroups>
          <ZoneGroup Coordinator="RINCON_B" ID="RINCON_B:12">
            <ZoneGroupMember UUID="RINCON_A" Location="http://10.0.0.5:1400/xml/device_description.xml" ZoneName="Kitchen"/>
            <ZoneGroupMember UUID="RINCON_B" Location="http://10.0.0.6:1400/xml/device_description.xml" ZoneName="Living Room">
              <Satellite UUID="RINCON_S" Location="http://10.0.0.9:1400/xml/device_description.xml" ZoneName="Living Room" Invisible="1"/>
            </ZoneGroupMember>
            <ZoneGroupMember UUID="RINCON_H" Location="http://10.0.0.7:1400/xml/device_description.xml" ZoneName="Living Room" Invisible="1"/>
          </ZoneGroup>
          <ZoneGroup Coordinator="RINCON_C" ID="RINCON_C:3">
            <ZoneGroupMember UUID="RINCON_C" Location="http://10.0.0.8:1400/xml/device_description.xml" ZoneName="Bedroom"/>
          </ZoneGroup>
          <ZoneGroup Coordinator="RINCON_BR" ID="RINCON_BR:1">
            <ZoneGroupMember UUID="RINCON_BR" Location="http://10.0.0.2:1400/xml/device_description.xml" ZoneName="BRIDGE" IsZoneBridge="1"/>
          </ZoneGroup>
        </ZoneGroups></ZoneGroupState>
        """
        let groups = try Parsing.zoneGroups(xml)
        #expect(groups.map(\.name) == ["Bedroom", "Living Room + 1"])
        let living = try #require(groups.last)
        #expect(living.members.map(\.id) == ["RINCON_B", "RINCON_A"])
        #expect(living.coordinator.baseURL.absoluteString == "http://10.0.0.6:1400")
    }

    /// Accepts a topology document whose root is `<ZoneGroups>` instead of `<ZoneGroupState>`.
    @Test func bareZoneGroupsRootIsAccepted() throws {
        let xml = """
        <ZoneGroups><ZoneGroup Coordinator="RINCON_C" ID="x">
          <ZoneGroupMember UUID="RINCON_C" Location="http://10.0.0.8:1400/xml/device_description.xml" ZoneName="Office"/>
        </ZoneGroup></ZoneGroups>
        """
        #expect(try Parsing.zoneGroups(xml).map(\.name) == ["Office"])
    }

    /// Reads title, artist and album from a DIDL-Lite item and resolves its relative album art against the player's base URL.
    @Test func didlTrackWithRelativeArt() throws {
        let didl = """
        <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" \
        xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">\
        <item id="-1" parentID="-1" restricted="true"><res duration="0:03:45">x-sonos-spotify:spotify%3atrack%3a1</res>\
        <upnp:albumArtURI>/getaa?s=1&amp;u=x-sonos-spotify%3aspotify</upnp:albumArtURI>\
        <dc:title>Teardrop</dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class>\
        <dc:creator>Massive Attack</dc:creator><upnp:album>Mezzanine</upnp:album></item></DIDL-Lite>
        """
        let item = try #require(Parsing.didlItems(didl, relativeTo: URL(string: "http://10.0.0.6:1400")!).first)
        #expect(item.title == "Teardrop")
        #expect(item.artist == "Massive Attack")
        #expect(item.album == "Mezzanine")
        #expect(item.albumArtURL?.absoluteString == "http://10.0.0.6:1400/getaa?s=1&u=x-sonos-spotify%3aspotify")
    }

    /// Yields no items for the `NOT_IMPLEMENTED` placeholder and for an empty string.
    @Test func emptyDidl() {
        #expect(Parsing.didlItems("NOT_IMPLEMENTED", relativeTo: URL(string: "http://h:1400")!).isEmpty)
        #expect(Parsing.didlItems("", relativeTo: URL(string: "http://h:1400")!).isEmpty)
    }

    /// Converts `H:MM:SS` to seconds and back, treating `NOT_IMPLEMENTED` as zero.
    @Test func timeRoundTrip() {
        #expect(Parsing.seconds("1:02:03") == 3723)
        #expect(Parsing.seconds("NOT_IMPLEMENTED") == 0)
        #expect(Parsing.hms(225) == "0:03:45")
    }

    /// Maps every Sonos play-mode string to a `PlayMode` and back unchanged.
    @Test func playModeRoundTrip() {
        for value in ["NORMAL", "REPEAT_ALL", "REPEAT_ONE", "SHUFFLE_NOREPEAT", "SHUFFLE", "SHUFFLE_REPEAT_ONE"] {
            #expect(PlayMode(sonosValue: value).sonosValue == value)
        }
    }

    /// Finds the LOCATION header of an SSDP response regardless of the header's case.
    @Test func ssdpHeaderIsCaseInsensitive() {
        let response = "HTTP/1.1 200 OK\r\nlocation: http://10.0.0.6:1400/xml/device_description.xml\r\nSERVER: Linux UPnP/1.0 Sonos/80.1\r\n\r\n"
        #expect(SonosDiscovery.header("LOCATION", in: response) == "http://10.0.0.6:1400/xml/device_description.xml")
    }
}

@Suite struct SOAPTests {
    /// Builds a SOAP envelope with the service namespace and XML-escaped argument values.
    @Test func envelopeEscapesArguments() {
        let body = SOAPClient.envelope(service: .avTransport, action: "AddURIToQueue", arguments: ["EnqueuedURIMetaData": "<a b=\"c\">&</a>"])
        #expect(body.contains("<EnqueuedURIMetaData>&lt;a b=&quot;c&quot;&gt;&amp;&lt;/a&gt;</EnqueuedURIMetaData>"))
        #expect(body.contains("xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\""))
    }

    /// Extracts out-arguments from a SOAP response and the UPnP error code from a SOAP fault.
    @Test func responseAndErrorParsing() throws {
        let ok = Data("""
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <u:GetVolumeResponse xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><CurrentVolume>23</CurrentVolume>\
        </u:GetVolumeResponse></s:Body></s:Envelope>
        """.utf8)
        #expect(try SOAPClient.parseResponse(ok, action: "GetVolume")["CurrentVolume"] == "23")

        let fault = Data("""
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><detail>\
        <UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>800</errorCode></UPnPError>\
        </detail></s:Fault></s:Body></s:Envelope>
        """.utf8)
        #expect(SOAPClient.upnpErrorCode(in: fault) == 800)
    }
}

@Suite struct SpotifyOnSonosTests {
    /// Queues an album as a container with the global service descriptor and an XML-escaped title.
    @Test func albumIsAContainer() throws {
        let entry = try #require(SpotifyOnSonos.entry(for: "spotify:album:4LH4d3cOWNNsVw41Gqt2kv", title: "A & B", region: .global))
        #expect(entry.uri == "x-rincon-cpcontainer:1004206cspotify%3aalbum%3a4LH4d3cOWNNsVw41Gqt2kv")
        #expect(entry.metadata.contains("id=\"00040000spotify%3aalbum%3a4LH4d3cOWNNsVw41Gqt2kv\""))
        #expect(entry.metadata.contains("SA_RINCON2311_X_#Svc2311-0-Token"))
        #expect(entry.metadata.contains("<dc:title>A &amp; B</dc:title>"))
    }

    /// Builds a track entry with the US service descriptor and a playlist entry as a container.
    @Test func trackAndPlaylist() throws {
        let track = try #require(SpotifyOnSonos.entry(for: "spotify:track:abc", region: .us))
        #expect(track.uri == "spotify%3atrack%3aabc")
        #expect(track.metadata.contains("SA_RINCON3079_X_#Svc3079-0-Token"))
        let playlist = try #require(SpotifyOnSonos.entry(for: "spotify:playlist:xyz", region: .global))
        #expect(playlist.uri == "x-rincon-cpcontainer:1006206cspotify%3aplaylist%3axyz")
    }

    /// Recovers the Spotify track URI from a Sonos Spotify stream URI and returns nil for other sources.
    @Test func spotifyTrackFromSonosURI() {
        #expect(SpotifyOnSonos.spotifyTrackURI(fromSonosURI: "x-sonos-spotify:spotify%3atrack%3a6rqhFgbbKwnb9MLmUQDhG6?sid=12&flags=8224&sn=1")
                == "spotify:track:6rqhFgbbKwnb9MLmUQDhG6")
        #expect(SpotifyOnSonos.spotifyTrackURI(fromSonosURI: "x-sonos-htastream:RINCON_X:spdif") == nil)
        #expect(SpotifyOnSonos.spotifyTrackURI(fromSonosURI: "x-file-cifs://nas/music/a.mp3") == nil)
    }

    /// Returns no queue entry for local-file URIs and for open.spotify.com links.
    @Test func rejectsUnknownURIs() {
        #expect(SpotifyOnSonos.entry(for: "spotify:local:a:b:c:1", region: .global) == nil)
        #expect(SpotifyOnSonos.entry(for: "https://open.spotify.com/track/abc", region: .global) == nil)
    }
}

@Suite struct EventTests {
    /// Derives each service's event subscription path from its control path.
    @Test func eventPathsMirrorControlPaths() {
        #expect(SonosService.avTransport.eventPath == "/MediaRenderer/AVTransport/Event")
        #expect(SonosService.zoneGroupTopology.eventPath == "/ZoneGroupTopology/Event")
        #expect(SonosService.contentDirectory.eventPath == "/MediaServer/ContentDirectory/Event")
    }

    /// Reads headers from a GENA NOTIFY request case-insensitively.
    @Test func notifyHeadersAreParsed() {
        let header = "NOTIFY /notify HTTP/1.1\r\nHOST: 10.0.0.2:5000\r\nCONTENT-TYPE: text/xml\r\nCONTENT-LENGTH: 512\r\nNT: upnp:event\r\nNTS: upnp:propchange\r\nSID: uuid:RINCON_X_sub0000000123\r\nSEQ: 0"
        #expect(SonosEventListener.header("SID", in: header) == "uuid:RINCON_X_sub0000000123")
        #expect(SonosEventListener.header("content-length", in: header) == "512")
    }

    /// Picks the loopback address as the route to 127.0.0.1 and returns nil for an invalid host.
    @Test func localAddressTowardLoopback() {
        #expect(SonosEventListener.localAddress(toward: "127.0.0.1") == "127.0.0.1")
        #expect(SonosEventListener.localAddress(toward: "not an ip") == nil)
    }
}
