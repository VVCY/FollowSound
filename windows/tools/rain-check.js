// 离屏跑一次 player.html，把画布状态和粒子数读出来，确认星雨到底画没画。
const { app, BrowserWindow } = require('electron');
const path = require('path');

app.disableHardwareAcceleration();
app.commandLine.appendSwitch('no-sandbox');

app.whenReady().then(async () => {
  const win = new BrowserWindow({
    width: 480, height: 900, show: false,
    webPreferences: { offscreen: true, nodeIntegration: false, contextIsolation: true }
  });
  win.webContents.on('console-message', (_e, level, msg) => {
    console.log('[page]', msg);
  });
  win.webContents.on('render-process-gone', (_e, d) => console.log('[gone]', JSON.stringify(d)));

  const file = path.join(__dirname, '../../shared/player.html');
  await win.loadURL('file://' + file + '?style=rain&theme=crimson&demo=1&chrome=0');
  await new Promise(r => setTimeout(r, 2500));

  const info = await win.webContents.executeJavaScript(`(function(){
    var c = document.getElementById('stage');
    var fs = window.fs;
    var out = {
      canvasCss: [c.getBoundingClientRect().width, c.getBoundingClientRect().height],
      backing: [c.width, c.height],
      dpr: window.devicePixelRatio,
      level: fs ? fs.level : null,
      style: fs ? fs.style : null,
      theme: fs ? fs.themeKey : null
    };
    // 统计画布上非黑像素的分布，判断有没有东西被画出来
    var ctx = c.getContext('2d');
    var w = c.width, h = c.height;
    var rows = 0, total = 0, bottom = 0, top = 0;
    var data = ctx.getImageData(0, 0, w, h).data;
    for (var y = 0; y < h; y += 4) {
      for (var x = 0; x < w; x += 4) {
        var o = (y * w + x) * 4;
        var a = data[o + 3];
        total++;
        if (a > 8) { rows++; if (y > h * 0.6) bottom++; else top++; }
      }
    }
    out.painted = rows; out.sampled = total;
    out.paintedBottom = bottom; out.paintedTop = top;
    return out;
  })()`);

  console.log('RESULT', JSON.stringify(info, null, 2));

  const img = await win.webContents.capturePage();
  require('fs').writeFileSync('/tmp/rain-check.png', img.toPNG());
  console.log('shot saved');
  app.quit();
});
