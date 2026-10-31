#!/bin/bash
# 视觉核心只有一份真身：shared/。官网和 Android 用的是拷贝，
# 改了 shared 忘了同步，线上/装机版就还是旧算法 ——
# 之前「星雨改完不生效」就是这么来的，所以这里加 --check 给 CI 用。
#
#   ./scripts/sync-web.sh          同步
#   ./scripts/sync-web.sh --check  只比对，不一致就退出 1
set -euo pipefail
cd "$(dirname "$0")/.."

FILES="player.html visualizer.js themes.js"

# 目标：官网只要 themes+visualizer（没有播放页），Android 三份都要
targets() {
  echo "docs/assets:themes.js,visualizer.js"
  echo "android/app/src/main/assets:player.html,visualizer.js,themes.js"
}

fail=0
while IFS=: read -r dir list; do
  mkdir -p "$dir"
  for f in ${list//,/ }; do
    src="shared/$f"; dst="$dir/$f"
    if [ "${1:-}" = "--check" ]; then
      if ! cmp -s "$src" "$dst"; then
        echo "✗ $dst 与 $src 不一致（跑一次 scripts/sync-web.sh）"
        fail=1
      fi
    else
      cp "$src" "$dst"
    fi
  done
done < <(targets)

if [ "${1:-}" = "--check" ]; then
  [ "$fail" -eq 0 ] && echo "✓ 三处视觉核心一致"
  exit "$fail"
fi
echo "synced: shared/ → docs/assets/, android/app/src/main/assets/"
