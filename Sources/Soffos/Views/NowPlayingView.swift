import SonosKit
import SwiftUI

struct NowPlayingView: View {
    @Environment(SonosStore.self) private var sonos

    var body: some View {
        let state = sonos.current
        Group {
            if sonos.selectedGroup == nil {
                emptyState
            } else if let art = state.track?.albumArtURL {
                // The cover, centered with breathing room, over a soft blur of itself.
                GeometryReader { geo in
                    let shortest = min(geo.size.width, geo.size.height)
                    let side = max(0, shortest - 2 * max(28, shortest * 0.09))
                    Artwork(url: art, cornerRadius: 10)
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .background {
                    Artwork(url: art, cornerRadius: 0)
                        .scaledToFill()
                        .blur(radius: 60)
                        .opacity(0.45)
                }
                .clipped()
            } else {
                // No cover (TV, line-in, some radio): show what's playing instead.
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 56))
                        .foregroundStyle(.tertiary)
                    Text(state.displayTitle).font(.title2.weight(.semibold))
                    if let label = state.sourceLabel {
                        Text(label).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
            }
        }
        .navigationTitle(sonos.selectedGroup?.name ?? "Now Playing")
        .toolbar { ToolbarPlaceholder() }
    }

    @ViewBuilder private var emptyState: some View {
        switch sonos.status {
        case .idle, .searching:
            VStack(spacing: 12) {
                ProgressView()
                Text("Looking for Sonos speakers…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("No Speakers Found", systemImage: "hifispeaker.badge.plus")
            } description: {
                Text("\(message)\n\nMake sure this Mac is on the same network as your Sonos system and that Soffos is allowed under System Settings › Privacy & Security › Local Network.")
            } actions: {
                Button("Try Again") { Task { await sonos.discover() } }
            }
        case .ready:
            ContentUnavailableView("Pick a Room", systemImage: "hifispeaker.2", description: Text("Choose a room in the sidebar."))
        }
    }
}
