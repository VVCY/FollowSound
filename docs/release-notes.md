### 随响 FollowSound v1.0.0

把说话的音量，变成屏幕底边的一条光带。不录音、不上传、不需要账号。

**本次更新**

- 首个公开版本：7 种特效（光带 / 色差光带 / 横向镜头光斑 / 像素拉丝 / 均衡器 / 波纹 / 星雨）
- 24 套配色，菜单悬浮即预览
- 高度 80–400 pt 无级调节，拖动滑块时画面实时满高预览
- 由 HappyVoice 更名为「随响 FollowSound」，图标换成白底透明的声波
- 三端一致：macOS 原生 / Windows / Android，共用同一份渲染核心
- 应用内检查更新，直接走本页 Release

**安装**

| 平台 | 下载 | 大小 | 说明 |
| --- | --- | --- | --- |
| macOS 14+ | `FollowSound-macOS-1.0.0.zip` / `.dmg` | 337 KB / 614 KB | 通用二进制（arm64 + Intel）。未公证，首次打开请右键 → 打开 |
| Windows 10/11 | `FollowSound-Windows-1.0.0-Setup.exe` | 78 MB | 安装包；另有 `-x64.zip` 免安装版。未签名，SmartScreen 选「仍要运行」 |
| Android 8+ | `FollowSound-Android-1.0.0.apk` | 4.4 MB | 无原生依赖，各架构通用。需允许「显示在其他应用上层」 |

`SHA256SUMS.txt` 是上面所有包的校验值；`latest.yml` 是 Windows 端 electron-updater 的更新清单。

**固定下载链接**（发新版不用改网页）

- `https://github.com/VVCY/FollowSound/releases/latest/download/FollowSound-macOS.zip`
- `https://github.com/VVCY/FollowSound/releases/latest/download/FollowSound-Windows-Setup.exe`
- `https://github.com/VVCY/FollowSound/releases/latest/download/FollowSound-Android.apk`

**关于签名**：三端都还没有正式签名证书（mac 未公证、Windows 无 EV 证书、Android 用 debug keystore）。
能装能用，只是首次运行会有系统警告。拿到证书后替换即可，代码不用改，见 `docs/RELEASE.md`。
