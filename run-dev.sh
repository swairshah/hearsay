#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Hearsay"
BUNDLE_ID="com.swair.hearsay"
BUILD_APP="build/Build/Products/Debug/Hearsay.app"
DEV_APP=".dev/Hearsay.app"
DEV_BIN="$DEV_APP/Contents/MacOS/Hearsay"
BINARY_SRC="$HOME/work/misc/qwen-asr/qwen_asr"

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

# Build
echo -e "${YELLOW}Building...${NC}"
xcodebuild -project Hearsay.xcodeproj \
    -scheme Hearsay \
    -configuration Debug \
    -derivedDataPath build \
    build 2>&1 | grep -E "^(Build|error:|warning:|\*\*)" || true

# Check build succeeded
if [ ! -d "$BUILD_APP" ]; then
    echo -e "${RED}Build failed!${NC}"
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
        codesign --force --sign - "$DEV_APP/Contents/MacOS/qwen_asr"
    fi

    # Sign the whole bundle
    codesign --force --sign - "$DEV_APP"

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
    # Update only the binary + resources in the stable bundle
    echo -e "${YELLOW}Updating dev app bundle...${NC}"
    cp "$BUILD_APP/Contents/MacOS/Hearsay" "$DEV_BIN"
    # Also copy debug dylib and any other supporting binaries
    for f in "$BUILD_APP/Contents/MacOS/"*.dylib; do
        [ -f "$f" ] && cp "$f" "$DEV_APP/Contents/MacOS/"
    done
    cp -R "$BUILD_APP/Contents/Resources/" "$DEV_APP/Contents/Resources/"
    cp "$BUILD_APP/Contents/Info.plist" "$DEV_APP/Contents/Info.plist"
fi

# Update qwen_asr if it's newer
if [ -f "$BINARY_SRC" ]; then
    if [ ! -f "$DEV_APP/Contents/MacOS/qwen_asr" ] || [ "$BINARY_SRC" -nt "$DEV_APP/Contents/MacOS/qwen_asr" ]; then
        echo -e "${YELLOW}Updating qwen_asr binary...${NC}"
        cp "$BINARY_SRC" "$DEV_APP/Contents/MacOS/"
        codesign --force --sign - "$DEV_APP/Contents/MacOS/qwen_asr"
    fi
fi

# Launch the binary directly (preserves TCC permissions)
echo -e "${GREEN}Launching Hearsay (dev mode)...${NC}"
"$DEV_BIN" &
PID=$!

sleep 1
echo -e "${GREEN}Hearsay is running (PID: $PID)${NC}"
echo -e "Hold RIGHT OPTION (⌥) to record."
echo ""
echo -e "To stop: ${YELLOW}pkill -f Hearsay${NC}"
echo -e "Logs:    ${YELLOW}log stream --predicate 'subsystem == \"com.swair.hearsay\"' --level debug${NC}"
