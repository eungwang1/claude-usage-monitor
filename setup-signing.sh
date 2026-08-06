#!/bin/bash
# 앱 서명을 고정하기 위한 self-signed 코드서명 인증서를 만들어 로그인 키체인에 넣습니다.
#
# ad-hoc 서명(codesign -s -)은 코드가 바뀔 때마다 서명이 달라져,
# macOS가 재빌드된 앱을 "다른 앱"으로 보고 키체인 접근을 다시 묻습니다.
# 고정된 인증서로 서명하면 코드가 바뀌어도 같은 앱으로 인식됩니다.
#
# 되돌리려면: 키체인 접근 앱에서 아래 이름의 인증서를 삭제하세요.
set -euo pipefail

IDENTITY="ClaudeUsageMonitor Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "이미 설치되어 있습니다: $IDENTITY"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "코드서명 인증서를 생성합니다..."
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -out "$TMP/identity.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$IDENTITY" -passout pass:temp 2>/dev/null

echo "로그인 키체인에 등록합니다..."
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P temp \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# codesign 이 개인키를 쓸 때마다 묻지 않도록 파티션 목록을 열어 둡니다.
# 로그인 키체인 암호를 묻는 창이 뜰 수 있습니다 (맥 로그인 암호).
if ! security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -l "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "참고: 키 접근 권한 자동 설정을 건너뛰었습니다."
    echo "      첫 서명 때 키체인 허용 창이 뜨면 '항상 허용'을 눌러 주세요."
fi

echo
echo "완료: $IDENTITY"
echo "이제 ./build.sh 가 이 인증서로 서명합니다."
