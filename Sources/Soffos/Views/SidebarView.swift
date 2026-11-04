import SonosKit
import SwiftUI

struct SidebarView: View {
    @Environment(SonosStore.self) private var sonos
    @Environment(SpotifyStore.self) private var spotify
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Label("Now Playing", systemImage: "play.circle").tag(SidebarItem.nowPlaying)

            Section("Rooms") {
                roomsContent
            }

            Section("Spotify") {
                Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)
                Label("Playlists", systemImage: "music.note.list").tag(SidebarItem.playlists)
                Label("Albums", systemImage: "square.stack").tag(SidebarItem.albums)
                Label("Artists", systemImage: "music.mic").tag(SidebarItem.artists)
                Label("Liked Songs", systemImage: "heart").tag(SidebarItem.likedSongs)
                Label("Recently Played", systemImage: "clock").tag(SidebarItem.recent)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            if let user = spotify.user {
                HStack(spacing: 8) {
                    Artwork(url: user.images?.best(minWidth: 64), cornerRadius: 12, placeholder: "person.fill")
                        .frame(width: 24, height: 24)
                    Text(user.displayName ?? user.id)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private var roomsContent: some View {
        switch sonos.status {
        case .searching where sonos.groups.isEmpty:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for speakers…").foregroundStyle(.secondary)
            }
        case let .failed(message) where sonos.groups.isEmpty:
            VStack(alignment: .leading, spacing: 6) {
                Text("No speakers found").font(.callout.weight(.medium))
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Try Again") { Task { await sonos.discover() } }
                    .controlSize(.small)
            }
            .padding(.vertical, 4)
        default:
            ForEach(sonos.groups) { group in
                RoomRow(group: group, isSelected: group.id == sonos.selectedGroupID, state: sonos.nowPlaying[group.id])
                    .contentShape(Rectangle())
                    .onTapGesture { sonos.selectedGroupID = group.id }
                    .selectionDisabled()
            }
        }
    }
}

struct RoomRow: View {
    let group: SonosGroup
    let isSelected: Bool
    let state: NowPlaying?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: group.members.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill")
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                .frame(width: 26, height: 26)
                .background(isSelected ? Color.accentColor : Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if let state, state.track != nil || state.sourceLabel != nil {
                    Text(state.displayTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if state?.transport == .playing {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
        .help(group.longName)
    }
}
