#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="Hearsay"
BUNDLE_ID="com.swair.hearsay"
APP_PATH="build/Build/Products/Debug/Hearsay.app"
BINARY_SRC="$HOME/work/misc/qwen-asr/qwen_asr"
RESET_PERMISSIONS=true

for arg in "$@"; do
    case "$arg" in
        --no-reset)
            RESET_PERMISSIONS=false
            ;;
        --reset)
            RESET_PERMISSIONS=true
            ;;
        *)
            echo "Unknown flag: $arg"
            echo "Usage: ./run.sh [--no-reset|--reset]"
            exit 1
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Hearsay Build & Run ===${NC}"

# Kill existing instance
pkill -f "Hearsay.app" 2>/dev/null || true

# Generate Xcode project if needed
if [ ! -d "Hearsay.xcodeproj" ] || [ "project.yml" -nt "Hearsay.xcodeproj" ]; then
    echo -e "${YELLOW}Generating Xcode project...${NC}"
    xcodegen generate
fi

# Remove old qwen_asr from bundle (prevents codesign failure)
rm -f "$APP_PATH/Contents/MacOS/qwen_asr" 2>/dev/null || true

# Build
echo -e "${YELLOW}Building...${NC}"
xcodebuild -project Hearsay.xcodeproj \
    -scheme Hearsay \
    -configuration Debug \
    -derivedDataPath build \
    build 2>&1 | grep -E "^(Build|error:|warning:|\*\*)" || true

# Check build succeeded
if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}Build failed!${NC}"
    exit 1
fi

# Copy qwen_asr binary into app bundle and re-sign
if [ -f "$BINARY_SRC" ]; then
    echo -e "${YELLOW}Bundling qwen_asr binary...${NC}"
    cp "$BINARY_SRC" "$APP_PATH/Contents/MacOS/"
    # Sign the binary and re-sign the whole app bundle
    codesign --force --sign - "$APP_PATH/Contents/MacOS/qwen_asr"
    codesign --force --sign - "$APP_PATH"
else
    echo -e "${RED}Warning: qwen_asr binary not found at $BINARY_SRC${NC}"
    echo "Build it first: cd ~/work/misc/qwen-asr && make blas"
fi

if [ "$RESET_PERMISSIONS" = true ]; then
    # Reset permissions (clears stale entries from previous builds)
    echo -e "${YELLOW}Resetting permissions...${NC}"
    tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true

    # Check if we need to prompt for accessibility
    echo ""
    echo -e "${YELLOW}NOTE: After rebuild, you may need to re-grant Accessibility permission.${NC}"
    echo -e "If hotkey doesn't work:"
    echo -e "  1. Open System Settings → Privacy & Security → Accessibility"
    echo -e "  2. Click + and add: ${GREEN}$(pwd)/$APP_PATH${NC}"
    echo ""

    # Ask user if they want to open settings
    read -p "Open Accessibility Settings now? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        echo -e "${YELLOW}Add Hearsay.app, then press Enter to launch...${NC}"
        read
    fi
else
    echo -e "${GREEN}Skipping permission reset (--no-reset).${NC}"
fi

# Launch
echo -e "${GREEN}Launching Hearsay...${NC}"
open "$APP_PATH"

echo -e "${GREEN}Done! Hold RIGHT OPTION (⌥) to record.${NC}"
