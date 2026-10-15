#!/bin/sh
# Kokoro TTS packages (ADR-020), pinned by commit. They declare swift-tools 6.2 (Xcode 26); the app builds with
# Xcode 16.2 (ADR-008), so this lowers the tools version and drops `nonisolated` on type declarations, which only
# has meaning under Swift 6.2's default-main-actor mode. Idempotent.
set -e
cd "$(dirname "$0")/../.."
D=Packages/kokoro
mkdir -p "$D"
get() {  # name url commit
  if [ -d "$D/$1" ]; then git -C "$D/$1" fetch -q --tags; else git clone -q "$2" "$D/$1"; fi
  git -C "$D/$1" checkout -q -f "$3"
  git -C "$D/$1" clean -fdq
  sed -i '' '1s/swift-tools-version: *6\.2/swift-tools-version: 6.0/' "$D/$1/Package.swift"
}
get kokoro-ios      https://github.com/mlalma/kokoro-ios.git      4d6d1d8ff8cd012014180c9cd4cf0151e7682354  # 1.0.11
get MisakiSwift     https://github.com/mlalma/MisakiSwift.git     b7477b15fc46cf8e20b32c008126611b38ec6b79  # 1.0.6
get MLXUtilsLibrary https://github.com/mlalma/MLXUtilsLibrary.git cb6b744e10342139103332162d0cdf0f495ef722  # 0.0.6
sed -i '' 's#\.package(url: "https://github.com/mlalma/MisakiSwift"[^)]*)#.package(path: "../MisakiSwift")#; s#\.package(url: "https://github.com/mlalma/MLXUtilsLibrary.git"[^)]*)#.package(path: "../MLXUtilsLibrary")#' "$D/kokoro-ios/Package.swift"
sed -i '' 's#\.package(url: "https://github.com/mlalma/MLXUtilsLibrary.git"[^)]*)#.package(path: "../MLXUtilsLibrary")#' "$D/MisakiSwift/Package.swift"
# iOS codesign rejects a resource folder named "Resources" inside a bundle (same as EarCore's Assets folder): rename
# it to Assets in both packages, in the manifest and in the Bundle.module lookups.
mv "$D/MisakiSwift/Sources/MisakiSwift/Resources" "$D/MisakiSwift/Sources/MisakiSwift/Assets"
sed -i '' 's#\.copy("Resources")#.copy("Assets")#' "$D/MisakiSwift/Package.swift"
mv "$D/kokoro-ios/Resources" "$D/kokoro-ios/Assets"
sed -i '' 's#\.copy("\.\./\.\./Resources/")#.copy("../../Assets/")#' "$D/kokoro-ios/Package.swift"
find "$D/MisakiSwift/Sources" "$D/kokoro-ios/Sources" -name "*.swift" -exec sed -i '' 's/subdirectory: "Resources"/subdirectory: "Assets"/' {} +
find "$D" -name "*.swift" -path "*/Sources/*" -exec sed -i '' -E \
  's/^([[:space:]]*)(public |internal |private |fileprivate )?nonisolated ((final |public |open )*)(class|struct|enum|extension) /\1\2\3\5 /' {} +
if grep -rEn '^[[:space:]]*(public |internal |private )?nonisolated (final |public |open )*(class|struct|enum|extension) ' "$D"/*/Sources; then
  echo "unpatched nonisolated type declarations remain" >&2; exit 1
fi
echo "kokoro packages ready in $D"
