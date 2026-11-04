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

Logs go to the unified log: `log stream --predicate 'subsystem == "re.mntw.soffos"'`.

## Setup

1. Make sure Spotify is added in the Sonos app (Settings > Services & Voice).
2. Create an app at [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard), select **Web API**, and
   add the redirect URI `soffos://callback`. Development mode is fine for personal use, but it needs a Premium
   account and allows at most 5 users.
3. In Soffos > Settings > Spotify, paste the app's Client ID and sign in.
4. Allow Local Network access when macOS asks.

If speakers aren't found (e.g. they're on a separate VLAN), enter any speaker's IP address in Settings > Sonos.

## Build

Requires macOS 14+ and Swift 6 (Xcode or the Command Line Tools).

```sh
./build.sh            # Soffos.app + Soffos.zip
swift test            # unit tests
SONOS_LIVE=1 swift test --filter LiveTests   # read-only checks against real speakers
```

You can also open `Package.swift` in Xcode.

The app icon is drawn in `icon.svg`. After changing it, regenerate `icon.icns` (needs `brew install librsvg`):

```sh
mkdir Soffos.iconset && for s in 16 32 128 256 512; do
  rsvg-convert -w $s icon.svg -o Soffos.iconset/icon_${s}x${s}.png
  rsvg-convert -w $((s * 2)) icon.svg -o Soffos.iconset/icon_${s}x${s}@2x.png
done && iconutil -c icns Soffos.iconset -o icon.icns && rm -r Soffos.iconset
```

## Layout

```
Sources/SonosKit/    UPnP/SOAP client, SSDP discovery, topology/DIDL parsing, Spotify-to-Sonos queue entries
Sources/SpotifyKit/  Spotify Web API client, PKCE auth, Keychain token storage
Sources/Soffos/      SwiftUI app: stores, views, settings
```
