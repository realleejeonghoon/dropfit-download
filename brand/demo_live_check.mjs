// 일회 확인: dropfit.kr 한·영 시연에 1.0 설정 창 장면이 실제로 나오는지 (사이트 #60 공개 확인, 11/22)
import { chromium } from 'playwright-core';
const b = await chromium.launch({ channel: 'chrome' });
let fails = 0;
for (const [path, name, want] of [['/', '한국어', '상품 사진'], ['/en/', '영어', 'Products']]) {
  const p = await b.newPage({ viewport: { width: 1280, height: 900 } });
  await p.addInitScript(() => { window.requestAnimationFrame = () => 0; });
  await p.goto('https://dropfit.kr' + path + '?from=qa-check', { waitUntil: 'load', timeout: 60000 });
  const r = await p.evaluate(want => {
    const s = document.querySelector('#dfCta .df-strip'); if (!s || !window.__dropfitSeek) return { ok: false, why: '시연 없음' };
    const W = parseFloat(s.style.width) / 7; let t5 = -1;
    for (let T = 0; T < 120; T += 0.05) { window.__dropfitSeek(T); const x = -parseFloat(/translateX\((-?[\d.]+)px/.exec(s.style.transform)[1]); if (x >= 5 * W - 0.5) { t5 = T; break; } }
    window.__dropfitSeek(t5 + 9);
    const w = document.querySelector('#dfCta .df-sw1');
    if (!w) return { ok: false, why: '설정 창 없음' };
    const vis = getComputedStyle(w).visibility, title = w.querySelector('.sw1-row b')?.textContent, sum = w.querySelector('.sw1-row span')?.textContent;
    return { ok: vis === 'visible' && title === want, why: `창 ${vis}, 첫 칸 '${title}' · '${sum}'` };
  }, want);
  console.log(`${r.ok ? '✓' : '✗'} ${name}: ${r.why}`); if (!r.ok) fails++;
}
await b.close(); process.exit(fails ? 1 : 0);
