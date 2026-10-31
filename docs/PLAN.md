# 落地路径：从测试到上线

按执行顺序排列。每一步都标了**交付物**（能拿在手里的东西）和**验收方式**（怎么算做完了）。
顺序不能换：测试要在改名之前跑完（改动最小的时候定位问题），图标要在打包之前替换（否则包里还是旧图标），
自动更新要在第一个 Release 之后才能验证（它读的就是 Release）。

## 总览

| # | 步骤 | 交付物 | 状态 |
| --- | --- | --- | --- |
| 0 | 通读源码 + 跑一轮测试 | `docs/REVIEW.md`、7 张特效出图 | ✅ |
| 1 | 测试功能从正式版剔除 | 编译期开关 `DEBUGTOOLS`；release 二进制 0 处测试文案 | ✅ |
| 2 | 逐项修审查问题 | 14 项已修记录（见 REVIEW.md） | ✅ |
| 3 | 图标重设计（白底透明） | `AppIcon.icns`、`StatusIcon(@2x).png`、`icon.ico`、Android mipmap、`favicon`/`og.png` | ✅ |
| 4 | 统一更名「随响 FollowSound」 | 新 bundle id + 偏好迁移 + 全部文案/文件名 | ✅ |
| 5 | 三端打包 | macOS `zip`/`dmg`、Windows `Setup.exe`/`zip`、Android `apk` | ✅ 三端实包均已产出并挂到 Release |
| 6 | 三端自动更新 | mac `Updater.swift`、win `electron-updater`、android `Updater.kt` | ✅ |
| 7 | 官网 | `docs/`（Pages 根目录）：功能 / 定价 / 下载 / 更新日志 / 实时演示 | ✅ |
| 8 | 发布 | GitHub 仓库 + v1.0.0 Release + Pages 线上地址 | ✅ |

## 步骤细节

### 0. 测试（改动最小的时候做）

```bash
cd macos
./build.sh --devtools --out /tmp/qa                     # QA 构建：菜单里有测试项、支持 --shot
BIN=/tmp/qa/FollowSound-QA.app/Contents/MacOS/FollowSound
for s in band chroma anamorphic pixelSort equalizer ripple rain; do
  "$BIN" --style=$s --theme=ocean --shot                 # 出图到 /tmp/shot-<style>-<theme>.png
done
"$BIN" --style=rain --level=0.95 --burst=34 --shot       # 音头回弹
```

**交付物**：7 张 `/tmp/shot-*.png` + 拼图核对。**验收**：每一格都有内容，没有全黑帧。
本轮就是靠这一步发现「横向镜头光斑满音量时被窗口上沿裁掉」，并修掉。

### 1. 把测试功能藏起来

自检入口分两类，都包在 `#if DEBUGTOOLS` 里：

- 菜单项「测试一下」「导出一张画面」
- 命令行 `--style/--theme/--level/--height/--shot/--burst`

```bash
./build.sh              # 正式版，无 -D DEBUGTOOLS
strings ... | grep 测试一下   # 应无结果
```

**交付物**：`/Applications/FollowSound.app`。**验收**：release 二进制里测试文案 0 处，QA 包 2 处。

### 2. 修问题

按 `docs/REVIEW.md` 逐条处理。优先级：用户可见 > 隐私承诺 > 性能 > 代码洁癖。
本轮修掉的 14 项里，影响最大的是「日志无限增长」和「改名后偏好清零」。

**交付物**：REVIEW.md 的「已修」列表 + 每条的验收证据。

### 3. 图标

一套几何（7 根声波柱，中线对称）生成五套资产：

```bash
swiftc -O macos/tools/make_icons.swift -o /tmp/make_icons
/tmp/make_icons build-icons                         # 出 iconset + StatusIcon + 多尺寸 PNG
iconutil -c icns build-icons/AppIcon.iconset -o macos/Resources/AppIcon.icns
```

- macOS：透明底白色声波（带极轻投影，浅色壁纸上才看得见轮廓）
- 菜单栏：模板图，系统按明暗自动反色
- Windows：多尺寸 `.ico`（16→256）
- Android：深色圆角底板 + 白色声波（桌面壁纸多为浅色，纯透明会糊掉）
- 网页：`favicon-32.png` + `og.png` 分享图

**交付物**：`macos/Resources/AppIcon.icns` 等 6 类文件。**验收**：`preview-dark.png` 目视 + Dock 里能看到。

### 4. 改名

- `CFBundleName` = 随响，`CFBundleDisplayName` = 随响 FollowSound
- 可执行文件名 `FollowSound`，bundle id `app.followsound.mac`
- 旧域 `com.local.happyvoice` 的 `style/theme/bandHeight/gateMode` 启动时迁移
- 日志、截图、弹窗、菜单、文档、仓库名同步

**验收**：二进制里 `HappyVoice` 出现 0 次。

### 5. 三端打包

| 平台 | 命令 | 产物 |
| --- | --- | --- |
| macOS | `VERSION=1.0.0 ./macos/package.sh` | `dist/macos/FollowSound-macOS-1.0.0.zip` + `.dmg` + `SHA256SUMS.txt` |
| Windows | `cd windows && npx electron-builder --win --publish never` | `dist/windows/FollowSound-Windows-1.0.0-Setup.exe`、`.zip`、`latest.yml` |
| Android | `cd android && gradle assembleRelease -PfsVersionName=1.0.0` | `app-release.apk` → 改名成 `FollowSound-Android-1.0.0.apk` |

组织和命名规则见 `docs/RELEASE.md`。**关键点**：每个平台额外复制一份**固定别名**
（`FollowSound-macOS.zip` / `FollowSound-Windows-Setup.exe` / `FollowSound-Android.apk`），
官网下载按钮只认别名，发版不用改网页。

### 6. 自动更新（三端都走 GitHub）

| 端 | 实现 | 检查时机 |
| --- | --- | --- |
| macOS | `Updater.swift`：GET `releases/latest` → 比版本 → 下 zip → `ditto` 解包 → 写一个脱离脚本等本进程退出后替换 `.app` → 重开 | 启动后一次 + 每 24 小时，菜单「检查更新」可手动 |
| Windows | `electron-updater` + `provider: github`，读 Release 里的 `latest.yml` | 启动 8 秒后 + 每 6 小时 |
| Android | `Updater.kt`：GET `releases/latest` → 找 `.apk` → `DownloadManager` 风格下载 → FileProvider 交给系统安装器 | 每次冷启动（静默，不打扰） |

**验收**：mac 端把 `macos/VERSION` 改成 0.9.0 构建一次，菜单里应出现「有新版 v1.0.0，点击下载并安装」。

### 7. 官网

`docs/` 直接作为 GitHub Pages 根目录（不需要 Actions）：

- 首屏：标题 + 实时演示画布（没麦克风时走演示动画，不空白）
- 01 特效切换 / 02 功能 / 03 24 套配色点选联动 / 04 定价 / 05 下载 / 06 更新日志 / 07 FAQ
- 定价按「免费 + 自愿赞助」写，没有功能锁

```bash
scripts/sync-web.sh          # 把 shared/ 同步到 docs/assets/
```

### 8. 发布

```bash
git init && git add -A && git commit -m "随响 FollowSound 1.0.0"
git remote add origin https://github.com/VVCY/FollowSound.git
git push -u origin main

# 首个 Release：三端产物 + 说明 + 校验值 + 更新清单
gh release create v1.0.0 \
  dist/macos/FollowSound-macOS-1.0.0.zip dist/macos/FollowSound-macOS-1.0.0.dmg \
  dist/windows/FollowSound-Windows-1.0.0-Setup.exe dist/windows/FollowSound-Windows-1.0.0-x64.zip \
  dist/windows/latest.yml dist/android/FollowSound-Android-1.0.0.apk \
  dist/macos/SHA256SUMS.txt \
  --title "随响 FollowSound v1.0.0" --notes-file docs/release-notes.md
```

再补上三个固定别名（官网按钮写死这几个名字，发新版不用改网页）：

```bash
for p in "macOS:dist/macos/FollowSound-macOS.zip" \
         "Windows-Setup:dist/windows/FollowSound-Windows-Setup.exe" \
         "Android:dist/android/FollowSound-Android.apk"; do
  gh release upload v1.0.0 "${p#*:}" --clobber
done
```

之后每次发版：改 `macos/VERSION` → 更新 `docs/release-notes.md` 与官网时间线 →
重新出三端包 → `gh release create/upload`。标签触发 CI 的自动化路径也已就绪（`ci/release.yml`），
启用后一条 `git push origin v1.1.0` 就能替代上面这段手工上传。

**交付物**：仓库、Release、Pages 地址。**验收**：三个 `releases/latest/download/...` 链接都能下到文件。

## 还差什么（诚实清单）

1. **签名证书**：三端都没有正式签名（mac 无公证、win 无 EV 证书、android 用 debug 签名）。
   能装能用，但都会有系统警告。要正经分发需要买证书，接入位置见 RELEASE.md。
2. **GitHub Token 的 workflow 权限**：如果 CI 推送被拒（403 workflow scope），
   需要在 GitHub 上给 token 勾上 `workflow`，或直接在网页上添加这两个 yml。
