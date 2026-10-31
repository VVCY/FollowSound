# 更新日志

## 1.0.0 — 2026-10-31

首个公开版本，三端同步发布。

**更名**
- HappyVoice → 随响 FollowSound；bundle id `app.followsound.mac`；老用户的特效/配色/高度自动迁移

**图标**
- 白底透明的声波标（7 根柱子，中线对称）：菜单栏模板图、AppIcon.icns、Windows .ico、Android mipmap、网页 favicon/og 全部同一套几何

**功能**
- 7 种特效：光带、色差光带、横向镜头光斑、像素拉丝、均衡器、波纹、星雨
- 24 套配色，菜单悬浮即预览
- 高度 80–400 pt 无级调节，拖动时实时满高预览
- 三端一致：macOS 原生 / Windows Electron / Android 原生 + WebView 悬浮窗

**修复**（详见 docs/REVIEW.md）
- 诊断日志无限增长 → 限 256 KB、仅调试构建开启
- 满音量时横向镜头光斑被窗口上沿裁掉
- 插拔显示器后覆盖层不跟随
- 退出时未释放麦克风
- 拒绝权限时提示框不可见
- 空闲仍 60fps 渲染 → 静音降到 15fps

**构建**
- macOS 改为通用二进制（arm64 + x86_64）
- 三端打包脚本 + GitHub Actions 发布流水线
- 三端自动更新，统一走 GitHub Releases
- **三端安装包已实际产出**：macOS 337 KB zip / 614 KB dmg、Windows 78 MB Setup.exe / 106 MB 免安装 zip、
  Android 4.4 MB apk，全部挂在同一个 Release 上，附 `latest.yml` 与 `SHA256SUMS.txt`
- Android 在 Android 15 模拟器上跑通：主界面出图、前台服务悬浮层盖在桌面上、
  悬浮层高度跟随 App 内滑块（SharedPreferences 桥）

## 0.x — 2026-10-31 之前

内部迭代版本（HappyVoice）：文字前沿特效、配色的悬浮预览、星雨回弹、可调高度滑块。
