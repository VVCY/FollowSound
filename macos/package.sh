#!/bin/bash
# 打包 macOS 分发包：zip（自动更新用）+ dmg（首次下载体验更好）
#
#   ./package.sh            产出到 ../dist/macos
#   VERSION=1.1.0 ./package.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-$(cat VERSION | tr -d ' \n')}"
OUT="${OUT:-../dist/macos}"
mkdir -p "$OUT"
rm -f "$OUT"/*.zip "$OUT"/*.dmg "$OUT"/*.sha256 "$OUT"/*.txt

VERSION="$VERSION" ./build.sh --out "$OUT" >/dev/null

APP="$OUT/FollowSound.app"
[[ -d "$APP" ]] || { echo "没有产物：$APP"; exit 1; }

# 1) 自动更新用的 zip：必须是 .app 在外层，ditto 能完整保留资源分支与权限位
ZIP_VER="$OUT/FollowSound-macOS-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_VER"
# 2) 固定别名：站点上写死 latest/download/FollowSound-macOS.zip，升版本不用改网页
cp "$ZIP_VER" "$OUT/FollowSound-macOS.zip"

# 3) 给人下的 dmg（拖拽安装）
DMG="$OUT/FollowSound-macOS-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "随响 FollowSound" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

( cd "$OUT" && shasum -a 256 ./*.zip ./*.dmg > SHA256SUMS.txt )

echo "== 产物 =="
ls -lh "$OUT" | awk 'NR>1 {print $5, $9}'
cat "$OUT/SHA256SUMS.txt"
