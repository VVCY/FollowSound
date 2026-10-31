# CI 工作流（需要手动启用一次）

`ci/release.yml` 是完整的发布流水线，但 GitHub 不允许 **没有 `workflow` scope 的 token**
写入 `.github/workflows/`。所以它放在这里，启用方式是二选一：

## 方式 A：给 token 加上 workflow 权限（推荐，一次性）

GitHub → Settings → Developer settings → Personal access tokens →
勾选 `workflow` → 然后执行：

```bash
mkdir -p .github/workflows
git mv ci/release.yml .github/workflows/release.yml
git commit -m "启用 CI 发布流水线" && git push
```

## 方式 B：在网页上粘贴

仓库 → Add file → Create new file → 路径填 `.github/workflows/release.yml`
→ 把 `ci/release.yml` 的内容整段粘进去 → Commit。

## 启用后

打标签即出三端包：

```bash
git tag v1.0.1 && git push origin v1.0.1
```

流水线会并行构建 macOS / Windows / Android，再把产物汇总到同一个 Release，
并生成固定别名（`FollowSound-macOS.zip` 等）供官网下载按钮使用。
