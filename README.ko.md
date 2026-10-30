# UsageIsland

[English](README.md) | **한국어**

Claude Code, Codex, DeepSeek의 남은 사용량을 메뉴바에서 바로 보는 맥 앱입니다. `claude usage`를 치거나 웹사이트에
들어가지 않아도, 메뉴바의 `>_` 아이콘을 누르면 아이콘 바로 아래에 Dynamic Island 모양의 패널이 펼쳐집니다.

![사용량 패널](docs/images/usage.png)

*실제 앱 화면을 표본 계정으로 그린 이미지입니다.*

## 설치

**[UsageIsland.zip 내려받기](https://github.com/youngnfire/UsageIsland/releases/latest/download/UsageIsland.zip)** 후
압축을 풀어 `UsageIsland.app`을 응용 프로그램 폴더로 옮기고 실행하세요. Apple 공증을 받은 앱이라 macOS가 차단하지 않습니다.

터미널로 설치하려면:

```sh
curl -L -o /tmp/UsageIsland.zip https://github.com/youngnfire/UsageIsland/releases/latest/download/UsageIsland.zip
ditto -x -k /tmp/UsageIsland.zip /Applications
open /Applications/UsageIsland.app
```

macOS 14 이상에서 동작하고, Apple Silicon과 Intel Mac을 모두 지원합니다. 첫 실행 때 로그인 시 자동 실행이 켜지며
패널의 톱니 버튼에서 끌 수 있습니다.

## 쓸 수 있는 것

- **계정별 남은 양:** 5시간, 주간, 모델별 한도를 링으로 보여 주고 초기화까지 남은 시간을 함께 표시합니다.
- **DeepSeek 잔액:** API 키를 연결하면 잔액을 보여 줍니다.
- **여러 계정:** 같은 서비스의 계정 여러 개를 나란히 보여 줍니다.
- **경고 색:** 남은 양이 30% 이하면 노랑, 10% 이하면 빨강으로 바뀝니다.
- **로그인 만료 안내:** 다시 로그인해야 하면 버튼이 나타나고, 끝나면 자동으로 다시 읽습니다.

![계정 설정](docs/images/settings.png)

## 계정 연결

| 서비스 | 필요한 것 |
|---|---|
| Claude | 이 맥에서 Claude Code CLI에 로그인돼 있으면 자동으로 나타납니다 |
| Codex | 이 맥에서 Codex CLI에 로그인돼 있으면 자동으로 나타납니다 |
| DeepSeek | 패널에서 API 키를 붙여넣습니다. 잔액 조회에 성공한 키만 저장합니다 |

계정을 더 추가하려면 톱니 버튼을 누르세요.

- **Claude / Codex:** 터미널 창이 열리고 브라우저 로그인을 마치면 `~/.claude-2`, `~/.codex-2` 같은 새 폴더에 저장돼
  자동으로 나타납니다. 이 계정을 CLI에서 쓰려면 `CLAUDE_CONFIG_DIR`, `CODEX_HOME`으로 같은 폴더를 지정하세요.
- **DeepSeek:** 이름과 API 키를 입력합니다.

앱은 `~/.claude.json`과 `/Users` 아래 각 홈 폴더의 `.claude`, `.claude-*`, `.codex`, `.codex-*` 폴더 중 읽을 수 있는 곳에서 계정을 찾습니다.

## 데이터와 보안

UsageIsland에는 자체 서버와 분석 도구가 없습니다.

| 서비스 | 읽는 곳 | 토큰 처리 |
|---|---|---|
| Claude | `api.anthropic.com/api/oauth/usage` | 요청할 때마다 Claude Code의 키체인 항목을 읽어 그 요청에만 씁니다 |
| Codex | `codex app-server`의 `account/rateLimits/read` | 앱은 토큰을 쓰지 않습니다. `auth.json`에서는 표시용 이메일과 계정 ID만 읽습니다 |
| DeepSeek | `api.deepseek.com/user/balance` | API 키를 키체인에 넣고 그 요청에만 씁니다 |

- **로그인 정보를 고치지 않습니다.** 앱이 refresh 토큰을 쓰면 CLI 로그인이 풀릴 수 있어 갱신은 각 CLI에 맡깁니다.
  Claude 토큰이 만료되면 모델을 호출하지 않는 `claude -p /cost`를 훅과 MCP를 끈 채 실행하며, 30분에 한 번만 시도합니다.
- **모르면 모른다고 표시합니다.** 응답 구조가 바뀌면 100%로 보이지 않고 "응답을 읽지 못함"으로 나옵니다. 조회에 실패하면
  마지막 값을 회색으로 두고 언제 값인지 함께 보여 줍니다.
- **API를 아낍니다.** 10분마다, 그리고 패널을 열 때 마지막 조회가 1분 넘게 지났으면 읽습니다. 요청 제한을 받으면 그 계정은
  재시도 시각까지 쉽니다.

설정은 `~/Library/Application Support/UsageIsland/settings.json`에 있고 비밀값은 들어가지 않습니다.

## 주의

Claude와 Codex의 사용량 경로는 공식 공개 API가 아니라서 서비스 쪽 변경으로 깨질 수 있습니다. 이 프로젝트는 Anthropic, OpenAI,
DeepSeek과 관련이 없습니다.

## 직접 빌드

Xcode가 필요합니다.

```sh
Scripts/test.sh                       # 핵심 로직 테스트
Scripts/build-app.sh --install        # 빌드 후 /Applications에 설치하고 실행
Scripts/snapshots.sh <폴더>            # 표본 데이터로 패널을 PNG로 렌더링
Scripts/verify-real-window.sh <폴더>   # 디버그 빌드를 실제 메뉴바에 띄워 점검 (실제 계정을 읽습니다)
Scripts/release.sh                    # 서명·공증한 배포본 생성 (필요한 환경변수는 스크립트 머리말 참고)
```
