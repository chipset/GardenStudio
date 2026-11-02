#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH=/private/tmp/sketchmake-clang-cache
export SWIFT_MODULECACHE_PATH=/private/tmp/sketchmake-swift-cache
if [[ -f "${SKETCHUP_SDK_HEADERS:-/Applications/Maxon Cinema 4D 2026/resource/modules/io_skp/Framework/SketchUpAPI.framework/Versions/A/Headers}/sketchup.h" ]]; then
  ./scripts/build-native.sh
fi
if [[ -f "${WCORE_SOURCE_ROOT:-/Users/thomas/Documents/source/woodworking-studio/Sources/WoodworkCore}/Model.swift" ]]; then
  ./scripts/build-woodwork.sh
fi
swift build --disable-sandbox --build-system native -c release -Xswiftc -gnone
APP="$PWD/artifacts/Sketch Make.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SketchMake "$APP/Contents/MacOS/SketchMake.next"
mv -f "$APP/Contents/MacOS/SketchMake.next" "$APP/Contents/MacOS/SketchMake"
cp scripts/model_script_bridge.rb scripts/ruby_runner.rb "$APP/Contents/Resources/"
if [[ -x artifacts/native/SketchNativeWorker ]]; then
  cp artifacts/native/SketchNativeWorker "$APP/Contents/Resources/SketchNativeWorker.next"
  mv -f "$APP/Contents/Resources/SketchNativeWorker.next" "$APP/Contents/Resources/SketchNativeWorker"
fi
if [[ -x artifacts/native/WoodworkWorker ]]; then
  cp artifacts/native/WoodworkWorker "$APP/Contents/Resources/WoodworkWorker.next"
  mv -f "$APP/Contents/Resources/WoodworkWorker.next" "$APP/Contents/Resources/WoodworkWorker"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SketchMake</string>
<key>CFBundleIdentifier</key><string>local.sketchmake.app</string>
<key>CFBundleName</key><string>Sketch Make</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.6.5</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" artifacts/SketchMake-macOS.zip
echo "$APP"
