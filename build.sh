#!/usr/bin/env bash
set -e

echo "🧪 Running tests..."
/opt/homebrew/bin/python3.13 -m pytest tests/ -q
echo ""

echo "🔨 Building AutoRipper.app..."
/opt/homebrew/bin/python3.13 -m PyInstaller AutoRipper.spec --noconfirm --clean

echo ""
echo "✅ Build complete!"
echo "📦 App bundle: dist/AutoRipper.app"
echo ""
echo "To install, run:"
echo "  cp -r dist/AutoRipper.app /Applications/"
