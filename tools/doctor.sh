#!/usr/bin/env bash
# make doctor — checks HANDOVER §2.1 as amended by ADR-005/ADR-008 (macOS ≥ 15.6, Xcode 16.2+ or 26.0–26.3). Exit 1 on anything missing.
set -u
fail=0
ok()  { printf "  ok    %-14s %s\n" "$1" "$2"; }
bad() { printf "  FAIL  %-14s %s\n" "$1" "$2"; fail=1; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

macos=$(sw_vers -productVersion)
ver_ge "$macos" 15.6 && ok macOS "$macos" || bad macOS "$macos (need ≥ 15.6)"

xcode=$(xcodebuild -version 2>/dev/null | awk 'NR==1{print $2}')
case "$xcode" in 16.[2-9]|16.[2-9].*|26.[0-3]|26.[0-3].*) ok Xcode "$xcode" ;; *) bad Xcode "${xcode:-none} (need 16.2+ or 26.0–26.3, ADR-008)" ;; esac

swiftv=$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p' | head -1)
ver_ge "${swiftv:-0}" 6.0 && ok swift "$swiftv" || bad swift "${swiftv:-none} (need ≥ 6.0)"
swift format --version >/dev/null 2>&1 && ok swift-format "bundled" || bad swift-format "missing"

for t in uv ollama ffmpeg sox jq git-lfs xcbeautify ruff; do
    command -v "$t" >/dev/null && ok "$t" "$(command -v "$t")" || bad "$t" "missing (make bootstrap)"
done
py=$(uv python find 3.12 2>/dev/null) && ok python3.12 "$py" || bad python3.12 "missing (uv python install 3.12)"

if xcrun simctl list devices 2>/dev/null | grep -q "EarSim"; then ok EarSim "present"
else bad EarSim "missing: xcodebuild -downloadPlatform iOS && xcrun simctl create EarSim 'iPhone 13 Pro Max'"; fi

[ $fail -eq 0 ] && echo "doctor: OK" || echo "doctor: FAILED"
exit $fail
