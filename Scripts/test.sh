#!/bin/bash
# 사용법: Scripts/test.sh [--filter 패턴]
# 빌드 로그 대신 실패·컴파일 오류·요약만 남긴다.
set -uo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."
log="$(mktemp -t usageisland-test)"
swift test "$@" >"$log" 2>&1
status=$?
grep -E 'error:|: failed|failed \(|Test Suite .All tests|Executed [0-9]+ test|warning: var|Test run with|✘|◇ Test run' "$log" | grep -v 'SwiftCompile normal' | sed -E 's/\x1b\[[0-9;]*m//g' | head -80
echo "exit=$status"
exit $status
