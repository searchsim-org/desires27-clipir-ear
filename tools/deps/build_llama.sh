#!/usr/bin/env bash
# Build llama.cpp (pinned tag, MIT) from source for iOS simulator, iOS device and macOS:
# the published b11624 xcframework has no iOS simulator slice, and EarSim needs one (ADR-010).
set -euo pipefail
TAG=b11624
COMMIT=af0579c78a07a555d84830d01da7b61cfadbc7ef
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$ROOT/.build/llama-src
OUT=$ROOT/Packages/llama
[ -d "$OUT/llama.xcframework" ] && { echo "build_llama: OK (cached $TAG)"; exit 0; }
[ -d "$SRC" ] || git clone -q --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp.git "$SRC"
cd "$SRC"
[ "$(git rev-parse HEAD)" = "$COMMIT" ] || { echo "llama.cpp source is not at $TAG ($COMMIT)"; exit 1; }
./build-xcframework.sh ios-sim ios-device macos
mkdir -p "$OUT" && rm -rf "$OUT/llama.xcframework"
cp -R build-apple/llama.xcframework "$OUT/"
plutil -p "$OUT/llama.xcframework/Info.plist" | grep LibraryIdentifier
echo "build_llama: OK ($TAG, built from source)"
