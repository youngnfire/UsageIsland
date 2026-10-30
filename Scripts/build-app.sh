#!/bin/bash
# 사용법: Scripts/build-app.sh [--install]
# dist/UsageIsland.app을 만든다. --install이면 /Applications에 넣고 다시 실행한다.
# SIGN_IDENTITY를 주면 그 인증서로 hardened runtime 서명을 하고, 없으면 ad-hoc으로 서명한다.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
root="$PWD"
app="$root/dist/UsageIsland.app"
installed="/Applications/UsageIsland.app"
bundle_id="com.ynf.usageisland"
log="$(mktemp -t usageisland-build)"

fail() {
  grep -E 'error:' "$log" | grep -v 'SwiftCompile normal' | sed -E 's/\x1b\[[0-9;]*m//g' | head -40
  echo "build failed; full log: $log"
  exit 1
}

# Apple Silicon과 Intel을 따로 빌드해 하나의 실행 파일로 합친다.
slices=()
for arch in arm64 x86_64; do
  scratch=".build/$arch"
  swift build -c release --arch "$arch" --scratch-path "$scratch" --product UsageIsland >>"$log" 2>&1 || fail
  slices+=("$(swift build -c release --arch "$arch" --scratch-path "$scratch" --show-bin-path)/UsageIsland")
done
swift build --product IslandSnapshots >>"$log" 2>&1 || fail
grep -E 'warning:' "$log" | sed -E 's/\x1b\[[0-9;]*m//g' | sort -u | head -20 || true
tool_bin="$(swift build --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "${slices[@]}" -output "$app/Contents/MacOS/UsageIsland"
cp Resources/Info.plist "$app/Contents/Info.plist"

iconset="$(mktemp -d -t usageisland-icon)/AppIcon.iconset"
"$tool_bin/IslandSnapshots" --icon "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

identity="${SIGN_IDENTITY:--}"
if [ "$identity" = "-" ]; then
  codesign --force --sign - --identifier "$bundle_id" "$app"
else
  codesign --force --sign "$identity" --identifier "$bundle_id" --options runtime --timestamp "$app"
fi
codesign --verify --strict "$app"
echo "built: $app"

if [ "${1:-}" = "--install" ]; then
  if [ -e "$installed" ]; then
    existing="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$installed/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$existing" != "$bundle_id" ]; then
      echo "refusing to replace $installed (bundle id: $existing)"
      exit 1
    fi
    pkill -x UsageIsland || true
    sleep 1
    rm -rf "$installed"
  fi
  ditto "$app" "$installed"
  open "$installed"
  echo "installed: $installed"
fi
