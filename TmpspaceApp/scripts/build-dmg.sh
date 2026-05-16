#!/bin/bash
# Build a release .dmg for tmpspace.
# Usage: ./scripts/build-dmg.sh [version]
# Output: ~/Desktop/Tmpspace-<version>.dmg
#
# For App Store / signed distribution, set these env vars first:
#   export DEV_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   export APPLE_ID="your@email.com"
#   export APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"   # App-specific password

set -euo pipefail

VERSION="${1:-1.1}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

echo "=== Building tmpspace v${VERSION} ==="

# 1. Build release binary
echo "→ Building release binary..."
swift build -c release 2>&1

# 2. Create .app bundle
BUNDLE_DIR="${PROJECT_DIR}/Tmpspace.app"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp "${PROJECT_DIR}/.build/arm64-apple-macosx/release/Tmpspace" \
   "${BUNDLE_DIR}/Contents/MacOS/Tmpspace"

# 3. Copy Info.plist
cp "${PROJECT_DIR}/Info.plist" \
   "${BUNDLE_DIR}/Contents/Info.plist"

# 4. Copy resources (icons, editor dist)
echo "→ Copying resources..."
mkdir -p "${BUNDLE_DIR}/Contents/Resources/icon"
mkdir -p "${BUNDLE_DIR}/Contents/Resources/dist/chunks"
cp -R "${PROJECT_DIR}/Resources/icon/" "${BUNDLE_DIR}/Contents/Resources/icon/"
cp "${PROJECT_DIR}/Resources/AppIcon.icns" "${BUNDLE_DIR}/Contents/Resources/" 2>/dev/null || true
DIST_SRC="/Users/admin/Desktop/tmpspace/MarkEdit-main/CoreEditor/dist"
if [ -d "$DIST_SRC" ]; then
    cp "$DIST_SRC/index.html" "${BUNDLE_DIR}/Contents/Resources/dist/"
    cp "$DIST_SRC/chunks/"* "${BUNDLE_DIR}/Contents/Resources/dist/chunks/"
    echo "→ Resources copied"
else
    echo "⚠ WARNING: dist/ not found at $DIST_SRC — editor will not work"
fi

# 5. Copy entitlements
if [ -f "${PROJECT_DIR}/TmpspaceApp.entitlements" ]; then
    cp "${PROJECT_DIR}/TmpspaceApp.entitlements" \
       "${BUNDLE_DIR}/Contents/Resources/TmpspaceApp.entitlements"
    echo "→ Entitlements copied"
fi

# 6. Add version stamp
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" \
   "${BUNDLE_DIR}/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
   "${BUNDLE_DIR}/Contents/Info.plist" 2>/dev/null || true

echo "→ Bundle created: ${BUNDLE_DIR}"

# 6. Code sign (if identity provided)
ENTITLEMENTS_PATH="${PROJECT_DIR}/TmpspaceApp.entitlements"
if [ -n "${DEV_IDENTITY:-}" ] && [ -f "$ENTITLEMENTS_PATH" ]; then
    echo "→ Signing with: ${DEV_IDENTITY}"
    codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS_PATH" \
        --sign "$DEV_IDENTITY" \
        "$BUNDLE_DIR"
    echo "→ Signed OK"
else
    echo "→ Skipping code sign (set DEV_IDENTITY env var to enable)"
fi

# 7. Create staging directory with /Applications symlink
STAGE_DIR="${PROJECT_DIR}/Tmpspace-DMG-Staging"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$BUNDLE_DIR" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

# 8. Create .dmg from staging directory
DMG_PATH="${HOME}/Desktop/Tmpspace-${VERSION}.dmg"
rm -f "$DMG_PATH"
hdiutil create -volname "Tmpspace" \
    -srcfolder "$STAGE_DIR" \
    -ov -format UDZO \
    "$DMG_PATH" 2>&1

# Clean up staging
rm -rf "$STAGE_DIR"

# 9. Sign .dmg (if identity provided)
if [ -n "${DEV_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$DEV_IDENTITY" "$DMG_PATH"
    echo "→ DMG signed OK"
fi

echo "→ DMG created: ${DMG_PATH}"
ls -lh "$DMG_PATH"

# 9. Notarize (if credentials provided)
if [ -n "${APPLE_ID:-}" ] && [ -n "${APP_PASSWORD:-}" ] && [ -n "${DEV_IDENTITY:-}" ]; then
    echo "→ Submitting for notarization..."
    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --password "$APP_PASSWORD" \
        --team-id "$(echo "$DEV_IDENTITY" | grep -oE '\([A-Z0-9]+\)' | tr -d '()')" \
        --wait 2>&1

    echo "→ Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"
    echo "→ Notarization complete"
fi

echo "=== Done ==="
