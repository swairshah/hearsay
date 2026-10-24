#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Hearsay Dev"
# A separate bundle ID gives the dev build its own TCC rows (Accessibility,
# Microphone, System Audio) instead of fighting the installed app for one.
BUNDLE_ID="com.swair.hearsay.dev"
RELEASE_BUNDLE_ID="com.swair.hearsay"
BUILD_APP="build/Build/Products/Debug/Hearsay.app"
DEV_APP=".dev/$APP_NAME.app"
DEV_BIN="$DEV_APP/Contents/MacOS/Hearsay"
BINARY_SRC="$HOME/work/misc/qwen-asr/qwen_asr"
SIGN_IDENTITY="Hearsay Dev"  # Self-signed cert for stable TCC permissions

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Hearsay Dev Build & Run ===${NC}"

# Kill existing instance
pkill -f "Hearsay" 2>/dev/null || true
sleep 0.5

# Generate Xcode project if needed
if [ ! -d "Hearsay.xcodeproj" ] || [ "project.yml" -nt "Hearsay.xcodeproj" ]; then
    echo -e "${YELLOW}Generating Xcode project...${NC}"
    xcodegen generate
fi

# Build the Parakeet/diarization helper first (the app bundles it)
echo -e "${YELLOW}Building Parakeet helper...${NC}"
xcodebuild -project Hearsay.xcodeproj \
    -scheme HearsayParakeetHelper \
    -configuration Debug \
    -derivedDataPath build \
    -skipMacroValidation \
    build

# Build
echo -e "${YELLOW}Building...${NC}"
# Remove previous build output so stale binaries never get launched on build failure
rm -rf "$BUILD_APP"
xcodebuild -project Hearsay.xcodeproj \
    -scheme Hearsay \
    -configuration Debug \
    -derivedDataPath build \
    -skipMacroValidation \
    build

# Check build succeeded
if [ ! -d "$BUILD_APP" ]; then
    echo -e "${RED}Build failed!${NC}"
    exit 1
fi

# Check that signing identity exists
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo -e "${RED}Signing certificate '$SIGN_IDENTITY' not found!${NC}"
    echo -e "Run this once to create it:"
    echo -e "  ${YELLOW}./setup-cert.sh${NC}"
    exit 1
fi

# Create stable dev app bundle if it doesn't exist yet
# This bundle persists across builds so TCC permissions stick
if [ ! -d "$DEV_APP" ]; then
    echo -e "${YELLOW}Creating stable dev app bundle...${NC}"
    mkdir -p .dev
    cp -R "$BUILD_APP" "$DEV_APP"

    # Bundle qwen_asr
    if [ -f "$BINARY_SRC" ]; then
        cp "$BINARY_SRC" "$DEV_APP/Contents/MacOS/"
        codesign --force --sign "$SIGN_IDENTITY" "$DEV_APP/Contents/MacOS/qwen_asr"
    fi

    # Sign the whole bundle with the persistent certificate
    codesign --force --sign "$SIGN_IDENTITY" "$DEV_APP"

    echo ""
    echo -e "${YELLOW}First run — you need to grant Accessibility permission once.${NC}"
    echo -e "  1. Open System Settings → Privacy & Security → Accessibility"
    echo -e "  2. Click + and add: ${GREEN}$(pwd)/$DEV_APP${NC}"
    echo ""
    read -p "Open Accessibility Settings now? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        echo -e "${YELLOW}Add Hearsay.app, then press Enter to launch...${NC}"
        read
    fi
else
    # Update the binary + resources in the stable bundle
    echo -e "${YELLOW}Updating dev app bundle...${NC}"
    cp "$BUILD_APP/Contents/MacOS/Hearsay" "$DEV_BIN"
    # Also copy debug dylib and any other supporting binaries
    for f in "$BUILD_APP/Contents/MacOS/"*.dylib; do
        [ -f "$f" ] && cp "$f" "$DEV_APP/Contents/MacOS/"
    done
    cp -R "$BUILD_APP/Contents/Resources/" "$DEV_APP/Contents/Resources/"
    cp "$BUILD_APP/Contents/Info.plist" "$DEV_APP/Contents/Info.plist"
fi

# Dev identity: own bundle ID and name, so permissions don't collide with
# /Applications/Hearsay.app. Data in ~/Library/Application Support/Hearsay is shared.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$DEV_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$DEV_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "$DEV_APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$DEV_APP/Contents/Info.plist"

# Start the dev build with the installed app's settings (model, hotkey, onboarding) once
if ! defaults read "$BUNDLE_ID" >/dev/null 2>&1 && defaults read "$RELEASE_BUNDLE_ID" >/dev/null 2>&1; then
    echo -e "${YELLOW}Copying settings from $RELEASE_BUNDLE_ID...${NC}"
    defaults export "$RELEASE_BUNDLE_ID" - | defaults import "$BUNDLE_ID" -
fi

# Parakeet transcription + meeting speaker detection run in this helper
HELPER_SRC="build/Build/Products/Debug/HearsayParakeetHelper"
if [ -f "$HELPER_SRC" ]; then
    cp "$HELPER_SRC" "$DEV_APP/Contents/MacOS/HearsayParakeetHelper"
    chmod 755 "$DEV_APP/Contents/MacOS/HearsayParakeetHelper"
fi

# Update qwen_asr if it's newer
if [ -f "$BINARY_SRC" ]; then
    if [ ! -f "$DEV_APP/Contents/MacOS/qwen_asr" ] || [ "$BINARY_SRC" -nt "$DEV_APP/Contents/MacOS/qwen_asr" ]; then
        echo -e "${YELLOW}Updating qwen_asr binary...${NC}"
        cp "$BINARY_SRC" "$DEV_APP/Contents/MacOS/"
    fi
fi

# Re-sign the bundle after any updates (same identity = TCC permissions persist)
# Nested binaries must be signed before the outer bundle
echo -e "${YELLOW}Signing with '$SIGN_IDENTITY'...${NC}"
for nested in "$DEV_APP/Contents/MacOS/"*; do
    [ -f "$nested" ] && [ -x "$nested" ] && [ "$(basename "$nested")" != "Hearsay" ] && \
        codesign --force --sign "$SIGN_IDENTITY" "$nested" 2>/dev/null || true
done
codesign --force --sign "$SIGN_IDENTITY" "$DEV_APP"

# Launch through LaunchServices so macOS attributes permissions to the app
# itself rather than to the terminal that ran this script
echo -e "${GREEN}Launching $APP_NAME...${NC}"
open -n "$DEV_APP"

sleep 1
echo -e "${GREEN}$APP_NAME is running (PID: $(pgrep -nf "$DEV_BIN"))${NC}"
echo -e "Hold RIGHT OPTION (⌥) to record."
echo ""
echo -e "To stop: ${YELLOW}pkill -f Hearsay${NC}"
echo -e "Logs:    ${YELLOW}log stream --predicate 'subsystem == \"com.swair.hearsay\"' --level debug${NC}"
