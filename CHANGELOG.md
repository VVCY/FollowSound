# 更新日志

## 1.0.4 — 2026-10-31

**更新检查加了国内加速源**
- 三端都不再是「一个写死的 GitHub 地址」，改成「有序源列表 + 竞速 + 记住」：
  上次能用的源排第一，其余并发探一次、谁先回一个合法 JSON 就用谁，全挂了才报错。
  默认镜像 `https://gh-proxy.com/`；安卓可用 `-PfsUpdateMirrors=a,b` 增删，
  mac 改 `AppInfo.mirrors`，Windows 改 `UPDATE_FEEDS`。
- 下载走同一个前缀，并且带兜底：一个源连不上就换下一个。
- Windows 的自动更新此前其实一直没生效：`electron-builder` 没写 `publish` 配置，
  包里就没有 `app-update.yml`，`checkForUpdates()` 只会 throw。现在改成显式
  `setFeedURL({ provider: 'generic', url })` 指向 `releases/latest/download`——
  顺带正好能套在镜像前缀后面，查版本和下载走同一条路。
- 安卓每次确认版本后往 logcat 打一行 `update source: <url>`，用户报「更不了」时先看它。

**实测（小米 15 Ultra）**
- Wi-Fi 与蜂窝各测一遍：直连可达时竞速会选直连（140ms 胜出），符合「谁快用谁」。
- 镜像配成死域名 → 自动回落直连，弹窗照常出现。
- 接口地址临时指到镜像 → 4.6MB 的 APK 几秒下完，系统安装器直接唤起。

## 1.0.3 — 2026-10-31

**修「改了默认值不生效」**
- 三端默认改为「星雨 + 深红信号」。问题是旧选择存在本地，永远压着新默认 ——
  现在加了一个默认值版本号（mac `prefsDefaultsRev` / Android `prefsRev` / Windows `settings.rev` /
  网页 `fs.prefRev`）：版本号一变，旧的特效/配色作废一次，之后用户自己再选照样记住。
  只作废样式这层，高度、门限这些用户调过的值不动。

**官网演示还是旧算法**
- `docs/assets/visualizer.js` 一直是 16:00 那份旧拷贝，星雨还是「从屏幕顶端往下落满屏」，
  而 `shared/visualizer.js` 在 16:59 已经改成 macOS 那套「从底边向上喷、撞水位线回弹」。
  `scripts/sync-web.sh` 现在同时同步官网与 Android assets，并支持 `--check`（CI 用）。

**Android 悬浮层不跟随切换**
- 悬浮层是另一个 WebView，App 里换特效/配色只写了 SharedPreferences，那一层不会变。
  现在 `AndroidHost.set()` 会通知 `OverlayService` 用 `fsSetStyle/fsSetTheme` 推过去，
  不 reload，粒子不中断。

**Android 更新下载**
- 下载有了进度条：实时百分比 + `x.x MB / y.y MB` + 取消；拿不到 Content-Length 时显示已下载量。
- 整个更新界面（发现新版本 / 下载中 / 下载失败）换成自定义深色卡片，和 App 里其它控件同一套观感，
  不再用系统 AlertDialog 的浅灰方角。
- 下载完先校验再交给安装器：长度对不上、或者拿到的不是 zip（被代理拦成 HTML）当场报
  「安装包不完整」，不再让系统弹一句看不懂的「解析软件包时出现问题」。
- 卡在「允许安装未知来源」时不再重下，允许后点「检查更新」直接装已下好的包。

**其它**
- 宿主（Windows 托盘 / Android）通过 `fsSetStyle/fsSetTheme/fsSetHeight` 改样式时，
  页面里的下拉文字、选中态、按钮强调色一并同步，不会出现「画布变了、标签还是旧的」。

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
