#!/bin/bash
set -euo pipefail

APP_NAME="AutoRipper"
BUNDLE_ID="com.autoripper.app"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_DIR="$BUILD_DIR/AutoRipperSwift"
DIST_DIR="$BUILD_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ICON_SRC="$BUILD_DIR/assets/AutoRipper.icns"
VERSION_FILE="$BUILD_DIR/VERSION"

# Read version from VERSION file
VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
echo "🔨 Building $APP_NAME v$VERSION..."

# Update version in UpdateService.swift
sed -i '' "s/static let currentVersion = \".*\"/static let currentVersion = \"$VERSION\"/" \
    "$SWIFT_DIR/AutoRipper/Services/UpdateService.swift"

# Update version in AutoRipperApp.swift
sed -i '' "s/\.applicationVersion: \".*\"/\.applicationVersion: \"$VERSION\"/" \
    "$SWIFT_DIR/AutoRipper/AutoRipperApp.swift"
sed -i '' "s/AutoRipper .* starting/AutoRipper $VERSION starting/" \
    "$SWIFT_DIR/AutoRipper/AutoRipperApp.swift"

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

    <!-- TCC usage descriptions: shown when macOS prompts the user for these
         capabilities. Without them the prompts can fail silently or repeat —
         which was breaking unattended Batch Mode. -->
    <key>NSRemovableVolumesUsageDescription</key>
    <string>AutoRipper reads inserted DVDs and Blu-ray discs to scan and rip them.</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>AutoRipper writes finished rips to your configured NAS share.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>AutoRipper saves ripped and encoded files to the output folder you choose, which defaults to ~/Desktop/Ripped.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>AutoRipper may save ripped and encoded files to a folder under Documents if you choose one.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>AutoRipper may save ripped and encoded files to a folder under Downloads if you choose one.</string>
</dict>
</plist>
PLIST
echo "   ✅ Info.plist created"

# 7. Code sign — prefer a stable identity so TCC permissions persist across
#    builds. Falls back to ad-hoc if no usable identity is in the keychain.
echo "🔏 Code signing..."
SIGN_IDENTITY=""
# Prefer Developer ID, then Apple Development, then anything else codesigning-capable.
# `|| true` because grep returns 1 when there's no match — set -e would otherwise exit.
for filter in "Developer ID Application" "Apple Development" "Mac Developer"; do
    FOUND=$(security find-identity -v -p codesigning 2>/dev/null | grep "\"$filter" | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
    if [ -n "$FOUND" ]; then
        SIGN_IDENTITY="$FOUND"
        break
    fi
done

if [ -n "$SIGN_IDENTITY" ]; then
    echo "   Using identity: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE" 2>&1
else
    echo "   ⚠️  No code signing identity found — falling back to ad-hoc"
    echo "   ⚠️  TCC permissions will reset on every build with ad-hoc signing"
    codesign --force --deep --sign - "$APP_BUNDLE" 2>&1
fi
echo "   ✅ Signed"

# 8. Verify
echo "🔍 Verifying..."
codesign --verify --deep --strict "$APP_BUNDLE" 2>&1
echo "   ✅ Verified"

# 9. Create DMG
echo "💿 Creating DMG..."
cd "$BUILD_DIR"
bash "$BUILD_DIR/create-dmg.sh"

# 10. Git tag + GitHub release
echo "🚀 Creating GitHub release v$VERSION..."
cd "$BUILD_DIR"
git add -A
git commit -m "Release v$VERSION

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" || true
git tag -f "v$VERSION"
git push origin main --tags --force 2>&1

gh release create "v$VERSION" \
    --title "$APP_NAME v$VERSION" \
    --generate-notes \
    "$DIST_DIR/AutoRipper-Installer.dmg" 2>&1 || \
gh release upload "v$VERSION" "$DIST_DIR/AutoRipper-Installer.dmg" --clobber 2>&1

# 11. Bump patch version for next build
IFS='.' read -r major minor patch <<< "$VERSION"
NEXT="$major.$minor.$((patch + 1))"
echo "$NEXT" > "$VERSION_FILE"
git add "$VERSION_FILE"
git commit -m "Bump version to $NEXT for next build

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" || true
git push origin main 2>&1

# 12. Summary
APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
echo ""
echo "✅ $APP_NAME v$VERSION released!"
echo "   📍 $APP_BUNDLE ($APP_SIZE)"
echo "   💿 $DIST_DIR/AutoRipper-Installer.dmg"
echo "   🏷️  Tagged: v$VERSION"
echo "   📦 Next version: $NEXT"
