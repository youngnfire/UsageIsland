#!/bin/bash
# 사용법: Scripts/release.sh
# Developer ID로 서명·공증하고 공증 티켓을 붙인 dist/UsageIsland.zip을 만든다.
#
# 필요한 환경변수:
#   SIGN_IDENTITY      "Developer ID Application: ..." 인증서 이름
#   APPLE_API_KEY      App Store Connect API 키(.p8) 경로
#   APPLE_API_KEY_ID   API 키 ID
#   APPLE_API_ISSUER   API 발급자 ID
set -euo pipefail
: "${SIGN_IDENTITY:?SIGN_IDENTITY가 필요합니다}"
: "${APPLE_API_KEY:?APPLE_API_KEY가 필요합니다}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID가 필요합니다}"
: "${APPLE_API_ISSUER:?APPLE_API_ISSUER가 필요합니다}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
app="dist/UsageIsland.app"
zip="dist/UsageIsland.zip"

bash Scripts/build-app.sh

rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" \
  --key "$APPLE_API_KEY" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER" \
  --wait --timeout 20m

# 티켓을 앱에 붙인 뒤 다시 압축해야 오프라인에서도 Gatekeeper를 통과한다.
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
shasum -a 256 "$zip"
