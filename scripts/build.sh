#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH=/private/tmp/gardenstudio-clang-cache
export SWIFT_MODULECACHE_PATH=/private/tmp/gardenstudio-swift-cache
if [[ -f "${SKETCHUP_SDK_HEADERS:-/Applications/Maxon Cinema 4D 2026/resource/modules/io_skp/Framework/SketchUpAPI.framework/Versions/A/Headers}/sketchup.h" ]]; then
  ./scripts/build-native.sh
fi
if [[ -f "${WCORE_SOURCE_ROOT:-/Users/thomas/Documents/source/woodworking-studio/Sources/WoodworkCore}/Model.swift" ]]; then
  ./scripts/build-woodwork.sh
fi
swift build --disable-sandbox --build-system native -c release -Xswiftc -gnone
APP="$PWD/artifacts/Garden Studio.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/GardenStudio "$APP/Contents/MacOS/GardenStudio.next"
mv -f "$APP/Contents/MacOS/GardenStudio.next" "$APP/Contents/MacOS/GardenStudio"
cp scripts/garden_studio_bridge.rb scripts/ruby_runner.rb "$APP/Contents/Resources/"
if [[ -x artifacts/native/GardenStudioNativeWorker ]]; then
  cp artifacts/native/GardenStudioNativeWorker "$APP/Contents/Resources/GardenStudioNativeWorker.next"
  mv -f "$APP/Contents/Resources/GardenStudioNativeWorker.next" "$APP/Contents/Resources/GardenStudioNativeWorker"
fi
if [[ -x artifacts/native/GardenStudioWoodworkWorker ]]; then
  cp artifacts/native/GardenStudioWoodworkWorker "$APP/Contents/Resources/GardenStudioWoodworkWorker.next"
  mv -f "$APP/Contents/Resources/GardenStudioWoodworkWorker.next" "$APP/Contents/Resources/GardenStudioWoodworkWorker"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>GardenStudio</string>
<key>CFBundleIdentifier</key><string>local.gardenstudio.app</string>
<key>CFBundleName</key><string>Garden Studio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.6</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" artifacts/GardenStudio-macOS.zip
echo "$APP"
