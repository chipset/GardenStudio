#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
WCORE_SOURCE_ROOT="${WCORE_SOURCE_ROOT:-/Users/thomas/Documents/source/woodworking-studio/Sources/WoodworkCore}"
if [[ ! -f "$WCORE_SOURCE_ROOT/Model.swift" || ! -f "$WCORE_SOURCE_ROOT/EdgeTreatment.swift" ]]; then
  echo "Woodwork helper build requires the existing Woodwork Studio core source directory (WCORE_SOURCE_ROOT)." >&2
  exit 1
fi
mkdir -p artifacts/native
export CLANG_MODULE_CACHE_PATH=/private/tmp/sketchmake-clang-cache
export SWIFT_MODULECACHE_PATH=/private/tmp/sketchmake-swift-cache
swiftc -swift-version 5 -O -whole-module-optimization -target arm64-apple-macosx13.0 -module-name WoodworkNativeWorker "$WCORE_SOURCE_ROOT"/*.swift native/WoodworkWorker.swift -o artifacts/native/WoodworkWorker
codesign --force --sign - artifacts/native/WoodworkWorker
