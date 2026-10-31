# 发布与构建产物组织

三端共用一个 GitHub Release，版本号一致，文件名有严格约定 —— 因为**自动更新靠文件名找包**。

## 1. 目录约定

```
followsound/
├─ macos/            Swift 源码 + build.sh（本地构建）+ package.sh（出 zip/dmg）
├─ windows/          Electron 工程；electron-builder 输出到 ../dist/windows
├─ android/          原生 Gradle 工程；APK 输出到 app/build/outputs/apk/release
├─ shared/           视觉核心（themes.js / visualizer.js / player.html），三端共用
├─ docs/             官网（GitHub Pages 的发布目录）+ 本目录的文档
└─ dist/             本地构建产物，已在 .gitignore 里
```

`shared/` 是唯一真源：

- Windows：打包时 `extraResources` 复制进 `resources/shared`
- Android：Gradle 任务 `syncShared` 在 preBuild 前复制进 `app/src/main/assets`
- 官网：`docs/assets/` 是它的副本（Pages 不支持跨目录引用），改动后执行 `scripts/sync-web.sh`

## 2. 产物命名（必须遵守）

| 平台 | 带版本号的文件 | 固定别名（官网写死这个） |
| --- | --- | --- |
| macOS | `FollowSound-macOS-1.0.0.zip` | `FollowSound-macOS.zip` |
| macOS 安装镜像 | `FollowSound-macOS-1.0.0.dmg` | — |
| Windows | `FollowSound-Windows-1.0.0-Setup.exe` | `FollowSound-Windows-Setup.exe` |
| Windows 免安装 | `FollowSound-Windows-1.0.0-x64.zip` | — |
| Android | `FollowSound-Android-1.0.0.apk` | `FollowSound-Android.apk` |
| 更新元数据 | `latest.yml`（electron-builder 生成，Windows 自动更新用） | — |
| 校验 | `SHA256SUMS.txt` | — |

固定别名的好处：官网下载按钮永远指向
`https://github.com/VVCY/FollowSound/releases/latest/download/FollowSound-macOS.zip`，
发新版本时网页一个字都不用改。

## 3. 三个平台的打包命令

三端都已在 macOS 本机实测出包（2026-10-31，v1.0.0）。以下命令按实际跑通的写法记录。

```bash
# macOS：本地出 zip + dmg（通用二进制，arm64 + x86_64）
VERSION=1.0.0 ./macos/package.sh            # → dist/macos/

# Windows：在 windows/ 下
npm install
npx electron-builder --win --publish never   # → dist/windows/（含 latest.yml、blockmap）
```

国内网络下 electron 与 nsis 的二进制走 GitHub 会卡死，用镜像：

```bash
export ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/
export ELECTRON_BUILDER_BINARIES_MIRROR=https://npmmirror.com/mirrors/electron-builder-binaries/
```

```bash
# Android：需要 JDK 17 + Android SDK（platform 35 / build-tools 35）
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
export ANDROID_HOME=$HOME/Library/Android/sdk
echo "sdk.dir=$ANDROID_HOME" > android/local.properties

cd android && ./gradlew assembleRelease \
  -PfsVersionName=1.0.0 -PfsVersionCode=1
# → android/app/build/outputs/apk/release/app-release.apk（约 4.4 MB）
```

`app/build.gradle.kts` 里的 `syncShared` 会在 preBuild 前把 `../shared` 复制进 assets，
所以 APK 里的渲染核心永远和仓库同源，不需要手工同步。

### 平台差异（踩过的坑）

- **托盘/菜单栏图标不是同一张图**：macOS 用模板图（白色透明）交给系统自动反色；
  Windows 托盘不反色，纯白透明图在浅色任务栏上等于隐形、纯黑底又会在深色任务栏上糊掉。
  所以 Windows 单独出一张 3 根青色声波柱的 `windows/build/tray.png`（16px 下 5 根会并成一团，3 根才认得出）。
- **Android 的前台服务**：`specialUse` 类型必须同时声明 `FOREGROUND_SERVICE_SPECIAL_USE` 权限，
  否则 `startForeground` 直接抛 `SecurityException`（Android 14+）。
- **Android 的渲染核心**由 `syncShared` 在 `preBuild` 前复制进 assets，不进 git；
  改了 `shared/` 一定要重新 `assembleRelease`，别只重启 App。

### 打包后核对（别省）

```bash
# Windows：托盘图标、更新配置、共享资源都在包里？
npx @electron/asar list dist/windows/win-unpacked/resources/app.asar | grep -E "^/(build|src)"
cat dist/windows/win-unpacked/resources/app-update.yml
ls dist/windows/win-unpacked/resources/shared/

# Android：包名、版本、权限、assets、签名
$ANDROID_HOME/build-tools/35.0.0/aapt2 dump badging <apk> | head -20
unzip -l <apk> | grep assets/
$ANDROID_HOME/build-tools/35.0.0/apksigner verify --print-certs <apk>

# Windows 端渲染自检（不需要 Windows 机器，Electron 跨平台跑同一份页面）
cd windows && npx electron tools/smoke.js
```

## 4. 发布流程（自动化）

> 工作流源文件在 `ci/release.yml`，需要先启用一次（原因与两种启用方式见 `ci/README.md`）：
> `mkdir -p .github/workflows && git mv ci/release.yml .github/workflows/release.yml`

```bash
# 1) 改版本号
echo 1.1.0 > macos/VERSION
# windows/package.json 的 version、android/gradle.properties 的 fsVersionName 由 CI 覆盖，不用手改

# 2) 更新更新日志
#    docs/release-notes.md（Release 正文）
#    docs/index.html 的 .timeline（官网时间线）

# 3) 打标签推上去，剩下的交给 .github/workflows/release.yml
git tag v1.1.0
git push origin v1.1.0
```

CI 里三个 job 并行构建，`publish` 汇总后一次性挂到同一个 Release：

```
macos-14        → FollowSound-macOS-*.zip / .dmg
windows-latest  → FollowSound-Windows-*-Setup.exe / .zip / latest.yml
ubuntu-latest   → FollowSound-Android-*.apk
publish         → 生成固定别名 + SHA256SUMS.txt + 创建 Release
```

## 5. 签名现状（诚实版）

- **macOS**：本地开发用自签证书（`macos/make_cert.sh` 生成，TCC 麦克风授权不会每次重置）；CI 里退回 ad-hoc 签名。**没有 Apple 公证**，用户首次打开需要右键 → 打开。要正经分发需要 99 美元/年的开发者账号，加两行 `notarytool` 即可。
- **Windows**：没有代码签名证书，SmartScreen 会提示「未知发布者」。EV 证书约 300-500 美元/年，拿到后把 `.pfx` 放进 Secrets，`electron-builder` 配 `win.certificateFile` 即可。
- **Android**：现在用 debug 签名（证书 DN 为 `CN=Android Debug`），能装能升级；但**更换签名后无法覆盖安装**，所以正式发版前应先固定一个 keystore。上架 Google Play 也需要正式签名。生成方式见下。

```bash
# Android 正式签名（一次性）
keytool -genkey -v -keystore followsound.jks -alias followsound \
        -keyalg RSA -keysize 2048 -validity 10000
# 然后把 jks 转 base64 放进仓库 Secrets：ANDROID_KEYSTORE_BASE64
# 并在 app/build.gradle.kts 的 release 里读它（脚本已留好 signingConfig 位置）
```

## 6. 官网部署

`docs/` 就是站点根目录，**不需要 Actions**。同一份文件同时发两个地方：GitHub Pages（主站）和
Cloudflare Pages（国内备用入口）。

### 6.1 GitHub Pages（主站）

仓库 Settings → Pages → Source 选 `Deploy from a branch` → `main` / `/docs`。

访问地址：https://vvcy.github.io/FollowSound/

改完网页执行一次 `scripts/sync-web.sh` 把 `shared/` 同步到 `docs/assets/`，然后 commit 即上线。

### 6.2 Cloudflare Pages（备用入口）

目的只有一个：GitHub Pages 在国内经常慢或打不开。**Gitee Pages 已无解**（2024-05 下线，
官方称暂不上线）；国内云厂商的静态托管要绑备案域名才有大陆节点，所以走 Cloudflare 这条免备案的路。

**现状：已接好，push 即自动发布。** 访问地址 https://followsound.pages.dev/

项目 `followsound` 已通过控制台连到 GitHub 仓库，配置如下（改配置在项目 Settings →
Build & deployments）：

| 字段 | 值 |
| --- | --- |
| Project name | `followsound`（决定 `followsound.pages.dev`） |
| Production branch | `main` |
| Framework preset | `None` |
| Build command | **留空** |
| Build output directory | `docs` |
| Root directory | 留空（仓库根） |

所以日常发布就是**推 main**：CF 收到 webhook 后重新部署，不需要跑任何命令。
GitHub App 授权时选的是「仅选定的仓库」→ 只给了 `VVCY/FollowSound` 一个，换仓库要回
GitHub → Settings → Applications 里改。

重新接线（换了账号或删了项目时）：Workers & Pages → 创建应用程序 → 继续前往 Pages →
导入现有 Git 存储库 → GitHub → 选仓库 → 按上表填。云厂商的 Pages 页面现在默认进
"Create project" 新流程（Workers + 静态资源），要点页脚那行 **「继续前往 Pages」** 才回到经典流程。

**B. 本地 wrangler**（不走 Git 时）

```bash
npx wrangler login          # 浏览器授权一次
./scripts/deploy-cf.sh      # 先跑 sync-web --check，再部署 docs/
```

### 6.3 关于 `*.pages.dev` 的国内可达性（别抱太高期望）

`pages.dev` 和 `workers.dev` 自 2022 年起在国内常遭 DNS 污染，**部分运营商/时段能通，属于"不稳定"
而不是"完全不可用"**；移动网络最明显。想要稳定，必须绑**自己的域名**——不要求 ICP 备案，
只要域名 DNS 能指向 Cloudflare：

- 域名几十元/年，NS 托管到 Cloudflare（或子域 CNAME 到 `followsound.pages.dev`）；
- 申请证书时若配过 CAA 记录，要放行 `letsencrypt.org`、`pki.goog`、`ssl.com`，否则证书激活不了；
- 先在该 Pages 项目的 Custom domains 里添加域名，再去 DNS 加记录，顺序反了会 522。

绑上自有域名后国内访问才谈得上稳定；只靠 `pages.dev`，它在国内的表现不一定比
`vvcy.github.io` 好，这点要如实告诉用户。

### 6.4 两份文件的用途

| 文件 | 作用 | 备注 |
| --- | --- | --- |
| `docs/_headers` | Cloudflare Pages 的响应头（MIME 防嗅探、静态资源长缓存、HTML 回源校验） | Jekyll 忽略下划线开头文件，GitHub Pages 不会发布它，无副作用 |
| `wrangler.toml` | `pages_build_output_dir = "docs"`，供本地 wrangler 与 CLI 部署 | 走控制台连 Git 时这份文件不参与构建 |

