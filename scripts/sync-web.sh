#!/bin/bash
# 把视觉核心同步进官网目录（GitHub Pages 只能访问仓库内相对路径）
set -euo pipefail
cd "$(dirname "$0")/.."
cp shared/themes.js shared/visualizer.js docs/assets/
echo "synced: shared/ → docs/assets/"
