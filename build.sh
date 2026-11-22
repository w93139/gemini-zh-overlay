#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="build/Gemini 中文侧栏.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/"
cp Settings.zh-Hans.json "$app/Contents/Resources/"
xcrun swiftc -O Sources/*.swift -o "$app/Contents/MacOS/GeminiSidebar"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "$app"
