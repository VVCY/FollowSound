#!/bin/bash
# 构建 随响 FollowSound（macOS）
#
#   ./build.sh                     构建通用二进制并安装到 /Applications
#   ./build.sh --devtools          构建带 QA 入口的开发版（菜单里有测试项、--shot 可用）
#   ./build.sh --dest /tmp/x.app   装到指定路径
#   ./build.sh --out dist          只产出到 dist/ 目录，不动 /Applications（发布用）
#   VERSION=1.1.0 ./build.sh ...   指定版本号
set -euo pipefail
cd "$(dirname "$0")"

APP_BASENAME="FollowSound"
EXEC_NAME="FollowSound"
VERSION="${VERSION:-$(cat VERSION 2>/dev/null | tr -d ' \n' || echo 1.0.0)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
DEVTOOLS=0
DEST="/Applications"
OUTDIR=""
SIGN_ID="${SIGN_ID:-FollowSound Dev}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --devtools) DEVTOOLS=1; shift ;;
    --dest) DEST="$2"; shift 2 ;;
    --out) OUTDIR="$2"; shift 2 ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
done

ARCHS="arm64 x86_64"
FLAGS=(-O -framework AppKit -framework AVFoundation)
[[ $DEVTOOLS -eq 1 ]] && FLAGS+=(-D DEBUGTOOLS)

BUNDLE="$APP_BASENAME.app"
[[ $DEVTOOLS -eq 1 ]] && BUNDLE="FollowSound-QA.app"
[[ -n "$OUTDIR" ]] && BUNDLE="$OUTDIR/$BUNDLE"

# 正在运行的实例不退出的话，替换 bundle 会让签名失效
pkill -f "$APP_BASENAME.app/Contents/MacOS/$EXEC_NAME" 2>/dev/null || true
pkill -f "FollowSound-QA.app/Contents/MacOS/$EXEC_NAME" 2>/dev/null || true
sleep 0.3

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

# 通用二进制：Apple 芯片与 Intel 都能跑
TMPD=$(mktemp -d)
for arch in $ARCHS; do
  swiftc "${FLAGS[@]}" -target "${arch}-apple-macos14.0" \
    Sources/*.swift -o "$TMPD/fs-$arch" &
done
wait
lipo -create -output "$BUNDLE/Contents/MacOS/$EXEC_NAME" "$TMPD"/fs-arm64 "$TMPD"/fs-x86_64
rm -rf "$TMPD"

cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/"
cp Resources/StatusIcon.png Resources/StatusIcon@2x.png "$BUNDLE/Contents/Resources/"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$BUNDLE/Contents/Info.plist"

# 签名：本机开发用固定自签身份（TCC 授权不会每次重置）；CI / 无证书时退回 ad-hoc
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" --timestamp=none "$BUNDLE"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  codesign --force --options runtime --timestamp --sign \
    "$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')" "$BUNDLE"
else
  codesign --force --sign - "$BUNDLE"
fi

codesign --verify --strict "$BUNDLE" 2>&1 | sed 's/^/  /'

# 安装到目标位置
if [[ -z "$OUTDIR" ]]; then
  TARGET="$DEST"
  [[ "$DEST" == /Applications ]] && TARGET="/Applications/$BUNDLE"
  rm -rf "$TARGET"
  mkdir -p "$(dirname "$TARGET")"
  cp -R "$BUNDLE" "$TARGET"
  echo "installed: $TARGET  ($VERSION)"
else
  echo "built: $BUNDLE  ($VERSION)"
fi
