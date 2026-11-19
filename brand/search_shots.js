// 고객 여정 A-01: 로그인·기록 없는 새 브라우저로 검색 결과 첫 화면을 찍는다(GitHub 서버, 미국 IP). 자동 확인 창이 뜨면 그대로 찍고 넘어간다(우회하지 않음).
const { chromium } = require('playwright');
const out = process.argv[2];
const Q = [
  ['naver-dropfit', 'https://search.naver.com/search.naver?query=' + encodeURIComponent('드롭핏')],
  ['naver-mac-pdf', 'https://search.naver.com/search.naver?query=' + encodeURIComponent('맥 PDF 합치기')],
  ['google-ko', 'https://www.google.com/search?hl=ko&gl=kr&q=' + encodeURIComponent('드롭핏 맥')],
  ['google-mac-pdf', 'https://www.google.com/search?hl=ko&gl=kr&q=' + encodeURIComponent('맥 PDF 합치기 앱')],
  ['bing-ko', 'https://www.bing.com/search?setmkt=ko-KR&q=' + encodeURIComponent('드롭핏 맥')],
  ['google-en', 'https://www.google.com/search?hl=en&q=' + encodeURIComponent('Dropfit for Mac')],
];
(async () => {
  const b = await chromium.launch();
  for (const [n, u] of Q) {
    const ctx = await b.newContext({ viewport: { width: 1280, height: 900 }, locale: n.endsWith('-en') ? 'en-US' : 'ko-KR', userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15' });
    const p = await ctx.newPage();
    try { await p.goto(u, { timeout: 30000 }); await p.waitForTimeout(3000); await p.screenshot({ path: `${out}/A-01-${n}.png` });
      const txt = (await p.innerText('body')).slice(0, 4000); require('fs').writeFileSync(`${out}/A-01-${n}.txt`, u + '\n' + (await p.title()) + '\n' + (/dropfit|드롭핏/i.test(txt) ? 'Dropfit 언급 있음' : 'Dropfit 언급 없음') + '\n');
      console.log(n, 'ok'); } catch (e) { console.log(n, 'ERR', e.message.slice(0, 100)); }
    await ctx.close();
  }
  await b.close();
})();
