#!/bin/bash
# 지금 Claude Code에 로그인되어 있는 계정의 OAuth 토큰을 꺼냅니다.
#
#   ./extract-token.sh          토큰 전체 출력 + access token 을 클립보드로 복사
#   ./extract-token.sh --info   만료 시각·플랜만 보고 토큰 값은 가립니다
#
# 키체인은 계정 하나만 담고 있으므로, 계정별로
# 로그인 → 이 스크립트 실행 → 앱에 등록 을 반복하세요.
set -euo pipefail

JSON=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)

if [ -z "$JSON" ]; then
    echo "키체인에서 Claude Code 자격증명을 찾지 못했습니다." >&2
    echo "Claude Code에 로그인되어 있는지, 키체인 접근 허용을 눌렀는지 확인하세요." >&2
    exit 1
fi

MASK=0
[ "${1:-}" = "--info" ] && MASK=1

printf '%s' "$JSON" | MASK=$MASK /usr/bin/python3 -c '
import json, os, subprocess, sys
from datetime import datetime, timezone

mask = os.environ.get("MASK") == "1"
data = json.load(sys.stdin)
oauth = data.get("claudeAiOauth", data)

access = oauth.get("accessToken", "")
refresh = oauth.get("refreshToken", "")

def when(ms):
    if not ms:
        return "알 수 없음"
    at = datetime.fromtimestamp(ms / 1000, tz=timezone.utc).astimezone()
    delta = at - datetime.now(tz=timezone.utc).astimezone()
    secs = int(delta.total_seconds())
    if secs <= 0:
        return at.strftime("%Y-%m-%d %H:%M") + " (만료됨)"
    if secs < 86400:
        rel = "%d시간 %d분 후" % (secs // 3600, (secs % 3600) // 60)
    else:
        rel = "%d일 후" % (secs // 86400)
    return at.strftime("%Y-%m-%d %H:%M") + " (" + rel + ")"

print("플랜:               " + str(oauth.get("subscriptionType", "?")))
print("access token 만료:  " + when(oauth.get("expiresAt")))
print("refresh token 만료: " + when(oauth.get("refreshTokenExpiresAt")))
print()

def show(label, token):
    if not token:
        print(label + ": (없음)")
    elif mask:
        print(label + ": " + token[:14] + "..." + " (" + str(len(token)) + "자)")
    else:
        print(label + ":")
        print(token)
    print()

show("access token", access)
show("refresh token", refresh)

if not mask and access:
    subprocess.run(["pbcopy"], input=access.encode())
    print("access token 을 클립보드에 복사했습니다.")
'
