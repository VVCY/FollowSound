// 验证「特效 / 配色」切换到底生不生效：走真实的 UI 点击，不看 API。
// 用法: npx electron tools/switch-check.js
const { app, BrowserWindow } = require('electron');
const path = require('path');

app.disableHardwareAcceleration();
app.commandLine.appendSwitch('no-sandbox');

const files = {
  player: path.join(__dirname, '../../shared/player.html'),
  site: path.join(__dirname, '../../docs/index.html'),
};

function wait(ms) { return new Promise(r => setTimeout(r, ms)); }

// 在页面里采样画布：非透明像素数 + 平均色（用来判断"换配色后颜色变没变"）
const SAMPLE = `(function(c){
  var ctx = c.getContext('2d');
  var w = c.width, h = c.height;
  var d = ctx.getImageData(0, 0, w, h).data;
  var n = 0, r = 0, g = 0, b = 0, bot = 0, top = 0;
  for (var y = 0; y < h; y += 3) {
    for (var x = 0; x < w; x += 3) {
      var o = (y * w + x) * 4, a = d[o+3];
      if (a > 12) { n++; r += d[o]; g += d[o+1]; b += d[o+2]; if (y > h*0.55) bot++; else top++; }
    }
  }
  return n ? { n: n, rgb: [Math.round(r/n), Math.round(g/n), Math.round(b/n)], bot: bot, top: top } : { n: 0 };
})`;

app.whenReady().then(async () => {
  const win = new BrowserWindow({
    width: 520, height: 780, show: false,
    webPreferences: { offscreen: true, nodeIntegration: false, contextIsolation: true }
  });
  win.webContents.on('console-message', (_e, l, m) => console.log('[page]', m));

  const out = {};

  // ---------- 1) 播放页：默认值 + UI 切换 ----------
  await win.loadURL('file://' + files.player + '?demo=1&chrome=1');
  await wait(1200);
  out.player = await win.webContents.executeJavaScript(`(function(){
    var fs = window.fs;
    var t = document.querySelector('#stylePick .fs-select-trigger .fs-select-label');
    var th = document.querySelector('#themePick .fs-select-trigger .fs-select-label');
    return {
      style: fs.style, theme: fs.themeKey,
      labelStyle: t ? t.textContent : null,
      labelTheme: th ? th.textContent : null,
      storedStyle: localStorage.getItem('fs.style'),
      storedTheme: localStorage.getItem('fs.theme')
    };
  })()`);

  out.player.pixelRain = await win.webContents.executeJavaScript(SAMPLE + `(document.getElementById('stage'))`);

  // 点开「特效」下拉 → 选「光带」
  out.player.pickBand = await win.webContents.executeJavaScript(`(function(){
    document.querySelector('#stylePick .fs-select-trigger').click();
    var menu = document.querySelector('#stylePick .fs-select-menu');
    var open = document.querySelector('#stylePick').classList.contains('open');
    var items = [].map.call(menu.querySelectorAll('button'), function(b){return b.textContent;});
    return { open: open, items: items };
  })()`);
  await win.webContents.executeJavaScript(`(function(){
    var menu = document.querySelector('#stylePick .fs-select-menu');
    var b = [].filter.call(menu.querySelectorAll('button'), function(x){return x.textContent==='光带';})[0];
    b.click();
    return true;
  })()`);
  await wait(400);
  out.player.afterBand = await win.webContents.executeJavaScript(`(function(){
    var fs = window.fs;
    return { style: fs.style, theme: fs.themeKey,
      label: document.querySelector('#stylePick .fs-select-label').textContent,
      stored: localStorage.getItem('fs.style') };
  })()`);
  out.player.pixelBand = await win.webContents.executeJavaScript(SAMPLE + `(document.getElementById('stage'))`);

  // 切回星雨
  await win.webContents.executeJavaScript(`(function(){
    document.querySelector('#stylePick .fs-select-trigger').click();
    var b = [].filter.call(document.querySelectorAll('#stylePick .fs-select-menu button'), function(x){return x.textContent==='星雨';})[0];
    b.click(); return true;
  })()`);
  await wait(600);
  out.player.backToRain = await win.webContents.executeJavaScript(`(function(){
    var fs = window.fs;
    return { style: fs.style, label: document.querySelector('#stylePick .fs-select-label').textContent,
      stored: localStorage.getItem('fs.style') };
  })()`);
  out.player.pixelRain2 = await win.webContents.executeJavaScript(SAMPLE + `(document.getElementById('stage'))`);

  // 换配色：深海
  await win.webContents.executeJavaScript(`(function(){
    document.querySelector('#themePick .fs-select-trigger').click();
    var b = [].filter.call(document.querySelectorAll('#themePick .fs-select-menu button'), function(x){return x.textContent==='深海';})[0];
    b.click(); return true;
  })()`);
  await wait(600);
  out.player.afterOcean = await win.webContents.executeJavaScript(`(function(){
    var fs = window.fs;
    return { theme: fs.themeKey,
      label: document.querySelector('#themePick .fs-select-label').textContent,
      accentVar: getComputedStyle(document.documentElement).getPropertyValue('--fs-accent').trim(),
      stored: localStorage.getItem('fs.theme') };
  })()`);
  out.player.pixelOcean = await win.webContents.executeJavaScript(SAMPLE + `(document.getElementById('stage'))`);

  require('fs').writeFileSync('/tmp/switch-player.png', (await win.webContents.capturePage()).toPNG());

  // ---------- 2) 默认值迁移：老用户存的旧选择要让位给新默认 ----------
  async function boot(stored) {
    await win.loadURL('file://' + files.player + '?demo=1');
    await win.webContents.executeJavaScript(`(function(){
      localStorage.clear();
      ${stored}
      return true;
    })()`);
    await win.loadURL('file://' + files.player + '?demo=1');
    await wait(900);
    return win.webContents.executeJavaScript(`(function(){
      var fs = window.fs;
      return { style: fs.style, theme: fs.themeKey,
               rev: localStorage.getItem('fs.prefRev') };
    })()`);
  }
  // 旧版留下的选择（没有 rev 戳）→ 应当被新默认顶掉
  out.migrateOld = await boot(
    "localStorage.setItem('fs.style','band');localStorage.setItem('fs.theme','ocean');"
  );
  // 已经是新版、用户自己选的 → 必须保留
  out.migrateKept = await boot(
    "localStorage.setItem('fs.style','band');localStorage.setItem('fs.theme','ocean');" +
    "localStorage.setItem('fs.prefRev','2');"
  );

  // ---------- 3) 官网：星雨是不是新版算法 ----------
  await win.loadURL('file://' + files.site);
  await wait(1800);
  out.site = await win.webContents.executeJavaScript(`(function(){
    var src = [].map.call(document.querySelectorAll('script[src]'), function(s){return s.getAttribute('src');});
    var c = document.getElementById('dockCanvas');
    var px = null;
    if (c) {
      var ctx = c.getContext('2d'), w = c.width, h = c.height;
      var d = ctx.getImageData(0, 0, w, h).data;
      var n = 0, bot = 0, top = 0;
      for (var y = 0; y < h; y += 3) for (var x = 0; x < w; x += 3) {
        var o = (y*w+x)*4;
        if (d[o+3] > 12) { n++; if (y > h*0.55) bot++; else top++; }
      }
      px = { n: n, bot: bot, top: top };
    }
    return { scripts: src, pixel: px };
  })()`);
  // 新版 drawRain 的特征：向上喷（vTop）。旧版是 y:-10 从顶端下落。
  out.site.alg = await win.webContents.executeJavaScript(`(function(){
    return typeof FollowSound === 'object' ? 'loaded' : 'missing';
  })()`);
  require('fs').writeFileSync('/tmp/switch-site.png', (await win.webContents.capturePage()).toPNG());

  console.log('RESULT ' + JSON.stringify(out, null, 2));
  app.quit();
});
