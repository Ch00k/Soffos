import AppKit
import SonosKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            SpotifySettings().tabItem { Label("Spotify", systemImage: "music.note") }
            SonosSettings().tabItem { Label("Sonos", systemImage: "hifispeaker.2") }
        }
        .frame(width: 500)
    }
}

/// Each tab sizes the window to its content.
private struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SpotifySettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SpotifyStore.self) private var spotify

    var body: some View {
        @Bindable var settings = settings
        SettingsForm {
            Section {
                HStack(spacing: 10) {
                    Artwork(url: spotify.user?.images?.best(minWidth: 64), cornerRadius: 16, placeholder: "person.fill")
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        if spotify.isSignedIn {
                            Text(spotify.user?.displayName ?? spotify.user?.id ?? "Signed in")
                            Text("Signed in to Spotify").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Not signed in")
                            Text(spotify.hasClientID ? "Sign in to browse and search Spotify" : "Enter your Spotify app's Client ID below to sign in")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if spotify.isSignedIn {
                        Button("Sign Out") { Task { await spotify.signOut() } }
                    } else {
                        Button("Sign In") { Task { await spotify.signIn() } }
                            .disabled(!spotify.hasClientID || spotify.isSigningIn)
                    }
                }
            }

            Section {
                TextField("Client ID", text: $settings.spotifyClientID, prompt: Text("Paste from your Spotify app"))
                    .disabled(spotify.isSignedIn)
                LabeledContent("Redirect URI") {
                    HStack(spacing: 6) {
                        Text(SpotifyStore.redirectURI).textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(SpotifyStore.redirectURI, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    }
                }
            } header: {
                Text("Spotify App")
            } footer: {
                Text("Create an app at [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) with **Web API** and this redirect URI. Playback goes through Sonos, so Spotify must also be added in the Sonos app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct SonosSettings: View {
    @Environment(SonosStore.self) private var sonos

    var body: some View {
        SettingsForm {
            Section {
                if case let .failed(message) = sonos.status {
                    Text(message).foregroundStyle(.red)
                }
                ForEach(sonos.groups) { group in
                    ForEach(group.members) { room in
                        RoomSpeakersRow(room: room, groupedWith: group.members.filter { $0.id != room.id }.map(\.roomName))
                    }
                }
            } header: {
                Text("Rooms")
            } footer: {
                HStack {
                    Spacer()
                    if sonos.status == .searching {
                        ProgressView().controlSize(.small)
                    }
                    Button("Rediscover Speakers") { Task { await sonos.discover() } }
                        .disabled(sonos.status == .searching)
                }
            }
        }
        .task(id: sonos.allPlayers.flatMap(\.speakers).map(\.id)) {
            await sonos.loadSpeakerModels()
        }
    }
}

/// A room: its main speaker's picture, its name, the speakers it's made of,
/// and their addresses in the same order.
private struct RoomSpeakersRow: View {
    @Environment(SonosStore.self) private var sonos
    let room: SonosPlayer
    let groupedWith: [String]

    var body: some View {
        HStack(spacing: 10) {
            // Speakers serve 48 px icons, which are pixel-sharp at 24 pt on Retina displays.
            Artwork(url: room.speakers.first.flatMap { sonos.speakerModels[$0.id]?.iconURL }, cornerRadius: 4, placeholder: "hifispeaker")
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(room.roomName).font(.body).foregroundStyle(.primary)
                ForEach(room.speakers) { speaker in
                    HStack {
                        Text(name(of: speaker))
                        Spacer()
                        Text(speaker.host).monospaced().textSelection(.enabled)
                    }
                }
                if !groupedWith.isEmpty {
                    Text("Grouped with \(groupedWith.joined(separator: ", "))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// "Play:1", or "Play:1 Left" for a speaker with a role in the room.
    private func name(of speaker: SonosSpeaker) -> String {
        let model = sonos.speakerModels[speaker.id]?.name ?? "Speaker"
        return speaker.role.map { "\(model) \($0.label)" } ?? model
    }
}

extension SonosSpeaker.Role {
    var label: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .sub: "Sub"
        case .surroundLeft: "Left surround"
        case .surroundRight: "Right surround"
        }
    }
}
