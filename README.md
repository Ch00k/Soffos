# Soffos

A native macOS controller for Sonos, with Spotify as its only music source. It talks to the speakers directly over the
local network, with no Sonos cloud account involved.

## How it works

- **Speakers**: Soffos finds your speakers on the local network and controls them directly: rooms (including groups
  made in the Sonos app), playback, volume (per group and per room), shuffle/repeat, and the queue.
- **Spotify**: Soffos uses Spotify only for browsing and search. To play, it adds the track, album or playlist to the
  Sonos queue, and Sonos streams it from its own linked Spotify account. Audio never passes through your Mac. This also
  means followed playlists play fine even though Spotify no longer lets third-party apps list their tracks.

## Features

- Now Playing shows the cover art; the sidebar (rooms, Spotify) and the queue open from floating buttons and widen
  the window instead of squeezing the cover
- Compact playback footer: hover the progress line for times (click/drag to seek), hover the track for full details
- Group volume with -/+ for single steps, per-room volumes for groups, and mute
- Browse Spotify: search, playlists, saved albums, followed artists, liked songs, recently played
- **Play** or **Shuffle** any playlist or album. Both replace the room's queue; Shuffle turns on Sonos shuffle and
  starts on a random track
- **Add to Playlist**: add the track that's playing to one of your own (or collaborative) Spotify playlists
- System overview in Settings > Sonos: every room's speakers with their model, role (stereo pair left/right, Sub,
  surrounds) and IP address

## Install

Requires macOS 14 or later.

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

## Development

Building, testing and releasing Soffos are described in [docs/development.md](docs/development.md) and
[docs/releasing.md](docs/releasing.md).
