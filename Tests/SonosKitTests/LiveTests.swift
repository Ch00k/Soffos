import Foundation
import Testing
@testable import SonosKit

/// Read-only checks against real speakers. Never changes playback or volume.
///
///     SONOS_LIVE=1 swift test --filter LiveTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SONOS_LIVE"] != nil))
struct LiveTests {
    let client = SonosClient()

    /// Discovers real speakers over SSDP and reads every group's transport, position, source, play mode, volumes and queue, printing them for inspection.
    @Test func discoverAndReadState() async throws {
        let found = try await SonosDiscovery.discover()
        print("SSDP found:", found.map(\.absoluteString))
        let anchor = try #require(found.first)

        let groups = try await client.groups(via: anchor)
        #expect(!groups.isEmpty)
        for group in groups {
            let c = group.coordinator
            let transport = try await client.transportState(c)
            let position = try await client.positionInfo(c)
            let source = try await client.currentSourceURI(c)
            let mode = try await client.playMode(c)
            let volume = try await client.groupVolume(c)
            let queue = try await client.queue(c, count: 5)
            print("""
            [\(group.longName)] @ \(c.host)
              transport=\(transport) mode=\(mode) groupVolume=\(volume)
              source=\(source.prefix(60))
              track #\(position.trackNumber): \(position.metadata?.title ?? "-") - \(position.metadata?.artist ?? "-") \
            (\(Int(position.elapsed))/\(Int(position.duration))s) art=\(position.metadata?.albumArtURL?.absoluteString.prefix(60) ?? "-")
              queue: \(queue.totalMatches) items; first: \(queue.items.first?.metadata.title ?? "-")
            """)
            for member in group.members {
                _ = try await client.volume(member)
                for speaker in member.speakers {
                    let model = try await client.model(of: speaker)
                    print("  \(member.roomName): \(model.name) role=\(speaker.role.map { "\($0)" } ?? "-") @ \(speaker.host)")
                }
            }
        }
    }
}
