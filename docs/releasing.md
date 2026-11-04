# Releasing

Push a version tag (e.g. `0.0.2`). The release workflow tests, runs `VERSION=<tag> ./build.sh --universal` to build
**Soffos** signed with the project's self-signed certificate, and publishes `Soffos.zip` together with the Sparkle
update feed `appcast.xml` on the GitHub release. Installed copies find the update through
`releases/latest/download/appcast.xml`.

The workflow needs these repository secrets:

- `SIGNING_CERTIFICATE_P12`: the "Soffos Code Signing" certificate and private key as a base64-encoded `.p12`
- `SIGNING_CERTIFICATE_PASSWORD`: the `.p12` password
- `SPARKLE_PRIVATE_KEY`: the EdDSA key that signs updates; its public half is `SUPublicEDKey` in `build.sh`

Every release must be signed with the same certificate and Sparkle key: Sparkle rejects an update signed with anything
else, and a new certificate makes macOS ask for Keychain and Local Network access again.
