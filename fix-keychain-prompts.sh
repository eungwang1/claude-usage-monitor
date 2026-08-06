#!/bin/bash
# 키체인 허용 창이 "항상 허용"을 눌러도 계속 뜰 때 실행하세요.
#
# macOS Sierra 부터 키체인 항목에는 ACL 외에 '파티션 목록'이라는 2차 관문이
# 있습니다. "항상 허용"은 ACL 에만 기록되므로, 파티션 목록이 비어 있으면
# 다음 접근에서 또 묻습니다. 이 스크립트가 파티션 목록을 직접 채웁니다.
#
# 실행하면 키체인 암호(맥 로그인 암호)를 한 번 묻고, 그 뒤로는 뜨지 않습니다.
set -euo pipefail

SERVICE="Claude Code-credentials"

if ! security find-generic-password -s "$SERVICE" >/dev/null 2>&1; then
    echo "'$SERVICE' 항목이 없습니다." >&2
    echo "Claude Code 에서 /login 으로 로그인한 뒤 다시 실행하세요." >&2
    exit 1
fi

# 항목이 실제로 쓰는 계정 이름을 읽습니다 ($USER 와 다를 수 있음).
ACCOUNT=$(security find-generic-password -s "$SERVICE" 2>/dev/null \
    | awk -F'"' '/"acct"<blob>=/ {print $4; exit}')
ACCOUNT=${ACCOUNT:-$USER}

# apple-tool: 은 Claude Code 가 쓰는 /usr/bin/security 를 커버합니다.
PARTITIONS="apple-tool:,apple:"

# 이 앱은 서명 팀 ID 로 식별됩니다. 인증서 이름의 괄호 안 값이 아니라
# codesign 이 보고하는 TeamIdentifier 여야 합니다.
for APP in "/Applications/Claude Usage.app" "$(dirname "$0")/build/Claude Usage.app"; do
    [ -d "$APP" ] || continue
    TEAM=$(codesign -dv --verbose=4 "$APP" 2>&1 \
        | awk -F= '/^TeamIdentifier=/ && $2 != "not set" {print $2; exit}')
    if [ -n "${TEAM:-}" ]; then
        PARTITIONS="$PARTITIONS,teamid:$TEAM"
        break
    fi
done

echo "항목:     $SERVICE ($ACCOUNT)"
echo "파티션:   $PARTITIONS"
echo
echo "키체인 암호(맥 로그인 암호)를 물어봅니다. 한 번만 입력하면 됩니다."

security set-generic-password-partition-list \
    -S "$PARTITIONS" -s "$SERVICE" -a "$ACCOUNT" >/dev/null

echo
echo "완료. 이제 허용 창이 반복해서 뜨지 않습니다."
