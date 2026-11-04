#!/bin/bash
# Builds the app bundle (and a zip of it) from the Swift package.
#
#   ./build.sh              # native architecture
#   ./build.sh --universal  # arm64 + x86_64 (needs full Xcode)
#
# Release builds set VERSION (e.g. VERSION=0.0.2 ./build.sh) and produce
# "Soffos", which updates itself through Sparkle. Without VERSION the build is
# "Soffos Dev": a separate app with its own bundle ID, icon, settings and
# Spotify sign-in that runs alongside the installed release and never updates.
#
# SIGNING_IDENTITY names the code signing certificate to use. Without it, dev
# builds are signed with "Soffos Dev Signing", a self-signed certificate this
# script creates on first use, so every rebuild keeps the Local Network access
# granted to the previous one. Release builds without it are signed ad hoc.
set -e

DEV_SIGNING_IDENTITY="Soffos Dev Signing"
# The dev certificate lives in a keychain of its own with a fixed password, so
# the script can unlock it and let codesign use the key without a password
# dialog. The password guards only this self-signed dev key.
DEV_KEYCHAIN="${HOME}/Library/Keychains/soffos-dev.keychain-db"
DEV_KEYCHAIN_PASSWORD="soffos"

# Creates the dev keychain with the dev signing certificate and its private
# key. The system LibreSSL writes a PKCS#12 file that `security import` reads;
# Homebrew's OpenSSL 3 by default does not.
create_dev_keychain() {
    local dir
    dir="$(mktemp -d)"
    # The directory holds the unencrypted private key until it's imported.
    # The path is expanded now: `dir` is out of scope when the trap fires.
    trap "rm -rf '${dir}'" EXIT

    echo "Creating the \"${DEV_SIGNING_IDENTITY}\" certificate in ${DEV_KEYCHAIN}..."
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 36500 -subj "/CN=${DEV_SIGNING_IDENTITY}" \
        -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
        -keyout "${dir}/key.pem" -out "${dir}/cert.pem"
    /usr/bin/openssl pkcs12 -export -inkey "${dir}/key.pem" -in "${dir}/cert.pem" -name "${DEV_SIGNING_IDENTITY}" \
        -out "${dir}/identity.p12" -passout pass:"${DEV_KEYCHAIN_PASSWORD}"

    security create-keychain -p "${DEV_KEYCHAIN_PASSWORD}" "${DEV_KEYCHAIN}"
    security set-keychain-settings "${DEV_KEYCHAIN}"
    security unlock-keychain -p "${DEV_KEYCHAIN_PASSWORD}" "${DEV_KEYCHAIN}"
    security import "${dir}/identity.p12" -k "${DEV_KEYCHAIN}" -P "${DEV_KEYCHAIN_PASSWORD}" \
        -T /usr/bin/codesign > /dev/null
}

# Adds the dev keychain to the user's keychain search list, where codesign
# looks for identities, keeping the keychains already on it.
add_dev_keychain_to_search_list() {
    local keychains=() keychain
    while IFS= read -r keychain; do
        keychains+=("${keychain}")
    done < <(security list-keychains -d user | sed -n 's/^ *"\(.*\)"$/\1/p')
    security list-keychains -d user -s "${keychains[@]}" "${DEV_KEYCHAIN}"
}

if [[ -n "$VERSION" ]]; then
    APP_NAME="Soffos"
    BUNDLE_ID="re.mntw.soffos"
    ICON="icon.icns"
    UPDATE_KEYS="<key>SUFeedURL</key>
    <string>https://github.com/Ch00k/Soffos/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>BXF7oIWQmfjExKxAznMpP9aesdhgv2LlOLhKDdkVwtM=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>"
else
    APP_NAME="Soffos Dev"
    BUNDLE_ID="re.mntw.soffos.dev"
    ICON="icon-dev.icns"
    VERSION="0.0.0"
    UPDATE_KEYS=""
    if [[ -z "$SIGNING_IDENTITY" ]]; then
        SIGNING_IDENTITY="${DEV_SIGNING_IDENTITY}"
        # Recreates the keychain if an earlier run stopped before importing
        # the certificate.
        if ! security find-certificate -c "${DEV_SIGNING_IDENTITY}" "${DEV_KEYCHAIN}" > /dev/null 2>&1; then
            if [[ -f "${DEV_KEYCHAIN}" ]]; then
                security delete-keychain "${DEV_KEYCHAIN}"
            fi
            create_dev_keychain
        fi
        if ! security list-keychains -d user | grep -qF "\"${DEV_KEYCHAIN}\""; then
            add_dev_keychain_to_search_list
        fi
        security unlock-keychain -p "${DEV_KEYCHAIN_PASSWORD}" "${DEV_KEYCHAIN}"
        # Lets codesign use the key without a dialog. Done on every build so a
        # setup that stopped after the import is completed.
        security set-key-partition-list -S apple-tool:,apple: -s -k "${DEV_KEYCHAIN_PASSWORD}" "${DEV_KEYCHAIN}" > /dev/null
    fi
fi
EXECUTABLE="Soffos"
APP="${APP_NAME}.app"

ARCH_FLAGS=()
if [[ "$1" == "--universal" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "Compiling ${APP_NAME} ${VERSION}..."
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "Creating ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/Frameworks"

cp "${BIN_DIR}/${EXECUTABLE}" "${APP}/Contents/MacOS/${EXECUTABLE}"
ditto "${BIN_DIR}/Sparkle.framework" "${APP}/Contents/Frameworks/Sparkle.framework"
cp "${ICON}" "${APP}/Contents/Resources/AppIcon.icns"

cat > "${APP}/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>${APP_NAME} needs local network access to find and control your Sonos speakers.</string>
    ${UPDATE_KEYS}
</dict>
</plist>
EOF

# Sparkle's helpers are signed inside out, before the framework and the app
# that contain them.
echo "Code signing ${APP} (${SIGNING_IDENTITY:-ad hoc})..."
SIGN=(--force --sign "${SIGNING_IDENTITY:--}")
SPARKLE="${APP}/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${SIGN[@]}" "${SPARKLE}/XPCServices/Installer.xpc"
codesign "${SIGN[@]}" --preserve-metadata=entitlements "${SPARKLE}/XPCServices/Downloader.xpc"
codesign "${SIGN[@]}" "${SPARKLE}/Autoupdate"
codesign "${SIGN[@]}" "${SPARKLE}/Updater.app"
codesign "${SIGN[@]}" "${APP}/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN[@]}" "${APP}"
codesign --verify --deep --strict "${APP}"

echo "Creating ${APP_NAME}.zip..."
rm -f "${APP_NAME}.zip"
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${APP_NAME}.zip"

echo ""
echo "Done! Output:"
echo "  ${APP}  - ready to launch"
echo "  ${APP_NAME}.zip  - distributable archive"
