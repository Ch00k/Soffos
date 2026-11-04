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
# SIGNING_IDENTITY names the code signing certificate to use; without it the
# app is signed ad hoc.
set -e

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
