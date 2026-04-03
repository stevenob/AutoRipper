#!/bin/bash
set -euo pipefail

APP_NAME="AutoRipper"
BUNDLE_ID="com.autoripper.app"
VERSION="2.0.0"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_DIR="$BUILD_DIR/AutoRipperSwift"
DIST_DIR="$BUILD_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ICON_SRC="$BUILD_DIR/assets/AutoRipper.icns"

echo "🔨 Building $APP_NAME $VERSION..."

# 1. Run tests
echo "🧪 Running tests..."
cd "$SWIFT_DIR"
swift test --quiet
echo "   ✅ Tests passed"

# 2. Build release binary
echo "📦 Building release binary..."
swift build -c release --quiet
BINARY="$SWIFT_DIR/.build/release/$APP_NAME"

if [ ! -f "$BINARY" ]; then
    echo "❌ Build failed — binary not found"
    exit 1
fi
echo "   ✅ Built: $BINARY"

# 3. Create .app bundle structure
echo "📁 Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 4. Copy binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 5. Copy icon
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/$APP_NAME.icns"
    echo "   ✅ Icon copied"
else
    echo "   ⚠️  No icon found at $ICON_SRC"
fi

# 6. Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2024-2026 AutoRipper</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST
echo "   ✅ Info.plist created"

# 7. Code sign (ad-hoc)
echo "🔏 Code signing (ad-hoc)..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>&1
echo "   ✅ Signed"

# 8. Verify
echo "🔍 Verifying..."
codesign --verify --deep --strict "$APP_BUNDLE" 2>&1
echo "   ✅ Verified"

# 9. Summary
APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
echo ""
echo "✅ $APP_NAME.app built successfully!"
echo "   📍 $APP_BUNDLE"
echo "   📏 Size: $APP_SIZE"
echo ""
echo "To install:"
echo "   cp -r $APP_BUNDLE /Applications/"
echo ""
echo "To create a DMG:"
echo "   bash create-dmg.sh"
