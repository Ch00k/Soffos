import SpotifyKit
import SwiftUI

struct SearchView: View {
    @Environment(SpotifyStore.self) private var spotify
    @State private var query = ""
    @State private var results: SearchResults?
    @State private var searching = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let results {
                    if let tracks = results.tracks?.items, !tracks.isEmpty {
                        section("Songs") {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                                    TrackRow(index: index, track: track)
                                }
                            }
                            .padding(.horizontal, -12)
                        }
                    }
                    if let artists = results.artists?.items, !artists.isEmpty {
                        section("Artists") {
                            shelf(artists) { artist in
                                MediaCard(title: artist.name, subtitle: nil, imageURL: artist.images?.best(),
                                          route: .artist(id: artist.id, name: artist.name), uri: nil, circular: true)
                            }
                        }
                    }
                    if let albums = results.albums?.items, !albums.isEmpty {
                        section("Albums") {
                            shelf(albums) { album in
                                MediaCard(title: album.name, subtitle: album.artistNames, imageURL: album.images.best(),
                                          route: .album(album), uri: album.uri)
                            }
                        }
                    }
                    if let playlists = results.playlists?.items, !playlists.isEmpty {
                        section("Playlists") {
                            shelf(playlists) { playlist in
                                MediaCard(title: playlist.name, subtitle: playlist.owner.displayName,
                                          imageURL: playlist.images?.best(), route: .playlist(playlist), uri: playlist.uri)
                            }
                        }
                    }
                } else if !searching {
                    ContentUnavailableView("Search Spotify", systemImage: "magnifyingglass",
                                           description: Text("Find songs, artists, albums and playlists to play on Sonos."))
                        .padding(.top, 80)
                }
            }
            .padding(24)
        }
        .overlay { if searching && results == nil { ProgressView() } }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .toolbar, prompt: "Artists, songs, albums, playlists")
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { results = nil; return }
            // Debounce typing.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do {
                results = try await spotify.api.search(q)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                spotify.lastError = error.localizedDescription
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.semibold))
            content()
        }
    }

    private func shelf<Item: Identifiable, Card: View>(_ items: [Item], @ViewBuilder card: @escaping (Item) -> Card) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 20) {
                ForEach(items) { card($0).frame(width: 160) }
            }
            .padding(.bottom, 4)
        }
    }
}
