// 开发期自检：用 Electron 自己把覆盖层页面渲染出来并数像素。
// 不随安装包发布（electron-builder 的 files 只含 src/**），仅用于本地验收。
//
//   env -u ELECTRON_RUN_AS_NODE node_modules/.bin/electron tools/smoke.js
//
// 输出：/tmp/fs-smoke-<style>.png 与每个特效的不透明像素数。

const { app, BrowserWindow, protocol, net } = require('electron');
const path = require('path');
const fs = require('fs');

const SHARED = path.join(__dirname, '..', '..', 'shared');
const STYLES = ['band', 'chroma', 'anamorphic', 'pixelSort', 'equalizer', 'ripple', 'rain'];

protocol.registerSchemesAsPrivileged([{
  scheme: 'app',
  privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true }
}]);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

app.whenReady().then(async () => {
  protocol.handle('app', (req) => {
    const rel = decodeURIComponent(new URL(req.url).pathname).replace(/^\/+/, '');
    const file = path.join(SHARED, rel);
    if (!file.startsWith(SHARED)) return new Response('forbidden', { status: 403 });
    return net.fetch('file://' + file);
  });

  const win = new BrowserWindow({
    width: 900,
    height: 240,
    show: false,
    frame: false,
    backgroundColor: '#00000000',
    webPreferences: { offscreen: true, backgroundThrottling: false }
  });

  let bad = 0;
  for (const style of STYLES) {
    const q = new URLSearchParams({
      demo: '1', style, theme: 'vapor', height: '160', bg: '0b0d12'
    });
    await win.loadURL('app://local/player.html?' + q.toString());
    await sleep(2600);

    const stat = await win.webContents.executeJavaScript(`(() => {
      const c = document.getElementById('stage');
      const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
      let n = 0, maxA = 0;
      for (let i = 3; i < d.length; i += 4) { if (d[i] > 8) n++; if (d[i] > maxA) maxA = d[i]; }
      const err = document.getElementById('err');
      return { n, maxA, w: c.width, h: c.height,
               err: err && err.style.display === 'block' ? err.textContent : '' };
    })()`);

    const png = (await win.webContents.capturePage()).toPNG();
    const out = `/tmp/fs-smoke-${style}.png`;
    fs.writeFileSync(out, png);
    const ok = stat.n > 200 && !stat.err;
    if (!ok) bad++;
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${style.padEnd(10)} px=${String(stat.n).padStart(6)} maxA=${stat.maxA} ${stat.w}x${stat.h} ${stat.err}`);
  }

  console.log(bad === 0 ? 'ALL PASS' : `${bad} FAILED`);
  app.exit(bad === 0 ? 0 : 1);
});
