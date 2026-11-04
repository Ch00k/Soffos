import SonosKit
import SpotifyKit
import SwiftUI

enum SidebarItem: Hashable {
    case nowPlaying, search, playlists, albums, artists, likedSongs, recent
}

enum Route: Hashable {
    case album(SpotifyAlbum)
    case albumID(String, name: String)
    case playlist(SpotifyPlaylist)
    case artist(id: String, name: String)
}

/// Sidebar | main pane | queue, with the playback footer pinned to the
/// bottom. Opening a panel widens the window rather than squeezing the main
/// pane (see `MainWindow`).
struct RootView: View {
    @Environment(SonosStore.self) private var sonos
    @Environment(SpotifyStore.self) private var spotify
    @State private var window = MainWindow()
    // Always opens on Now Playing with both panels collapsed.
    @State private var selection: SidebarItem = .nowPlaying
    @State private var path = NavigationPath()

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let widths = window.layout(totalWidth: geo.size.width)
                HStack(spacing: 0) {
                    // Panel content keeps its full width and is pinned to the
                    // window edge, so it slides in as the window grows.
                    // Hidden panels are removed from the view tree entirely
                    // so they cost nothing while closed.
                    if widths.sidebar > 0 {
                        SidebarView(selection: Binding(get: { selection }, set: { if let new = $0 { selection = new } }))
                            .frame(width: MainWindow.panelWidth)
                            .background(SidebarMaterial().ignoresSafeArea())
                            .overlay(alignment: .trailing) { Divider() }
                            .frame(width: widths.sidebar, alignment: .trailing)
                            .clipped()
                            .accessibilityHidden(widths.sidebar == 0)
                    }

                    NavigationStack(path: $path) {
                        detail
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .navigationDestination(for: Route.self) { route in
                                switch route {
                                case let .album(album): AlbumDetailView(albumID: album.id, initial: album)
                                case let .albumID(id, _): AlbumDetailView(albumID: id, initial: nil)
                                case let .playlist(playlist): PlaylistDetailView(playlist: playlist)
                                case let .artist(id, name): ArtistDetailView(artistID: id, name: name)
                                }
                            }
                    }
                    .frame(width: widths.main)
                    .overlay(alignment: .top) { panelButtons }

                    if widths.queue > 0 {
                        QueueView()
                            .frame(width: MainWindow.panelWidth)
                            .overlay(alignment: .leading) { Divider() }
                            .frame(width: widths.queue, alignment: .leading)
                            .clipped()
                            .accessibilityHidden(widths.queue == 0)
                    }
                }
            }

            NowPlayingBar(leadingInset: window.showSidebar ? MainWindow.panelWidth : 0,
                          trailingInset: window.showQueue ? MainWindow.panelWidth : 0)
        }
        .frame(minWidth: window.minimumWidth, minHeight: 420)
        .background(WindowAccessor { window.attach($0) })
        .onChange(of: selection) { path = NavigationPath() }
        .overlay(alignment: .top) {
            if let notice = spotify.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: spotify.notice)
        .alert("Something went wrong", isPresented: Binding(get: { sonos.lastError != nil }, set: { if !$0 { sonos.lastError = nil } })) {
            Button("OK") { sonos.lastError = nil }
        } message: {
            Text(sonos.lastError ?? "")
        }
        .alert("Spotify", isPresented: Binding(get: { spotify.lastError != nil }, set: { if !$0 { spotify.lastError = nil } })) {
            Button("OK") { spotify.lastError = nil }
        } message: {
            Text(spotify.lastError ?? "")
        }
    }

    /// Sidebar and queue toggles, floating over the top corners of the main pane.
    private var panelButtons: some View {
        HStack {
            FloatingButton(symbol: "sidebar.left", isOn: window.showSidebar,
                           help: window.showSidebar ? "Hide the sidebar" : "Show the sidebar") {
                window.toggle(.sidebar)
            }
            Spacer()
            FloatingButton(symbol: "list.bullet", isOn: window.showQueue,
                           help: window.showQueue ? "Hide the queue" : "Show the queue") {
                window.toggle(.queue)
            }
        }
        .padding(10)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .nowPlaying: NowPlayingView()
        case .search: SpotifyGate { SearchView() }
        case .playlists: SpotifyGate { PlaylistsView() }
        case .albums: SpotifyGate { AlbumsView() }
        case .artists: SpotifyGate { ArtistsView() }
        case .likedSongs: SpotifyGate { LikedSongsView() }
        case .recent: SpotifyGate { RecentView() }
        }
    }
}

/// A small round button on a translucent background.
private struct FloatingButton: View {
    let symbol: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? Color.accentColor : .primary)
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15)))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                .opacity(hovering ? 1 : 0.75)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The translucent sidebar background used by native split views.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Shows a sign-in prompt in place of Spotify content until the user is signed in.
struct SpotifyGate<Content: View>: View {
    @Environment(SpotifyStore.self) private var spotify
    @Environment(\.openSettings) private var openSettings
    @ViewBuilder var content: Content

    var body: some View {
        if spotify.isSignedIn {
            content
        } else {
            ContentUnavailableView {
                Label("Connect Spotify", systemImage: "music.note.list")
            } description: {
                Text(spotify.hasClientID
                     ? "Sign in to browse your library and search Spotify. Music plays directly on your Sonos speakers."
                     : "Add your Spotify app's Client ID in Settings, then sign in.")
            } actions: {
                if spotify.hasClientID {
                    Button("Sign In with Spotify") { Task { await spotify.signIn() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(spotify.isSigningIn)
                } else {
                    Button("Open Settings…") { openSettings() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
