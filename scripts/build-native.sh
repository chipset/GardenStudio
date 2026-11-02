#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
SDK_HEADERS="${SKETCHUP_SDK_HEADERS:-/Applications/Maxon Cinema 4D 2026/resource/modules/io_skp/Framework/SketchUpAPI.framework/Versions/A/Headers}"
if [[ ! -f "$SDK_HEADERS/sketchup.h" ]]; then
  echo "Native SketchUp helper requires locally installed public SketchUp SDK headers." >&2
  exit 1
fi
INCLUDES=$(mktemp -d /private/tmp/sketchmake-native-includes.XXXXXX)
trap 'rm -rf "$INCLUDES"' EXIT
ln -s "$SDK_HEADERS" "$INCLUDES/SketchUpAPI"
mkdir -p artifacts/native
clang++ -std=c++17 -fobjc-arc -framework Foundation -framework ImageIO -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 -I"$INCLUDES" native/NativeMain.mm native/NativeModel.mm native/NativeMaterial.mm -o artifacts/native/SketchNativeWorker
codesign --force --sign - artifacts/native/SketchNativeWorker
