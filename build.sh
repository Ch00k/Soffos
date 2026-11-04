#!/bin/bash
# Builds Soffos.app (and Soffos.zip) from the Swift package.
#
#   ./build.sh              # native architecture
#   ./build.sh --universal  # arm64 + x86_64 (needs full Xcode)
set -e

APP_NAME="Soffos"
BUNDLE_ID="re.mntw.soffos"
VERSION="VERSION_PLACEHOLDER"

ARCH_FLAGS=()
if [[ "$1" == "--universal" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "Compiling ${APP_NAME}..."
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "Creating ${APP_NAME}.app bundle..."
rm -rf "${APP_NAME}.app"
mkdir -p "${APP_NAME}.app/Contents/MacOS"
mkdir -p "${APP_NAME}.app/Contents/Resources"

cp "${BIN_DIR}/${APP_NAME}" "${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

if [[ -f icon.icns ]]; then
    cp icon.icns "${APP_NAME}.app/Contents/Resources/AppIcon.icns"
fi

cat > "${APP_NAME}.app/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
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
    <string>Soffos needs local network access to find and control your Sonos speakers.</string>
</dict>
</plist>
EOF

echo "Code signing ${APP_NAME}.app..."
codesign --force --deep --sign - "${APP_NAME}.app"

echo "Creating ${APP_NAME}.zip..."
rm -f "${APP_NAME}.zip"
ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "${APP_NAME}.zip"

echo ""
echo "Done! Output:"
echo "  ${APP_NAME}.app  - ready to launch"
echo "  ${APP_NAME}.zip  - distributable archive"
