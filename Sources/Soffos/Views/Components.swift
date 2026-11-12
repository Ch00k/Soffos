import SonosKit
import SpotifyKit
import SwiftUI

/// Remote artwork with a placeholder. Images are kept in memory so rows
/// scrolling back into view (e.g. in a long queue) don't reload them.
struct Artwork: View {
    let url: URL?
    var cornerRadius: CGFloat = 6
    var placeholder = "music.note"
    @State private var image: NSImage?

    var body: some View {
        // The square sets the size; the image fills it from an overlay, so
        // an image that isn't square is cropped instead of widening the view.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                    Image(systemName: placeholder)
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .task(id: url) {
                guard let url else { image = nil; return }
                if let cached = ImageCache.shared.cached(url) {
                    image = cached
                    return
                }
                image = nil
                let loaded = await ImageCache.shared.load(url)
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            }
    }
}

@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    private init() { cache.countLimit = 1500 }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    /// Loads an image, sharing one request between views asking for the same URL.
    func load(_ url: URL) async -> NSImage? {
        if let cached = cached(url) { return cached }
        let task: Task<Data?, Never>
        if let existing = inFlight[url] {
            task = existing
        } else {
            task = Task { try? await URLSession.shared.data(from: url).0 }
            inFlight[url] = task
        }
        let data = await task.value
        inFlight[url] = nil
        if let cached = cached(url) { return cached }
        guard let data, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}

/// Header for albums and playlists: art, title, metadata, Play and Shuffle.
struct CollectionHeader: View {
    @Environment(SonosStore.self) private var sonos
    let kind: String
    let title: String
    let subtitle: String
    let detail: String?
    let imageURL: URL?
    let uri: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            Artwork(url: imageURL, cornerRadius: 8)
                .frame(width: 180, height: 180)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(kind.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.tertiary)
                }
                PlayShuffleButtons { shuffled in
                    await sonos.playCollection(uri: uri, title: title, shuffled: shuffled)
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

/// "Play" (in order) and "Shuffle" buttons. Both replace the queue, so
/// they're disabled while the room's queue is still being filled.
struct PlayShuffleButtons: View {
    @Environment(SonosStore.self) private var sonos
    let play: (_ shuffled: Bool) async -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await play(false) }
            } label: {
                Label("Play", systemImage: "play.fill").frame(minWidth: 70)
            }
            .buttonStyle(.borderedProminent)

            Button {
                Task { await play(true) }
            } label: {
                Label("Shuffle", systemImage: "shuffle").frame(minWidth: 70)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .disabled(sonos.selectedGroup == nil || sonos.queueingTitle != nil)
        .help(sonos.selectedGroup.map { "Replaces the queue in \($0.name)" } ?? "Pick a room first")
    }
}

/// A track list row (display only).
struct TrackRow: View {
    let index: Int
    let track: SpotifyTrack
    var showArtwork = true
    var showAlbum = true

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)

            if showArtwork {
                Artwork(url: track.album?.images.best(minWidth: 64), cornerRadius: 4)
                    .frame(width: 36, height: 36)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(track.name).lineLimit(1)
                    if track.explicit == true {
                        Text("E")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 3)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 2))
                    }
                }
                Text(track.artistNames).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showAlbum, let album = track.album {
                Text(album.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .leading)
            }

            Text(formatTime(track.duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .opacity(track.isPlayable ? 1 : 0.4)
        .contentShape(Rectangle())
        .contextMenu {
            if let artist = track.artists.first, let id = artist.id {
                NavigationLink("Go to Artist", value: Route.artist(id: id, name: artist.name))
            }
            if let album = track.album, let id = album.id {
                NavigationLink("Go to Album", value: Route.albumID(id, name: album.name))
            }
        }
    }
}

/// A grid card for albums, playlists and artists.
struct MediaCard: View {
    @Environment(SonosStore.self) private var sonos
    let title: String
    let subtitle: String?
    let imageURL: URL?
    let route: Route
    /// Playable Spotify URI; nil for artists.
    let uri: String?
    var circular = false
    @State private var hovering = false

    var body: some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Artwork(url: imageURL, cornerRadius: circular ? 1000 : 8, placeholder: circular ? "music.mic" : "music.note")
                        .shadow(color: .black.opacity(hovering ? 0.25 : 0.1), radius: hovering ? 8 : 3, y: 2)
                    if hovering, uri != nil, sonos.selectedGroup != nil {
                        HStack(spacing: 6) {
                            cardButton("shuffle", help: "Shuffle") { await play(shuffled: true) }
                            cardButton("play.fill", help: "Play") { await play(shuffled: false) }
                        }
                        .padding(8)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: circular ? .center : .leading)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: circular ? .center : .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .contextMenu {
            if uri != nil {
                Group {
                    Button("Play", systemImage: "play.fill") { Task { await play(shuffled: false) } }
                    Button("Shuffle", systemImage: "shuffle") { Task { await play(shuffled: true) } }
                }
                .disabled(sonos.queueingTitle != nil)
            }
        }
    }

    private func play(shuffled: Bool) async {
        guard let uri else { return }
        await sonos.playCollection(uri: uri, title: title, shuffled: shuffled)
    }

    private func cardButton(_ symbol: String, help: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor, in: Circle())
                .shadow(radius: 4)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Adds the track playing on the selected room to one of the user's playlists.
struct AddToPlaylistMenu: View {
    @Environment(SonosStore.self) private var sonos
    @Environment(SpotifyStore.self) private var spotify
    /// The track at the moment the popover opened, so a track change while
    /// choosing doesn't add the wrong song. The popover is open while it's set.
    @State private var target: Target?

    private struct Target: Identifiable {
        let uri: String
        let title: String

        var id: String { uri }
    }

    var body: some View {
        let trackURI = sonos.current.spotifyTrackURI
        Button {
            target = trackURI.map { Target(uri: $0, title: sonos.current.displayTitle) }
        } label: {
            Image(systemName: "plus.circle")
        }
        .buttonStyle(.borderless)
        .disabled(!spotify.isSignedIn || trackURI == nil)
        .help(!spotify.isSignedIn ? "Sign in to Spotify first"
              : trackURI == nil ? "The current track isn't from Spotify"
              : "Add this track to a playlist")
        .popover(item: $target, arrowEdge: .top) { target in
            PlaylistPicker(trackTitle: target.title) { playlist in
                self.target = nil
                Task { await spotify.addToPlaylist(trackURI: target.uri, trackTitle: target.title, playlist: playlist) }
            }
        }
    }
}

private struct PlaylistPicker: View {
    @Environment(SpotifyStore.self) private var spotify
    let trackTitle: String
    let choose: (SpotifyPlaylist) -> Void
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add “\(trackTitle)” to…")
                .font(.headline)
                .lineLimit(1)

            if spotify.playlists == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                let items = spotify.editablePlaylists.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
                if items.isEmpty {
                    Text(spotify.editablePlaylists.isEmpty ? "You don't own any playlists." : "No matches.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    List(items) { playlist in
                        Button {
                            choose(playlist)
                        } label: {
                            HStack(spacing: 8) {
                                Artwork(url: playlist.images?.best(minWidth: 64), cornerRadius: 3)
                                    .frame(width: 28, height: 28)
                                Text(playlist.name).lineLimit(1)
                                Spacer()
                                if let count = playlist.trackCount {
                                    Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(height: min(CGFloat(items.count) * 36 + 8, 320))
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .task { await spotify.loadPlaylists() }
    }
}

let cardColumns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 20, alignment: .top)]

/// Shows a spinner until `loaded` is true, then the content or an empty state.
struct Loadable<Content: View>: View {
    let loaded: Bool
    let isEmpty: Bool
    let emptyTitle: String
    let emptySymbol: String
    @ViewBuilder var content: Content

    var body: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: emptySymbol)
        } else {
            content
        }
    }
}
