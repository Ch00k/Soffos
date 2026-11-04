import SpotifyKit
import SwiftUI

struct AlbumDetailView: View {
    @Environment(SpotifyStore.self) private var spotify
    let albumID: String
    let initial: SpotifyAlbum?
    @State private var album: SpotifyAlbum?
    @State private var tracks: [SpotifyTrack]?

    var body: some View {
        let shown = album ?? initial
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let shown {
                    CollectionHeader(
                        kind: shown.albumType ?? "Album",
                        title: shown.name,
                        subtitle: shown.artistNames,
                        detail: [shown.year, tracks.map { "\($0.count) songs" }].compactMap { $0 }.joined(separator: " · "),
                        imageURL: shown.images.best(minWidth: 400),
                        uri: shown.uri
                    )
                    if let tracks {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                                TrackRow(index: index, track: track, showArtwork: false, showAlbum: false)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 24)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(80)
                }
            }
        }
        .navigationTitle(shown?.name ?? "Album")
        .task(id: albumID) {
            do {
                if album == nil { album = try await spotify.api.album(albumID) }
                tracks = try await spotify.api.all { try await spotify.api.albumTracks(albumID, offset: $0) }
            } catch {
                spotify.lastError = error.localizedDescription
                tracks = []
            }
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(SpotifyStore.self) private var spotify
    let playlist: SpotifyPlaylist
    @State private var tracks: [SpotifyTrack]?
    @State private var restricted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CollectionHeader(
                    kind: "Playlist",
                    title: playlist.name,
                    subtitle: playlist.owner.displayName.map { "By \($0)" } ?? "",
                    detail: playlist.trackCount.map { "\($0) songs" },
                    imageURL: playlist.images?.best(minWidth: 400),
                    uri: playlist.uri
                )
                if let tracks, !tracks.isEmpty {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                            TrackRow(index: index, track: track)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                } else if restricted {
                    Text("Spotify only lists the songs of playlists you own. You can still play this playlist on Sonos.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                } else if tracks == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
        }
        .navigationTitle(playlist.name)
        .task(id: playlist.id) {
            do {
                tracks = try await spotify.api.all { try await spotify.api.playlistItems(playlist.id, offset: $0) }.map(\.track)
                restricted = tracks?.isEmpty == true && (playlist.trackCount ?? 0) > 0
            } catch SpotifyAPIError.http(let status, _) where status == 403 || status == 404 {
                tracks = []
                restricted = true
            } catch {
                tracks = []
                spotify.lastError = error.localizedDescription
            }
        }
    }
}

struct ArtistDetailView: View {
    @Environment(SpotifyStore.self) private var spotify
    let artistID: String
    let name: String
    @State private var artist: SpotifyArtist?
    @State private var albums: [SpotifyAlbum]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 20) {
                    Artwork(url: artist?.images?.best(), cornerRadius: 1000, placeholder: "music.mic")
                        .frame(width: 140, height: 140)
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ARTIST").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(name).font(.largeTitle.weight(.bold))
                        if let genres = artist?.genres, !genres.isEmpty {
                            Text(genres.prefix(3).joined(separator: ", ")).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding([.horizontal, .top], 24)

                if let albums {
                    ForEach(sections(albums), id: \.title) { section in
                        Text(section.title).font(.title2.weight(.semibold)).padding(.horizontal, 24)
                        LazyVGrid(columns: cardColumns, spacing: 24) {
                            ForEach(section.albums) { album in
                                MediaCard(title: album.name, subtitle: album.year, imageURL: album.images.best(),
                                          route: .album(album), uri: album.uri)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(name)
        .task(id: artistID) {
            do {
                async let a = spotify.api.artist(artistID)
                async let list = spotify.api.all(cap: 200) { try await spotify.api.artistAlbums(artistID, offset: $0) }
                artist = try await a
                albums = try await list
            } catch {
                albums = []
                spotify.lastError = error.localizedDescription
            }
        }
    }

    private func sections(_ albums: [SpotifyAlbum]) -> [(title: String, albums: [SpotifyAlbum])] {
        let order = [("album", "Albums"), ("single", "Singles & EPs"), ("compilation", "Compilations")]
        return order.compactMap { type, title in
            let matching = albums.filter { ($0.albumType ?? "album") == type }
            return matching.isEmpty ? nil : (title, matching)
        }
    }
}
