// 随响 FollowSound —— Windows 端（Electron）
// 目标与 macOS 版一致：贴底的透明覆盖层、点击穿透、托盘常驻、不占任务栏。
// 视觉核心复用 ../shared/visualizer.js，与网页演示、Android 端是同一份代码。

const {
  app, BrowserWindow, Tray, Menu, nativeImage, screen, protocol, net,
  session, shell, Notification
} = require('electron');
const path = require('path');
const fs = require('fs');
const { autoUpdater } = require('electron-updater');

const APP_NAME = '随响 FollowSound';
const REPO = { owner: 'VVCY', repo: 'FollowSound' };
/** 覆盖层比光带本身高出一截，光斑/光晕才有地方画（与 macOS 版 overlayHeadroom 一致） */
const HEADROOM = 56;

const isDev = !app.isPackaged;
const SETTINGS_PATH = () => path.join(app.getPath('userData'), 'settings.json');

let win = null;
let tray = null;
let settings = { style: 'band', theme: 'ocean', height: 180, autoLaunch: false };

// ---------- 设置 ----------
function loadSettings() {
  try {
    Object.assign(settings, JSON.parse(fs.readFileSync(SETTINGS_PATH(), 'utf8')));
  } catch (e) { /* 首次运行没有文件，用默认值 */ }
}
function saveSettings() {
  try {
    fs.mkdirSync(path.dirname(SETTINGS_PATH()), { recursive: true });
    fs.writeFileSync(SETTINGS_PATH(), JSON.stringify(settings, null, 2));
  } catch (e) { /* 写不进去也不该影响主流程 */ }
}

// 让 player.html 能以「安全上下文」加载，getUserMedia 才不会被 Chromium 拦掉
protocol.registerSchemesAsPrivileged([{
  scheme: 'app',
  privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true }
}]);

function sharedDir() {
  return isDev
    ? path.join(__dirname, '..', '..', 'shared')
    : path.join(process.resourcesPath, 'shared');
}

function registerAppProtocol() {
  protocol.handle('app', (req) => {
    const rel = decodeURIComponent(new URL(req.url).pathname).replace(/^\/+/, '');
    const file = path.join(sharedDir(), rel);
    // 只允许访问 shared 目录内的文件
    if (!file.startsWith(sharedDir())) return new Response('forbidden', { status: 403 });
    return net.fetch('file://' + file);
  });
}

// ---------- 覆盖层窗口 ----------
function overlayBounds() {
  const d = screen.getPrimaryDisplay();
  const h = settings.height + HEADROOM;
  return {
    x: d.bounds.x,
    y: d.bounds.y + d.bounds.height - h,
    width: d.bounds.width,
    height: h
  };
}

function createOverlay() {
  win = new BrowserWindow({
    ...overlayBounds(),
    frame: false,
    transparent: true,
    backgroundColor: '#00000000',
    hasShadow: false,
    resizable: false,
    movable: false,
    focusable: false,
    skipTaskbar: true,
    show: false,
    alwaysOnTop: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      backgroundThrottling: false
    }
  });

  win.setAlwaysOnTop(true, 'screen-saver');
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  // 点击穿透：鼠标事件直接落到下面的窗口，不挡用户干活
  win.setIgnoreMouseEvents(true, { forward: true });

  const q = new URLSearchParams({
    style: settings.style,
    theme: settings.theme,
    height: String(settings.height),
    autostart: '1'
  });
  win.loadURL('app://local/player.html?' + q.toString());
  win.once('ready-to-show', () => win.showInactive());

  // 只有显式要求时才开调试面板，否则开发模式下每次启动都弹一个窗口
  if (isDev && process.env.FS_DEVTOOLS === '1') win.webContents.openDevTools({ mode: 'detach' });
}

function applyHeight(h) {
  settings.height = Math.max(80, Math.min(400, Math.round(h)));
  saveSettings();
  if (win) {
    win.setBounds(overlayBounds());
    win.webContents.executeJavaScript(`window.fsSetHeight && fsSetHeight(${settings.height})`).catch(() => {});
  }
  rebuildTray();
}

function applyStyle(key) {
  settings.style = key; saveSettings();
  win?.webContents.executeJavaScript(`window.fsSetStyle && fsSetStyle(${JSON.stringify(key)})`).catch(() => {});
  rebuildTray();
}

function applyTheme(key) {
  settings.theme = key; saveSettings();
  win?.webContents.executeJavaScript(`window.fsSetTheme && fsSetTheme(${JSON.stringify(key)})`).catch(() => {});
  rebuildTray();
}

// ---------- 托盘 ----------
const STYLES = [
  ['band', '光带'], ['chroma', '色差光带'], ['anamorphic', '横向镜头光斑'],
  ['pixelSort', '像素拉丝'], ['equalizer', '均衡器'], ['ripple', '波纹'], ['rain', '星雨']
];
const THEMES = [
  ['ocean', '深海'], ['noir', '黑金偏色'], ['crimson', '深红信号'], ['magenta', '品红波普'],
  ['hud', '暗色 HUD'], ['mint', '薄荷终端'], ['sakura', '樱花'], ['sunset', '晚霞'],
  ['vapor', '蒸汽波'], ['synth80', '合成 80s'], ['gold', '金夜'], ['mono', '单色 RGB'],
  ['forest', '森之帖'], ['paper', '纸与墨'], ['blueprint', '蓝图'], ['acid', '酸液']
];

let updateState = '未检查';

function rebuildTray() {
  if (!tray) return;
  const heights = [100, 140, 180, 220, 280, 340];
  const menu = Menu.buildFromTemplate([
    { label: `${APP_NAME} v${app.getVersion()}`, enabled: false },
    { type: 'separator' },
    {
      label: '特效',
      submenu: STYLES.map(([k, t]) => ({
        label: t, type: 'radio', checked: settings.style === k, click: () => applyStyle(k)
      }))
    },
    {
      label: '配色',
      submenu: THEMES.map(([k, t]) => ({
        label: t, type: 'radio', checked: settings.theme === k, click: () => applyTheme(k)
      }))
    },
    {
      label: `高度（当前 ${settings.height} pt）`,
      submenu: heights.concat([400]).map((h) => ({
        label: `${h} pt`, type: 'radio', checked: settings.height === h, click: () => applyHeight(h)
      }))
    },
    { type: 'separator' },
    // 麦克风偶尔会被系统降级成"打开了但收不到声"，重载一次页面就能重新申请
    { label: '重连麦克风', click: () => win?.webContents.reload() },
    { type: 'separator' },
    { label: `检查更新：${updateState}`, click: checkForUpdates },
    { label: '打开发布页', click: () => shell.openExternal(`https://github.com/${REPO.owner}/${REPO.repo}/releases`) },
    { label: '退出', click: () => app.quit() }
  ]);
  tray.setContextMenu(menu);
}

// ---------- 自动更新 ----------
function checkForUpdates() {
  if (isDev) { updateState = '开发模式下不检查'; rebuildTray(); return; }
  updateState = '检查中…';
  rebuildTray();
  autoUpdater.checkForUpdates().catch((e) => {
    updateState = '检查失败';
    rebuildTray();
    console.warn('update check failed:', e.message);
  });
}

autoUpdater.on('update-available', (info) => {
  updateState = `发现 v${info.version}，正在下载`;
  rebuildTray();
  autoUpdater.downloadUpdate().catch(() => {});
});
autoUpdater.on('update-not-available', () => {
  updateState = '已是最新版本';
  rebuildTray();
});
autoUpdater.on('update-downloaded', (info) => {
  updateState = `v${info.version} 已就绪`;
  rebuildTray();
  new Notification({
    title: APP_NAME,
    body: `新版本 v${info.version} 已下载，退出后自动安装。`
  }).show();
});
autoUpdater.on('error', () => { updateState = '更新出错'; rebuildTray(); });

// ---------- 启动 ----------
app.requestSingleInstanceLock() || app.quit();
app.on('second-instance', () => { win?.showInactive(); });

app.whenReady().then(() => {
  loadSettings();
  registerAppProtocol();

  // 只在第一次需要时询问麦克风，交给系统弹窗
  session.defaultSession.setPermissionRequestHandler((wc, permission, callback) => {
    callback(['media', 'audioCapture', 'microphone'].includes(permission));
  });
  session.defaultSession.setPermissionCheckHandler((wc, permission) => {
    return ['media', 'audioCapture', 'microphone'].includes(permission);
  });

  createOverlay();

  const iconPath = path.join(__dirname, '..', 'build', 'tray.png');
  // 托盘图标是青色声波（非模板图）：Windows 不会自动反色，纯白透明图在浅色任务栏上会隐形。
  const trayIcon = nativeImage.createFromPath(iconPath);
  trayIcon.setTemplateImage(false);
  tray = new Tray(trayIcon);
  tray.setToolTip(APP_NAME);
  rebuildTray();

  screen.on('display-metrics-changed', () => win?.setBounds(overlayBounds()));
  screen.on('display-added', () => win?.setBounds(overlayBounds()));
  screen.on('display-removed', () => win?.setBounds(overlayBounds()));

  // 启动 8 秒后静默查一次，之后每 6 小时一次
  setTimeout(checkForUpdates, 8000);
  setInterval(checkForUpdates, 6 * 3600 * 1000);
});

app.on('window-all-closed', () => { /* 托盘常驻，不退出 */ });
app.on('before-quit', () => { saveSettings(); });
