import AppKit
import SonosKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            SpotifySettings().tabItem { Label("Spotify", systemImage: "music.note") }
            SonosSettings().tabItem { Label("Sonos", systemImage: "hifispeaker.2") }
        }
        .frame(width: 560, height: 440)
    }
}

private struct SpotifySettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SpotifyStore.self) private var spotify

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Soffos uses your own Spotify app for browsing and search:")
                    Text("1. Create an app at [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) and select **Web API**.")
                    HStack(spacing: 4) {
                        Text("2. Add the redirect URI")
                        Text(SpotifyStore.redirectURI).font(.body.monospaced()).textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(SpotifyStore.redirectURI, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    }
                    Text("3. Paste the app's Client ID below and sign in.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                TextField("Client ID", text: $settings.spotifyClientID)
                    .font(.body.monospaced())
                    .disabled(spotify.isSignedIn)
                LabeledContent("Account") {
                    if spotify.isSignedIn {
                        HStack {
                            Text(spotify.user?.displayName ?? spotify.user?.id ?? "Signed in")
                            Button("Sign Out") { Task { await spotify.signOut() } }
                        }
                    } else {
                        Button("Sign In with Spotify") { Task { await spotify.signIn() } }
                            .disabled(!spotify.hasClientID || spotify.isSigningIn)
                    }
                }
            }

            Section {
                Text("Playback doesn't use this app: Sonos streams Spotify itself, so Spotify must also be added in the Sonos app (Settings › Services & Voice).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SonosSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SonosStore.self) private var sonos

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Speakers") {
                LabeledContent("Status") {
                    switch sonos.status {
                    case .idle: Text("Idle")
                    case .searching: HStack { ProgressView().controlSize(.small); Text("Searching…") }
                    case .ready: Text("\(sonos.allPlayers.count) rooms in \(sonos.groups.count) groups")
                    case let .failed(message): Text(message).foregroundStyle(.red).lineLimit(3)
                    }
                }
                TextField("Speaker IP address (optional)", text: $settings.manualPlayerHost, prompt: Text("e.g. 192.168.1.40"))
                Text("Only needed if automatic discovery doesn't work, e.g. when the speakers are on a different VLAN. Any one speaker is enough.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Rediscover Speakers") { Task { await sonos.discover() } }
            }

            Section("Spotify on Sonos") {
                Picker("Service region", selection: $settings.spotifyRegion) {
                    ForEach(SpotifyOnSonos.Region.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Sonos identifies Spotify by a region-specific service number. If one is rejected Soffos tries the other automatically and remembers the one that works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Rooms") {
                ForEach(sonos.allPlayers) { player in
                    LabeledContent(player.roomName) {
                        Text(player.host).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
