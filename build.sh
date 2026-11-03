#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
APP_DIR="$PROJECT_DIR/build/LibreBar.app"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
swiftc -swift-version 5 -O -framework AppKit -framework SwiftUI -framework Security -framework CryptoKit -framework ServiceManagement "$PROJECT_DIR/Sources/LibreBar.swift" -o "$APP_DIR/Contents/MacOS/LibreBar"
"$APP_DIR/Contents/MacOS/LibreBar" --self-test
xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
xattr -cr "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
print "Built $APP_DIR"
