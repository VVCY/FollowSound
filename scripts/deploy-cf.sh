#!/bin/bash
# 把 docs/ 发布到 Cloudflare Pages（备用入口；主站仍是 GitHub Pages）
#
#   ./scripts/deploy-cf.sh              # 首次会提示创建项目，输入 y
#   CF_PROJECT=xxx ./scripts/deploy-cf.sh
#
# 前提：本机已登录过 wrangler（npx wrangler login，浏览器授权一次即可）。
# 如果走的是控制台「Connect to Git」，push 到 main 就会自动部署，这个脚本不用跑。
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="${CF_PROJECT:-followsound}"

# 官网 / Android assets 必须与 shared/ 一致，不一致就别发
./scripts/sync-web.sh --check

echo "→ 部署 docs/ 到 Cloudflare Pages 项目：$PROJECT"
npx --yes wrangler@latest pages deploy docs \
  --project-name "$PROJECT" \
  --branch main \
  --commit-dirty=true
