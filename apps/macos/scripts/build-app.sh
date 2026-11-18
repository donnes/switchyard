#!/bin/sh
# Builds build/Switchyard.app with SwiftPM and registers it with Launch Services.
# Usage: scripts/build-app.sh [release|debug]
# scripts/release sets SWITCHYARD_VERSION, like 0.1.0, to stamp the bundle.
set -eu
cd "$(dirname "$0")/.."
config=${1:-release}

swift build -c "$config" --product Switchyard
bin=$(swift build -c "$config" --show-bin-path)

# The app icon: actool compiles the Icon Composer project into Assets.car, which macOS 26 draws as
# Liquid Glass, plus an .icns. See assets/README.md. It runs before the old bundle is removed, so a
# failure leaves the last working app in place.
icon=build/icon
rm -rf "$icon"
mkdir -p "$icon"
xcrun actool ../../assets/app-icon.icon \
  --compile "$icon" \
  --platform macosx \
  --minimum-deployment-target 26.0 \
  --app-icon app-icon \
  --output-partial-info-plist "$icon/icon.plist" >/dev/null
# actool exits 0 without writing an icon when it can't read the project.
if [ ! -f "$icon/Assets.car" ] || [ ! -f "$icon/app-icon.icns" ]; then
  echo "actool wrote no app icon; compiling an Icon Composer project takes Xcode 26 or newer" >&2
  exit 1
fi

app=build/Switchyard.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Switchyard" "$app/Contents/MacOS/Switchyard"
cp Support/Info.plist "$app/Contents/Info.plist"
if [ -n "${SWITCHYARD_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $SWITCHYARD_VERSION" \
    -c "Set :CFBundleVersion $SWITCHYARD_VERSION" \
    "$app/Contents/Info.plist"
fi
mv "$icon/Assets.car" "$icon/app-icon.icns" "$app/Contents/Resources/"
rm -rf "$icon"
codesign --force --sign - "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "$PWD/$app"
