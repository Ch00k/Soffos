# Soffos

- Lifecycle stage: alpha (0.0.x), no users yet. Breaking changes are fine and need no compatibility code. The version
  comes from the git tag; the release workflow passes it to `build.sh` as `VERSION`. Without `VERSION`, `build.sh`
  makes the separate "Soffos Dev" app.
- User-facing UI strings may use the ellipsis on menu items and buttons that ask for more input (an HIG convention),
  `›` in settings paths, `·` as a separator, curly quotes, and the en dash between artist and album in Now Playing.
  Other dashes are ASCII hyphens. Comments, docs and tests stay ASCII.
- Release signing: the self-signed "Soffos Code Signing" certificate and the Sparkle EdDSA key are GitHub secrets (see
  README, Release). The Sparkle private key is also in aymini's login keychain (`generate_keys --account soffos`). The
  certificate deliberately has no copy outside GitHub, which can't read secrets back. Replacing either breaks
  auto-updates: installed copies then need one manual reinstall.
- Speaker firmware updates: `CheckForUpdate` on ZoneGroupTopology is read-only and safe. Never send
  `BeginSoftwareUpdate` to real speakers until its arguments are known from what the official Sonos app sends.
