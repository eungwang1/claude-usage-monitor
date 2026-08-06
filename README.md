# Claude Usage — 다중 계정 사용량 메뉴바 앱 (macOS)

Claude 구독 계정 여러 개의 **세션(5시간) 한도 · 주간 한도 · 모델별 주간 한도 · 리셋까지 남은 시간**을 메뉴바에서 한눈에 봅니다. 계정 카드의 **전환** 버튼으로 Claude Code 로그인 계정을 로그아웃 없이 바꿀 수도 있습니다.

메뉴바 제목에는 **지금 가장 여유 있는 계정**이 표시되므로, 클릭하지 않아도 "어느 계정을 쓸까"에 바로 답이 됩니다.

> **English**: A macOS menu bar app that tracks usage limits across multiple Claude subscription accounts — 5-hour session, weekly, and per-model weekly limits with reset countdowns — and switches Claude Code's logged-in account without logging out. Built with SwiftUI. Uses the same undocumented endpoint Claude Code's own `/usage` command calls; see [Caveats](#알아둘-점).

## 빌드 · 설치

```bash
git clone https://github.com/eungwang1/claude-usage-monitor.git
cd claude-usage-monitor
./build.sh --install    # 빌드 후 /Applications 에 설치
```

`--install` 없이 실행하면 `build/Claude Usage.app` 까지만 만듭니다.

요구사항: macOS 14+, Swift 6 툴체인(Xcode 또는 Command Line Tools).

### 서명에 대해

`build.sh`는 키체인에 있는 `Apple Development` 인증서를 자동으로 찾아 서명합니다. 서명이 고정되어야 재빌드해도 macOS가 같은 앱으로 인식하고, 저장된 토큰에 접근할 때 허용 창이 다시 뜨지 않습니다.

Apple Developer 인증서가 없다면 `./setup-signing.sh`를 한 번 실행해 로컬 전용 코드서명 인증서를 만들어 두세요. 둘 다 없으면 ad-hoc 서명으로 빌드되는데, 이 경우 **코드를 고칠 때마다** 계정 수만큼 키체인 허용 창이 뜹니다.

## 계정 등록하기 (4개 계정 기준)

토큰은 계정마다 하나씩 필요합니다. Claude Code에 로그인된 계정을 하나씩 가져오는 방식이 가장 간단합니다.

1. 메뉴바 아이콘 클릭 → **계정 추가** → *Claude Code에서 가져오기*
2. 표시 이름(예: `회사`, `개인A`)을 입력하고 **가져오기**
   - 처음 한 번은 macOS가 키체인 접근 허용을 묻습니다. **항상 허용**을 누르세요.
3. Claude Code에서 `/logout` 후 다음 계정으로 로그인
4. 1~3을 계정 수만큼 반복

토큰을 이미 갖고 있다면 *토큰 직접 입력* 탭에서 access token(+선택적으로 refresh token)을 붙여넣어도 됩니다.

등록한 토큰은 이 앱 전용 키체인 항목(`ClaudeUsageMonitor` 서비스)에 계정별로 저장되며, Anthropic API 외부로 전송되지 않습니다.

## 계정 전환

각 계정 카드의 **전환** 버튼을 누르면 Claude Code의 로그인 계정이 그 계정으로 바뀝니다. 앱이 보관 중인 토큰을 Claude Code의 키체인 항목에 써넣는 방식이라, 로그아웃·재로그인 없이 전환됩니다. 현재 로그인 중인 계정에는 `사용 중` 배지가 붙습니다.

- **전환 후 Claude Code를 재시작해야 적용됩니다.** 실행 중인 세션은 이전 토큰을 메모리에 들고 있습니다.
- **대화는 이어집니다.** 세션 기록은 `~/.claude/projects/<프로젝트경로>/<세션ID>.jsonl` 에 계정과 무관하게 저장되고, 레코드 어디에도 계정 식별자가 없습니다. 재시작 후 `claude -c`(직전 대화) 또는 `claude -r`(세션 선택)로 그대로 이어가면 됩니다. 다만 프롬프트 캐시는 계정별이라, 전환 직후 첫 요청은 대화 전체가 캐시 미스로 처리돼 느리고 비쌉니다 — 긴 세션일수록 체감이 큽니다.
- 토큰뿐 아니라 `~/.claude.json` 의 `oauthAccount`(이메일·조직 정보)도 함께 교체하므로, 전환 후 Claude Code가 표시하는 계정 정보도 맞습니다. 이 파일은 `oauthAccount` 키만 원자적으로 갱신하고 나머지 설정은 건드리지 않습니다.
- 만료된 토큰은 전환 직전에 자동 갱신하므로, 오래 안 쓴 계정으로 바꿔도 바로 쓸 수 있습니다.
- 앱에 등록되지 않은 계정이 로그인되어 있으면 확인 창이 뜹니다 — 그대로 전환하면 그 계정 토큰이 사라지므로, *먼저 저장하고 전환*을 고르면 앱에 추가한 뒤 바꿉니다.

**Claude 데스크탑 앱(Claude.app)은 전환 대상이 아닙니다.** 데스크탑 앱은 세션을 Electron 쿠키 DB에 `Claude Safe Storage` 키로 암호화해 보관하기 때문에, 안정적으로 바꿔치기할 방법이 없습니다. 전환은 Claude Code(CLI)에만 적용됩니다.

## 동작 방식

Claude Code의 `/usage` 명령이 쓰는 것과 같은 엔드포인트를 계정별 OAuth 토큰으로 호출합니다.

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <access token>
anthropic-beta: oauth-2025-04-20
```

응답의 `limits` 배열(`kind`, `percent`, `severity`, `resets_at`, `scope.model`)을 그대로 화면에 렌더링하므로, Anthropic이 한도 종류를 추가해도 별도 수정 없이 표시됩니다.

## 알아둘 점

- **비공개 엔드포인트입니다.** Anthropic 공식 문서에 없으며 예고 없이 바뀔 수 있습니다. 응답 형식이 바뀌면 화면이 비어 보일 수 있습니다.
- **요청 제한이 엄격합니다.** 기본 폴링 주기는 5분이고, 계정 요청은 1.5초씩 시차를 둡니다. 429를 받으면 해당 계정만 자동 백오프하며, 마지막으로 성공한 값을 "N분 전 업데이트" 표시와 함께 계속 보여줍니다. 설정에서 주기를 늘릴 수 있습니다.
- **토큰 만료 시** 저장된 refresh token으로 자동 갱신을 시도하고, 실패하면 해당 계정에 `재인증 필요` 배지가 뜹니다. 그 계정으로 Claude Code에 다시 로그인한 뒤 계정을 다시 가져오면 됩니다.
- 세션 한도는 이름과 달리 **5시간** 롤링 윈도우입니다(4시간 아님).
- **본인 계정에만 쓰세요.** 이 앱은 사용자가 직접 로그인한 계정의 토큰을 로컬 키체인에서 읽을 뿐, 어떤 인증도 우회하지 않습니다. 토큰은 Anthropic API 외 어디로도 전송되지 않습니다.
- 공식 도구가 아니며 Anthropic과 무관합니다. 사용에 따른 책임은 사용자에게 있습니다.

## 구조

| 파일 | 역할 |
|---|---|
| `Models.swift` | 응답 디코딩 + 표시용 `LimitRow` 변환 |
| `Keychain.swift` | 앱 전용 토큰 저장, Claude Code 항목 읽기·쓰기 |
| `UsageClient.swift` | 사용량 조회 + 토큰 갱신 |
| `AccountStore.swift` | 계정 목록, 폴링, 백오프, 계정 전환, 상태 관리 |
| `ClaudeCodeConfig.swift` | `~/.claude.json` 의 `oauthAccount` 읽기·쓰기 (전환 시 프로필 동기화) |
| `App.swift` / `DashboardView.swift` / `AddAccountView.swift` | 메뉴바 UI |

## 라이선스

MIT — 자유롭게 쓰고 고치세요. 버그 제보와 PR 환영합니다.
