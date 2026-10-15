#!/usr/bin/env bash
# Build sherpa-onnx (pinned tag) WITHOUT TTS for iOS device, iOS simulator and macOS arm64, and assemble
# Packages/SherpaOnnx/{SherpaOnnxC,onnxruntime}.xcframework.   ADR-007: no espeak-ng (GPL-3.0) in any slice.
# Usage: make deps   (needs cmake, wget; downloads only from github.com release assets)
set -euo pipefail
TAG=v1.13.8
ORT=1.28.2
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC=$ROOT/.build/sherpa-onnx-src
OUT=$ROOT/Packages/SherpaOnnx
ORT_URL=https://github.com/csukuangfj/onnxruntime-libs/releases/download/v$ORT
JOBS=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo 4)

[ -d "$SRC" ] || git clone -q --depth 1 --branch "$TAG" https://github.com/k2-fsa/sherpa-onnx.git "$SRC"
cd "$SRC"
[ "$(git describe --tags)" = "$TAG" ] || { echo "sherpa-onnx source is not at $TAG"; exit 1; }

# 1. iOS device + simulator, upstream no-TTS script (only the job count changed)
if [ ! -d build-ios-no-tts/sherpa-onnx.xcframework ]; then
  sed "s/-j 4/-j $JOBS/" build-ios-no-tts.sh > build-ios-no-tts.local.sh
  bash build-ios-no-tts.local.sh
fi

# 2. macOS arm64, TTS off, linked against the static onnxruntime from the same release family
MAC=build-macos-no-tts
if [ ! -f $MAC/framework/SherpaOnnxC.framework/SherpaOnnxC ]; then
  mkdir -p $MAC/ort && pushd $MAC/ort >/dev/null
  if [ ! -d onnxruntime.xcframework ]; then
    wget -q -c "$ORT_URL/onnxruntime-macos-static-xcframework-$ORT.xcframework.zip"
    unzip -q -o "onnxruntime-macos-static-xcframework-$ORT.xcframework.zip"
  fi
  popd >/dev/null
  ORT_SLICE=$(ls -d $PWD/$MAC/ort/onnxruntime.xcframework/macos-*)
  SHERPA_ONNXRUNTIME_LIB_DIR=$ORT_SLICE SHERPA_ONNXRUNTIME_INCLUDE_DIR=$ORT_SLICE/onnxruntime.framework/Headers \
  cmake -S . -B $MAC/build -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PWD/$MAC/install -DBUILD_SHARED_LIBS=OFF \
    -DSHERPA_ONNX_ENABLE_TTS=OFF -DSHERPA_ONNX_ENABLE_BINARY=OFF -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF \
    -DSHERPA_ONNX_ENABLE_PYTHON=OFF -DSHERPA_ONNX_ENABLE_TESTS=OFF -DSHERPA_ONNX_ENABLE_CHECK=OFF \
    -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF -DSHERPA_ONNX_ENABLE_JNI=OFF -DSHERPA_ONNX_ENABLE_C_API=ON \
    -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF >/dev/null
  cmake --build $MAC/build -j "$JOBS"
  cmake --install $MAC/build >/dev/null
  L=$MAC/install/lib
  FW=$MAC/framework/SherpaOnnxC.framework
  rm -rf $FW && mkdir -p $FW/Headers/sherpa-onnx/c-api $FW/Modules
  libtool -static -o $FW/SherpaOnnxC $L/libsherpa-onnx-c-api.a $L/libsherpa-onnx-core.a \
    $L/libkaldi-native-fbank-core.a $L/libkissfft-float.a $L/libsherpa-onnx-fstfar.a $L/libsherpa-onnx-fst.a \
    $L/libsherpa-onnx-kaldifst-core.a $L/libkaldi-decoder-core.a $L/libssentencepiece_core.a
  cp $MAC/install/include/sherpa-onnx/c-api/c-api.h $FW/Headers/sherpa-onnx/c-api/
  cp build-ios-no-tts/build/os64/SherpaOnnxC.framework/Modules/module.modulemap $FW/Modules/
fi

# 3. Assemble three-platform xcframeworks
rm -rf "$OUT/SherpaOnnxC.xcframework" "$OUT/onnxruntime.xcframework" && mkdir -p "$OUT"
I=build-ios-no-tts
xcodebuild -create-xcframework -output "$OUT/SherpaOnnxC.xcframework" \
  -framework $I/build/os64/SherpaOnnxC.framework \
  -framework $I/build/simulator/SherpaOnnxC.framework \
  -framework $MAC/framework/SherpaOnnxC.framework >/dev/null
IORT=$I/ios-onnxruntime/onnxruntime.xcframework
xcodebuild -create-xcframework -output "$OUT/onnxruntime.xcframework" \
  -framework $IORT/ios-arm64/onnxruntime.framework \
  -framework $IORT/ios-arm64_x86_64-simulator/onnxruntime.framework \
  -framework "$(ls -d $MAC/ort/onnxruntime.xcframework/macos-*)/onnxruntime.framework" >/dev/null

# 4. ADR-007 guard: no espeak-ng / piper in any slice
if find "$OUT/SherpaOnnxC.xcframework" -name SherpaOnnxC -type f -exec nm -A {} + 2>/dev/null | grep -qiE "espeak|piper"; then
  echo "FAIL: espeak-ng/piper symbols found (ADR-007)"; exit 1
fi
ls "$OUT/SherpaOnnxC.xcframework" "$OUT/onnxruntime.xcframework"
echo "build_sherpa: OK ($TAG, onnxruntime $ORT, TTS off)"
