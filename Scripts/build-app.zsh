#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
icon='Sources/KapitsaLauncher/Resources/Kapitsa.icns'
mark='Sources/KapitsaLauncher/KapitsaMark.swift'
# Regenerate the icon when it is missing or the shared mark has changed.
if [[ ! -s "$icon" || "$mark" -nt "$icon" || Scripts/make-icon/main.swift -nt "$icon" ]]; then
  mkdir -p Sources/KapitsaLauncher/Resources .build
  swiftc -O Scripts/make-icon/main.swift "$mark" -o .build/make-icon
  .build/make-icon
  iconutil -c icns .build/Kapitsa.iconset -o "$icon"
fi
swift build -c release --product KapitsaLauncher
app='dist/Kapitsa Launcher.app'
# Release builds pass the version from the git tag; local builds use the default.
version="${KAPITSA_LAUNCHER_VERSION:-0.1.0}"
build="${KAPITSA_LAUNCHER_BUILD:-1}"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$build" =~ '^[0-9]+$' ]] || { print -u2 "Invalid version or build number."; exit 1; }
# Start from an empty bundle so files from earlier builds can't linger in the app.
rm -rf -- "dist/Kapitsa Launcher.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Sources/KapitsaLauncher/Resources/Kapitsa.icns "$app/Contents/Resources/Kapitsa.icns"
cp .build/release/KapitsaLauncher "$app/Contents/MacOS/KapitsaLauncher"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>KapitsaLauncher</string>
  <key>CFBundleIdentifier</key><string>io.github.alphaexposure.KapitsaLauncher</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIconFile</key><string>Kapitsa.icns</string>
  <key>CFBundleName</key><string>Kapitsa Launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
test -s "$app/Contents/Resources/Kapitsa.icns"
# Refresh the bundle date so macOS notices resources changed during an in-place build.
touch "$app"
codesign --force --sign - "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PWD/$app"
print -r -- "$PWD/$app"
