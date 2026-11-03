/* Dropfit 첫 화면 로고 모션
   화살표 선이 그려지고(아이콘과 같은 경로·굵기 2.2→5.6) → 아이콘 칸이 떠오르며 꼬리가 칸에 맞춰 잘리고 속빛이 켜짐
   → 아이콘이 살짝 올라가며 Dropfit 글자가 한 자씩. 화면에 들어오면 한 번 재생하고 완성된 모습으로 멈춘다.
   속도는 첫 시안의 0.8배(K = 1.25), 튕김 없는 곡선만 쓴다. '동작 줄이기'에서는 완성된 모습만 보인다. */
(function () {
  'use strict';
  var host = document.getElementById('dfLogo');
  if (!host) return;

  var NS = 'http://www.w3.org/2000/svg';
  var GP = 'M9.7 33.3C26 32.6 40 34.5 48.2 41.2C53.4 45.5 56.3 49.4 56.3 53A4.8 4.8 0 1 1 51.5 48.2C59.5 48.2 70 59 76 73.2';
  var K = 1.25, END = 3.1 * K;

  /* 아이콘 바깥 모양(스퀘어클, n = 5): 앱 아이콘과 같은 식으로 만든다 */
  function squircle() {
    var pts = [], n = 5, a = 42;
    for (var i = 0; i < 360; i++) {
      var t = i / 360 * 2 * Math.PI, c = Math.cos(t), s = Math.sin(t);
      pts.push((50 + a * Math.sign(c) * Math.pow(Math.abs(c), 2 / n)).toFixed(3) + ' ' + (50 + a * Math.sign(s) * Math.pow(Math.abs(s), 2 / n)).toFixed(3));
    }
    return 'M' + pts.join('L') + 'Z';
  }
  var SQ = squircle();

  function bezier(x1, y1, x2, y2) {
    return function (x) {
      if (x <= 0) return 0; if (x >= 1) return 1;
      var t = x;
      for (var i = 0; i < 12; i++) {
        var cx = 3 * x1 * t * (1 - t) * (1 - t) + 3 * x2 * t * t * (1 - t) + t * t * t - x;
        if (Math.abs(cx) < 1e-6) break;
        var dx = 3 * x1 * (1 - t) * (1 - t) + 6 * (x2 - x1) * t * (1 - t) + 3 * (1 - x2) * t * t;
        t = Math.min(1, Math.max(0, t - cx / (dx || 1e-6)));
      }
      return 3 * y1 * t * (1 - t) * (1 - t) + 3 * y2 * t * t * (1 - t) + t * t * t;
    };
  }
  var DRAW = bezier(0.55, 0, 0.18, 1), GLIDE = bezier(0.22, 1, 0.36, 1), SILK = bezier(0.65, 0, 0.25, 1);
  function seg(T, a, d) { return Math.min(1, Math.max(0, (T - a) / d)); }
  function lerp(a, b, t) { return a + (b - a) * t; }
  function f2(n) { return n.toFixed(2); }

  /* 선 표본 */
  var probe = document.createElementNS(NS, 'svg');
  probe.setAttribute('width', '0'); probe.setAttribute('height', '0'); probe.style.position = 'absolute';
  var pe = document.createElementNS(NS, 'path'); pe.setAttribute('d', GP); probe.appendChild(pe);
  document.body.appendChild(probe);
  var L = pe.getTotalLength(), N = 700, PTS = [];
  for (var i = 0; i <= N; i++) {
    var s = i / N * L, p = pe.getPointAtLength(s), q = pe.getPointAtLength(Math.min(L, s + 0.12)), o = pe.getPointAtLength(Math.max(0, s - 0.12));
    var dx = q.x - o.x, dy = q.y - o.y, m = Math.hypot(dx, dy) || 1;
    PTS.push([p.x, p.y, -dy / m, dx / m]);
  }
  document.body.removeChild(probe);
  function W(t) { t = t * t * (3 - 2 * t); return 2.2 + 3.4 * t; }
  function ribbon(u, k) {
    k = k || 1;
    var n = Math.max(1, Math.round(u * N)), l = [], r = [];
    for (var j = 0; j <= n; j++) {
      var P = PTS[j], w = W(j / N) * k / 2;
      l.push(f2(P[0] + P[2] * w) + ' ' + f2(P[1] + P[3] * w));
      r.push(f2(P[0] - P[2] * w) + ' ' + f2(P[1] - P[3] * w));
    }
    return 'M' + l.concat(r.reverse()).join('L') + 'Z';
  }
  var FULL = ribbon(1), CORE = ribbon(1, 0.42);
  var TIP = [76, 73.2], ARM_A = [79.13, 62.66], ARM_B = [66.14, 68.32];
  function around(sc) { return 'translate(50 50) scale(' + sc.toFixed(4) + ') translate(-50 -50)'; }

  var u = 'dfl';
  host.innerHTML = '<div class="lg-lock"><div class="lg-ic"><svg viewBox="0 0 100 100" aria-hidden="true"><defs>' +
    '<linearGradient id="b' + u + '" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FCFCFA"/><stop offset="1" stop-color="#F3F2EE"/></linearGradient>' +
    '<filter id="s' + u + '" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="1.2" stdDeviation="1.4" flood-color="rgb(18,28,45)" flood-opacity=".12"/></filter>' +
    '<filter id="h' + u + '" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="0.5" stdDeviation="0.35" flood-color="rgb(18,28,45)" flood-opacity=".18"/><feDropShadow dx="0" dy="1.8" stdDeviation="1.6" flood-color="rgb(18,28,45)" flood-opacity=".14"/></filter>' +
    '<linearGradient id="vg' + u + '" gradientUnits="userSpaceOnUse" x1="0" y1="30" x2="0" y2="76"><stop offset="0" stop-color="#dae9f7"/><stop offset="1" stop-color="#bed5ec"/></linearGradient>' +
    '<clipPath id="t' + u + '"><path class="lg-clip" d="' + SQ + '"/></clipPath>' +
    '<mask id="cm' + u + '" maskUnits="userSpaceOnUse" x="-20" y="-20" width="140" height="140"><g fill="#fff"><path d="' + FULL + '"/><circle cx="9.7" cy="33.3" r="1.1"/><circle cx="76" cy="73.2" r="2.8"/></g><path d="M79.13 62.66L76 73.2L66.14 68.32" fill="none" stroke="#fff" stroke-width="5.6" stroke-linecap="round" stroke-linejoin="round"/></mask>' +
    '<filter id="cb' + u + '" filterUnits="userSpaceOnUse" x="-20" y="-20" width="140" height="140"><feGaussianBlur stdDeviation="0.9"/></filter></defs>' +
    '<path class="lg-tile" d="' + SQ + '" fill="url(#b' + u + ')" filter="url(#s' + u + ')"/>' +
    '<g clip-path="url(#t' + u + ')"><g transform="translate(50 50) scale(1.16) translate(-54.5 -51.5)">' +
      '<g filter="url(#h' + u + ')"><g fill="url(#vg' + u + ')"><path class="lg-rb"/><circle cx="9.7" cy="33.3" r="1.1"/><circle class="lg-hd"/></g>' +
      '<path class="lg-chev" fill="none" stroke="url(#vg' + u + ')" stroke-width="5.6" stroke-linecap="round"/></g>' +
      '<g class="lg-core" mask="url(#cm' + u + ')"><g filter="url(#cb' + u + ')" fill="#FCFCFA" fill-opacity=".6"><path d="' + CORE + '"/><circle cx="9.7" cy="33.3" r=".46"/><circle cx="76" cy="73.2" r="1.18"/>' +
      '<path d="M78.51 64.76L76 73.2L68.11 69.3" fill="none" stroke="#FCFCFA" stroke-opacity=".6" stroke-width="2.352" stroke-linecap="round" stroke-linejoin="round"/></g></g>' +
    '</g></g></svg></div>' +
    '<div class="lg-wm" aria-hidden="true">' + 'Dropfit'.split('').map(function (c) { return '<span>' + c + '</span>'; }).join('') + '</div></div>';

  function pick(sel) { return host.querySelector(sel); }
  var E = { ic: pick('.lg-ic'), tile: pick('.lg-tile'), clip: pick('.lg-clip'), rb: pick('.lg-rb'), hd: pick('.lg-hd'), chev: pick('.lg-chev'),
    core: pick('.lg-core'), letters: [].slice.call(host.querySelectorAll('.lg-wm span')) };
  var lastU = -1;

  function render(T) {
    T = T / K;
    /* 1. 선 그리기: 천천히 출발해 길게 감속 */
    var du = DRAW(seg(T, 0.15, 1.0));
    if (du !== lastU) {
      lastU = du;
      if (du <= 0) { E.rb.setAttribute('d', ''); E.hd.setAttribute('r', '0'); }
      else {
        E.rb.setAttribute('d', ribbon(du));
        var P = PTS[Math.max(1, Math.round(du * N))];
        E.hd.setAttribute('cx', f2(P[0])); E.hd.setAttribute('cy', f2(P[1])); E.hd.setAttribute('r', f2(W(du) / 2));
      }
    }
    var a = GLIDE(seg(T, 1.0, 0.34)), b = GLIDE(seg(T, 1.07, 0.34)), d = '';
    if (a > 0) d += 'M' + TIP[0] + ' ' + TIP[1] + 'L' + f2(lerp(TIP[0], ARM_A[0], a)) + ' ' + f2(lerp(TIP[1], ARM_A[1], a));
    if (b > 0) d += 'M' + TIP[0] + ' ' + TIP[1] + 'L' + f2(lerp(TIP[0], ARM_B[0], b)) + ' ' + f2(lerp(TIP[1], ARM_B[1], b));
    E.chev.setAttribute('d', d);
    /* 2. 아이콘이 됨 */
    E.tile.setAttribute('opacity', GLIDE(seg(T, 1.2, 0.55)).toFixed(3));
    E.tile.setAttribute('transform', around(0.94 + 0.06 * GLIDE(seg(T, 1.2, 0.8))));
    E.clip.setAttribute('transform', around(1.7 - 0.7 * SILK(seg(T, 1.2, 0.8))));
    E.core.setAttribute('opacity', SILK(seg(T, 1.5, 0.65)).toFixed(3));
    /* 3. 이름 */
    var icw = E.ic.offsetWidth || 240, lift = (1 - SILK(seg(T, 1.9, 0.8))) * icw * (0.096 + 0.226 * 1.1) / 2;
    var icS = 1.38 - 0.38 * SILK(seg(T, 1.12, 0.9));
    E.ic.style.transform = 'translateY(' + lift.toFixed(2) + 'px) scale(' + icS.toFixed(4) + ')';
    E.letters.forEach(function (el, i) {
      var k = GLIDE(seg(T, 2.0 + 0.065 * i, 0.75));
      el.style.opacity = k.toFixed(3);
      el.style.transform = k < 1 ? 'translateY(' + ((1 - k) * icw * 0.03).toFixed(2) + 'px)' : 'none';
      el.style.filter = k < 1 ? 'blur(' + ((1 - k) * icw * 0.02).toFixed(2) + 'px)' : 'none';
    });
  }

  var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var t0 = null;
  function frame(now) {
    if (t0 === null) t0 = now;
    var T = (now - t0) / 1000;
    render(Math.min(T, END));
    if (T < END) requestAnimationFrame(frame);
  }
  function play() { t0 = null; setTimeout(function () { requestAnimationFrame(frame); }, 350); }

  if (reduce) { render(END); return; }
  render(0);
  if ('IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { io.disconnect(); play(); } });
    }, { threshold: 0.5 });
    io.observe(host);
  } else play();
})();
