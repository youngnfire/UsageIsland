#!/bin/bash
# 사용법: Scripts/verify-real-window.sh <출력 폴더>
# 디버그 빌드를 실제 메뉴바에 띄워 창 렌더링과 연속 클릭 경쟁을 점검한다. 실제 계정을 읽는다.
set -uo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."
log="$(mktemp -t usageisland-verify)"
if ! swift build --product UsageIsland >"$log" 2>&1; then
  grep -E 'error:' "$log" | grep -v 'SwiftCompile normal' | sed -E 's/\x1b\[[0-9;]*m//g' | head -40
  exit 1
fi
bin="$(swift build --show-bin-path)/UsageIsland"

# 메뉴바 아이콘이 둘이 되지 않게 설치본을 잠시 내렸다가 끝나면 다시 띄운다.
pkill -x UsageIsland || true
sleep 1
"$bin" --verify "$1" &
pid=$!
( sleep 60; kill "$pid" 2>/dev/null ) &
watchdog=$!
wait "$pid"
status=$?
kill "$watchdog" 2>/dev/null
echo "exit=$status"
open /Applications/UsageIsland.app
