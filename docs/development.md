# Development

## Build and test

Requires macOS 14+ and Swift 6 (Xcode or the Command Line Tools).

```sh
./build.sh            # Soffos Dev.app + Soffos Dev.zip
swift test            # unit tests
SONOS_LIVE=1 swift test --filter LiveTests   # read-only checks against real speakers
```

You can also open `Package.swift` in Xcode.

## Dev builds

Local builds are **Soffos Dev**: a separate app (bundle ID `re.mntw.soffos.dev`) with a navy icon and its own
settings, Spotify sign-in and logs, and no auto-updates, so it runs side by side with an installed release. Both
control the same speakers.

Builds are signed ad hoc unless `SIGNING_IDENTITY` names a code signing certificate. An ad-hoc build is signed
differently every time, so macOS asks again for Keychain and Local Network access after each rebuild.

## Logs

Soffos logs to the unified log under its bundle ID:

```sh
log stream --predicate 'subsystem == "re.mntw.soffos"'       # release
log stream --predicate 'subsystem == "re.mntw.soffos.dev"'   # dev build
```

## App icon

The app icon is drawn in `icon.svg`, and the dev build's navy variant in `icon-dev.svg`. After changing either,
regenerate the `.icns` files (needs `brew install librsvg`):

```sh
for name in icon icon-dev; do mkdir $name.iconset && for s in 16 32 128 256 512; do
  rsvg-convert -w $s $name.svg -o $name.iconset/icon_${s}x${s}.png
  rsvg-convert -w $((s * 2)) $name.svg -o $name.iconset/icon_${s}x${s}@2x.png
done && iconutil -c icns $name.iconset -o $name.icns && rm -r $name.iconset; done
```

## Layout

```
Sources/SonosKit/    UPnP/SOAP client, SSDP discovery, topology/DIDL parsing, Spotify-to-Sonos queue entries
Sources/SpotifyKit/  Spotify Web API client, PKCE auth, Keychain token storage
Sources/Soffos/      SwiftUI app: stores, views, settings
```
