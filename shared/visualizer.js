/* 随响 FollowSound —— 跨端视觉核心
 *
 * 同一份渲染代码，三处复用：
 *   macOS   原生 AppKit 实现（macos/Sources/main.swift，图层更细腻，这条是主实现）
 *   Windows Electron / Android WebView 用这份 Canvas 实现
 *   官网首页的实时演示也用这份
 *
 * 设计约定与原生版一致：
 *   · 光带永远贴底，高度 = 当前音量 × 设定最高高度
 *   · 包络起得快、落得慢（attack 0.55 / release 0.10），才像"光升起"而不是数字跳动
 *   · 配色 24 套，来自 JIZURA (MIT, (c) 2026 hakoniwa / 852wa)
 */
(function (global) {
  'use strict';

  var STYLES = [
    { key: 'band',        title: '光带' },
    { key: 'chroma',      title: '色差光带' },
    { key: 'anamorphic',  title: '横向镜头光斑' },
    { key: 'pixelSort',   title: '像素拉丝' },
    { key: 'equalizer',   title: '均衡器' },
    { key: 'ripple',      title: '波纹' },
    { key: 'rain',        title: '星雨' }
  ];

  var ATTACK = 0.55, RELEASE = 0.10, NOISE_FLOOR = -55, BANDS = 32;

  // ---------- 颜色工具 ----------
  function hex2rgb(hex) {
    var h = String(hex || '#ffffff').replace('#', '');
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    var v = parseInt(h, 16) || 0;
    return { r: (v >> 16) & 255, g: (v >> 8) & 255, b: v & 255 };
  }
  function rgba(hex, a) {
    var c = hex2rgb(hex);
    return 'rgba(' + c.r + ',' + c.g + ',' + c.b + ',' + a + ')';
  }
  function luma(hex) {
    var c = hex2rgb(hex);
    return (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) / 255;
  }
  function mix(h1, h2, t) {
    var a = hex2rgb(h1), b = hex2rgb(h2);
    var r = Math.round(a.r + (b.r - a.r) * t);
    var g = Math.round(a.g + (b.g - a.g) * t);
    var bl = Math.round(a.b + (b.b - a.b) * t);
    return '#' + [r, g, bl].map(function (x) { return ('0' + x.toString(16)).slice(-2); }).join('');
  }

  function themeByKey(key) {
    var list = global.FS_THEMES || [];
    for (var i = 0; i < list.length; i++) if (list[i].key === key) return list[i];
    return list[0] || { key: 'ocean', name: '深海', accent: '#1FD2E6', second: '#3B5BFF', ghostA: '#1FD2E6', ghostB: '#3B5BFF' };
  }

  // ---------- 实例 ----------
  function create(canvas, opts) {
    opts = opts || {};
    var ctx = canvas.getContext('2d');
    var style = opts.style || 'band';
    var theme = themeByKey(opts.theme || 'ocean');
    var bandHeight = opts.height || 180;      // 设定的"最高高度"（CSS px）
    var raf = null, last = 0, time = 0;
    var env = 0, target = 0, phase = 0;
    var bands = new Array(BANDS).fill(0);
    var particles = [], spawnAccum = 0, waterLine = 0;
    var prevLevel = 0, spike = 0;

    var mic = null;      // {ctx, analyser, timeBuf, freqBuf, stream}
    // 默认不演示。以前默认开，麦克风挂了画面上照样有东西在动，
    // 看起来「好像能用了」，实际一个音都没收到。
    var demoMode = !!opts.demo;
    var micError = null;
    var peakDB = -30;

    var dpr = Math.min(global.devicePixelRatio || 1, 2);
    var W = 0, H = 0;

    function resize() {
      var rect = canvas.getBoundingClientRect();
      var w = Math.max(1, Math.round(rect.width));
      var h = Math.max(1, Math.round(rect.height));
      if (w === W && h === H) return;
      W = w; H = h;
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      particles.length = 0;
    }

    // ---------- 素材 ----------
    function stylePalette() {
      var accent = theme.accent;
      var second = theme.second;
      var midC = luma(second) > 0.2 ? mix(accent, second, 0.45) : accent;
      return { accent: accent, mid: midC, second: second };
    }

    // ---------- 各特效 ----------
    function drawBand(h) {
      var p = stylePalette();
      var top = H - h;
      // 顶部外溢的柔光
      var glow = ctx.createLinearGradient(0, top - 46, 0, top + 8);
      glow.addColorStop(0, rgba(p.accent, 0));
      glow.addColorStop(0.85, rgba(p.accent, 0.30 * Math.min(1, h / 40)));
      glow.addColorStop(1, rgba(p.accent, 0.55 * Math.min(1, h / 40)));
      ctx.fillStyle = glow;
      ctx.fillRect(0, top - 46, W, 54);

      // 带身：顶部实色 → 底部透明
      var body = ctx.createLinearGradient(0, top, 0, H);
      body.addColorStop(0, rgba(p.accent, 1));
      body.addColorStop(0.28, rgba(p.mid, 0.55));
      body.addColorStop(1, rgba(p.accent, 0));
      ctx.fillStyle = body;
      ctx.fillRect(0, top, W, h);

      // 亮芯：一条 1.5px 的实边，光带"有厚度"全靠它
      ctx.fillStyle = rgba(p.accent, 0.95);
      ctx.fillRect(0, top, W, 1.5);
    }

    function drawChroma(h, lv) {
      var ga = theme.ghostA, gb = theme.ghostB;
      if (luma(ga) < 0.22) ga = theme.accent;
      if (luma(gb) < 0.22) gb = theme.accent;
      var passes = [
        { c: gb, dx: -12 * lv, hs: 1.06, amp: 0.06, period: 152, ph: 0, alpha: 0.75 },
        { c: ga, dx: 10 * lv, hs: 0.99, amp: 0.05, period: 128, ph: 1.9, alpha: 0.85 },
        { c: theme.accent, dx: 0, hs: 0.94, amp: 0.015, period: 215, ph: 0.7, alpha: 1 }
      ];
      for (var k = 0; k < passes.length; k++) {
        var ps = passes[k];
        var hh = h * ps.hs;
        var top = H - hh;
        var g = ctx.createLinearGradient(0, top, 0, H);
        g.addColorStop(0, rgba(ps.c, ps.alpha));
        g.addColorStop(0.22, rgba(ps.c, ps.alpha * 0.55));
        g.addColorStop(1, rgba(ps.c, 0));
        ctx.save();
        ctx.translate(ps.dx * 0.35, 0);
        ctx.beginPath();
        ctx.moveTo(0, H);
        var step = 6;
        for (var x = 0; x <= W; x += step) {
          var y = top + Math.sin((x / ps.period) * Math.PI * 2 + phase + ps.ph) * (hh * ps.amp);
          if (x === 0) ctx.lineTo(0, y); else ctx.lineTo(x, y);
        }
        ctx.lineTo(W, H);
        ctx.closePath();
        ctx.fillStyle = g;
        ctx.fill();
        ctx.restore();
      }
    }

    function drawAnamorphic(h, lv) {
      var p = stylePalette();
      var top = H - h;
      var cy = Math.max(28, top - 22);
      var cx = W / 2 + Math.sin(time * 0.33) * W * 0.085;
      var grow = 1 + 0.3 * lv;
      var a = Math.min(1, 1.3 * lv);

      function glow(radiusX, radiusY, color, alpha) {
        ctx.save();
        ctx.translate(cx, cy);
        ctx.scale(radiusX * grow, radiusY * grow);
        var g = ctx.createRadialGradient(0, 0, 0, 0, 0, 1);
        g.addColorStop(0, rgba(color, alpha));
        g.addColorStop(0.45, rgba(color, alpha * 0.35));
        g.addColorStop(1, rgba(color, 0));
        ctx.fillStyle = g;
        ctx.beginPath();
        ctx.arc(0, 0, 1, 0, Math.PI * 2);
        ctx.fill();
        ctx.restore();
      }
      ctx.globalAlpha = a;
      glow(W * 0.34, 22, p.accent, 0.72);          // 横向光晕
      glow(W * 0.30, 1.3, '#ffffff', 0.95);         // 细亮芯
      glow(15, 15, '#ffffff', 0.90);                // 热斑
      var f = [0.55, 1.1, 1.7], r = [5.4, 10.8, 3.6];
      for (var i = 0; i < 3; i++) {
        var gx = W / 2 + (W / 2 - cx) * f[i];
        ctx.save();
        ctx.translate(gx, cy);
        ctx.scale(r[i] * grow, r[i] * grow);
        var g2 = ctx.createRadialGradient(0, 0, 0, 0, 0, 1);
        g2.addColorStop(0, rgba(p.accent, 0.22));
        g2.addColorStop(1, rgba(p.accent, 0));
        ctx.fillStyle = g2;
        ctx.beginPath(); ctx.arc(0, 0, 1, 0, Math.PI * 2); ctx.fill();
        ctx.restore();
      }
      ctx.globalAlpha = 1;
      drawBand(h);
    }

    function drawPixelSort(h, lv, dt) {
      var p = stylePalette();
      var top = H - h;
      var rise = lv - prevLevel;
      if (rise > 0.08) spike = Math.min(2.2, spike + rise * 3);
      spike *= Math.pow(0.55, dt * 20);
      var boost = 1 + spike;
      ctx.save();
      ctx.globalAlpha = Math.min(1, 0.18 + 0.95 * lv);
      for (var i = 0; i < 120; i++) {
        var seedX = (i * 137.508) % W;
        var n = 0.5 + 0.5 * Math.sin(seedX * 0.011 + phase) * Math.sin(seedX * 0.031 - phase * 0.6);
        var len = Math.max(1, (0.20 + 1.45 * n) * lv * boost * bandHeight * 0.75);
        var w = 1.5 + ((i * 7) % 9) * 0.5;
        var g = ctx.createLinearGradient(0, top - len, 0, top);
        g.addColorStop(0, rgba(p.accent, 0));
        g.addColorStop(1, rgba(p.accent, 0.62 + 0.28 * n));
        ctx.fillStyle = g;
        ctx.fillRect(seedX, top - len, w, len);
      }
      ctx.restore();
      drawBand(h);
    }

    function drawEqualizer(lv) {
      var p = stylePalette();
      var gap = 3, w = (W - gap * (BANDS - 1)) / BANDS;
      for (var i = 0; i < BANDS; i++) {
        var v = Math.max(bands[i], 0.02);
        var bh = Math.max(2, v * bandHeight);
        var x = i * (w + gap);
        var g = ctx.createLinearGradient(0, H - bh, 0, H);
        g.addColorStop(0, rgba(p.accent, 0.95));
        g.addColorStop(1, rgba(p.mid, 0.35));
        ctx.fillStyle = g;
        ctx.fillRect(x, H - bh, w, bh);
      }
    }

    function drawRipple(h) {
      var p = stylePalette();
      var base = H - h * 0.55;
      for (var k = 0; k < 3; k++) {
        var amp = h * (0.16 - k * 0.035);
        var y0 = base + k * 10;
        ctx.beginPath();
        ctx.moveTo(0, H);
        for (var x = 0; x <= W; x += 8) {
          var y = y0 + Math.sin(x * 0.006 + phase * (1 + k * 0.4) + k) * amp;
          ctx.lineTo(x, y);
        }
        ctx.lineTo(W, H);
        ctx.closePath();
        var g = ctx.createLinearGradient(0, base - amp, 0, H);
        g.addColorStop(0, rgba(p.accent, 0.45 - k * 0.12));
        g.addColorStop(1, rgba(p.accent, 0));
        ctx.fillStyle = g;
        ctx.fill();
        ctx.strokeStyle = rgba(p.accent, 0.55 - k * 0.15);
        ctx.lineWidth = 1.2;
        ctx.stroke();
      }
    }

    function drawRain(h, lv, dt, rise) {
      var p = stylePalette();
      // 水位线 = 这一帧光带的顶边，从底边往上量（macOS 端同名变量叫 top）。
      // 粒子只在「底边 → 水位线」这段里活动，所以整屏也是底部那一截在动，
      // 不会像旧版那样从屏幕顶端一路下满屏 —— 那就是看着不如 mac 顺的原因。
      var top = Math.min(h + 10, H - 4);
      waterLine = H - top;
      var gravity = 760;
      // 恰好够到水位线所需的初速：雨点的劲头始终跟当前音量对得上，
      // 否则音量一低、水面只剩十几 px，粒子按满音量速度冲上去会直接穿过水面。
      var vTop = Math.sqrt(2 * gravity * Math.max(8, top));

      // 鼓点一响，正在上冲的雨点整个被顶高一头 —— 节奏最直观的表现
      if (rise > 0.12 && top > 8) {
        for (var j = 0; j < particles.length; j++) {
          if (!particles[j].bounced && particles[j].v < 0) {
            particles[j].v -= 95 * Math.min(1.5, spike);
          }
        }
      }

      // 生成速率用 lv^0.7 而不是线性：小声说话时也有雨，不然轻声几乎什么都看不见
      spawnAccum += Math.pow(Math.max(0, lv), 0.7) * 300 * dt;
      while (spawnAccum >= 1) {
        spawnAccum -= 1;
        if (particles.length < 220) {
          // 分两拨：慢雨够不到水面，只铺在中下段；快雨一路冲到水面撞出回弹，
          // 那一拨才是节奏的落点。
          var slow = Math.random() < 0.38;
          var k = slow ? (0.36 + 0.26 * Math.random()) : (0.78 + 0.34 * Math.random());
          particles.push({
            x: Math.random() * W,
            y: H + 8,
            v: -(vTop * k + Math.random() * 40),   // 负 = 向上冲
            r: 1.5 + Math.random() * 1.9,
            bounced: false,
            kick: 0.78 + Math.random() * 0.5,
            bright: 0
          });
        }
      }

      ctx.save();
      ctx.strokeStyle = rgba(p.accent, 0.45 + 0.55 * lv);
      ctx.fillStyle = rgba(p.accent, 0.85);
      ctx.lineCap = 'round';
      var newborn = [];                 // 撞水面溅出的碎星，循环结束再并进去
      for (var i = particles.length - 1; i >= 0; i--) {
        var q = particles[i];
        q.v += gravity * dt;
        q.bright = Math.max(0, q.bright - dt * 4.5);
        var ny = q.y + q.v * dt;
        // 撞到水位线 → 回弹一次。弹起初速 = 撞上来的速度 × 弹性，
        // 弹性跟音头走：没有音头只是轻轻退下，鼓点上会被整个弹回去。
        if (!q.bounced && top > 4 && q.v < 0 && ny <= waterLine &&
            particles.length + newborn.length < 320) {
          ny = waterLine;
          q.v = -q.v * (0.42 + 0.42 * Math.min(1, spike)) * q.kick;
          q.bounced = true;
          q.bright = 1;
          // 顶到水面时溅两颗小碎星向下散开：回弹的「啪」就靠这一下被看见。
          // 数量别多、位置要散，否则鼓点那一帧会挤成一团噪点。
          for (var s = 0; s < 2; s++) {
            newborn.push({
              x: q.x + (Math.random() * 28 - 14),
              y: waterLine + Math.random() * 5,
              v: 100 + 140 * Math.random(),
              r: 0.9 + Math.random() * 0.7,
              bounced: true, kick: 1, bright: 0.5
            });
          }
        }
        q.y = ny;
        if (q.y > H + 16) { particles.splice(i, 1); continue; }
        // 尾巴在运动的反方向：冲得越快拉得越长，才像雨丝而不像噪点
        var tail = Math.min(26, Math.abs(q.v) * 0.055);
        var tip = q.y - (q.v >= 0 ? tail : -tail);
        if (tip < waterLine) tip = waterLine;   // 尾巴别越过水面，否则像穿帮
        ctx.lineWidth = Math.max(1, q.r * 0.9);
        ctx.beginPath();
        ctx.moveTo(q.x, tip);
        ctx.lineTo(q.x, q.y);
        ctx.stroke();
        var rr = q.r * (1 + q.bright * 1.1);
        ctx.beginPath();
        ctx.arc(q.x, q.y, rr, 0, Math.PI * 2);
        ctx.fill();
      }
      ctx.restore();
      if (newborn.length) Array.prototype.push.apply(particles, newborn);
      if (particles.length > 400) particles.splice(0, particles.length - 400);

      // 水位线：粒子撞上去回弹的那个平面，跟着音量上下走
      ctx.strokeStyle = rgba(p.accent, 0.30 + 0.38 * lv);
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(0, waterLine);
      ctx.lineTo(W, waterLine);
      ctx.stroke();
    }

    // ---------- 主循环 ----------
    function draw(lv, bd, dt) {
      resize();
      ctx.clearRect(0, 0, W, H);
      var h = Math.max(0.5, lv * bandHeight);
      var rise = lv - prevLevel;
      if (rise > 0.08 && style === 'rain') spike = Math.min(2.2, spike + rise * 3);
      if (style !== 'pixelSort') spike *= Math.pow(0.55, dt * 20);
      prevLevel = lv;

      switch (style) {
        case 'chroma': drawChroma(h, lv); break;
        case 'anamorphic': drawAnamorphic(h, lv); break;
        case 'pixelSort': drawPixelSort(h, lv, dt); break;
        case 'equalizer': drawEqualizer(lv); break;
        case 'ripple': drawRipple(h); break;
        case 'rain': drawRain(h, lv, dt, rise); break;
        default: drawBand(h);
      }
    }

    function readMic() {
      var a = mic.analyser, tb = mic.timeBuf, fb = mic.freqBuf;
      a.getFloatTimeDomainData(tb);
      var sum = 0;
      for (var i = 0; i < tb.length; i++) sum += tb[i] * tb[i];
      var rms = Math.sqrt(sum / tb.length);
      var db = 20 * Math.log10(Math.max(rms, 1e-7));
      if (db > -139) {
        peakDB = Math.max(db, peakDB - 0.08);
        var span = Math.max(peakDB - NOISE_FLOOR, 8);
        target = Math.min(1, Math.max(0, (db - NOISE_FLOOR) / span));
      } else {
        target = 0;
      }

      a.getByteFrequencyData(fb);
      var n = fb.length, binHz = (mic.ctx.sampleRate / 2) / n;
      for (var b = 0; b < BANDS; b++) {
        var f0 = 60 * Math.pow(12000 / 60, b / BANDS);
        var f1 = 60 * Math.pow(12000 / 60, (b + 1) / BANDS);
        var i0 = Math.max(1, Math.floor(f0 / binHz));
        var i1 = Math.max(i0 + 1, Math.floor(f1 / binHz));
        var peak = 0;
        for (var k = i0; k < Math.min(i1, n); k++) peak = Math.max(peak, fb[k]);
        var v = peak / 255;
        bands[b] = v > bands[b] ? v : bands[b] * 0.8 + v * 0.2;
      }
    }

    function readDemo() {
      target = 0.55 + 0.30 * Math.abs(Math.sin(time * 1.6));
      for (var i = 0; i < BANDS; i++) {
        var v = Math.abs(Math.sin(time * 3.1 + i * 0.45)) * 0.85;
        bands[i] = Math.min(1, v > bands[i] ? v : bands[i] * 0.82 + v * 0.18);
      }
    }

    function loop(ts) {
      raf = requestAnimationFrame(loop);
      if (!last) last = ts;
      var dt = Math.min(0.05, (ts - last) / 1000);
      last = ts;
      time += dt;
      phase += dt * 1.1;

      if (mic) readMic(); else if (demoMode) readDemo(); else target = 0;
      var coeff = target > env ? ATTACK : RELEASE;
      env += (target - env) * coeff;
      draw(env, bands, dt);
    }

    var api = {
      STYLES: STYLES,
      get style() { return style; },
      get themeKey() { return theme.key; },
      get level() { return env; },
      setStyle: function (k) { style = k; particles.length = 0; },
      setTheme: function (k) { theme = themeByKey(k); },
      setHeight: function (px) { bandHeight = Math.max(40, Math.min(600, px)); },
      getHeight: function () { return bandHeight; },
      /** 固定电平渲染一帧，用于导出截图/自动化测试 */
      renderOnce: function (lv, bd, dt) { draw(lv || 0.9, bd || new Array(BANDS).fill(0.7), dt || 1 / 60); },
      start: function () {
        resize();
        if (!raf) raf = requestAnimationFrame(loop);
        return api;
      },
      stop: function () { if (raf) cancelAnimationFrame(raf); raf = null; last = 0; },
      /** 接麦克风：返回 Promise，失败时抛出（浏览器/Android 需要用户手势触发） */
      attachMic: function () {
        if (mic) return Promise.resolve(true);
        var md = navigator.mediaDevices;
        if (!md || !md.getUserMedia) {
          micError = 'no getUserMedia';
          return Promise.reject(new Error(micError));
        }
        return md.getUserMedia({
          audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false }
        }).then(function (stream) {
          var AC = global.AudioContext || global.webkitAudioContext;
          var ac = new AC();
          var src  = ac.createMediaStreamSource(stream);
          var an = ac.createAnalyser();
          an.fftSize = 2048;
          an.smoothingTimeConstant = 0.75;
          src.connect(an);
          mic = { ctx: ac, analyser: an, timeBuf: new Float32Array(an.fftSize),
                  freqBuf: new Uint8Array(an.frequencyBinCount), stream: stream };
          micError = null;
          demoMode = false;
          // 移动端 Web Audio 受自动播放策略约束，new AudioContext() 可能停在 suspended。
          // 停在 suspended 时 analyser 读出来全是 0 —— 现象就是「授权了但没反应」。
          resumeCtx(ac);
          // 被别的 App 抢走麦克风（通话/录音）时轨道会 ended，自动接回来一次
          stream.getAudioTracks().forEach(function (t) {
            t.onended = function () {
              if (mic && mic.stream === stream) {
                mic = null; micError = 'track ended';
                setTimeout(function () { if (!mic) api.attachMic().catch(function () {}); }, 400);
              }
            };
          });
          return true;
        }).then(null, function (err) {
          micError = (err && (err.name || err.message)) || 'unknown';
          throw err;
        });
      },
      detachMic: function () {
        if (!mic) return;
        try { mic.stream.getTracks().forEach(function (t) { t.stop(); }); } catch (e) {}
        try { mic.ctx.close(); } catch (e) {}
        mic = null;
        demoMode = false;
      },
      setDemo: function (on) { demoMode = !!on; },
      isMic: function () { return !!mic; },
      /** 诊断用：一眼看出是「没权限」「音频上下文没跑」还是「在收但没有声」 */
      micInfo: function () {
        if (!mic) return { ok: false, error: micError, demo: demoMode };
        var t = mic.stream.getAudioTracks()[0];
        return {
          ok: true, error: null, demo: demoMode,
          state: mic.ctx.state, sampleRate: mic.ctx.sampleRate,
          trackState: t ? t.readyState : null,
          label: t && t.label ? t.label : '',
          level: env
        };
      }
    };
    return api;
  }

  /** 把停在 suspended 的 AudioContext 叫醒；叫不醒就等用户下一次触摸 */
  function resumeCtx(ac) {
    if (ac.state === 'running') return;
    try { ac.resume(); } catch (e) {}
    var unlock = function () {
      if (ac.state !== 'running') { try { ac.resume(); } catch (e) {} }
    };
    ['pointerdown', 'touchstart', 'keydown'].forEach(function (ev) {
      global.addEventListener(ev, unlock, { passive: true });
    });
  }

  global.FollowSound = { create: create, STYLES: STYLES, themeByKey: themeByKey };
})(window);
