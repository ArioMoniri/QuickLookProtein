#!/usr/bin/env bash
#
# release.sh — build, sign, notarise, staple, and zip QuickLookProtein for distribution.
#
# Usage:
#   ./scripts/release.sh <version>
#   e.g. ./scripts/release.sh 2.0.0
#
# One-time setup (see docs/RELEASE.md):
#   1. Have a "Developer ID Application" certificate in your login keychain.
#   2. Store an app-specific password in the keychain via:
#        xcrun notarytool store-credentials notarytool-profile \
#          --apple-id YOUR_APPLE_ID@example.com \
#          --team-id   FF68N39FU5 \
#          --password  YOUR-APP-SPECIFIC-PASSWORD
#      The credentials are read by name on each run; you only do this once.
#
set -euo pipefail

# ---- Inputs --------------------------------------------------------------
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"; exit 1
fi

TEAM_ID="${TEAM_ID:-FF68N39FU5}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Ariorad Moniri (${TEAM_ID})}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool-profile}"
SCHEME="${SCHEME:-QuickLookProtein}"
PROJECT="${PROJECT:-Xcode/QuickLookProtein.xcodeproj}"

BUILD_DIR="build/release"
ARCHIVE_PATH="${BUILD_DIR}/QuickLookProtein.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
APP_PATH="${EXPORT_PATH}/QuickLookProtein.app"
ZIP_NAME="QuickLookProtein-${VERSION}.zip"
ZIP_PATH="${BUILD_DIR}/${ZIP_NAME}"

# ---- Cleanup -------------------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ---- Archive -------------------------------------------------------------
echo "▶ Archiving (this builds all four targets)…"
xcodebuild -project "$PROJECT" \
           -scheme "$SCHEME" \
           -configuration Release \
           -archivePath "$ARCHIVE_PATH" \
           -destination 'generic/platform=macOS' \
           MARKETING_VERSION="$VERSION" \
           DEVELOPMENT_TEAM="$TEAM_ID" \
           CODE_SIGN_STYLE=Manual \
           CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
           archive | xcbeautify || true

# ---- Export --------------------------------------------------------------
EXPORT_PLIST="$(mktemp)"
cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key>          <string>developer-id</string>
  <key>teamID</key>          <string>${TEAM_ID}</string>
  <key>signingStyle</key>    <string>manual</string>
  <key>signingCertificate</key> <string>Developer ID Application</string>
</dict></plist>
EOF

echo "▶ Exporting signed .app…"
xcodebuild -exportArchive \
           -archivePath "$ARCHIVE_PATH" \
           -exportPath "$EXPORT_PATH" \
           -exportOptionsPlist "$EXPORT_PLIST"
rm -f "$EXPORT_PLIST"

# ---- Quick local signing-validation -------------------------------------
echo "▶ Verifying code signature…"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl -a -t exec -vv "$APP_PATH" || true  # informational; will fail until notarised

# ---- Zip for notarytool -------------------------------------------------
echo "▶ Packaging $ZIP_NAME…"
( cd "$EXPORT_PATH" && /usr/bin/ditto -c -k --keepParent QuickLookProtein.app "../${ZIP_NAME}" )

# ---- Notarise -----------------------------------------------------------
echo "▶ Submitting to Apple notary service (this can take 2–10 minutes)…"
xcrun notarytool submit "$ZIP_PATH" \
                 --keychain-profile "$NOTARY_PROFILE" \
                 --wait

# ---- Staple -------------------------------------------------------------
echo "▶ Stapling notarisation ticket…"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

# ---- Repackage stapled app ----------------------------------------------
echo "▶ Repackaging stapled .app into final ZIP…"
rm -f "$ZIP_PATH"
( cd "$EXPORT_PATH" && /usr/bin/ditto -c -k --keepParent QuickLookProtein.app "../${ZIP_NAME}" )

echo ""
echo "✅ Release ready: $ZIP_PATH"
echo ""
echo "Next steps:"
echo "  1. gh release create v${VERSION} \"$ZIP_PATH\" --notes-file CHANGELOG.md"
echo "     (or upload manually at https://github.com/ArioMoniri/QuickLookProtein/releases/new)"
echo "  2. Once published, your in-app updater will pick it up automatically."
