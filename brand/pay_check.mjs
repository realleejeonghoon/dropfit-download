// 결제 흐름 매일 점검 (2026-11-21 정훈 님 "업데이트 진행"): 실제 결제는 하지 않는다.
// 1) dropfit.kr(한국어)·dropfit.kr/en: 판매 중인지, 구입 버튼이 있는지, 가격 칸이 Paddle 금액으로 채워지는지(한국어는 기념가 기간이면 ₩9,900, 지나면 ₩14,900)
// 2) 한국어 구입 버튼 길(DropfitCheckout.open)로 Paddle 결제창이 실제로 열리고 금액이 보이는지. 카드 칸은 건드리지 않고 닫는다
// 3) 결제 알림을 받는 중계(Cloudflare Worker)가 응답하는지(빈 알림이라 처리 없이 거절만 받는다)
// 쓰는 값은 모두 공개 페이지에 있는 것뿐이다(비밀 값 없음). 결과: ✓/✗ 줄, 실패가 있으면 끝 코드 1
import { chromium } from 'playwright-core';

const SITE = process.env.SITE || 'https://dropfit.kr';
const RELAY = 'https://dropfit-paddle-relay.dropfit-worker.workers.dev/paddle';
let fails = 0;
const put = (ok, msg) => { console.log(`${ok ? '✓' : '✗'} ${msg}`); if (!ok) fails++; };

const browser = await chromium.launch({ channel: process.env.CHROME_CHANNEL || 'chrome' });
const ctx = await browser.newContext({ locale: 'ko-KR', viewport: { width: 1280, height: 900 } });

async function pricePage(path, label, expectKRW) {
  const page = await ctx.newPage();
  const errs = [];
  page.on('console', m => { if (m.type() === 'error' && /Dropfit/.test(m.text())) errs.push(m.text().slice(0, 120)); });
  try {
    await page.goto(SITE + path, { waitUntil: 'load', timeout: 60000 });
    const cfg = await page.evaluate(() => {
      const C = window.DROPFIT_PADDLE || {};
      return { stage: C.stage, env: C.environment, ends: C.discountEnds, buy: document.querySelectorAll('[data-buy]').length, open: !!window.DropfitCheckout };
    });
    put(cfg.stage === 'open' && cfg.env === 'production' && cfg.open, `${label}: 판매 중(stage ${cfg.stage}, ${cfg.env})`);
    put(cfg.buy > 0, `${label}: 구입 버튼 ${cfg.buy}개`);
    await page.locator('[data-price="pro"]').first().scrollIntoViewIfNeeded();
    await page.waitForSelector('html[data-price-ready]', { timeout: 45000 });
    const price = (await page.locator('[data-price="pro"]').first().textContent() || '').trim();
    // 가격 칸은 방문자 위치의 통화로 채워진다(점검 서버는 미국이라 $). 금액이 채워졌는지만 본다
    put(/\d/.test(price), `${label}: 가격 칸이 Paddle 금액으로 채워짐 '${price}' (점검 서버 위치 통화)`);
    if (expectKRW) {
      // 한국 방문자 금액은 같은 Paddle 가격 조회에 국가 KR을 넣어 확인한다 (사이트와 같은 가격·할인 ID)
      const r = await page.evaluate(async () => {
        const C = window.DROPFIT_PADDLE, sale = Date.now() < Date.parse(C.discountEnds || '');
        const req = { items: [{ priceId: C.priceId, quantity: 1 }], address: { countryCode: 'KR' } };
        if (sale) req.discountId = C.discountId;
        const x = await window.Paddle.PricePreview(req);
        return { sale, total: x.data.details.lineItems[0].formattedTotals.total };
      });
      const want = r.sale ? '9,900' : '14,900';
      put(r.total.includes(want), `${label}: 한국 방문자 금액 '${r.total}' (기대 ₩${want}${r.sale ? ', 기념가 기간' : ''})`);
    }
  } catch (e) {
    put(false, `${label}: ${String(e.message || e).split('\n')[0].slice(0, 140)}`);
  }
  errs.forEach(e => put(false, `${label}: 콘솔 오류 ${e}`));
  return page;
}

const ko = await pricePage('/', '한국어', true);
const en = await pricePage('/en/', '영어', false);
await en.close();

// 결제창: 구입 버튼과 같은 길(DropfitCheckout.open). 결제창이 뜨고 금액이 보이면 닫는다
try {
  await ko.evaluate(() => window.DropfitCheckout.open({ locale: 'ko', from: 'qa-check' }));
  const frame = await ko.waitForSelector('iframe[name="paddle_frame"], iframe.paddle-frame', { timeout: 45000 });
  const f = await frame.contentFrame();
  await f.waitForLoadState('domcontentloaded', { timeout: 30000 });
  // 결제창 안은 eval을 막으므로(CSP) 글자를 직접 읽어 금액이 보일 때까지 기다린다. 통화는 점검 서버 위치를 따른다
  let text = '';
  for (let i = 0; i < 45 && !/[₩$€£¥]\s?[0-9]|[0-9][0-9,.]*\s?(KRW|USD|EUR)/.test(text); i++) {
    text = await f.locator('body').innerText().catch(() => '');
    if (!/[₩$€£¥]\s?[0-9]/.test(text)) await ko.waitForTimeout(1000);
  }
  const amount = (text.match(/[₩$€£¥]\s?[0-9][0-9,.]*/) || [''])[0];
  put(!!amount, `결제창: Paddle 결제창이 열리고 금액이 보임 (${amount || '금액 없음'})`);
  await ko.evaluate(() => { try { window.Paddle.Checkout.close(); } catch (e) {} });
} catch (e) {
  put(false, `결제창: 열리지 않음 (${String(e.message || e).split('\n')[0].slice(0, 140)})`);
}
await browser.close();

// 결제 알림 중계: 빈 알림('{}')은 앞으로 넘기지 않고 400 'bad request'로 거절한다(처리 없음, 결제중계/src/index.js).
// 이 대답이 오면 중계가 살아 있다. 없는 주소(404)·5xx·연결 실패면 키 발급이 멈출 수 있다
try {
  const r = await fetch(RELAY, { method: 'POST', body: '{}', headers: { 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(20000) });
  const t = (await r.text()).trim();
  put(r.status === 400 && t === 'bad request', `결제 알림 중계가 살아 있음 (빈 알림에 HTTP ${r.status} '${t.slice(0, 30)}')`);
} catch (e) {
  put(false, `결제 알림 중계에 연결하지 못함 (${String(e.message || e).slice(0, 100)})`);
}

console.log(fails ? `결과: ✗ ${fails}건` : '결과: ✓ 모두 통과');
process.exit(fails ? 1 : 0);
