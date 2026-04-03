#!/usr/bin/env bash
# Build a drag-and-drop DMG installer for AutoRipper.
# Requires: dist/AutoRipper.app (run build-swift.sh first)
set -e

APP_NAME="AutoRipper"
DMG_NAME="${APP_NAME}-Installer"
APP_PATH="dist/${APP_NAME}.app"
DMG_DIR="dist/dmg"
DMG_PATH="dist/${DMG_NAME}.dmg"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ $APP_PATH not found — run build-swift.sh first"
    exit 1
fi

echo "📦 Creating DMG..."

# Clean previous
rm -rf "$DMG_DIR" "$DMG_PATH"
mkdir -p "$DMG_DIR"

# Copy app bundle
cp -r "$APP_PATH" "$DMG_DIR/"

# Create Applications symlink for drag-and-drop install
ln -s /Applications "$DMG_DIR/Applications"

# Create DMG
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH"

# Clean up staging dir
rm -rf "$DMG_DIR"

echo ""
echo "✅ DMG created: $DMG_PATH"
echo "   Open it and drag AutoRipper to Applications."
