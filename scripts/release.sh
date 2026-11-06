#!/bin/bash
# 배포용 빌드: Developer ID 서명 → DMG → 애플 공증 → 스테이플
# 준비 (한 번만):
#   1) Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application
#   2) xcrun notarytool store-credentials popcorn-notary --apple-id <애플 ID> --team-id <팀 ID>
# 사용: ./scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
PROFILE=${NOTARY_PROFILE:-popcorn-notary}
IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')}
[ -n "$IDENTITY" ] || { echo "✗ Developer ID Application 인증서가 키체인에 없습니다."; exit 1; }
echo "→ $VERSION, $IDENTITY"

./build.sh --no-install
APP="build/Popcorn Nodes.app"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

DMG="build/PopcornNodes-$VERSION.dmg"
STAGE=build/dmg; rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Popcorn Nodes" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "→ 공증 요청 (보통 1~5분)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
shasum -a 256 "$DMG" | awk '{print $1}' > "$DMG.sha256"
echo "✓ $DMG"
echo "  sha256 $(cat "$DMG.sha256")"
echo "  다음: GitHub Releases에 v$VERSION 태그로 DMG 업로드, packaging/homebrew/popcorn-nodes.rb의 version·sha256 갱신"
