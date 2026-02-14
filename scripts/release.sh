#!/bin/bash
# Build, sign, notarize, and create DMG for Hearsay
#
# Prerequisites:
#   - Xcode Command Line Tools
#   - Developer ID Application certificate
#   - App-specific password in ~/.env as APPLE_APP_PASSWORD
#   - create-dmg: brew install create-dmg
#
# Usage:
#   ./scripts/release.sh
#   ./scripts/release.sh --skip-notarize  # Skip notarization (faster for testing)

set -e

cd "$(dirname "$0")/.."

# Load environment
source ~/.env 2>/dev/null || true

# Configuration
APP_NAME="Hearsay"
BUNDLE_ID="com.swair.hearsay"
SCHEME="Hearsay"

# Signing identity (adjust if different)
SIGNING_IDENTITY="Developer ID Application: Swair Rajesh Shah (8B9YURJS4G)"
TEAM_ID="8B9YURJS4G"

# Apple ID for notarization
APPLE_ID="swairshah@gmail.com"  # Your Apple ID email
# APPLE_APP_PASSWORD should be in ~/.env

# Paths
BUILD_DIR="build/Release"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="$APP_NAME"
DMG_PATH="dist/$DMG_NAME.dmg"
QWEN_ASR_BINARY="$HOME/work/misc/qwen-asr/qwen_asr"

# Parse arguments
SKIP_NOTARIZE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarize)
            SKIP_NOTARIZE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Hearsay Release Build ===${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if [ -z "$APPLE_APP_PASSWORD" ]; then
    echo -e "${RED}Error: APPLE_APP_PASSWORD not set in ~/.env${NC}"
    exit 1
fi

if [ ! -f "$QWEN_ASR_BINARY" ]; then
    echo -e "${RED}Error: qwen_asr binary not found at $QWEN_ASR_BINARY${NC}"
    echo "Build it first: cd ~/work/misc/qwen-asr && make blas"
    exit 1
fi

if ! command -v create-dmg &> /dev/null; then
    echo -e "${YELLOW}Installing create-dmg...${NC}"
    brew install create-dmg
fi

# Clean previous builds
echo -e "${YELLOW}Cleaning previous builds...${NC}"
rm -rf build/Release
rm -rf dist
mkdir -p dist

# Generate Xcode project
echo -e "${YELLOW}Generating Xcode project...${NC}"
xcodegen generate

# Build Release
echo -e "${YELLOW}Building Release configuration...${NC}"
xcodebuild -project Hearsay.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath build \
    -archivePath "build/$APP_NAME.xcarchive" \
    archive \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE="Manual" \
    2>&1 | grep -E "(error:|warning:|BUILD|Archive)"

# Export from archive
echo -e "${YELLOW}Exporting app from archive...${NC}"

cat > build/export-options.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "build/$APP_NAME.xcarchive" \
    -exportPath "$BUILD_DIR" \
    -exportOptionsPlist build/export-options.plist \
    2>&1 | grep -E "(error:|Export)"

# Bundle qwen_asr binary
echo -e "${YELLOW}Bundling qwen_asr binary...${NC}"
cp "$QWEN_ASR_BINARY" "$APP_PATH/Contents/MacOS/"

# Sign the bundled binary
echo -e "${YELLOW}Signing bundled binary...${NC}"
codesign --force --options runtime \
    --sign "$SIGNING_IDENTITY" \
    "$APP_PATH/Contents/MacOS/qwen_asr"

# Re-sign the entire app (including nested code)
echo -e "${YELLOW}Re-signing app bundle...${NC}"
codesign --force --deep --options runtime \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "Hearsay/Hearsay.entitlements" \
    "$APP_PATH"

# Verify signature
echo -e "${YELLOW}Verifying signature...${NC}"
codesign --verify --verbose=2 "$APP_PATH"
spctl --assess --verbose=2 "$APP_PATH" || true

if [ "$SKIP_NOTARIZE" = false ]; then
    # Create ZIP for notarization
    echo -e "${YELLOW}Creating ZIP for notarization...${NC}"
    ditto -c -k --keepParent "$APP_PATH" "build/$APP_NAME.zip"

    # Submit for notarization
    echo -e "${YELLOW}Submitting for notarization (this may take a few minutes)...${NC}"
    xcrun notarytool submit "build/$APP_NAME.zip" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$TEAM_ID" \
        --wait

    # Staple the notarization ticket
    echo -e "${YELLOW}Stapling notarization ticket...${NC}"
    xcrun stapler staple "$APP_PATH"

    # Verify stapling
    echo -e "${YELLOW}Verifying notarization...${NC}"
    xcrun stapler validate "$APP_PATH"
    spctl --assess --verbose=2 "$APP_PATH"
else
    echo -e "${YELLOW}Skipping notarization (--skip-notarize)${NC}"
fi

# Create DMG
echo -e "${YELLOW}Creating DMG...${NC}"

# Get version from Info.plist
VERSION=$(defaults read "$(pwd)/$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
DMG_PATH="dist/${APP_NAME}-${VERSION}.dmg"

create-dmg \
    --volname "$APP_NAME" \
    --volicon "$APP_PATH/Contents/Resources/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "$APP_NAME.app" 150 190 \
    --app-drop-link 450 185 \
    --hide-extension "$APP_NAME.app" \
    "$DMG_PATH" \
    "$APP_PATH" \
    2>&1 || true

# Sign the DMG
echo -e "${YELLOW}Signing DMG...${NC}"
codesign --force --sign "$SIGNING_IDENTITY" "$DMG_PATH"

if [ "$SKIP_NOTARIZE" = false ]; then
    # Notarize the DMG
    echo -e "${YELLOW}Notarizing DMG...${NC}"
    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$TEAM_ID" \
        --wait

    # Staple the DMG
    echo -e "${YELLOW}Stapling DMG...${NC}"
    xcrun stapler staple "$DMG_PATH"
fi

echo ""
echo -e "${GREEN}=== Release Build Complete ===${NC}"
echo ""
echo -e "App: ${GREEN}$APP_PATH${NC}"
echo -e "DMG: ${GREEN}$DMG_PATH${NC}"
echo ""

# Show file sizes
ls -lh "$DMG_PATH"
