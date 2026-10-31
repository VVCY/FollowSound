/* 站点交互：两个实时画布（首屏 + 演示区）、配色联动、麦克风、版本号 */
(function () {
  'use strict';

  var STYLE_LABEL = {};
  FollowSound.STYLES.forEach(function (s) { STYLE_LABEL[s.key] = s.title; });

  var heroCanvas = document.getElementById('heroCanvas');
  var demoCanvas = document.getElementById('demoCanvas');
  var shared = { style: 'band', theme: 'ocean' };

  function make(canvas, opts) {
    var fs = FollowSound.create(canvas, {
      style: opts.style,
      theme: opts.theme,
      height: opts.height
    });
    fs.setDemo(true);
    fs.start();
    return fs;
  }

  var hero = make(heroCanvas, { style: shared.style, theme: shared.theme, height: 150 });
  var demo = make(demoCanvas, { style: shared.style, theme: shared.theme, height: 130 });

  function syncTag() {
    var tag = document.getElementById('heroTag');
    tag.textContent = STYLE_LABEL[hero.style] + ' · ' + FollowSound.themeByKey(hero.themeKey).name;
  }

  // ---------- 首屏：特效切换 ----------
  var picker = document.getElementById('heroPicker');
  FollowSound.STYLES.forEach(function (s) {
    var b = document.createElement('button');
    b.textContent = s.title;
    b.dataset.key = s.key;
    if (s.key === shared.style) b.className = 'on';
    b.onclick = function () {
      hero.setStyle(s.key);
      demo.setStyle(s.key);
      [].forEach.call(picker.children, function (c) { c.className = c === b ? 'on' : ''; });
      [].forEach.call(tabs.children, function (c) { c.className = c.dataset.key === s.key ? 'on' : ''; });
      document.getElementById('demoLabel').textContent = s.title;
      syncTag();
    };
    picker.appendChild(b);
  });

  // ---------- 演示区：特效 tab ----------
  var tabs = document.getElementById('demoTabs');
  FollowSound.STYLES.forEach(function (s) {
    var b = document.createElement('button');
    b.textContent = s.title;
    b.dataset.key = s.key;
    if (s.key === shared.style) b.className = 'on';
    b.onclick = function () {
      hero.setStyle(s.key);
      demo.setStyle(s.key);
      [].forEach.call(tabs.children, function (c) { c.className = c === b ? 'on' : ''; });
      [].forEach.call(picker.children, function (c) { c.className = c.dataset.key === s.key ? 'on' : ''; });
      document.getElementById('demoLabel').textContent = s.title;
      syncTag();
    };
    tabs.appendChild(b);
  });

  // ---------- 配色色块 ----------
  var sw = document.getElementById('swatches');
  (window.FS_THEMES || []).forEach(function (t) {
    var b = document.createElement('button');
    b.className = 'swatch' + (t.key === shared.theme ? ' on' : '');
    b.innerHTML =
      '<span class="chips">' +
      '<i style="background:' + t.accent + '"></i>' +
      '<i style="background:' + t.second + '"></i>' +
      '<i style="background:' + t.ghostB + '"></i>' +
      '</span><span class="nm">' + t.name + '</span>';
    b.onclick = function () {
      shared.theme = t.key;
      hero.setTheme(t.key);
      demo.setTheme(t.key);
      [].forEach.call(sw.children, function (c) { c.className = c === b ? 'swatch on' : 'swatch'; });
      syncTag();
    };
    sw.appendChild(b);
  });

  syncTag();

  // ---------- 麦克风 ----------
  var heroMic = document.getElementById('heroMic');
  var heroHint = document.getElementById('heroHint');

  function askMic() {
    hero.attachMic().then(function () {
      return demo.attachMic();
    }).then(function () {
      heroHint.style.display = 'none';
      heroMic.textContent = '已接麦克风';
      try { localStorage.setItem('fs.micAsked', '1'); } catch (e) {}
    }).catch(function () {
      heroMic.textContent = '这里打不开麦克风，去 App 里试';
      hero.setDemo(true);
      demo.setDemo(true);
    });
  }
  heroMic.onclick = askMic;

  // ---------- 画布可见性：滚出视口就停，别白烧 CPU ----------
  if ('IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        var fs = en.target === heroCanvas ? hero : demo;
        if (en.isIntersecting) fs.start(); else fs.stop();
      });
    }, { threshold: 0.05 });
    io.observe(heroCanvas);
    io.observe(demoCanvas);
  }

  // ---------- 版本号：优先读 GitHub，取不到就用页面上写死的 ----------
  fetch('https://api.github.com/repos/VVCY/FollowSound/releases/latest', {
    headers: { Accept: 'application/vnd.github+json' }
  }).then(function (r) { return r.ok ? r.json() : null; })
    .then(function (j) {
      if (!j || !j.tag_name) return;
      var v = String(j.tag_name).replace(/^v/i, '');
      document.getElementById('latestVer').textContent = 'v' + v;
    })
    .catch(function () { /* 离线或用 GitHub 被墙时保持默认值 */ });
})();
