#!/bin/bash
# 사용법: Scripts/snapshots.sh <출력 폴더>
# 표본 데이터로 패널을 PNG로 뽑는다. 실제 계정과 네트워크를 쓰지 않는다.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."
log="$(mktemp -t usageisland-snapshots)"
if ! swift build --product IslandSnapshots >"$log" 2>&1; then
  grep -E 'error:' "$log" | grep -v 'SwiftCompile normal' | sed -E 's/\x1b\[[0-9;]*m//g' | head -40
  exit 1
fi
"$(swift build --show-bin-path)/IslandSnapshots" "$1"
