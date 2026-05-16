#!/bin/bash
# Build and upload tmpspace to the Mac App Store.
#
# Prerequisites:
#   1. Apple Distribution certificate in Keychain
#      ("Apple Distribution: Jiahui Jiang (S8FBPXF9AA)")
#   2. Mac App Store provisioning profile installed
#      (~/Library/MobileDevice/Provisioning Profiles/*.provisionprofile)
#   3. App-specific password generated at https://appleid.apple.com
#
# Usage:
#   export APPLE_ID="your@email.com"
#   export APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
#   ./scripts/build-appstore.sh 1.2
#
# Output: ~/Desktop/Tmpspace-<version>.pkg (uploaded to App Store Connect)

set -euo pipefail

VERSION="${1:-1.2}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES_DIR="${PROJECT_DIR}/Resources"
DIST_SRC="/Users/admin/Desktop/tmpspace/MarkEdit-main/CoreEditor/dist"
DIST_DIR="${PROJECT_DIR}/dist"
BUILD_DIR="${PROJECT_DIR}/.build/arm64-apple-macosx/release"
BUNDLE_DIR="${PROJECT_DIR}/Tmpspace.app"
SIGNING_IDENTITY="Apple Distribution: Jiahui Jiang (S8FBPXF9AA)"
BUNDLE_ID="com.tmpspace.app"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "============================================"
echo "  Tmpspace App Store Build v${VERSION}"
echo "============================================"

# ── 1. Build release binary ──────────────────────────────────
echo ""
echo "→ [1/8] Building release binary with SPM..."
cd "$PROJECT_DIR"
swift build -c release --disable-sandbox 2>&1
echo -e "${GREEN}  Build complete${NC}"

# ── 2. Prepare .app bundle ───────────────────────────────────
echo ""
echo "→ [2/8] Creating .app bundle..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources/icon"
mkdir -p "$BUNDLE_DIR/Contents/Resources/dist/chunks"

# Copy binary
cp "${BUILD_DIR}/Tmpspace" "$BUNDLE_DIR/Contents/MacOS/Tmpspace"
chmod +x "$BUNDLE_DIR/Contents/MacOS/Tmpspace"

# Copy Info.plist
cp "${PROJECT_DIR}/Info.plist" "$BUNDLE_DIR/Contents/Info.plist"

# Copy resources (flat — no .bundle directories)
cp "${RESOURCES_DIR}/AppIcon.icns" "$BUNDLE_DIR/Contents/Resources/AppIcon.icns"
cp "${RESOURCES_DIR}/icon/"*.svg "$BUNDLE_DIR/Contents/Resources/icon/"
cp "${DIST_SRC}/index.html" "$BUNDLE_DIR/Contents/Resources/dist/index.html"
cp "${DIST_SRC}/chunks/"* "$BUNDLE_DIR/Contents/Resources/dist/chunks/"

# Copy notify.wav (SPM builds it into the bundle — grab from build output)
NOTIFY_SRC=$(find "$BUILD_DIR" -name 'notify.wav' -path '*/TmpspaceEditor*' 2>/dev/null | head -1)
if [ -n "$NOTIFY_SRC" ] && [ -f "$NOTIFY_SRC" ]; then
    cp "$NOTIFY_SRC" "$BUNDLE_DIR/Contents/Resources/notify.wav"
    echo "  notify.wav: copied from build output"
else
    echo "  notify.wav: WARNING — not found, sound disabled"
fi

# Copy entitlements for reference
cp "${PROJECT_DIR}/TmpspaceApp.entitlements" "$BUNDLE_DIR/Contents/Resources/"

# ── 3. Stamp version ─────────────────────────────────────────
echo ""
echo "→ [3/8] Stamping version ${VERSION}..."
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" \
    "$BUNDLE_DIR/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
    "$BUNDLE_DIR/Contents/Info.plist" 2>/dev/null || true

# ── 4. Embed provisioning profile ────────────────────────────
echo ""
echo "→ [4/8] Embedding provisioning profile..."
PROV_DIR="${HOME}/Library/MobileDevice/Provisioning Profiles"
PROV_FILE=$(ls -t "$PROV_DIR"/*.provisionprofile 2>/dev/null | head -1)
if [ -z "$PROV_FILE" ]; then
    echo -e "${RED}  ERROR: No .provisionprofile found in ${PROV_DIR}${NC}"
    echo "  Please install the Mac App Store provisioning profile first."
    exit 1
fi
cp "$PROV_FILE" "$BUNDLE_DIR/Contents/embedded.provisionprofile"
echo "  Using: $(basename "$PROV_FILE")"

# ── 5. Sign .app bundle ──────────────────────────────────────
echo ""
echo "→ [5/8] Signing .app bundle with Apple Distribution..."
codesign --force --timestamp --options runtime \
    --entitlements "${PROJECT_DIR}/TmpspaceApp.entitlements" \
    --sign "$SIGNING_IDENTITY" \
    "$BUNDLE_DIR" 2>&1
codesign --verify --deep --strict "$BUNDLE_DIR" 2>&1
echo -e "${GREEN}  .app signed and verified${NC}"

# ── 6. Create .pkg with productbuild ─────────────────────────
echo ""
echo "→ [6/8] Creating .pkg with productbuild..."
PKG_PATH="${HOME}/Desktop/Tmpspace-${VERSION}.pkg"
rm -f "$PKG_PATH"

# Create a component plist for productbuild
COMP_PLIST=$(mktemp)
cat > "$COMP_PLIST" << COMPEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
</dict>
</plist>
COMPEOF

# Build unsigned .pkg first, then sign with productsign.
echo "→ Building unsigned .pkg..."
UNSIGNED_PKG=$(mktemp).pkg
productbuild --component "$BUNDLE_DIR" /Applications \
    --product "$COMP_PLIST" \
    "$UNSIGNED_PKG" 2>&1

echo "→ Signing .pkg with productsign..."
productsign --sign "$SIGNING_IDENTITY" \
    "$UNSIGNED_PKG" \
    "$PKG_PATH" 2>&1
rm -f "$UNSIGNED_PKG"
rm -f "$COMP_PLIST"

echo -e "${GREEN}  .pkg created: ${PKG_PATH}${NC}"
ls -lh "$PKG_PATH"

# ── 7. Validate .pkg ─────────────────────────────────────────
echo ""
echo "→ [7/8] Validating .pkg with altool..."
if [ -n "${APPLE_ID:-}" ] && [ -n "${APP_PASSWORD:-}" ]; then
    xcrun altool --validate-app \
        --file "$PKG_PATH" \
        --type osx \
        --username "$APPLE_ID" \
        --app-password "$APP_PASSWORD" 2>&1
    echo -e "${GREEN}  Validation complete${NC}"
else
    echo "  Skipping (set APPLE_ID and APP_PASSWORD to validate)"
fi

# ── 8. Upload to App Store Connect ───────────────────────────
echo ""
echo "→ [8/8] Uploading to App Store Connect..."
if [ -n "${APPLE_ID:-}" ] && [ -n "${APP_PASSWORD:-}" ]; then
    xcrun altool --upload-app \
        --file "$PKG_PATH" \
        --type osx \
        --username "$APPLE_ID" \
        --app-password "$APP_PASSWORD" 2>&1
    echo -e "${GREEN}  Upload complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Visit https://appstoreconnect.apple.com"
    echo "  2. Open your app record (com.tmpspace.app)"
    echo "  3. Select the new build under 'TestFlight' or 'App Store'"
    echo "  4. Complete metadata and submit for review"
else
    echo "  Skipping upload (set APPLE_ID and APP_PASSWORD)"
    echo ""
    echo "Manual upload:"
    echo "  xcrun altool --upload-app --file ${PKG_PATH} --type osx"
fi

echo ""
echo "============================================"
echo "  All steps complete!"
echo "============================================"
