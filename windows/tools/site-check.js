// 离屏检查官网：版本号是否读到、下载按钮与镜像兜底链接是否齐全
const { app, BrowserWindow } = require('electron');
const path = require('path');
const fs = require('fs');

const SITE = path.resolve(__dirname, '../../docs/index.html');

app.disableHardwareAcceleration();
app.whenReady().then(async () => {
  const win = new BrowserWindow({
    width: 1280, height: 1500, show: false,
    webPreferences: { offscreen: true, javascript: true }
  });
  await win.loadURL('file://' + SITE);
  await new Promise((r) => setTimeout(r, 3500));

  const out = await win.webContents.executeJavaScript(`(function(){
    var btns = [].map.call(document.querySelectorAll('.dl-card a.btn.primary'), function(a){
      return { text: a.textContent.trim(), href: a.getAttribute('href') };
    });
    var mirrors = [].filter.call(document.querySelectorAll('a'), function(a){
      return (a.getAttribute('href')||'').indexOf('gh-proxy.com') === 0;
    }).map(function(a){ return a.textContent.trim() + ' -> ' + a.getAttribute('href'); });
    return {
      latestVer: (document.getElementById('latestVer')||{}).textContent,
      buttons: btns,
      mirrorCount: mirrors.length,
      mirrors: mirrors,
      tinyNotes: [].map.call(document.querySelectorAll('.dl-card .tiny-note'), function(p){
        return p.textContent.replace(/\\s+/g,' ').trim();
      }),
      title: document.title
    };
  })()`);

  fs.writeFileSync('/tmp/site.png', (await win.webContents.capturePage()).toPNG());
  // 再滚到下载区截一张，确认多出来的镜像说明没把卡片撑歪
  await win.webContents.executeJavaScript(
    "var g=document.querySelector('.dl-grid'); g && g.scrollIntoView({block:'start'});");
  await new Promise((r) => setTimeout(r, 600));
  fs.writeFileSync('/tmp/site-dl.png', (await win.webContents.capturePage()).toPNG());
  console.log('RESULT ' + JSON.stringify(out, null, 2));

  // --live：把两个线上站点和本地 docs/index.html 对一遍，确认发出去的是同一份
  if (process.argv.includes('--live')) {
    const crypto = require('crypto');
    const local = crypto.createHash('sha256').update(fs.readFileSync(SITE)).digest('hex');
    const hosts = ['https://vvcy.github.io/FollowSound/', 'https://followsound.pages.dev/'];
    const live = [];
    for (const url of hosts) {
      try {
        const r = await fetch(url, { redirect: 'follow' });
        const buf = Buffer.from(await r.arrayBuffer());
        live.push({
          url,
          status: r.status,
          bytes: buf.length,
          sameAsLocal: crypto.createHash('sha256').update(buf).digest('hex') === local,
          nosniff: r.headers.get('x-content-type-options'),
          jsCache: null
        });
      } catch (e) {
        live.push({ url, error: e.message });
      }
    }
    console.log('LIVE ' + JSON.stringify(live, null, 2));
  }
  app.quit();
});
