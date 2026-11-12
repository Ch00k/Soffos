import SpotifyKit
import SwiftUI

struct PlaylistsView: View {
    @Environment(SpotifyStore.self) private var spotify
    @State private var filter = ""

    var body: some View {
        let items = (spotify.playlists ?? []).filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
        Loadable(loaded: spotify.playlists != nil, isEmpty: spotify.playlists?.isEmpty == true,
                 emptyTitle: "No Playlists", emptySymbol: "music.note.list") {
            ScrollView {
                LazyVGrid(columns: cardColumns, spacing: 24) {
                    ForEach(items) { playlist in
                        MediaCard(title: playlist.name,
                                  subtitle: playlist.owner.displayName.map { "By \($0)" },
                                  imageURL: playlist.images?.best(),
                                  route: .playlist(playlist),
                                  uri: playlist.uri)
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("Playlists")
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter playlists")
        .toolbar { RefreshButton { await spotify.loadPlaylists(force: true) } }
        .task { await spotify.loadPlaylists() }
    }
}

struct AlbumsView: View {
    @Environment(SpotifyStore.self) private var spotify
    @State private var filter = ""

    var body: some View {
        let items = (spotify.albums ?? []).filter {
            filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.artistNames.localizedCaseInsensitiveContains(filter)
        }
        Loadable(loaded: spotify.albums != nil, isEmpty: spotify.albums?.isEmpty == true,
                 emptyTitle: "No Saved Albums", emptySymbol: "square.stack") {
            ScrollView {
                LazyVGrid(columns: cardColumns, spacing: 24) {
                    ForEach(items) { album in
                        MediaCard(title: album.name, subtitle: album.artistNames, imageURL: album.images.best(),
                                  route: .album(album), uri: album.uri)
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("Albums")
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter albums")
        .toolbar { RefreshButton { await spotify.loadAlbums(force: true) } }
        .task { await spotify.loadAlbums() }
    }
}

struct ArtistsView: View {
    @Environment(SpotifyStore.self) private var spotify

    var body: some View {
        Loadable(loaded: spotify.artists != nil, isEmpty: spotify.artists?.isEmpty == true,
                 emptyTitle: "No Followed Artists", emptySymbol: "music.mic") {
            ScrollView {
                LazyVGrid(columns: cardColumns, spacing: 24) {
                    ForEach(spotify.artists ?? []) { artist in
                        MediaCard(title: artist.name, subtitle: nil, imageURL: artist.images?.best(),
                                  route: .artist(id: artist.id, name: artist.name), uri: nil, circular: true)
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("Artists")
        .toolbar { RefreshButton { await spotify.loadArtists(force: true) } }
        .task { await spotify.loadArtists() }
    }
}

struct LikedSongsView: View {
    @Environment(SpotifyStore.self) private var spotify
    @Environment(SonosStore.self) private var sonos
    @State private var filter = ""

    var body: some View {
        let tracks = (spotify.likedSongs ?? []).filter {
            filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.artistNames.localizedCaseInsensitiveContains(filter)
        }
        Loadable(loaded: spotify.likedSongs != nil, isEmpty: spotify.likedSongs?.isEmpty == true,
                 emptyTitle: "No Liked Songs", emptySymbol: "heart") {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Liked Songs").font(.largeTitle.weight(.bold))
                        Text("\(spotify.likedSongs?.count ?? 0) songs").foregroundStyle(.secondary)
                        Spacer()
                        PlayShuffleButtons { shuffled in await queueAll(tracks, shuffled: shuffled) }
                            .disabled(tracks.isEmpty)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)

                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                            TrackRow(index: index, track: track)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("Liked Songs")
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter songs")
        .toolbar { RefreshButton { await spotify.loadLikedSongs(force: true) } }
        .task { await spotify.loadLikedSongs() }
    }

    /// Liked Songs isn't a playlist Sonos can expand, so queue tracks one by
    /// one (up to 100; when shuffling, a random 100).
    private func queueAll(_ tracks: [SpotifyTrack], shuffled: Bool) async {
        let playable = tracks.filter(\.isPlayable).map { (uri: $0.uri, title: $0.name) }
        let picked = shuffled ? Array(playable.shuffled().prefix(100)) : Array(playable.prefix(100))
        await sonos.playTracks(picked, title: "Liked Songs", shuffled: shuffled)
    }
}

struct RecentView: View {
    @Environment(SpotifyStore.self) private var spotify

    var body: some View {
        Loadable(loaded: spotify.recent != nil, isEmpty: spotify.recent?.isEmpty == true,
                 emptyTitle: "Nothing Played Recently", emptySymbol: "clock") {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array((spotify.recent ?? []).enumerated()), id: \.offset) { index, track in
                        TrackRow(index: index, track: track)
                    }
                }
                .padding(12)
            }
        }
        .navigationTitle("Recently Played")
        .toolbar { RefreshButton { await spotify.loadRecent(force: true) } }
        .task { await spotify.loadRecent() }
    }
}

struct RefreshButton: ToolbarContent {
    let action: () async -> Void

    var body: some ToolbarContent {
        ToolbarItem {
            Button {
                Task { await action() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh")
        }
    }
}
