// 检查控制条：自定义下拉能否展开、菜单样式、麦克风按钮文案。
const { app, BrowserWindow } = require('electron');
const path = require('path');
const fs = require('fs');

app.disableHardwareAcceleration();
app.commandLine.appendSwitch('no-sandbox');

const wait = ms => new Promise(r => setTimeout(r, ms));

app.whenReady().then(async () => {
  const win = new BrowserWindow({
    width: 480, height: 900, show: false,
    webPreferences: { offscreen: true, nodeIntegration: false, contextIsolation: true }
  });
  win.webContents.on('console-message', (_e, l, m) => console.log('[page]', m));

  const file = path.join(__dirname, '../../shared/player.html');
  await win.loadURL('file://' + file + '?style=rain&theme=crimson&demo=1&chrome=1&bg=0B0D12');
  await wait(1500);

  const before = await win.webContents.executeJavaScript(`(function(){
    var t = document.querySelector('#stylePick .fs-select-trigger');
    var lab = document.querySelector('#stylePick .fs-select-label');
    var th = document.querySelector('#themePick .fs-select-label');
    var mic = document.getElementById('micBtn');
    return { styleLabel: lab && lab.textContent, themeLabel: th && th.textContent,
             micText: mic && mic.textContent, hasTrigger: !!t };
  })()`);
  console.log('BEFORE', JSON.stringify(before));

  let img = await win.webContents.capturePage();
  fs.writeFileSync('/tmp/ui-closed.png', img.toPNG());

  // 展开特效下拉
  await win.webContents.executeJavaScript(`document.querySelector('#stylePick .fs-select-trigger').click(); true`);
  await wait(500);

  const opened = await win.webContents.executeJavaScript(`(function(){
    var host = document.getElementById('stylePick');
    var menu = host.querySelector('.fs-select-menu');
    var cs = getComputedStyle(menu);
    var items = menu.querySelectorAll('button');
    var on = menu.querySelector('button.on');
    return { open: host.classList.contains('open'), display: cs.display,
             count: items.length, current: on && on.textContent,
             first: items[0] && items[0].textContent };
  })()`);
  console.log('OPENED', JSON.stringify(opened));

  img = await win.webContents.capturePage();
  fs.writeFileSync('/tmp/ui-open.png', img.toPNG());

  app.quit();
});
