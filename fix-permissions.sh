#!/bin/bash
# Quick fix for accessibility permissions after rebuild

cd "$(dirname "$0")"

BUNDLE_ID="com.swair.hearsay"
APP_PATH="$(pwd)/build/Build/Products/Debug/Hearsay.app"

echo "=== Hearsay Permission Fix ==="

# Kill app if running
pkill -f "Hearsay.app" 2>/dev/null || true

# Reset TCC
echo "Resetting accessibility permissions..."
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true

# Open settings
echo ""
echo "Opening Accessibility Settings..."
echo "Please add: $APP_PATH"
echo ""
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

echo "After adding, press Enter to launch Hearsay..."
read

open "$APP_PATH"
echo "Done! Try RIGHT OPTION to record."
