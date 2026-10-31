/* 站点交互：常驻底部的演示坞（只有一个画布）、麦克风开关、特效与配色联动、版本号 */
(function () {
  'use strict';

  var STYLE_LABEL = {};
  FollowSound.STYLES.forEach(function (s) { STYLE_LABEL[s.key] = s.title; });

  var dock = document.getElementById('dock');
  var stage = dock.querySelector('.dock-stage');
  var canvas = document.getElementById('dockCanvas');
  var state = { style: 'rain', theme: 'crimson' };

  var fs = FollowSound.create(canvas, { style: state.style, theme: state.theme, height: 96 });
  fs.setDemo(true);   // 没有麦克风权限时，先用演示动画顶上
  fs.start();

  // ---------- 尺寸：光带最高高度跟着坞走，顺便把坞占了多高告诉页面 ----------
  function fit() {
    var h = stage.clientHeight || 96;
    // 0.62 而不是 1：满音量时也要留一截黑的，光才是"升起"而不是"糊满"
    fs.setHeight(Math.max(40, Math.round(h * 0.62)));
    document.documentElement.style.setProperty('--dock-h', (dock.offsetHeight + 8) + 'px');
  }
  fit();
  if (window.ResizeObserver) new ResizeObserver(fit).observe(stage);
  window.addEventListener('resize', fit);
  window.addEventListener('load', fit);   // 字体到位后行高可能变，重量一次

  // ---------- 折叠：收起后只留光带动效，开关与配色隐藏，正文不再被压住 ----------
  var dockToggle = document.getElementById('dockToggle');
  var COLLAPSE_KEY = 'fs.dockCollapsed.v2';   // 换 key：旧记录里存的"首次访问自动收起"不再生效

  function setCollapsed(on) {
    dock.classList.toggle('is-collapsed', on);
    dockToggle.setAttribute('aria-expanded', on ? 'false' : 'true');
    dockToggle.setAttribute('aria-label', on ? '展开演示控件' : '收起演示控件');
    try { localStorage.setItem(COLLAPSE_KEY, on ? '1' : '0'); } catch (e) { /* 隐私模式忽略 */ }
    fit();   // 坞变矮，正文底部留白要跟着收回，否则底部多出一大片空白
  }

  var savedCollapse = null;
  try { savedCollapse = localStorage.getItem(COLLAPSE_KEY); } catch (e) { /* 同上 */ }
  // 默认展开：控件一进来就该看得见。只有自己手动收起来过，才按记录保持收起
  var startCollapsed = savedCollapse === '1';
  if (startCollapsed) setCollapsed(true);

  dockToggle.onclick = function () {
    setCollapsed(!dock.classList.contains('is-collapsed'));
  };

  // ---------- 开关 / 状态 ----------
  var statusEl = document.getElementById('dockText');
  var switchEl = document.getElementById('micSwitch');
  var heroMic = document.getElementById('heroMic');
  var inFrame = window.self !== window.top;

  function setLive(on, msg, isErr) {
    switchEl.setAttribute('aria-checked', on ? 'true' : 'false');
    dock.classList.toggle('is-live', on);
    dock.classList.toggle('is-err', !!isErr);
    heroMic.classList.toggle('is-on', on);
    heroMic.textContent = on ? '已接入麦克风 · 说话看底部的光' : '授予麦克风权限即可在网页端试用';
    if (msg) statusEl.textContent = msg;
  }

  // 失败原因要分开说：三种情况的处置完全不同，含混一句「没反应」等于没修
  function errText(err) {
    var name = (err && err.name) || '';
    if (name === 'NotAllowedError') {
      return inFrame
        ? '预览框里拿不到麦克风权限 · 在浏览器里打开这页再试'
        : '麦克风权限被拒了 · 允许之后打开开关再试';
    }
    if (name === 'NotFoundError' || name === 'DevicesNotFoundError') return '这台设备上没找到麦克风';
    if (name === 'NotReadableError') return '麦克风被别的程序占着 · 关掉录音/会议软件再试';
    if (name === 'SecurityError') return '这个页面不是安全来源 · 换 http://localhost 或 https 打开';
    return '接不上麦克风（' + (name || '未知原因') + '）· 先看底部的演示动画';
  }

  var asking = false;
  var monitor = null;

  function stopMonitor() { if (monitor) { clearInterval(monitor); monitor = null; } }

  // 接上了不等于有声音：把「音频被挂起」和「设备没信号」也分开报出来，
  // 否则画面不动的时候，用户只能猜是权限、设备还是代码的问题。
  function watchAudio() {
    var info = fs.micInfo();
    if (info.ok && info.state !== 'running') {
      setLive(true, '浏览器把音频挂起了 · 在页面上点一下就好');
      window.addEventListener('pointerdown', function once() {
        window.removeEventListener('pointerdown', once);
        setTimeout(function () {
          var i2 = fs.micInfo();
          if (i2.ok && i2.state === 'running') {
            setLive(true, '正在跟随麦克风 · 关掉开关就回到演示动画');
          }
        }, 300);
      });
      return;
    }
    // 持续看着电平：静音先等，连着十几秒一点信号都没有才报，一有声音立刻恢复。
    // 原来 1.8 秒就判定"没收到声音"，点完开关还没开口就会误报。
    stopMonitor();
    var quiet = 0;
    monitor = setInterval(function () {
      if (!fs.isMic()) { stopMonitor(); return; }
      if (fs.level > 0.03) {
        quiet = 0;
        if (dock.classList.contains('is-err')) {
          setLive(true, '正在跟随麦克风 · 关掉开关就回到演示动画');
        }
      } else if (++quiet >= 15) {
        setLive(true, '接上了但一直没收到声音 · 检查系统输入设备和静音键', true);
      }
    }, 1000);
  }

  function micOn() {
    if (asking || fs.isMic()) return;
    // 有些环境（预览框、非安全来源）根本不给 mediaDevices，这跟"用户拒绝了"是两回事
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      setLive(false, inFrame
        ? '预览框里拿不到麦克风接口 · 在浏览器里打开这页再试'
        : '这个地址拿不到麦克风 · 需要 https 或 localhost', true);
      return;
    }
    asking = true;
    statusEl.textContent = '正在接麦克风…';
    fs.attachMic().then(function () {
      asking = false;
      setLive(true, '正在跟随麦克风 · 关掉开关就回到演示动画');
      watchAudio();
    }).catch(function (err) {
      asking = false;
      fs.detachMic();
      fs.setDemo(true);
      setLive(false, errText(err), true);
    });
  }

  function micOff() {
    stopMonitor();
    fs.detachMic();
    fs.setDemo(true);
    setLive(false, '演示动画 · 打开开关换成你的声音');
  }

  switchEl.onclick = function () {
    if (switchEl.getAttribute('aria-checked') === 'true') micOff(); else micOn();
  };
  heroMic.onclick = micOn;

  // 之前已经授过权的，进页面就直接跟麦克风；没授权就停在演示动画，不主动弹框。
  // 否则刷新一次就要手动再开一遍开关，看起来就像"它不跟我的麦克风动"。
  if (navigator.permissions && navigator.permissions.query) {
    navigator.permissions.query({ name: 'microphone' }).then(function (p) {
      if (p.state === 'granted') micOn();
    }).catch(function () { /* Safari 等不支持查询时，就用手动开关 */ });
  }

  // ---------- 特效 ----------
  var styles = document.getElementById('dockStyles');
  var styleList = document.getElementById('styleList');
  var tag = document.getElementById('dockTag');
  var styleBtns = [];   // 坞里一份胶囊 + 面板里一份，选中态必须一起同步

  function syncTag() {
    tag.textContent = STYLE_LABEL[fs.style] + ' · ' + FollowSound.themeByKey(fs.themeKey).name;
  }

  // 排障用：地址后面加 ?debug 就在标签里显示实时电平，正常访问看不到。
  // 「接上了但没声音」到底是浏览器没收到信号、还是信号太弱，一眼就能分辨。
  if (/[?&]debug/.test(location.search)) {
    setInterval(function () {
      tag.textContent = STYLE_LABEL[fs.style] + ' · ' + FollowSound.themeByKey(fs.themeKey).name +
        ' · 电平 ' + Math.round(fs.level * 100) + (fs.isMic() ? '' : ' · 未接麦克风');
    }, 300);
  }

  function pickStyle(key) {
    fs.setStyle(key);
    styleBtns.forEach(function (b) { b.classList.toggle('on', b.dataset.key === key); });
    syncTag();
    closeSheets();
  }

  function buildStyle(s, host) {
    var b = document.createElement('button');
    b.type = 'button';
    b.textContent = s.title;
    b.dataset.key = s.key;
    if (s.key === fs.style) b.className = 'on';
    b.onclick = function () { pickStyle(s.key); };
    host.appendChild(b);
    styleBtns.push(b);
  }

  FollowSound.STYLES.forEach(function (s) {
    buildStyle(s, styles);
    buildStyle(s, styleList);
  });
  syncTag();

  // ---------- 配色：坞里铺一份，窄屏另有完整一份在面板里 ----------
  var sw = document.getElementById('swatches');
  var sheetGrid = document.getElementById('sheetGrid');
  var themeBtn = document.getElementById('dockThemeBtn');
  var styleBtn = document.getElementById('dockStyleBtn');
  var tbChip = document.getElementById('tbChip');
  var chips = [];   // 两处色块，选中态必须一起同步

  function buildSwatch(t, host) {
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'swatch' + (t.key === fs.themeKey ? ' on' : '');
    b.dataset.key = t.key;
    b.title = t.name;
    b.innerHTML =
      '<span class="chips">' +
      '<i style="background:' + t.accent + '"></i>' +
      '<i style="background:' + t.second + '"></i>' +
      '<i style="background:' + t.ghostB + '"></i>' +
      '</span><span class="nm">' + t.name + '</span>';
    b.onclick = function () { pickTheme(t.key); };
    host.appendChild(b);
    chips.push(b);
  }

  function paintBtn(key) {
    var t = FollowSound.themeByKey(key);
    if (t && tbChip) tbChip.style.background = 'linear-gradient(135deg, ' + t.accent + ', ' + t.second + ')';
  }

  function pickTheme(key) {
    fs.setTheme(key);
    chips.forEach(function (c) { c.classList.toggle('on', c.dataset.key === key); });
    paintBtn(key);
    syncTag();
    closeSheets();
  }

  // 两个面板共用一套开合逻辑：一次只开一个，遮罩 / 关闭按钮 / Esc 都能关
  var sheets = [
    { el: document.getElementById('themeSheet'), btn: themeBtn },
    { el: document.getElementById('styleSheet'), btn: styleBtn }
  ];

  function openSheet(s) {
    closeSheets();
    s.el.hidden = false;
    s.btn.setAttribute('aria-expanded', 'true');
    var act = s.el.querySelector('.on');
    if (act) act.scrollIntoView({ block: 'center' });
  }
  function closeSheets() {
    sheets.forEach(function (s) {
      if (s.el.hidden) return;
      s.el.hidden = true;
      s.btn.setAttribute('aria-expanded', 'false');
    });
  }

  (window.FS_THEMES || []).forEach(function (t) {
    buildSwatch(t, sw);
    buildSwatch(t, sheetGrid);
  });
  paintBtn(fs.themeKey);

  sheets.forEach(function (s) {
    s.btn.onclick = function () { if (s.el.hidden) openSheet(s); else closeSheets(); };
    s.el.querySelector('.sheet-backdrop').onclick = closeSheets;
    s.el.querySelector('.sheet-close').onclick = closeSheets;
  });
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') closeSheets();
  });

  // 坞里这一行放不下 24 个，把当前配色滚进视野，否则一进来只能看到最左边几个
  var active = sw.querySelector('.swatch.on');
  if (active) sw.scrollLeft = active.offsetLeft - sw.clientWidth / 2 + active.offsetWidth / 2;

  // ---------- 版本号：优先读 GitHub，取不到就用页面上写死的 ----------
  fetch('https://api.github.com/repos/VVCY/FollowSound/releases/latest', {
    headers: { Accept: 'application/vnd.github+json' }
  }).then(function (r) { return r.ok ? r.json() : null; })
    .then(function (j) {
      if (!j || !j.tag_name) return;
      var v = String(j.tag_name).replace(/^v/i, '');
      document.getElementById('latestVer').textContent = 'v' + v;
    })
    .catch(function () { /* 离线或访问不了 GitHub 时保持默认值 */ });
})();
