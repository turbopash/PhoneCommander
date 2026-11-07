#!/bin/zsh
# Сборка Phone Commander. Нужно: Command Line Tools и `brew install libimobiledevice`.
set -e
cd "${0:A:h}"
APP="build/Phone Commander.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
PREFIX="${PC_PREFIX:-/opt/homebrew}"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -import-objc-header Sources/bridge.h -I"$PREFIX/include" -L"$PREFIX/lib" \
  -limobiledevice-1.0 -lplist-2.0 Sources/*.swift -o "$APP/Contents/MacOS/PhoneCommander"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Phone Commander</string>
<key>CFBundleExecutable</key><string>PhoneCommander</string>
<key>CFBundleIdentifier</key><string>local.phonecommander</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
P
codesign --force -s - "$APP"
echo "Собрано: $PWD/$APP"
