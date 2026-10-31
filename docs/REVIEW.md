# 项目审查报告

审查对象：macOS 原生实现（`macos/Sources/*.swift`，约 1.6k 行）＋ 仓库结构。
审查时间：2026-10-31。方法：通读全部源码、跑一轮 7 种特效自检出图、检查二进制产物、实测空闲 CPU 与日志落盘行为。

状态说明：**已修** = 本次改动；**评估不改** = 有意保留并说明理由；**待办** = 进 1.1。

## 一、缺陷（会导致用户可见的问题）

| # | 问题 | 影响 | 状态 |
| --- | --- | --- | --- |
| 1 | 诊断日志每 2 秒写一行、文件永不回收，落在 `/tmp/happyvoice.log` | 挂一天能长到几十 MB，且与"不落盘"的隐私承诺冲突 | **已修**：`DiagLog` 限 256 KB 自动截断，迁移到 `~/Library/Logs/FollowSound/`，且**仅开发构建或 `FS_DIAG=1` 时开启**；正式版实测 5 秒 0 字节 |
| 2 | 菜单栏图标是 emoji `🎙` | 不同系统版本渲染不一致，与产品调性不符 | **已修**：改为 18pt 模板图（白底透明的声波），资源缺失时退回 SF Symbol |
| 3 | `Info.plist` 没有 `CFBundleIconFile` | 应用根本没有图标，Finder/Dock 里是空白文档 | **已修**：生成 `AppIcon.icns`（16→1024 全尺寸）并接入 |
| 4 | 未监听屏幕参数变化 | 插拔外接显示器后，覆盖层仍留在已拔掉的屏幕上，用户以为它挂了 | **已修**：监听 `didChangeScreenParametersNotification` → `relocateWindow()` |
| 5 | 退出时不释放麦克风、不停 Timer | 进程退出前一刻仍在录，麦克风指示灯残留 | **已修**：`applicationWillTerminate` 停 Timer、`mic.stop()` |
| 6 | 满音量时「横向镜头光斑」被窗口上沿裁掉 | 该档在音量最大时看起来"什么都没画" | **已修**：窗口比光带高 56pt（`overlayHeadroom`），光斑、光晕有地方画；出图已复核 |
| 7 | 拒绝麦克风权限时 `NSAlert.runModal()` 不激活 App | `LSUIElement` 应用弹窗浮在别的空间，用户看不到"为什么不亮" | **已修**：先 `NSApp.activate`，并加「打开系统设置」按钮直达麦克风面板 |
| 8 | 空闲时仍以 60fps 渲染 | 静音状态下白烧 CPU | **已修**：静音 + 无预览时降到 15fps，有声立刻回 60fps；实测空闲 0.6% |
| 9 | 只编译 arm64 | Intel Mac 无法运行 | **已修**：`build.sh` 出通用二进制（arm64 + x86_64，`lipo` 合并） |
| 10 | 改名后 bundle id 变化 | 老用户的特效/配色/高度设置全部清零 | **已修**：`Prefs.migrateFromLegacyIfNeeded()` 从旧域搬 4 个键 |
| 11 | 测试菜单项与 `--shot/--burst` 入口硬编码在正式菜单里 | 用户能看到"测试一下""导出一张画面"这种内部功能 | **已修**：`#if DEBUGTOOLS` 编译期剔除；已用二进制字节比对确认正式包 0 处、QA 包 2 处 |
| 12 | 版本号写死在 plist 里，改一次要手改 | 发版容易漏 | **已修**：`macos/VERSION` + 构建时 `PlistBuddy` 注入版本号与构建号 |
| 13 | 没有任何更新机制 | 用户只能手动回来下新版 | **已修**：`Updater`（GitHub Releases API，日检 + 菜单入口 + 下载解包替换重启） |
| 14 | 品牌名混用（HappyVoice / 无中文名 / 日志路径 / 弹窗文案） | 改名不彻底，用户看到两个名字 | **已修**：`AppInfo` 统一出口；二进制里 `FollowSound` 22 处、`随响` 5 处、`HappyVoice` 0 处 |

## 二、代码质量

| # | 问题 | 结论 |
| --- | --- | --- |
| 15 | `Mic` 的 `lastDB / bufferCount / silentSince / sawAnySignal / restartCount` 由音频回调线程写、主线程读，无锁 | **评估不改**：arm64 上对齐的 Float/Int 写入不会撕裂，最坏是状态文案或看门狗晚一帧判断，不影响画面。彻底修需要引入快照结构并改全部调用点，收益低于回归风险，排进 1.1 |
| 16 | `required init?(coder:)` 直接 `fatalError` | 可接受：视图全部代码构建，没有 nib 路径 |
| 17 | `NSScreen.screens[0]`、`timer!`、`vDSP_create_fftsetup(...)!` 等强解包 | 可接受：均为启动即成立的前提；`screens` 为空意味着没有显示器 |
| 18 | 中文文案散落在各处，无本地化 | **待办**：1.1 抽出 `Strings` 表，配合已声明的 `zh_CN/en` |
| 19 | `writeDiagnostics` 每次都会调 `AVCaptureDevice.authorizationStatus` | 已随 #1 一并只在调试构建里执行 |
| 20 | `rebuild()` 每次重建整棵图层树（改高度/换配色时） | 可接受：一次性操作，代价是粒子与包络历史清空，肉眼不可见 |

## 三、产品/体验

| # | 问题 | 结论 |
| --- | --- | --- |
| 21 | 只贴主屏，不能跟随鼠标所在屏幕 | **待办**：多屏用户的实际需求，属功能增强 |
| 22 | 没有开机自启开关 | **待办**：Windows 端已留 `autoLaunch` 字段，mac 端用 `SMAppService` 实现 |
| 23 | Windows 端只有高度预设档（100/140/180/220/280/340/400），没有滑块 | **评估不改（当前）**：Electron 托盘菜单不支持内嵌滑块；macOS 端保持无级滑块，Windows 走预设档，文档已注明 |
| 24 | 无崩溃上报、无任何遥测 | **有意保留**：与"不联网、不分析内容"的承诺一致 |
| 25 | macOS 未做 Apple 公证 | **已知限制**：需要 99 美元/年账号；文档给出接入位置，当前用"右键 → 打开"绕过 |

## 四、本轮验证记录

- `--shot` 逐项出图：band / chroma / anamorphic / pixelSort / equalizer / ripple / rain 七种均有内容，拼图核对无空白帧
- `--burst=34`：星雨粒子在水位线回弹、碎星不结团
- 正式包字符串检查：`测试一下` 0、`导出一张画面` 0、`检查更新` 2
- 运行态：`/Applications/FollowSound.app` 启动正常，空闲 CPU 0.6%，诊断日志 0 字节（未设 `FS_DIAG`）
- 打包：`FollowSound-macOS-1.0.0.zip` 337 KB / `.dmg` 614 KB，SHA-256 已生成
