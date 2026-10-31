### 随响 FollowSound v1.0.4

这一版主要在收拾两类问题：**改了设置却不生效**，和**更新更不动**。三端同步。

**特效与配色**

- 默认改成「星雨 + 深红信号」。老版本里存过别的选择，所以你看到的可能不是新默认 —— 现在带了默认值版本号，
  升级后旧的特效/配色作废一次（高度、门限这些你调过的值不动），之后自己再选照样记住。
- 星雨重写为 macOS 那套物理：从底边向上喷、撞到水位线回弹、溅出碎星。网页版此前是「从屏幕顶端往下落」，
  同一个特效三端观感不一样，现在一致了。
- 官网演示区一直是旧拷贝，所以「网页上看着没变」。`scripts/sync-web.sh` 现在同时同步官网和安卓资源，
  并带 `--check`，两处不一致会直接报错。

**界面**

- 安卓按钮不再用系统原生控件（圆角被裁、阴影发灰、内边距不齐），换成 Element 风格：实心主按钮 + 描边次按钮。
- 下拉菜单不再用原生 `<select>`（弹层由系统绘制，深色页面里会跳出一块浅色方框），改成自绘卡片：
  向上弹出、圆角、选中项主题色高亮、同时只开一个。
- 「接麦克风」改成「麦克风启用 / 麦克风关闭」，状态和颜色跟着走。
- 更新弹窗（发现新版本 / 下载中 / 下载失败）统一成深色圆角卡片，与 App 其余控件同一套观感。

**安卓**

- 补上 `MODIFY_AUDIO_SETTINGS`。WebView 的 `getUserMedia` 由 Chromium 的 cr_media 实现，
  它要求 `RECORD_AUDIO` 和 `MODIFY_AUDIO_SETTINGS` **同时**具备，缺一个就 `NotReadableError`——
  表现正是「授权了麦克风却一点反应没有」。
- 悬浮层补 `microphone` 前台服务类型：切到微信、浏览器之后，系统不会再把后台麦克风静音。
- 悬浮层会跟随 App 内的切换（推送 `fsSetStyle/fsSetTheme`，不 reload，粒子不中断）。
- 小米机型上 `canDrawOverlays()` 会误报 false（实际 AppOps 已放行），补了一层 AppOps 兜底。

**更新**

- 下载有真进度了：百分比 + `x.x MB / y.y MB`，可以取消，取消后半截文件会删掉。
- 下载完先校验：长度对不上、或者拿到的不是 zip（被代理拦成 HTML 页）就当场说「安装包不完整」，
  不再让你到系统安装器那儿看一句「解析软件包时出现问题」。
- 三端更新源改成「有序列表 + 并发竞速 + 记住上次能用的」：不再被一个写死的 GitHub 地址卡死，
  默认镜像 `https://gh-proxy.com/`，直连超时会自动换源，下载也走同一个前缀。
- Windows 的自动更新此前其实一直没生效——`electron-builder` 缺 `publish` 配置，包里根本没有
  `app-update.yml`，检查更新只会抛错。现在显式指定 generic feed 指向 `releases/latest/download`。
- 卡在「允许安装未知来源」时不再重下：允许之后点「检查更新」直接装已下好的包。

**安装**

| 平台 | 下载 | 大小 | 说明 |
| --- | --- | --- | --- |
| Android 8+ | `FollowSound-Android-1.0.4.apk` | 4.4 MB | 无原生依赖，各架构通用。需允许「显示在其他应用上层」 |
| macOS 14+ | `FollowSound-macOS-1.0.4.zip` / `.dmg` | 342 KB / 625 KB | 通用二进制（arm64 + Intel）。未公证，首次打开请右键 → 打开 |
| Windows 10/11 | `FollowSound-Windows-1.0.4-Setup.exe` | 78 MB | 安装包；另有 `-x64.zip` 免安装版。未签名，SmartScreen 选「仍要运行」 |

`SHA256SUMS.txt` 是所有包的校验值；`latest.yml` 是 Windows 端更新清单。

**固定下载链接**（发新版不用改网页）

- `https://github.com/VVCY/FollowSound/releases/latest/download/FollowSound-macOS.zip`
- `https://github.com/VVCY/FollowSound/releases/latest/download/FollowSound-Windows-Setup.exe`
- `https://github.com/VVCY/FollowSound/releases/latest/download/FollowSound-Android.apk`

国内直连不稳的话，在链接前加 `https://gh-proxy.com/` 即可，例如
`https://gh-proxy.com/https://github.com/VVCY/FollowSound/releases/latest/download/FollowSound-Android.apk`。

**关于签名**：三端都还没有正式签名证书（mac 未公证、Windows 无 EV 证书、Android 用 debug keystore）。
能装能用，只是首次运行会有系统警告。拿到证书后替换即可，代码不用改，见 `docs/RELEASE.md`。

---

### 随响 FollowSound v1.0.1

安卓端麦克风修复版。macOS / Windows 只是跟着升版本号，功能不变。

**修了什么**

- **安卓：授权了麦克风却没反应。** 旧版是页面在系统权限弹窗还没结束时就去要麦克风，
  拿不到就静默切成演示动画——看起来在动，其实一个音都没收到。现在改成：先要系统权限，
  授权回来才接麦克风。
- **接不上了会说话。** 页面上会出一条状态提示，直接写原因（`NotAllowedError` / `NotReadableError`），
  带「重试」和「去设置」。以前是默默放演示动画，看不出坏在哪。
- **悬浮窗在别的 App 上层能继续收声。** 前台服务补上 `microphone` 类型——否则切到微信、
  浏览器之后系统会把后台麦克风静音，光带就僵在那里。
- 页面里的音频上下文会主动 resume：移动端自动播放策略会把它停在 suspended，读出来全是 0。
- 拒绝授权后不再反复弹窗；勾了「不再询问」会直接把人送到本应用的系统设置页。

**安装**

| 平台 | 下载 | 大小 | 说明 |
| --- | --- | --- | --- |
| Android 8+ | `FollowSound-Android-1.0.1.apk` | 4.4 MB | 无原生依赖，各架构通用。需允许「显示在其他应用上层」 |
| macOS 14+ | `FollowSound-macOS-1.0.1.zip` / `.dmg` | 337 KB / 614 KB | 通用二进制（arm64 + Intel）。未公证，首次打开请右键 → 打开 |
| Windows 10/11 | `FollowSound-Windows-1.0.1-Setup.exe` | 78 MB | 安装包；另有 `-x64.zip` 免安装版。未签名，SmartScreen 选「仍要运行」 |

`SHA256SUMS.txt` 是上面所有包的校验值；`latest.yml` 是 Windows 端 electron-updater 的更新清单。

**固定下载链接**（发新版不用改网页）

- `https://github.com/VVCY/FollowSound/releases/latest/download/FollowSound-macOS.zip`
- `https://github.com/VVCY/FollowSound/releases/latest/download/FollowSound-Windows-Setup.exe`
- `https://github.com/VVCY/FollowSound/releases/latest/download/FollowSound-Android.apk`

**关于签名**：三端都还没有正式签名证书（mac 未公证、Windows 无 EV 证书、Android 用 debug keystore）。
能装能用，只是首次运行会有系统警告。拿到证书后替换即可，代码不用改，见 `docs/RELEASE.md`。

---

### 随响 FollowSound v1.0.0

把说话的音量，变成屏幕底边的一条光带。不录音、不上传、不需要账号。

- 首个公开版本：7 种特效（光带 / 色差光带 / 横向镜头光斑 / 像素拉丝 / 均衡器 / 波纹 / 星雨）
- 24 套配色，菜单悬浮即预览
- 高度 80–400 pt 无级调节，拖动滑块时画面实时满高预览
- 由 HappyVoice 更名为「随响 FollowSound」，图标换成白底透明的声波
- 三端一致：macOS 原生 / Windows / Android，共用同一份渲染核心
- 应用内检查更新，直接走本页 Release
