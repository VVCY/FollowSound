# 随响 FollowSound

把说话的音量，变成屏幕底边的一条光带。

开会、录播客、语音输入 —— 你开口的那一刻，屏幕底部升起一条跟着音量和节奏起伏的光。
7 种特效、24 套配色、高度无级调节，macOS / Windows / Android 三端一致。
**只读音量，不录音、不识字、不联网、不需要账号。**

<sub>原名 HappyVoice，1.0.0 起更名。</sub>

## 下载

| 平台 | 直链 |
| --- | --- |
| macOS 14+ | [FollowSound-macOS.zip](https://github.com/VVCY/FollowSound/releases/latest/download/FollowSound-macOS.zip) |
| Windows 10/11 | [FollowSound-Windows-Setup.exe](https://github.com/VVCY/FollowSound/releases/latest/download/FollowSound-Windows-Setup.exe) |
| Android 8+ | [FollowSound-Android.apk](https://github.com/VVCY/FollowSound/releases/latest/download/FollowSound-Android.apk) |

官网：https://vvcy.github.io/FollowSound/
备用入口（国内更常打得开）：https://followsound.pages.dev/

> 打不开 GitHub 时，在任意直链前面加上 `https://gh-proxy.com/` 即可加速，例如
> `https://gh-proxy.com/https://github.com/VVCY/FollowSound/releases/latest/download/FollowSound-Android.apk`。
> 应用内的检查更新也会走这个源：三端都是「上次成功的源 → 镜像 → 直连」，谁快用谁。

## 仓库结构

```
macos/     Swift + AppKit 原生实现（主实现，Core Animation 图层）
windows/   Electron 工程（透明覆盖层 + 托盘 + electron-updater）
android/   原生 Gradle 工程（WebView 悬浮窗 + 前台服务 + 自更新）
shared/    视觉核心：themes.js / visualizer.js / player.html —— 三端共用
docs/      官网（GitHub Pages 根目录）与项目文档
design/    配色来源数据（JIZURA 24 个 style pack 的原始色板）
```

`shared/` 是 Web 侧唯一真源，Windows、Android、官网都从它取；macOS 是原生的等价实现，
两者的包络曲线、配色、特效名一一对应。

## 本地构建

**macOS**（需要 Xcode Command Line Tools）

```bash
cd macos
./build.sh                 # 构建通用二进制并安装到 /Applications
./build.sh --devtools --out /tmp/qa   # QA 构建：菜单带测试项，支持 --shot 出图
VERSION=1.0.0 ./package.sh            # 出 zip + dmg
```

**Windows**

```bash
cd windows
npm install
npm start                  # 开发运行
npm run dist               # 出安装包（dist/windows）
```

**Android**

```bash
cd android
gradle assembleRelease -PfsVersionName=1.0.0 -PfsVersionCode=1
```

**官网**

```bash
scripts/sync-web.sh        # 同步 shared/ 到 docs/assets/
open docs/index.html
```

## 文档

- [落地路径](docs/PLAN.md) —— 从测试到上线的执行顺序与每步交付物
- [发布与产物组织](docs/RELEASE.md) —— 三端打包命令、文件命名、签名现状
- [项目审查](docs/REVIEW.md) —— 修了什么、为什么有些没修

## 隐私

音频缓冲区只用来算一次均方根（音量），算完即丢。没有网络请求，没有本地缓存，
没有崩溃上报。唯一的联网行为是检查更新（GET GitHub releases API，不带任何标识）。

## 许可

MIT。配色与部分特效算法移植自 [JIZURA](https://github.com/852wa/JIZURA)（MIT, © 2026 hakoniwa / 852wa）。
