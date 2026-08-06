#!/bin/bash
# Builds Claude Usage.app into ./build. Pass --install to also copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Claude Usage.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeUsageMonitor "$APP/Contents/MacOS/ClaudeUsageMonitor"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Signing identity decides whether macOS re-asks for keychain access after every
# rebuild. Ad-hoc signatures change with the code, so the app looks like a new
# app each time; a real certificate keeps the identity stable.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')

if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"ClaudeUsageMonitor Local Signing"' | head -1 | tr -d '"')
fi

if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "서명: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "서명: ad-hoc (재빌드 시 키체인 허용 창이 다시 뜹니다 — ./setup-signing.sh 참고)"
fi

echo "빌드 완료: $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/Claude Usage.app"
    cp -R "$APP" /Applications/
    echo "설치 완료: /Applications/Claude Usage.app"
fi
