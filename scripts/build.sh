#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
APP="$PWD/dist/Tokenometr.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -whole-module-optimization -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
  Sources/*.swift -o "$APP/Contents/MacOS/Tokenometr" -framework AppKit -framework ServiceManagement -lsqlite3
cp Resources/* "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier dev.tokenometr.app "$APP"
du -sh "$APP"
print "Готово: $APP"
