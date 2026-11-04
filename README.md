# Soffos

A native macOS controller for Sonos, with Spotify as its only music source. Built with SwiftUI. It talks to the speakers
directly over the local network, with no Sonos cloud account involved.

## How it works

- **Speakers**: Soffos finds your players via SSDP and controls them over Sonos's local UPnP/SOAP API on port 1400:
  rooms (including groups made in the Sonos app), transport, volume (per group and per room), shuffle/repeat, and the
  queue.
- **Spotify**: the Spotify Web API (your own app, PKCE sign-in) is used only for browsing and search. To play, Soffos
  adds the Spotify track/album/playlist to the Sonos queue and Sonos streams it from its own linked Spotify account.
  Audio never passes through your Mac. This also means followed playlists play fine even though Spotify no longer
  lets third-party apps list their tracks.

## Features

- Now Playing shows the cover art; the sidebar (rooms, Spotify) and the queue open from floating buttons and widen
  the window instead of squeezing the cover
- Compact playback footer: hover the progress line for times (click/drag to seek), hover the track for full details
- Group volume with -/+ for single steps, per-room volumes for groups, and mute
- Browse Spotify: search, playlists, saved albums, followed artists, liked songs, recently played
- **Play** or **Shuffle** any playlist or album. Both replace the room's queue; Shuffle turns on Sonos shuffle and
  starts on a random track
- **Add to Playlist**: add the track that's playing to one of your own (or collaborative) Spotify playlists
- System overview in Settings > Sonos: every room's speakers with their model and role (stereo pair left/right, Sub,
  surrounds)

Logs go to the unified log: `log stream --predicate 'subsystem == "re.mntw.soffos"'` (`re.mntw.soffos.dev` for local
builds).

## Install

Download `Soffos.zip` from the [latest release](https://github.com/Ch00k/Soffos/releases/latest), unzip it and move
`Soffos.app` to Applications.

Soffos is not notarized by Apple, so macOS blocks it on first launch. To allow it, open it once, then go to System
Settings > Privacy & Security and click **Open Anyway** (on macOS 14 you can instead Control-click the app and choose
**Open**). Alternatively, clear the quarantine flag in Terminal:

```sh
xattr -d com.apple.quarantine /Applications/Soffos.app
```

After that, Soffos keeps itself up to date: it checks for new releases in the background, and Soffos > Check for
Updates... checks right away.

## Setup

1. Make sure Spotify is added in the Sonos app (Settings > Services & Voice).
2. Create an app at [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard), select **Web API**, and
   add the redirect URI `soffos://callback`. Development mode is fine for personal use, but it needs a Premium
   account and allows at most 5 users.
3. In Soffos > Settings > Spotify, paste the app's Client ID and sign in.
4. Allow Local Network access when macOS asks.

## Build

Requires macOS 14+ and Swift 6 (Xcode or the Command Line Tools).

```sh
./build.sh            # Soffos Dev.app + Soffos Dev.zip
swift test            # unit tests
SONOS_LIVE=1 swift test --filter LiveTests   # read-only checks against real speakers
```

You can also open `Package.swift` in Xcode.

Local builds are **Soffos Dev**: a separate app (bundle ID `re.mntw.soffos.dev`) with a navy icon and its own
settings, Spotify sign-in and logs, and no auto-updates, so it runs side by side with an installed release. Both
control the same speakers. Builds are signed ad hoc unless `SIGNING_IDENTITY` names a code signing certificate; an
ad-hoc build is signed differently every time, so macOS asks again for Keychain and Local Network access after each
rebuild.

The app icon is drawn in `icon.svg`, and the dev build's navy variant in `icon-dev.svg`. After changing either,
regenerate the `.icns` files (needs `brew install librsvg`):

```sh
for name in icon icon-dev; do mkdir $name.iconset && for s in 16 32 128 256 512; do
  rsvg-convert -w $s $name.svg -o $name.iconset/icon_${s}x${s}.png
  rsvg-convert -w $((s * 2)) $name.svg -o $name.iconset/icon_${s}x${s}@2x.png
done && iconutil -c icns $name.iconset -o $name.icns && rm -r $name.iconset; done
```

## Release

Push a version tag (e.g. `0.0.2`). The release workflow tests, runs `VERSION=<tag> ./build.sh --universal` to build
**Soffos** signed with the project's self-signed certificate, and publishes `Soffos.zip` together with the Sparkle
update feed `appcast.xml` on the GitHub release. Installed copies find the update through
`releases/latest/download/appcast.xml`.

The workflow needs these repository secrets:

- `SIGNING_CERTIFICATE_P12`: the "Soffos Code Signing" certificate and private key as a base64-encoded `.p12`
- `SIGNING_CERTIFICATE_PASSWORD`: the `.p12` password
- `SPARKLE_PRIVATE_KEY`: the EdDSA key that signs updates; its public half is `SUPublicEDKey` in `build.sh`

Every release must be signed with the same certificate and Sparkle key: Sparkle rejects an update signed with
anything else, and a new certificate makes macOS ask for Keychain and Local Network access again.

## Layout

```
Sources/SonosKit/    UPnP/SOAP client, SSDP discovery, topology/DIDL parsing, Spotify-to-Sonos queue entries
Sources/SpotifyKit/  Spotify Web API client, PKCE auth, Keychain token storage
Sources/Soffos/      SwiftUI app: stores, views, settings
```
