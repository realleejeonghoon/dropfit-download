/* Dropfit 시연 엔진
   앱 소스(OrbViews.swift · OrbModel.swift · OrbController.swift, 0.4)의 치수·색·애니메이션 곡선을 그대로 옮겼다.
   - 링: 두께 54, 첫 줄 중심 반지름 74, 칸 사이 평행 간격 4. 화면 가장자리·모서리에서는 반원·사분원(RadialLayout.make)
   - 펼침: spring(response 0.62, damping 0.92), 칸마다 0.045초 차이, 칸 중심 기준 0.86배·-8°·안쪽 14pt에서 시작
   - 접힘 easeInOut 0.26 · 호버 easeInOut 0.28 · 완료 spring(0.5, 0.85) · 1.8초 뒤 easeInOut 0.4로 대기 상태
   - 여러 장: 오브 테두리가 진행선(easeOut 0.4) + 가운데 퍼센트·장수. 한 장: 스피너
   - 변환 속도: 사진 400장 약 30초(장당 75ms), 놓은 뒤 0.3초 뒤 시작
   - PDF(0.4): 여러 장을 PDF 칸에 올리면 바깥 6pt에 두께 34의 보조 두 칸(반시계 쪽 '합치기', 시계 쪽 '나누기')이
     spring(0.62, 0.92)로 0.94배에서 펼쳐지고, 안내는 'N장 → PDF 1개 / N개'. 칸에 바로 놓으면 합치기
   타임라인은 미리 계산해 두고 매 프레임 시각 T의 값을 읽어 그린다(되감기·정지 화면 모두 같은 결과). */
(function (global) {
  'use strict';

  var C = {
    graphite: '#2c2c2e', pearl: '#fefdfc', veil: '#f6f5f2',
    skySoft: '#cce1f5', skyDeep: '#a3c4e6', skyText: '#3c608a', skyLine: 'rgba(60,96,138,.85)',
    appleTop: '#cce1f5', appleBottom: '#a3c4e6'
  };
  var M = { orb: 60, thick: 54, ring: 74, minArc: 46, fanArc: 116, gap: 4, pad: 72, panel: 112, subGap: 6, subThick: 34 };
  var FORMATS = [['JPG', '범용'], ['PNG', '무손실'], ['HEIC', '고효율'], ['TIFF', '인쇄'], ['GIF', '웹·단순'], ['PDF', '문서']];
  var PDF = 5;
  var PER_FILE = 0.075;
  var SVGNS = 'http://www.w3.org/2000/svg';

  /* ---------- 곡선 ---------- */
  function bezier(x1, y1, x2, y2) {
    return function (x) {
      if (x <= 0) return 0;
      if (x >= 1) return 1;
      var t = x;
      for (var i = 0; i < 10; i++) {
        var cx = 3 * x1 * t * (1 - t) * (1 - t) + 3 * x2 * t * t * (1 - t) + t * t * t - x;
        if (Math.abs(cx) < 1e-6) break;
        var dx = 3 * x1 * (1 - t) * (1 - t) + 6 * (x2 - x1) * t * (1 - t) + 3 * (1 - x2) * t * t;
        t = Math.min(1, Math.max(0, t - cx / (dx || 1e-6)));
      }
      return 3 * y1 * t * (1 - t) * (1 - t) + 3 * y2 * t * t * (1 - t) + t * t * t;
    };
  }
  var EIO = bezier(0.42, 0, 0.58, 1), EO = bezier(0, 0, 0.58, 1), HAND = bezier(0.3, 0.05, 0.25, 1);
  function ease(fn, d) { return function (e) { return e >= d ? 1 : fn(e / d); }; }
  function spring(resp, damp) {
    var w = 2 * Math.PI / resp, z = damp, wd = w * Math.sqrt(1 - z * z);
    return function (e) {
      if (e <= 0) return 0;
      if (e > resp * 6) return 1;
      return 1 - Math.exp(-z * w * e) * (Math.cos(wd * e) + z * w / wd * Math.sin(wd * e));
    };
  }
  var Motion = {
    open: spring(0.62, 0.92), close: ease(EIO, 0.26), hover: ease(EIO, 0.28),
    orb: spring(0.5, 0.88), done: spring(0.5, 0.85), reset: ease(EIO, 0.4), stagger: 0.045
  };

  /* ---------- 시간에 따라 바뀌는 값 ---------- */
  function P(v) { this.s = [[-1e9, v, v, null, 0]]; }
  P.prototype.at = function (t) {
    var s = this.s, i = s.length - 1;
    while (i > 0 && s[i][0] > t) i--;
    var g = s[i];
    if (!g[3]) return g[2];
    var e = t - g[0] - g[4];
    return e <= 0 ? g[1] : g[1] + (g[2] - g[1]) * g[3](e);
  };
  P.prototype.to = function (t, v, curve, delay) {
    this.s.push([t, curve ? this.at(t) : v, v, curve || null, delay || 0]);
    return this;
  };

  /* ---------- 링 배치 (RadialLayout.make) — 각도는 수학 좌표(라디안, 3시 = 0, 반시계 +) ---------- */
  function rowMid(r) { return M.ring + r * (M.thick + M.gap); }
  function makeLayout(n, c, vis) {
    var half = M.thick / 2, margin = M.ring + half + 16;
    var nearL = c.x - vis.x0 < margin, nearR = vis.x1 - c.x < margin;
    var nearB = vis.y1 - c.y < margin, nearT = c.y - vis.y0 < margin;
    var base = Math.PI / 2, span = 2 * Math.PI;
    if (nearL || nearR || nearB || nearT) {
      var dx = 0, dy = 0;
      if (nearL) dx += 1; if (nearR) dx -= 1; if (nearB) dy += 1; if (nearT) dy -= 1;
      if (dx === 0 && dy === 0) dy = 1;
      base = Math.atan2(dy, dx);
      span = (nearL || nearR) && (nearB || nearT) ? Math.PI / 2 : Math.PI;
    }
    function capacity(row) { return Math.max(1, Math.floor(span * rowMid(row) / M.minArc)); }
    var counts = [];
    if (n <= capacity(0)) counts = [n];
    else if (span < 2 * Math.PI) {
      var target = function (row) { return Math.max(1, Math.round(span * rowMid(row) / M.fanArc)); };
      var used = 0, row = 0;
      while (used < n) {
        var k = Math.min(target(row), n - used), rest = n - used - k;
        if (rest > 0 && rest < target(row + 1) / 2 && n - used <= capacity(row)) k = n - used;
        counts.push(k); used += k; row++;
      }
    }
    var segs = [], g = M.gap / 2, fan = span < 2 * Math.PI;
    counts.forEach(function (k, row) {
      var mid = rowMid(row), step = span / k, first = fan ? base + span / 2 - step / 2 : base;
      for (var i = 0; i < k; i++) {
        var cc = first - step * i;
        segs.push({ start: cc - step / 2, end: cc + step / 2, inner: mid - half, outer: mid + half, row: row,
          startInset: fan && i === k - 1 ? 0 : g, endInset: fan && i === 0 ? 0 : g });
      }
    });
    var outer = rowMid(counts.length - 1) + half;
    // 안내 문구: 기본은 메뉴 아래 +22, 화면 밖이면 위로, 좌우는 화면 안으로. 보조 칸이 생길 수 있으면 그 바깥으로
    function hint(o) {
      var gap = o + 22, below = c.y + gap;
      var hy = below + 12 <= vis.y1 ? below : c.y - gap;
      var hx = Math.min(Math.max(c.x, vis.x0 + 80), vis.x1 - 80);
      return { x: hx - c.x, y: hy - c.y };
    }
    return { segs: segs, outer: outer, rows: counts.length, hint: hint(outer), hintSub: hint(outer + M.subGap + M.subThick) };
  }
  function sectorPath(s) {
    function pt(r, a) { return (r * Math.cos(a)).toFixed(2) + ' ' + (-r * Math.sin(a)).toFixed(2); }
    function arc(r) { return [s.start + Math.asin(Math.min(1, s.startInset / r)), s.end - Math.asin(Math.min(1, s.endInset / r))]; }
    var o = arc(s.outer), inn = arc(s.inner), steps = Math.max(8, Math.floor((s.end - s.start) * 48)), d = 'M' + pt(s.outer, o[0]);
    for (var i = 1; i <= steps; i++) d += 'L' + pt(s.outer, o[0] + (o[1] - o[0]) * i / steps);
    for (i = steps; i >= 0; i--) d += 'L' + pt(s.inner, inn[0] + (inn[1] - inn[0]) * i / steps);
    return d + 'Z';
  }
  // 포인터 → 칸 판정 (OrbController.hitTest). p는 오브 중심 기준, y 아래 +
  // armed: 보조 칸을 펼친 칸. 보조 칸 위면 { i, m: 'c' 합치기 | 's' 나누기 }, 칸에서 보조 칸으로 가는 길목은 그 칸
  function hitSub(L, armed, px, py) {
    var d = Math.hypot(px, py), th = Math.atan2(-py, px), s = L.segs[armed];
    var mid = (s.start + s.end) / 2, half = (s.end - s.start) / 2;
    var delta = Math.atan2(Math.sin(th - mid), Math.cos(th - mid));
    if (Math.abs(delta) > half + 0.02) return null;
    var subIn = L.outer + M.subGap;
    if (d >= subIn - M.subGap / 2 && d < subIn + M.subThick + 24) return { i: armed, m: delta >= 0 ? 'c' : 's' };
    if (d >= s.inner - M.gap / 2 && d < subIn) return { i: armed, m: null };
    return null;
  }
  function hitTest(L, disabled, px, py) {
    var d = Math.hypot(px, py);
    if (d <= M.orb / 2 + 4 || d >= L.outer + 28) return -1;
    var th = Math.atan2(-py, px), last = L.rows - 1;
    for (var i = 0; i < L.segs.length; i++) {
      if (disabled === i) continue;
      var s = L.segs[i], lo = s.row === 0 ? 0 : s.inner - M.gap / 2, hi = s.row === last ? Infinity : s.outer + M.gap / 2;
      if (d < lo || d >= hi) continue;
      var mid = (s.start + s.end) / 2, half = (s.end - s.start) / 2;
      var delta = Math.abs(Math.atan2(Math.sin(th - mid), Math.cos(th - mid)));
      if (delta <= half + 0.01) return i;
    }
    return -1;
  }

  /* ---------- DOM 도우미 ---------- */
  function el(tag, cls, parent, html) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html != null) e.innerHTML = html;
    if (parent) parent.appendChild(e);
    return e;
  }
  function sv(tag, attrs, parent) {
    var e = document.createElementNS(SVGNS, tag);
    for (var k in attrs) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  }
  var uid = 0;
  var GLYPH = '<svg class="df-glyph" viewBox="0 0 46 46" aria-hidden="true"><defs><linearGradient id="dfApple{u}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="' + C.appleTop + '"/><stop offset="1" stop-color="' + C.appleBottom + '"/></linearGradient></defs>' +
    '<path fill="url(#dfApple{u})" d="M23.00 15.79C29.69 8.26 42.65 9.10 42.65 22.90C42.65 37.11 37.64 45.90 30.95 45.90C27.60 45.90 25.51 44.64 23.00 44.64C20.49 44.64 18.40 45.90 15.05 45.90C8.36 45.90 3.35 37.11 3.35 22.90C3.35 9.10 16.31 8.26 23.00 15.79Z"/>' +
    '<path fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" d="M16.73 3.66C20.91 -1.36 23.84 2.82 23.00 29.59M20.37 26.95L23.00 29.59L25.63 26.95"/></svg>';
  var FOLDER = '<svg class="df-folder" viewBox="0 0 64 52" aria-hidden="true"><path d="M3 7a3.5 3.5 0 0 1 3.5-3.5h15.2l4.4 4.4h31.4A3.5 3.5 0 0 1 61 11.4v34.1A3.5 3.5 0 0 1 57.5 49h-51A3.5 3.5 0 0 1 3 45.5z" fill="#6aa9de"/><path d="M3 15.5A3.5 3.5 0 0 1 6.5 12h51a3.5 3.5 0 0 1 3.5 3.5v30A3.5 3.5 0 0 1 57.5 49h-51A3.5 3.5 0 0 1 3 45.5z" fill="#8ec4f0"/><path d="M3.5 15.6h57" stroke="rgba(255,255,255,.5)" stroke-width="1"/></svg>';
  var DOC = '<svg class="df-doc" viewBox="0 0 48 60" aria-hidden="true"><path d="M5 2.5h26.5L45.5 16.5v39A2.5 2.5 0 0 1 43 58H5a2.5 2.5 0 0 1-2.5-2.5v-50.5A2.5 2.5 0 0 1 5 2.5z" fill="#fff"/><path d="M31.5 2.5v11.5a2.5 2.5 0 0 0 2.5 2.5h11.5" fill="#e9ebef"/><path d="M9 24h30M9 29.5h30M9 35h22" stroke="#d6d9df" stroke-width="1.6" stroke-linecap="round"/><rect x="9" y="42" width="21" height="10" rx="2" fill="#db665c"/><text x="19.5" y="49.4" text-anchor="middle" font-size="7" font-weight="700" letter-spacing=".4" fill="#fff" font-family="-apple-system, sans-serif">PDF</text></svg>';
  var CHECK = '<svg viewBox="0 0 18 18" aria-hidden="true"><path d="M3.6 9.6l3.5 3.5 7.3-8.2" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  var ARROW = '<svg viewBox="0 0 17 24" aria-hidden="true"><path d="M1.5 1.5v17.2l4.3-4.2 2.9 6.8 3-1.3-2.9-6.7h6z" fill="#000" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></svg>';
  var PHOTOS = ['p0', 'p1', 'p2', 'p3', 'p4', 'p5'];

  /* ---------- 오브 (OrbView) ---------- */
  function Orb(parent) {
    var u = ++uid;
    this.x = new P(0); this.y = new P(0);
    this.scale = new P(1);          // spring(0.5, 0.88)
    this.active = new P(0);         // 그림자·테두리 (대기 0 → 끌어오는 중 1)
    this.glyph = new P(1);
    this.thumb = new P(0); this.thumbVeil = new P(0.12); this.photo = new P('p0');
    this.hl = new P(0); this.hlText = new P('PNG');
    this.badge = new P(0); this.badgeText = new P('');
    this.scan = new P(0);
    this.prog = new P(0); this.trim = new P(0); this.pText = new P('0%'); this.nText = new P('');
    this.spin = new P(0);
    this.done = new P(0); this.doneText = new P('PNG');
    this.burst = new P(0);
    this.crop = new P(0);            // 가운데에 머물면 오브가 '자르기' 칸이 된다
    var e = this.e = el('div', 'df-orb', parent);
    el('div', 'df-orb-body', e);
    this.eScan = sv('svg', { 'class': 'df-scan', viewBox: '0 0 53 53' }, e);
    var r1 = 26.5 - 0.6, L1 = 2 * Math.PI * r1;
    this.eScanC = sv('circle', { cx: 26.5, cy: 26.5, r: r1, fill: 'none', stroke: C.skyLine, 'stroke-opacity': 0.45, 'stroke-width': 1.2, 'stroke-linecap': 'round', 'stroke-dasharray': (L1 * 0.18).toFixed(2) + ' ' + L1.toFixed(2) }, this.eScan);
    this.eProg = sv('svg', { 'class': 'df-prog', viewBox: '0 0 60 60' }, e);
    this.L2 = 2 * Math.PI * 30;
    this.eProgC = sv('circle', { cx: 30, cy: 30, r: 30, fill: 'none', stroke: C.skyLine, 'stroke-width': 1.6, 'stroke-linecap': 'round', transform: 'rotate(-90 30 30)', 'stroke-dasharray': this.L2.toFixed(2) + ' ' + this.L2.toFixed(2) }, this.eProg);
    this.eGlyph = el('div', 'df-orb-glyph', e, GLYPH.replace(/\{u\}/g, u));
    this.eThumb = el('div', 'df-thumb', e, '<i></i>');
    this.eHl = el('span', 'df-hl', e);
    this.eBadge = el('span', 'df-badge', e);
    this.eP = el('div', 'df-plabel', e, '<b></b><small></small>');
    this.eSpin = sv('svg', { 'class': 'df-spin', viewBox: '0 0 28 28' }, e);
    var r3 = 14 - 0.8, L3 = 2 * Math.PI * r3;
    sv('circle', { cx: 14, cy: 14, r: r3, fill: 'none', stroke: C.skyLine, 'stroke-width': 1.6, 'stroke-linecap': 'round', 'stroke-dasharray': (L3 * 0.68).toFixed(2) + ' ' + L3.toFixed(2) }, this.eSpin);
    this.eDone = el('div', 'df-done', e, CHECK + '<b></b>');
    this.eBurst = el('div', 'df-burst', e);
    this.eCrop = el('div', 'df-cropc', e, '<b>자르기</b>');
    this.cache = {};
  }
  Orb.prototype.render = function (T) {
    var s = this.scale.at(T), a = this.active.at(T);
    this.e.style.transform = 'translate(' + (this.x.at(T) - 30).toFixed(2) + 'px,' + (this.y.at(T) - 30).toFixed(2) + 'px) scale(' + s.toFixed(4) + ')';
    this.e.style.setProperty('--a', a.toFixed(3));
    this.eGlyph.style.opacity = this.glyph.at(T);
    this.eThumb.style.opacity = this.thumb.at(T);
    var ph = this.photo.at(T);
    if (this.cache.ph !== ph) { this.eThumb.className = 'df-thumb ' + ph; this.cache.ph = ph; }
    this.eThumb.firstChild.style.opacity = this.thumbVeil.at(T);
    this.eHl.style.opacity = this.hl.at(T);
    this.set(this.eHl, 'hl', this.hlText.at(T));
    this.eBadge.style.opacity = this.badge.at(T);
    this.set(this.eBadge, 'b', this.badgeText.at(T));
    var sc = this.scan.at(T);
    this.eScan.style.opacity = sc;
    if (sc > 0) this.eScan.style.transform = 'translate(-50%,-50%) rotate(' + ((T * 90) % 360).toFixed(1) + 'deg)';
    var pv = this.prog.at(T);
    this.eProg.style.opacity = pv; this.eP.style.opacity = pv;
    if (pv > 0) {
      var tr = Math.max(0.012, Math.min(1, this.trim.at(T)));
      this.eProgC.setAttribute('stroke-dashoffset', (this.L2 * (1 - tr)).toFixed(2));
      this.set(this.eP.firstChild, 'p', this.pText.at(T));
      this.set(this.eP.lastChild, 'n', this.nText.at(T));
    }
    var sp = this.spin.at(T);
    this.eSpin.style.opacity = sp;
    if (sp > 0) this.eSpin.style.transform = 'translate(-50%,-50%) rotate(' + ((T * 320) % 360).toFixed(1) + 'deg)';
    var d = this.done.at(T);
    this.eDone.style.opacity = Math.max(0, Math.min(1, d));
    this.eDone.style.transform = 'translate(-50%,-50%) scale(' + (0.85 + 0.15 * d).toFixed(4) + ')';
    this.set(this.eDone.lastChild, 'd', this.doneText.at(T));
    var b = this.burst.at(T);
    this.eBurst.style.opacity = b > 0 && b < 1 ? (0.8 * (1 - b)).toFixed(3) : 0;
    this.eBurst.style.transform = 'translate(-50%,-50%) scale(' + (1 + 0.4 * b).toFixed(4) + ')';
    this.eCrop.style.opacity = this.crop.at(T);
  };
  Orb.prototype.set = function (node, key, v) { if (this.cache[key] !== v) { node.textContent = v; this.cache[key] = v; } };

  /* ---------- 포맷 링 (SegmentView + IrisOpen + HUDBackdrop) ---------- */
  function Ring(parent, L, orb) {
    var u = ++uid, S = Math.ceil(L.outer + M.pad);
    this.L = L; this.S = S; this.orb = orb;
    var svg = this.e = sv('svg', { 'class': 'df-ring', viewBox: [-S, -S, 2 * S, 2 * S].join(' '), width: 2 * S, height: 2 * S }, parent);
    var defs = sv('defs', {}, svg);
    function lin(id, a, b) {
      var g = sv('linearGradient', { id: id, gradientUnits: 'userSpaceOnUse', x1: 0, y1: -S, x2: 0, y2: S }, defs);
      sv('stop', { offset: 0, 'stop-color': a }, g); sv('stop', { offset: 1, 'stop-color': b }, g);
    }
    lin('dfPearl' + u, C.pearl, C.veil);
    lin('dfSky' + u, C.skySoft, C.skyDeep);
    var rg = sv('radialGradient', { id: 'dfVeil' + u, gradientUnits: 'userSpaceOnUse', cx: 0, cy: 0, r: L.outer + 30, fr: M.orb / 2 }, defs);
    sv('stop', { offset: 0, 'stop-color': '#fff', 'stop-opacity': 0.10 }, rg);
    sv('stop', { offset: 0.5, 'stop-color': '#fff', 'stop-opacity': 0.06 }, rg);
    sv('stop', { offset: 1, 'stop-color': '#fff', 'stop-opacity': 0 }, rg);
    this.veil = new P(0);
    this.eVeil = sv('circle', { cx: 0, cy: 0, r: L.outer + 30, fill: 'url(#dfVeil' + u + ')' }, svg);
    this.petals = L.segs.map(function (s, i) {
      var mid = (s.start + s.end) / 2, r = (s.inner + s.outer) / 2;
      var g = sv('g', { 'class': 'df-petal' }, svg);
      var d = sectorPath(s);
      var base = sv('path', { d: d, fill: 'url(#dfPearl' + u + ')' }, g);
      var on = sv('path', { d: d, fill: 'url(#dfSky' + u + ')', opacity: 0 }, g);
      var rot = Math.PI / 2 - mid;
      if (Math.sin(mid) < -0.05) rot += Math.PI;
      var tf = 'translate(' + (r * Math.cos(mid)).toFixed(2) + ' ' + (-r * Math.sin(mid)).toFixed(2) + ') rotate(' + (rot * 180 / Math.PI).toFixed(2) + ')';
      var t1 = sv('text', { transform: tf, 'class': 'df-seg-t' }, g); t1.textContent = FORMATS[i][0];
      var t2 = sv('text', { transform: tf, 'class': 'df-seg-t on' }, g); t2.textContent = FORMATS[i][0];
      return { s: s, mid: mid, r: r, g: g, base: base, on: on, t1: t1, t2: t2,
        open: new P(0), hover: new P(0), dim: new P(0), off: new P(0) };
    });
    // 보조 두 칸 (SubChoices): PDF 칸 바깥. 반시계 쪽 절반 '합치기', 시계 쪽 절반 '나누기'
    var ps = L.segs[PDF], pm = (ps.start + ps.end) / 2, si = L.outer + M.subGap, so = si + M.subThick, g2 = M.gap / 2;
    var sg = sv('g', { 'class': 'df-sub' }, svg);
    this.sub = { g: sg, op: new P(0), sc: new P(1), halves: [['c', '합치기', pm, ps.end], ['s', '나누기', ps.start, pm]].map(function (h) {
      var seg = { start: h[2], end: h[3], inner: si, outer: so, startInset: g2, endInset: g2 };
      var hg = sv('g', {}, sg), d = sectorPath(seg), mid = (h[2] + h[3]) / 2, r = (si + so) / 2;
      var base = sv('path', { d: d, fill: 'url(#dfPearl' + u + ')', 'fill-opacity': 0.94 }, hg);
      var on = sv('path', { d: d, fill: 'url(#dfSky' + u + ')', 'fill-opacity': 0.97, opacity: 0 }, hg);
      var rot = Math.PI / 2 - mid;
      if (Math.sin(mid) < -0.05) rot += Math.PI;
      var tf = 'translate(' + (r * Math.cos(mid)).toFixed(2) + ' ' + (-r * Math.sin(mid)).toFixed(2) + ') rotate(' + (rot * 180 / Math.PI).toFixed(2) + ')';
      var t1 = sv('text', { transform: tf, 'class': 'df-sub-t' }, hg); t1.textContent = h[1];
      var t2 = sv('text', { transform: tf, 'class': 'df-sub-t on' }, hg); t2.textContent = h[1];
      return { m: h[0], g: hg, on: on, t1: t1, t2: t2, hover: new P(0) };
    }) };
  }
  Ring.prototype.render = function (T) {
    var x = this.orb.x.at(T), y = this.orb.y.at(T), S = this.S, any = false;
    this.e.style.transform = 'translate(' + (x - S).toFixed(2) + 'px,' + (y - S).toFixed(2) + 'px)';
    var v = this.veil.at(T);
    this.eVeil.setAttribute('opacity', v.toFixed(3));
    for (var i = 0; i < this.petals.length; i++) {
      var p = this.petals[i], k = p.open.at(T);
      if (k <= 0.0005) { p.g.style.display = 'none'; continue; }
      any = true;
      p.g.style.display = '';
      // IrisOpen: 칸 중심 기준 0.86배 → 1, (-8° × 74/r) → 0, 안쪽 14pt → 0
      var sc = 0.86 + 0.14 * k, rot = -8 * (M.ring / p.r) * (1 - k);
      var ox = -14 * Math.cos(p.mid) * (1 - k), oy = 14 * Math.sin(p.mid) * (1 - k);
      var cx = p.r * Math.cos(p.mid), cy = -p.r * Math.sin(p.mid);
      p.g.setAttribute('transform', 'translate(' + ox.toFixed(2) + ' ' + oy.toFixed(2) + ') rotate(' + rot.toFixed(3) + ') translate(' + cx.toFixed(2) + ' ' + cy.toFixed(2) + ') scale(' + sc.toFixed(4) + ') translate(' + (-cx).toFixed(2) + ' ' + (-cy).toFixed(2) + ')');
      p.g.setAttribute('opacity', Math.min(1, k).toFixed(3));
      var h = p.hover.at(T), dm = p.dim.at(T), off = p.off.at(T);
      // 칸 바탕: 0.94 → 흐림 0.8 · 비활성 0.42 (0.5부터 테두리 없음)
      var fo = off ? 0.42 : 0.94 - 0.14 * dm;
      p.base.setAttribute('fill-opacity', fo.toFixed(3));
      p.on.setAttribute('opacity', (0.97 * h).toFixed(3));
      p.g.style.setProperty('--h', h.toFixed(3));   // 고른 칸은 그림자가 조금 짙고 넓게
      var to = off ? 0.3 : 0.9 - 0.4 * dm;
      p.t1.setAttribute('fill-opacity', (to * (1 - h)).toFixed(3));
      p.t2.setAttribute('fill-opacity', h.toFixed(3));
    }
    var sb = this.sub, so = sb.op.at(T);
    if (so <= 0.0005) sb.g.style.display = 'none';
    else {
      any = true;
      sb.g.style.display = '';
      sb.g.setAttribute('opacity', Math.min(1, so).toFixed(3));
      sb.g.setAttribute('transform', 'scale(' + sb.sc.at(T).toFixed(4) + ')');
      sb.halves.forEach(function (h) {
        var k = h.hover.at(T);
        h.on.setAttribute('opacity', k.toFixed(3));
        h.t1.setAttribute('fill-opacity', (0.9 * (1 - k)).toFixed(3));
        h.t2.setAttribute('fill-opacity', k.toFixed(3));
        // 그림자: 0.08 · 반경 5 · y 1.5 → 올라가면 0.13 · 7 · 2.5
        h.g.style.filter = 'drop-shadow(0 .5px .6px rgba(18,28,45,.10)) drop-shadow(0 ' + (4 + k).toFixed(2) + 'px ' + (5.5 + 1.5 * k).toFixed(2) + 'px rgba(18,28,45,' + (0.06 + 0.04 * k).toFixed(3) + '))';
      });
    }
    this.e.style.visibility = any || v > 0.001 ? 'visible' : 'hidden';
  };

  /* ---------- 안내 문구 (HintLabel) ---------- */
  function Hint(parent, orb) {
    this.orb = orb;
    this.op = new P(0); this.dx = new P(0); this.dy = new P(123);
    this.base = new P('포맷 위에 놓으세요'); this.hov = new P(''); this.k = new P(0);
    this.e = el('div', 'df-hint', parent, '<span></span><span class="h"></span>');
    this.cache = {};
  }
  Hint.prototype.render = function (T) {
    var o = this.op.at(T);
    this.e.style.opacity = o;
    if (o <= 0) return;
    this.e.style.transform = 'translate(' + (this.orb.x.at(T) + this.dx.at(T)).toFixed(2) + 'px,' + (this.orb.y.at(T) + this.dy.at(T)).toFixed(2) + 'px)';
    var k = this.k.at(T), b = this.base.at(T), h = this.hov.at(T);
    if (this.cache.b !== b) { this.e.firstChild.textContent = b; this.cache.b = b; }
    if (this.cache.h !== h) { this.e.lastChild.textContent = h; this.cache.h = h; }
    this.e.firstChild.style.opacity = 1 - k;
    this.e.lastChild.style.opacity = k;
  };

  /* ---------- 바탕화면 파일 (Finder 아이콘) ---------- */
  function File(parent, f) {
    this.f = f;
    this.op = new P(0); this.sel = new P(0);
    var cls = 'df-file' + (f.folder ? ' folder' : '');
    var vis = f.folder ? FOLDER : f.pdf ? DOC : '<div class="ph ' + f.photo + '"></div>';
    this.e = el('div', cls, parent, '<div class="ic">' + vis + '</div><span>' + f.name + '</span>');
    this.e.style.transform = 'translate(' + f.x + 'px,' + f.y + 'px)';
    this.sel0 = -1;
  }
  File.prototype.render = function (T) {
    var o = this.op.at(T);
    this.e.style.opacity = o;
    if (o <= 0) return;
    var s = this.sel.at(T) > 0.5 ? 1 : 0;
    if (s !== this.sel0) { this.e.classList.toggle('sel', !!s); this.sel0 = s; }
  };
  // 끌려가는 반투명 사본: 커서를 따라 움직인다
  function Ghost(parent, f, cursor) {
    this.f = f; this.cursor = cursor;
    this.op = new P(0); this.dx = 0; this.dy = 0;
    var vis = f.folder ? FOLDER : '<div class="ph ' + f.photo + '"></div>';
    this.e = el('div', 'df-file df-ghost' + (f.folder ? ' folder' : ''), parent, '<div class="ic">' + vis + '</div><span>' + f.name + '</span>');
  }
  Ghost.prototype.render = function (T) {
    var o = this.op.at(T);
    this.e.style.opacity = o;
    if (o <= 0) return;
    this.e.style.transform = 'translate(' + (this.cursor.x.at(T) + this.dx).toFixed(2) + 'px,' + (this.cursor.y.at(T) + this.dy).toFixed(2) + 'px)';
  };
  function Cursor(parent) {
    this.x = new P(0); this.y = new P(0); this.op = new P(0);
    this.count = new P(0); this.countText = new P('');
    this.e = el('div', 'df-cursor', parent, ARROW);
    this.eCount = el('div', 'df-count', parent);
    this.n = '';
  }
  Cursor.prototype.render = function (T) {
    var x = this.x.at(T), y = this.y.at(T), c = this.count.at(T);
    this.e.style.opacity = this.op.at(T);
    this.e.style.transform = 'translate(' + (x - 1.5).toFixed(2) + 'px,' + (y - 1.5).toFixed(2) + 'px)';
    this.eCount.style.opacity = c;
    if (c > 0) {
      var n = this.countText.at(T);
      if (n !== this.n) { this.eCount.textContent = n; this.n = n; }
      this.eCount.style.transform = 'translate(' + (x + 12).toFixed(2) + 'px,' + (y + 14).toFixed(2) + 'px)';
    }
  };
  function Marquee(parent, cursor) {
    this.cursor = cursor; this.op = new P(0); this.x0 = 0; this.y0 = 0;
    this.e = el('div', 'df-marquee', parent);
  }
  Marquee.prototype.render = function (T) {
    var o = this.op.at(T);
    this.e.style.opacity = o;
    if (o <= 0) return;
    var x = this.cursor.x.at(T), y = this.cursor.y.at(T);
    this.e.style.transform = 'translate(' + Math.min(x, this.x0).toFixed(1) + 'px,' + Math.min(y, this.y0).toFixed(1) + 'px)';
    this.e.style.width = Math.abs(x - this.x0).toFixed(1) + 'px';
    this.e.style.height = Math.abs(y - this.y0).toFixed(1) + 'px';
  };


  /* ---------- 자르기 창 (CropWindow · 0.5) ----------
     창 684×512pt: 제목 줄 28, 왼쪽 이미지 칸 440 + 여백 22, 오른쪽 패널 200 (비율 카드 · 크기 카드 · 결과 · 저장 · 취소) */
  var RATIOS = ['자유', '1:1', '4:5', '3:4', '16:9', '크기 지정'];
  function CropWin(parent, name) {
    this.op = new P(0); this.sc = new P(0.97); this.k = new P(0);
    this.on = RATIOS.map(function (r, i) { return new P(i === 0 ? 1 : 0); });
    this.ready = new P(0.45); this.res = new P('4,032 × 3,024 px'); this.w = new P('4032');
    var chips = RATIOS.map(function (r, i) {
      var x = 8 + (i % 2) * 79, y = 8 + Math.floor(i / 2) * 32;
      return '<div class="cw-chip" style="left:' + x + 'px;top:' + y + 'px"><span>' + r + '</span><i><span>' + r + '</span></i></div>';
    }).join('');
    this.e = el('div', 'df-cw', parent,
      '<div class="cw-bar"><i></i><i></i><i></i><b>자르기 · ' + name + '</b></div>' +
      '<div class="cw-img p0"><div class="cw-frame"></div></div>' +
      '<div class="cw-panel">' +
        '<p class="cw-lab" style="top:20px">비율</p><div class="cw-card" style="top:40px;height:106px">' + chips + '</div>' +
        '<p class="cw-lab" style="top:162px">크기</p><div class="cw-card" style="top:182px;height:75px">' +
          '<span class="cw-f" style="left:10px"></span><span class="cw-x">×</span><span class="cw-f" style="left:95px">3024</span>' +
          '<p class="cw-note">px · "크기 지정"을 누르면 입력할 수 있어요</p></div>' +
        '<p class="cw-res"><span>결과</span><b></b></p>' +
        '<div class="cw-save">저장</div><div class="cw-cancel">취소</div>' +
      '</div>');
    this.eFrame = this.e.querySelector('.cw-frame');
    this.eChips = this.e.querySelectorAll('.cw-chip i');
    this.eRes = this.e.querySelector('.cw-res b');
    this.eW = this.e.querySelector('.cw-f');
    this.eSave = this.e.querySelector('.cw-save');
    this.cache = {};
  }
  CropWin.prototype.render = function (T) {
    var o = this.op.at(T);
    this.e.style.opacity = o;
    this.e.style.visibility = o > 0.001 ? 'visible' : 'hidden';
    if (o <= 0.001) return;
    this.e.style.setProperty('--sc', this.sc.at(T).toFixed(4));
    var k = this.k.at(T);   // 자유(사진 전체) → 4:5 (높이 그대로, 가운데)
    this.eFrame.style.left = (88 * k).toFixed(2) + 'px';
    this.eFrame.style.width = (440 - 176 * k).toFixed(2) + 'px';
    for (var i = 0; i < this.eChips.length; i++) this.eChips[i].style.opacity = this.on[i].at(T);
    this.eSave.style.opacity = this.ready.at(T);
    var r = this.res.at(T), w = this.w.at(T);
    if (this.cache.r !== r) { this.eRes.textContent = r; this.cache.r = r; }
    if (this.cache.w !== w) { this.eW.textContent = w; this.cache.w = w; }
  };

  /* ---------- 앱 동작 (OrbController) ---------- */
  function App(root, orb, opts) {
    this.root = root; this.orb = orb; this.opts = opts || {};
    this.rings = []; this.hint = opts && opts.hint ? new Hint(root, orb) : null;
  }
  App.prototype.ring = function (L) {
    var r = new Ring(this.root, L, this.orb);
    this.rings.push(r);
    return r;
  };
  // 파일이 오브 창에 들어옴: dragging + 펼침
  App.prototype.enter = function (t, ring, files, disabled) {
    var o = this.orb, n = files.length;
    this.cur = ring; this.disabled = disabled; this.files = files; this.hovered = -1; this.mode = null; this.armed = -1;
    this.choices = !!files.choices;   // 이미지 여러 장 → PDF 칸에서 '합치기 · 나누기'를 고를 수 있다
    ring.sub.op.to(t, 0); ring.sub.halves.forEach(function (h) { h.hover.to(t, 0); });
    o.glyph.to(t, 0); o.photo.to(t, files.photo || 'p0');
    o.thumb.to(t, 1, ease(EO, 0.2), 0.05); o.thumbVeil.to(t, 0.12);
    o.badgeText.to(t, n > 1 ? String(n) : ''); o.badge.to(t, n > 1 ? 1 : 0);
    o.scan.to(t, 1); o.active.to(t, 1, ease(EIO, 0.3));
    o.scale.to(t, 1.02, Motion.orb);
    var t1 = t + 1 / 60;   // 꽃잎이 접힌 자리에서 한 프레임 그려진 뒤 펼친다
    ring.petals.forEach(function (p, i) {
      p.off.to(t, i === disabled ? 1 : 0);
      p.hover.to(t, 0); p.dim.to(t, 0);
      p.open.to(t1, 1, Motion.open, i * Motion.stagger);
    });
    ring.veil.to(t, 1, ease(EIO, 0.5));
    if (this.hint) {
      var h = this.hint;
      var hp = this.choices ? ring.L.hintSub : ring.L.hint;
      h.dx.to(t, hp.x); h.dy.to(t, hp.y);
      h.base.to(t, '포맷 위에 놓으세요'); h.k.to(t, 0);
      h.op.to(t, 1, ease(EIO, 0.4), 0.25);
    }
  };
  App.prototype.hover = function (t, idx, mode) {
    mode = mode || null;
    if (idx === this.hovered && mode === this.mode) return;
    var o = this.orb, ring = this.cur, sub = ring.sub;
    // 칸이 같고 보조 칸만 바뀜: 보조 칸 강조와 안내 숫자만 바꾼다
    var same = idx === this.hovered;
    this.mode = mode;
    var armed = this.choices && idx === PDF ? PDF : -1;
    if (armed !== this.armed) {
      this.armed = armed;
      if (armed >= 0) { sub.sc.to(t, 0.94); sub.sc.to(t, 1, Motion.open); sub.op.to(t, 1, Motion.open); }
      else sub.op.to(t, 0, Motion.close);
    }
    sub.halves.forEach(function (h) { h.hover.to(t, mode === h.m ? 1 : 0, Motion.hover); });
    if (this.hint && armed >= 0) {
      var n = this.files.length;
      this.hint.hov.to(t, n + '장 → PDF ' + ((mode || 'c') === 'c' ? 1 : n) + '개');
    }
    if (same) return;
    this.hovered = idx;
    ring.petals.forEach(function (p, i) {
      p.hover.to(t, i === idx ? 1 : 0, Motion.hover);
      p.dim.to(t, idx >= 0 && i !== idx ? 1 : 0, Motion.hover);
    });
    o.thumbVeil.to(t, idx >= 0 ? 0.62 : 0.12, Motion.hover);
    if (idx >= 0) o.hlText.to(t, FORMATS[idx][0]);
    o.hl.to(t, idx >= 0 ? 1 : 0, Motion.hover);
    o.scale.to(t, idx >= 0 ? 0.98 : 1.02, Motion.orb);
    if (this.hint) {
      if (idx >= 0 && armed < 0) this.hint.hov.to(t, FORMATS[idx][0] + '로 변환 · ' + FORMATS[idx][1]);
      this.hint.k.to(t, idx >= 0 ? 1 : 0, Motion.hover);
    }
  };
  // 놓는 순간 변환 시작 → 접히는 0.3초 동안 가운데는 비워 둠 → 접힘이 끝나면 실제 진행 지점부터 진행선과 %
  // (이미 끝났으면 진행선 없이 바로 완료) → 1.8초 뒤 대기. 일부러 늦추는 연출 없음 (앱과 같음)
  // 반환: { start, finish[i], done, idle }
  App.prototype.drop = function (t, fmt, total, outs) {
    var o = this.orb, ring = this.cur;
    this.hover(t, -1);
    ring.petals.forEach(function (p) { p.open.to(t, 0, Motion.close); });
    ring.veil.to(t, 0, Motion.close);
    if (this.hint) this.hint.op.to(t, 0, ease(EIO, 0.2));
    // dragging → working (hovered가 함께 바뀌어 0.28초 동안 교차)
    o.thumb.to(t, 0, Motion.hover); o.hl.to(t, 0, Motion.hover); o.badge.to(t, 0, Motion.hover);
    o.scale.to(t, 1, Motion.orb);
    var start = t, shown = t + 0.3, fin = [];
    for (var i = 0; i < total; i++) fin.push(start + PER_FILE * (i + 1));
    var last = fin[fin.length - 1];
    if (total > 1 && last > shown) {
      // 접힘이 끝난 시점까지 끝난 장 수에서 이어 시작
      var k = 0; while (k < total && fin[k] <= shown) k++;
      o.trim.to(shown, k / total); o.pText.to(shown, Math.floor(k / total * 100) + '%'); o.nText.to(shown, k + ' / ' + total);
      o.prog.to(shown, 1, Motion.hover); o.scan.to(shown, 0);
      for (i = k; i < total; i++) {
        o.trim.to(fin[i], (i + 1) / total, ease(EO, 0.4));
        o.pText.to(fin[i], Math.floor((i + 1) / total * 100) + '%');
        o.nText.to(fin[i], (i + 1) + ' / ' + total);
      }
    }
    var done = Math.max(last, shown) + 0.02;
    o.prog.to(done, 0, Motion.done);
    outs = outs || total;   // 합치기는 결과 1개
    o.doneText.to(done, outs > 1 ? fmt + ' ×' + outs : fmt);
    o.done.to(done, 1, Motion.done);
    o.scan.to(done, 1);
    o.burst.to(done, 1, ease(EO, 0.9));
    var idle = done + 1.8;
    o.done.to(idle, 0, Motion.reset); o.glyph.to(idle, 1, Motion.reset);
    o.scan.to(idle, 0); o.active.to(idle, 0, Motion.reset);
    o.burst.to(idle, 0);
    return { start: start, finish: fin, done: done, idle: idle + 0.4 };
  };

  /* ---------- 공통: 무대 ---------- */
  function Stage(host, build) {
    this.host = host; this.build = build;
    this.items = []; this.dur = 1; this.key = ''; this.off = 0; this.T = 0;
  }
  // 지금 보이는 시각을 t로 옮긴다(이후로는 그 자리에서 이어 재생)
  Stage.prototype.seek = function (t) { this.off = t - this.T; this.render(this.T); };
  Stage.prototype.layout = function () {
    var w = this.host.clientWidth, h = this.host.clientHeight;
    var spec = this.build.spec(w, h);
    this.host.style.setProperty('--s', spec.s.toFixed(4));
    if (spec.key !== this.key) {
      this.key = spec.key;
      if (this.root) this.root.remove();
      this.root = el('div', 'df-root', this.host);
      this.root.style.width = spec.W + 'px'; this.root.style.height = spec.H + 'px';
      this.items = []; this.still = null; this.off = 0;
      this.dur = this.build.make(this, spec);
    }
    this.root.style.transform = 'scale(' + spec.s.toFixed(4) + ')';
    // 창 너비가 바뀌면 높이도 같은 비율로 (안 그러면 넓힌 뒤 아래 글자와 겹친다)
    if (spec.fit) this.host.style.height = (spec.H * spec.s).toFixed(1) + 'px';
  };
  Stage.prototype.add = function (x) { this.items.push(x); return x; };
  Stage.prototype.render = function (T) {
    this.T = T;
    var t = (((T + this.off) % this.dur) + this.dur) % this.dur;
    for (var i = 0; i < this.items.length; i++) this.items[i].render(t);
  };

  /* ================= 상단 시연: 실제 바탕화면 ================= */
  var TOP = {
    spec: function (w) {
      var mobile = w < 600, W = mobile ? 540 : 1080, s = w / W;
      return { key: mobile ? 'm' : 'd', W: W, s: s, mobile: mobile };
    },
    make: function (st, spec) {
      var W = spec.W, H = Math.round(st.host.clientHeight / spec.s), mob = spec.mobile;
      st.root.style.height = H + 'px';
      var root = st.root, vis = { x0: 0, y0: 24, x1: W, y1: H };
      var col = function (c) { return W - 58 - c * 100; }, row = function (r) { return 24 + 50 + r * 98; };
      var home = { x: Math.round(W * (mob ? 0.36 : 0.42)), y: Math.round(24 + (H - 24) * 0.5) };

      var layer = el('div', 'df-layer', root);
      var orb = new Orb(root), cursor = new Cursor(root);
      var app = new App(root, orb, { hint: true });
      var fullL = makeLayout(6, home, vis);
      var ringFull = app.ring(fullL);
      root.appendChild(orb.e);   // 오브는 링 위
      root.appendChild(app.hint.e);
      var marquee = new Marquee(root, cursor);
      var cw = new CropWin(root, '바다.heic'), KW = mob ? 0.66 : 0.88;
      var wc = { x: W / 2, y: 24 + (H - 24) / 2 };
      cw.e.style.transform = 'translate(' + (wc.x - 342).toFixed(1) + 'px,' + (wc.y - 256).toFixed(1) + 'px) scale(calc(' + KW + ' * var(--sc, 1)))';
      function inWin(x, y) { return { x: wc.x + (x - 342) * KW, y: wc.y + (y - 256) * KW }; }
      root.appendChild(cursor.e);
      orb.x.to(0, home.x); orb.y.to(0, home.y);

      var files = [], ghosts = [];
      function file(f) { var x = new File(layer, f); files.push(x); return x; }
      function ghost(f) { var g = new Ghost(root, f, cursor); ghosts.push(g); root.insertBefore(g.e, cursor.e); return g; }

      var t = 0;
      function at() { return { x: cursor.x.at(t), y: cursor.y.at(t) }; }
      // 손으로 옮기는 듯한 움직임: x와 y가 조금 다른 곡선을 따라 살짝 휘어진다
      function move(x, y, d, withOrb) {
        var p = at(), dist = Math.hypot(x - p.x, y - p.y);
        d = d || Math.min(1.15, Math.max(0.42, 0.32 + dist / 900));
        cursor.x.to(t, x, ease(EIO, d)); cursor.y.to(t, y, ease(HAND, d));
        if (withOrb) { orb.x.to(t, x - withOrb.x, ease(EIO, d)); orb.y.to(t, y - withOrb.y, ease(HAND, d)); }
        var t0 = t; t += d; return [t0, t];
      }
      function wait(d) { t += d; }
      function scan(t0, t1, fn) { for (var u = t0; u <= t1 + 1e-6; u += 1 / 240) fn(u, cursor.x.at(u), cursor.y.at(u)); }
      function show(list, d) { list.forEach(function (f) { f.op.to(t, 1, ease(EO, d || 0.5)); }); }
      function hide(list, tt) { list.forEach(function (f) { f.sel.to(tt, 0); f.op.to(tt, 0, ease(EIO, 0.5)); }); }

      // 파일(들)을 오브까지 끌어 와 fmt 칸에 놓는다
      function dragToOrb(sel, grab, ring, fmt, disabled, opts) {
        opts = opts || {};
        var g0 = { x: grab.f.x + 2, y: grab.f.y - 6 };
        move(g0.x, g0.y);
        wait(0.14);
        if (!grab.sel.at(t)) { files.forEach(function (f) { f.sel.to(t, 0); }); sel.forEach(function (f) { f.sel.to(t, 1); }); }
        wait(0.12);
        var gs = sel.map(function (f) { var g = ghost(f.f); g.dx = f.f.x - g0.x; g.dy = f.f.y - g0.y; g.op.to(t, 0.62); return g; });
        if (sel.length > 1) { cursor.countText.to(t, String(sel.length)); cursor.count.to(t, 1, ease(EO, 0.15)); }
        var c = { x: orb.x.at(t), y: orb.y.at(t) };
        var span = move(c.x + 5, c.y + 3, opts.d);
        // 커서가 오브 창(112pt 정사각)에 들어오는 순간 dragEntered
        var te = null;
        scan(span[0], span[1], function (u, x, y) { if (te === null && Math.abs(x - c.x) < M.panel / 2 && Math.abs(y - c.y) < M.panel / 2) te = u; });
        var meta = sel.map(function (f) { return f.f; });
        var count = opts.count || sel.length;
        var list = { length: count, photo: meta[0].photo || 'p2', choices: !!opts.sub };
        app.enter(te, ring, list, disabled);
        wait(0.55);
        // 칸으로: 지나는 칸마다 호버가 바뀐다 (hitTest)
        var s = ring.L.segs[fmt], mid = (s.start + s.end) / 2, r = (s.inner + s.outer) / 2 + 2;
        function pick(u, x, y) {
          var h = app.armed >= 0 ? hitSub(ring.L, app.armed, x - c.x, y - c.y) : null;
          if (h) app.hover(u, h.i, h.m); else app.hover(u, hitTest(ring.L, disabled, x - c.x, y - c.y));
        }
        var span2 = move(c.x + r * Math.cos(mid), c.y - r * Math.sin(mid), 0.55);
        scan(span2[0], span2[1], pick);
        if (st.still == null) st.still = t + 0.35;
        if (opts.sub) {
          // 보조 칸이 펼쳐지면 바깥으로: '나누기'(PDF 6개)를 지나 '합치기'(PDF 1개)에 놓는다
          var q = (s.end - s.start) / 4, rs = ring.L.outer + M.subGap + M.subThick / 2;
          wait(0.55);
          var sp3 = move(c.x + rs * Math.cos(mid - q), c.y - rs * Math.sin(mid - q), 0.6);
          scan(sp3[0], sp3[1], pick);
          wait(0.8);
          var sp4 = move(c.x + rs * Math.cos(mid + q), c.y - rs * Math.sin(mid + q), 0.5);
          scan(sp4[0], sp4[1], pick);
        }
        wait(0.6);
        var td = t;
        gs.forEach(function (g) { g.op.to(td, 0, ease(EO, 0.12)); });
        cursor.count.to(td, 0, ease(EO, 0.12));
        return app.drop(td, FORMATS[fmt][0], count, opts.outs);
      }

      /* ① 사진 1장 · 화면 가운데 */
      var a = file({ x: col(0), y: row(0), photo: 'p0', name: '여행.heic' });
      var aOut = file({ x: col(0), y: row(1), photo: 'p0', name: '여행.png' });
      cursor.x.to(0, home.x + 150); cursor.y.to(0, home.y + 120);
      show([a], 0.6); cursor.op.to(0, 1, ease(EO, 0.4));
      wait(0.7);
      var r1 = dragToOrb([a], a, ringFull, 1, 2);
      aOut.op.to(r1.finish[0], 1, ease(EO, 0.35));
      t = r1.done; move(home.x + 170, home.y + 110, 0.9);
      t = r1.idle + 0.3;
      hide([a, aOut], t); wait(0.6);

      /* ② 여러 장 · 끌어서 한꺼번에 선택 */
      var n2 = mob ? 4 : 6, rows2 = n2 / 2, names = ['바다', '사막', '숲', '노을', '골목', '카페'];
      var many = [], manyOut = [];
      for (var i = 0; i < n2; i++) {
        var cc = i % 2, rr = Math.floor(i / 2);
        many.push(file({ x: col(1 - cc), y: row(rr), photo: PHOTOS[i], name: names[i] + '.heic' }));
        manyOut.push(file({ x: col(1 - cc), y: row(rows2 + rr), photo: PHOTOS[i], name: names[i] + '.png' }));
      }
      // 바탕화면을 끌어서 한꺼번에 선택
      function lasso(list, rowsN) {
        var m0 = { x: col(1) - 52, y: row(0) - 52 }, m1 = { x: col(0) + 46, y: row(rowsN - 1) + 44 };
        move(m0.x, m0.y); wait(0.12);
        marquee.x0 = m0.x; marquee.y0 = m0.y; marquee.op.to(t, 1);
        files.forEach(function (f) { f.sel.to(t, 0); });
        var sp = move(m1.x, m1.y, 0.85);
        list.forEach(function (f) {
          var hit = null;
          scan(sp[0], sp[1], function (u, x, y) {
            if (hit === null && Math.min(x, m0.x) < f.f.x + 30 && Math.max(x, m0.x) > f.f.x - 30 && Math.min(y, m0.y) < f.f.y + 26 && Math.max(y, m0.y) > f.f.y - 26) hit = u;
          });
          f.sel.to(hit === null ? t : hit, 1);
        });
        wait(0.15); marquee.op.to(t, 0); wait(0.25);
      }
      show(many); wait(0.5);
      lasso(many, rows2);
      var r2 = dragToOrb(many, many[n2 - 2], ringFull, 1, 2);
      manyOut.forEach(function (f, k) { f.op.to(r2.finish[k], 1, ease(EO, 0.35)); });
      t = r2.done; move(home.x + 170, home.y + 110, 0.9);
      t = r2.idle + 0.3;
      hide(many.concat(manyOut), t); wait(0.6);

      /* ③ 폴더 48장 · JPG로 → 원본 옆 '여행 사진 (JPG)' 새 폴더 */
      var fd = file({ x: col(0), y: row(0), folder: true, name: '여행 사진' });
      var fdOut = file({ x: col(0), y: row(1), folder: true, name: '여행 사진 (JPG)' });
      show([fd]); wait(0.5);
      var r3 = dragToOrb([fd], fd, ringFull, 0, 2, { count: 48 });
      fdOut.op.to(r3.start, 1, ease(EO, 0.35));
      t = r3.start + 0.4; move(home.x + 170, home.y + 110, 0.9);
      t = r3.idle + 0.3;
      hide([fd, fdOut], t); wait(0.6);

      /* ④ 여러 장 → PDF 칸 → 바깥 '합치기' → PDF 1개 ('1일차 외 5장.pdf') */
      var days = [], dayNames = ['1일차', '2일차', '3일차', '4일차', '5일차', '6일차'];
      for (i = 0; i < n2; i++) {
        days.push(file({ x: col(1 - i % 2), y: row(Math.floor(i / 2)), photo: PHOTOS[(i + 2) % 6], name: dayNames[i] + '.heic' }));
      }
      var pdfOut = file({ x: col(0), y: row(rows2), pdf: true, name: '1일차 외 ' + (n2 - 1) + '장.pdf' });
      show(days); wait(0.5);
      lasso(days, rows2);
      var r5 = dragToOrb(days, days[n2 - 2], ringFull, PDF, 2, { sub: true, outs: 1 });
      pdfOut.op.to(r5.finish[n2 - 1], 1, ease(EO, 0.35));
      t = r5.done; move(home.x + 170, home.y + 110, 0.9);
      t = r5.idle + 0.3;
      hide(days.concat([pdfOut]), t); wait(0.6);

      /* ⑤ 자르기 · 가운데에 머물면 Dropfit이 '자르기' 칸이 된다 → 놓으면 자르기 창 → 4:5 → 저장 → '바다 (자름).heic' */
      var cr = file({ x: col(0), y: row(0), photo: 'p0', name: '바다.heic' });
      var crOut = file({ x: col(0), y: row(1), photo: 'p0 crop', name: '바다 (자름).heic' });
      show([cr]); wait(0.5);
      (function () {
        var g0 = { x: cr.f.x + 2, y: cr.f.y - 6 };
        move(g0.x, g0.y); wait(0.14);
        files.forEach(function (f) { f.sel.to(t, 0); }); cr.sel.to(t, 1);
        wait(0.12);
        var g = ghost(cr.f); g.dx = cr.f.x - g0.x; g.dy = cr.f.y - g0.y; g.op.to(t, 0.62);
        var c = { x: orb.x.at(t), y: orb.y.at(t) };
        var span = move(c.x + 5, c.y + 3), te = null;
        scan(span[0], span[1], function (u, x, y) { if (te === null && Math.abs(x - c.x) < M.panel / 2 && Math.abs(y - c.y) < M.panel / 2) te = u; });
        app.enter(te, ringFull, { length: 1, photo: 'p0' }, 2);
        wait(0.5);
        move(c.x + 1, c.y - 1, 0.3);
        wait(0.35);   // 가운데에 0.35초 머물면
        orb.crop.to(t, 1, Motion.hover); orb.scale.to(t, 1.05, Motion.orb);
        g.op.to(t, 0.3, Motion.hover);   // 끌고 온 사진이 '자르기' 칸을 가리지 않게 살짝 흐리게
        app.hint.hov.to(t, '자르기 · 포맷은 그대로'); app.hint.k.to(t, 1, Motion.hover);
        wait(0.8);
        // 놓으면 Dropfit은 접히고 자르기 창이 열린다
        var td = t;
        g.op.to(td, 0, ease(EO, 0.12));
        ringFull.petals.forEach(function (p) { p.open.to(td, 0, Motion.close); });
        ringFull.veil.to(td, 0, Motion.close);
        app.hint.op.to(td, 0, ease(EIO, 0.2));
        orb.crop.to(td, 0, Motion.hover); orb.thumb.to(td, 0, Motion.hover);
        orb.scale.to(td, 1, Motion.orb); orb.scan.to(td, 0); orb.active.to(td, 0, Motion.reset);
        orb.glyph.to(td + 0.3, 1, Motion.reset);
        var to = td + 0.35;
        cw.op.to(to, 1, ease(EO, 0.3)); cw.sc.to(to, 1, ease(EO, 0.35));
        t = to + 0.5;
        // 4:5를 고른다
        var p45 = inWin(544.5, 121);
        move(p45.x + 2, p45.y + 3, 0.8); wait(0.18);
        cw.on[0].to(t, 0, Motion.hover); cw.on[2].to(t, 1, Motion.hover);
        cw.k.to(t, 1, ease(EIO, 0.5));
        cw.res.to(t + 0.25, '2,419 × 3,024 px'); cw.w.to(t + 0.25, '2419');
        cw.ready.to(t, 1, Motion.hover);
        wait(1.1);
        // 저장
        var ps = inWin(584, 446);
        move(ps.x + 2, ps.y + 3, 0.75); wait(0.2);
        cw.op.to(t, 0, ease(EIO, 0.28)); cw.sc.to(t, 0.98, ease(EIO, 0.28));
        crOut.op.to(t + 0.35, 1, ease(EO, 0.35));
        wait(0.3);
        move(home.x + 150, home.y + 120, 0.9);
        wait(1.4);
        hide([cr, crOut], t); wait(0.6);
      })();
      st.marks = [r1, r2, r3, r5];

      files.forEach(st.add, st); ghosts.forEach(st.add, st);
      st.add(ringFull); st.add(orb); st.add(app.hint); st.add(marquee); st.add(cw); st.add(cursor);
      return t;
    }
  };

  /* ================= 마지막 섹션: 기능별 장면이 옆으로 넘어가는 슬라이드 =================
     한 장 → 여러 장 → 폴더째 → PDF 한 권으로 → 자르기. 장면마다 자기 오브를 갖고, 끝나면 띠 전체가 한 칸 옆으로 간다.
     마지막 뒤에는 첫 장면의 시작 화면(빈 오브)과 같은 칸을 하나 더 두어 처음으로 이음매 없이 돌아간다. */
  var CTA = {
    spec: function (w) {
      var mobile = w < 600, W = mobile ? 540 : 1080;
      return { key: mobile ? 'm' : 'd', W: W, H: mobile ? 470 : 480, s: w / W, mobile: mobile, fit: true };
    },
    make: function (st, spec) {
      var W = spec.W, H = spec.H, mob = spec.mobile, root = st.root, K = mob ? 1.0 : 1.6;
      root.style.height = H + 'px';
      st.host.style.height = (H * spec.s).toFixed(1) + 'px';
      var cy = mob ? 200 : 180;
      var X = mob ? 185 : 340, CS = mob ? 0.8 : 1, ARC = mob ? 130 : 170;
      var CAPS = ['한 장', '여러 장 한꺼번에', '폴더째', 'PDF 한 권으로', '자르기'];
      var N = CAPS.length, SLIDE = 1.0;
      var strip = el('div', 'df-strip', root), shift = new P(0);
      strip.style.width = (W * (N + 1)) + 'px'; strip.style.height = H + 'px';
      var cards = el('div', 'df-cards', strip);   // 사본은 오브 뒤로 들어가고 뒤에서 나온다
      // 넘김 단추: ‹ 점 다섯 개 › — 누르면 그 장면으로 옮겨 가 처음부터 이어 재생한다
      var dotsE = el('div', 'df-dots', root), dots = [], dotOn = [];
      dotsE.style.transform = 'translate(' + (W / 2) + 'px,' + (H - (mob ? 28 : 36)) + 'px)';
      var CHEV = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M10 3.5L5.5 8l4.5 4.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
      var prevB = el('button', 'df-nav', dotsE, CHEV); prevB.type = 'button'; prevB.setAttribute('aria-label', '이전 장면');
      for (var d = 0; d < N; d++) {
        var db = el('button', 'df-dot', dotsE, '<i></i>'); db.type = 'button'; db.setAttribute('aria-label', CAPS[d]);
        dots.push(db); dotOn.push(new P(d === 0 ? 1 : 0));
      }
      var nextB = el('button', 'df-nav next', dotsE, CHEV); nextB.type = 'button'; nextB.setAttribute('aria-label', '다음 장면');
      var starts = [0], slideAt = [], shown = 0, glide = null;
      var sc = [], orbs = [];
      function panel(i) {
        var c = { x: W * i + W / 2, y: cy };
        var scaler = el('div', 'df-k', strip);
        scaler.style.transform = 'translate(' + c.x + 'px,' + c.y + 'px) scale(' + K + ')';
        var orb = new Orb(scaler), app = new App(scaler, orb, {});
        var ring = app.ring(makeLayout(6, { x: 0, y: 0 }, { x0: -1e4, y0: -1e4, x1: 1e4, y1: 1e4 }));
        scaler.appendChild(orb.e);
        st.add(ring); st.add(orb); orbs.push(orb);
        var cap = el('div', 'df-cap', strip, CAPS[i % N]);
        cap.style.transform = 'translate(' + c.x + 'px,' + (H - (mob ? 82 : 84)) + 'px) translate(-50%, -50%)';
        return { c: c, scaler: scaler, orb: orb, app: app, ring: ring };
      }
      function card(f, out) {
        var vis = f.folder ? FOLDER : f.pdf ? DOC : '<div class="ph ' + f.photo + '"></div>';
        var e = el('div', 'df-card' + (out ? ' new' : '') + (f.folder ? ' folder' : ''), cards, '<div class="ic">' + vis + '</div><span>' + f.name + '</span>');
        var o = { e: e, op: new P(0), k: new P(0), from: null, to: null, ctrl: null, base: f.pos, s0: CS };
        o.render = function (T) {
          var op = o.op.at(T);
          e.style.opacity = op;
          if (op <= 0) return;
          var k = o.k.at(T), x, y, s;
          if (o.from) {
            var u = 1 - k;
            x = u * u * o.from.x + 2 * u * k * o.ctrl.x + k * k * o.to.x;
            y = u * u * o.from.y + 2 * u * k * o.ctrl.y + k * k * o.to.y;
            s = o.s0 + (o.s1 - o.s0) * k;
          } else { x = o.base.x; y = o.base.y; s = CS; }
          e.style.transform = 'translate(' + x.toFixed(2) + 'px,' + y.toFixed(2) + 'px) translate(-50%,-50%) scale(' + s.toFixed(4) + ')';
        };
        sc.push(o); return o;
      }
      function flight(o, from, to, s0, s1) {
        o.from = from; o.to = to; o.s0 = s0; o.s1 = s1;
        o.ctrl = { x: (from.x + to.x) / 2, y: Math.min(from.y, to.y) - ARC };
      }
      var t = 0, idx = 0;
      // 장면 i의 원본은 칸이 들어오는 동안 이미 놓여 있다(첫 장면만 제자리에서 나타남)
      function scene(pn, items, outs, fmt, disabled, count, folder, sub, crop) {
        var c = pn.c, app = pn.app, hole = { x: c.x, y: c.y - 4 };
        var src = items.map(function (f) { return card(f); });
        src.forEach(function (o) { if (idx === 0) o.op.to(t, 1, ease(EO, 0.5)); else o.op.to(t - SLIDE, 1); });
        var t0 = t + (idx === 0 ? 0.6 : 0.3);
        items.forEach(function (f, i) {
          var o = card(f); flight(o, f.pos, hole, CS, CS * 0.4);
          var dd = t0 + i * 0.14;
          o.op.to(dd, 0.9); o.k.to(dd, 1, ease(EIO, 1.1));
          o.op.to(dd + 1.0, 0, ease(EO, 0.15));
        });
        var te = t0 + 0.95;
        app.enter(te, pn.ring, { length: count, photo: items[0].photo || 'p2', choices: !!sub }, disabled);
        var th = te + 0.8;
        if (st.still == null) st.still = th + 0.35;
        if (crop) {   // 자르기: 가운데에 머물면 오브가 '자르기' 칸이 되고, 놓으면 자르기 창이 열린다
          pn.orb.crop.to(th, 1, Motion.hover); pn.orb.scale.to(th, 1.05, Motion.orb);
        } else app.hover(th, fmt);
        if (sub) { th += 0.7; app.hover(th, fmt, 'c'); }   // PDF: 보조 칸이 펼쳐진 뒤 '합치기'에 놓는다
        var r = crop ? cropWin(pn, th + 0.65) : app.drop(th + 0.65, FORMATS[fmt][0], count, outs.length);
        outs.forEach(function (f, i) {
          var o = card(f, true); flight(o, hole, f.pos, CS * 0.4, CS);
          var dd = (folder ? r.start : r.finish[Math.round((i + 1) / outs.length * count) - 1]) + 0.05 + i * 0.12;
          o.op.to(dd, 1, ease(EO, 0.15)); o.k.to(dd, 1, ease(EIO, 1.0));
        });
        t = r.idle + 0.5;
        return r;
      }
      // 놓으면 Dropfit은 접히고 자르기 창이 열린다 → 4:5 → 저장 (맨 위 시연과 같은 흐름)
      function cropWin(pn, td) {
        var o = pn.orb, ring = pn.ring, KW = mob ? 0.62 : 0.68;
        var wc = { x: pn.c.x, y: mob ? 196 : 186 };
        var cw = new CropWin(strip, '바다.heic'), cur = new Cursor(strip);
        cw.e.style.transform = 'translate(' + (wc.x - 342).toFixed(1) + 'px,' + (wc.y - 256).toFixed(1) + 'px) scale(calc(' + KW + ' * var(--sc, 1)))';
        function inWin(x, y) { return { x: wc.x + (x - 342) * KW, y: wc.y + (y - 256) * KW }; }
        function go(p, tt, d) { cur.x.to(tt, p.x + 2, ease(EIO, d)); cur.y.to(tt, p.y + 3, ease(HAND, d)); return tt + d; }
        ring.petals.forEach(function (p) { p.open.to(td, 0, Motion.close); });
        ring.veil.to(td, 0, Motion.close);
        o.crop.to(td, 0, Motion.hover); o.thumb.to(td, 0, Motion.hover);
        o.scale.to(td, 1, Motion.orb); o.scan.to(td, 0); o.active.to(td, 0, Motion.reset);
        o.glyph.to(td + 0.3, 1, Motion.reset);
        var to = td + 0.35;
        cw.op.to(to, 1, ease(EO, 0.3)); cw.sc.to(to, 1, ease(EO, 0.35));
        var p0 = inWin(250, 330);
        cur.x.to(0, p0.x); cur.y.to(0, p0.y); cur.op.to(to + 0.25, 1, ease(EO, 0.25));
        var tt = go(inWin(544.5, 121), to + 0.6, 0.8) + 0.18;   // 4:5를 고른다
        cw.on[0].to(tt, 0, Motion.hover); cw.on[2].to(tt, 1, Motion.hover);
        cw.k.to(tt, 1, ease(EIO, 0.5));
        cw.res.to(tt + 0.25, '2,419 × 3,024 px'); cw.w.to(tt + 0.25, '2419');
        cw.ready.to(tt, 1, Motion.hover);
        tt = go(inWin(584, 446), tt + 1.1, 0.75) + 0.2;   // 저장
        cw.op.to(tt, 0, ease(EIO, 0.28)); cw.sc.to(tt, 0.98, ease(EIO, 0.28));
        cur.op.to(tt + 0.1, 0, ease(EIO, 0.3));
        st.add(cw); st.add(cur);
        return { start: tt, finish: [tt + 0.15], idle: tt + 1.6 };
      }
      function next() {
        slideAt.push(t);
        idx++;
        shift.to(t, -W * idx, ease(EIO, SLIDE));
        dotOn.forEach(function (p, k) { p.to(t, k === idx % N ? 1 : 0, ease(EIO, 0.5)); });
        t += SLIDE + 0.2;
        starts.push(t - 0.2);
      }
      function row(c, names, side, ext, out) {
        var n = names.length, gap = mob ? 72 : 110;
        return names.map(function (nm, i) {
          var off = (i - (n - 1) / 2) * gap;
          return { name: nm + ext, photo: PHOTOS[i], pos: { x: c.x + side * X + off, y: c.y + 30 } };
        });
      }
      var p0 = panel(0), p1 = panel(1), p2 = panel(2), p3 = panel(3), p4 = panel(4);
      panel(5);   // 처음과 같은 빈 화면

      scene(p0, row(p0.c, ['여행'], -1, '.heic'), row(p0.c, ['여행'], 1, '.png'), 1, 2, 1);
      next();
      var many = mob ? ['바다', '숲'] : ['바다', '사막', '숲'];
      scene(p1, row(p1.c, many, -1, '.heic'), row(p1.c, many, 1, '.png'), 1, 2, many.length);
      next();
      scene(p2, [{ name: '여행', folder: true, pos: { x: p2.c.x - X, y: p2.c.y + 30 } }],
        [{ name: '여행 (PNG)', folder: true, pos: { x: p2.c.x + X, y: p2.c.y + 30 } }], 1, 2, 48, true);
      next();
      scene(p3, row(p3.c, many, -1, '.heic'), [{ name: '바다 외 ' + (many.length - 1) + '장.pdf', pdf: true, pos: { x: p3.c.x + X, y: p3.c.y + 30 } }], PDF, 2, many.length, false, true);
      next();
      scene(p4, [{ name: '바다.heic', photo: 'p0', pos: { x: p4.c.x - X, y: p4.c.y + 30 } }],
        [{ name: '바다 (자름).heic', photo: 'p0 crop', pos: { x: p4.c.x + X, y: p4.c.y + 30 } }], 1, 2, 1, false, false, true);
      next();


      sc.forEach(st.add, st);
      st.add({ render: function (T) {
        var x = shift.at(T);
        if (glide) {   // 직접 넘긴 직후: 보이던 자리에서 고른 장면까지 부드럽게
          var e = (performance.now() - glide.t0) / 1000;
          if (e >= 0.7) glide = null; else x = glide.x0 + (x - glide.x0) * EIO(e / 0.7);
        }
        shown = x;
        strip.style.transform = 'translateX(' + x.toFixed(2) + 'px)';
        dots.forEach(function (e, k) { e.style.setProperty('--on', dotOn[k].at(T).toFixed(3)); e.setAttribute('aria-current', dotOn[k].at(T) > 0.5 ? 'true' : 'false'); });
      } });
      function current() { return ((Math.round(-shown / W) % N) + N) % N; }
      var still = global.matchMedia && global.matchMedia('(prefers-reduced-motion: reduce)').matches;
      function go(j) {
        var from = current();
        j = ((j % N) + N) % N;
        if (j === from && Math.abs(shown + W * from) < 1) { st.seek(starts[j]); return; }
        // 마지막 → 처음: 원래 흐름 그대로 끝 칸(처음과 같은 화면)으로 넘어간다
        if (j === 0 && from === N - 1 && !still) { glide = null; st.seek(slideAt[N - 1]); return; }
        glide = still ? null : { x0: shown, t0: performance.now() };
        // 처음 → 마지막: 처음과 같은 끝 칸에서 한 칸만 뒤로
        if (glide && j === N - 1 && from === 0 && shown > -W * (N - 0.5)) glide.x0 = shown - W * N;
        st.seek(starts[j]);
      }
      prevB.addEventListener('click', function () { go(current() - 1); });
      nextB.addEventListener('click', function () { go(current() + 1); });
      dots.forEach(function (b, k) { b.addEventListener('click', function () { go(k); }); });
      // 끌어서 넘기기(휴대폰 스와이프 · 트랙패드 드래그)
      var sx = null, sy = 0;
      st.host.addEventListener('pointerdown', function (e) { if (e.target.closest('button')) return; sx = e.clientX; sy = e.clientY; });
      st.host.addEventListener('pointerup', function (e) {
        if (sx == null) return;
        var dx = e.clientX - sx, dy = e.clientY - sy; sx = null;
        if (Math.abs(dx) > 40 && Math.abs(dx) > Math.abs(dy) * 1.2) go(current() + (dx < 0 ? 1 : -1));
      });
      st.host.addEventListener('pointercancel', function () { sx = null; });
      st.host.addEventListener('keydown', function (e) {
        if (e.key === 'ArrowRight') { go(current() + 1); e.preventDefault(); }
        if (e.key === 'ArrowLeft') { go(current() - 1); e.preventDefault(); }
      });
      return t;
    }
  };

  /* ---------- 실행 ---------- */
  function run(host, build) {
    if (!host) return null;
    var st = new Stage(host, build);
    st.layout();
    return st;
  }
  function start() {
    var stages = [run(document.getElementById('dfTop'), TOP), run(document.getElementById('dfCta'), CTA)].filter(Boolean);
    if (!stages.length) return;
    var reduce = global.matchMedia && global.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var visible = new Map(), t0 = performance.now();
    function frame(now) {
      var T = Math.max(0, now - t0) / 1000;
      stages.forEach(function (s) { if (visible.get(s) !== false) s.render(T); });
      raf = requestAnimationFrame(frame);
    }
    var raf;
    global.addEventListener('resize', function () { stages.forEach(function (s) { s.layout(); if (reduce) s.render(s.still); }); });
    global.__dropfitSeek = function (T) { stages.forEach(function (s) { s.render(T); }); };
    global.__dropfitStages = stages;
    if (reduce) { stages.forEach(function (s) { s.render(s.still); }); return; }
    if ('IntersectionObserver' in global) {
      var io = new IntersectionObserver(function (es) { es.forEach(function (e) { stages.forEach(function (s) { if (s.host === e.target) visible.set(s, e.isIntersecting); }); }); });
      stages.forEach(function (s) { io.observe(s.host); });
    }
    raf = requestAnimationFrame(frame);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})(window);
