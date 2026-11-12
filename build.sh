#!/bin/bash
# Rigbar 빌드 → build/Rigbar.app (유니버설: Apple silicon + Intel)
# 사용: ./build.sh            빌드 + ~/Applications 설치 (애드혹 서명, 이 Mac 전용)
#       ./build.sh --no-install
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
mkdir -p build
SRC=(Sources/Rigbar/*.swift)
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target $arch-apple-macosx14.0 "${SRC[@]}" -o build/Rigbar-$arch
done
lipo -create build/Rigbar-arm64 build/Rigbar-x86_64 -output build/Rigbar
rm build/Rigbar-arm64 build/Rigbar-x86_64
# 샌드박스·CI용 테스트 빌드 (ServiceManagement 제외)
xcrun swiftc -O -swift-version 5 -D NO_SM -target arm64-apple-macosx14.0 "${SRC[@]}" -o build/Rigbar-test
xattr -dr com.apple.quarantine build 2>/dev/null || true

if [ ! -f build/AppIcon.icns ]; then
  ./build/Rigbar-test --icon build/icon1024.png >/dev/null 2>&1
  IS=build/AppIcon.iconset; rm -rf $IS; mkdir $IS
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon1024.png --out $IS/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon1024.png --out $IS/icon_${s}x${s}@2x.png >/dev/null
  done
  python3 scripts/make-icns.py $IS build/AppIcon.icns
fi

APP="build/Rigbar.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Rigbar "$APP/Contents/MacOS/Rigbar"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Rigbar</string>
  <key>CFBundleDisplayName</key><string>Rigbar</string>
  <key>CFBundleIdentifier</key><string>ai.datapopcorn.rigbar</string>
  <key>CFBundleExecutable</key><string>Rigbar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
  <key>NSHumanReadableCopyright</key><string>© 2026 DataPopcorn. MIT License.</string>
</dict></plist>
PL
codesign --force -s - "$APP"
echo "built: $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/Rigbar"))"

if [ "${1:-}" != "--no-install" ]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/"Rigbar.app"; cp -R "$APP" ~/Applications/
  xattr -dr com.apple.quarantine ~/Applications/"Rigbar.app" 2>/dev/null || true
  echo "installed: ~/Applications/Rigbar.app"
fi
