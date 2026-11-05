#!/usr/bin/env python3
"""Dropfit 랜딩 통일 점검.

  python3 brand/check.py            저장소 점검 (PR마다 자동)
  python3 brand/check.py --live     공개 사이트가 이 저장소와 같은지 (매일 09:00 KST 자동)
  python3 brand/check.py --confirm  지금 상태를 확정값으로 기록 (정훈 확정 뒤에만)
  --no-render                       휴대폰 폭 화면 점검(playwright) 건너뛰기

기준: brand/master/ 의 11/3 확정 아이콘(하늘 선), brand/palette.json, brand/ledger.json.
하나라도 다르면 ✗ 와 함께 끝 코드 1.
"""
import hashlib, io, json, os, plistlib, re, sys, urllib.request, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
B = os.path.join(ROOT, 'brand')
LIVE = 'https://realleejeonghoon.github.io/dropfit-download/'
TOL = {'rounded': 3.0, 'full': 3.0, 'tab': 4.0}   # 255 기준 평균 차이 허용치

results = []
def ok(area, msg): results.append(('✓', area, msg))
def bad(area, msg): results.append(('✗', area, msg))

def load(name):
    with open(os.path.join(B, name), encoding='utf-8') as f: return json.load(f)
def sha(path):
    with open(os.path.join(ROOT, path), 'rb') as f: return hashlib.sha256(f.read()).hexdigest()
def read(path):
    with open(os.path.join(ROOT, path), encoding='utf-8') as f: return f.read()

TP = load('touchpoints.json')

# ---------- 아이콘: 같은 그림인지 ----------
def masters():
    from PIL import Image
    full = Image.open(os.path.join(B, 'master/full-light-1024.png')).convert('RGBA')
    full.alpha_composite(Image.open(os.path.join(B, 'master/full-line-1024.png')).convert('RGBA'))
    rounded = Image.open(os.path.join(B, 'master/rounded-1024.png')).convert('RGBA')
    return full, rounded

def squircle(n):
    import numpy as np
    from PIL import Image
    N = n * 8; y, x = np.mgrid[0:N, 0:N]; c = N / 2; r = N / 2 - 1
    m = ((np.abs((x - c) / r) ** 5 + np.abs((y - c) / r) ** 5) <= 1).astype('uint8') * 255
    return Image.fromarray(m).resize((n, n), Image.LANCZOS)

def flat(im, bg):
    import numpy as np
    from PIL import Image
    b = Image.new('RGBA', im.size, bg + (255,)); b.alpha_composite(im)
    return np.asarray(b.convert('RGB')).astype(float)

def icon_diff(im, ref, inner=1.0):
    """밝은 바탕·어두운 바탕 두 번 비교해 큰 값. inner<1이면 가장자리 띠는 빼고 안쪽만."""
    import numpy as np
    from PIL import Image
    r = ref.resize(im.size, Image.LANCZOS)
    n = im.size[0]; k = int(round(n * (1 - inner) / 2)); sl = slice(k, n - k) if k else slice(None)
    d = []
    for bg in [(246, 246, 248), (29, 29, 31)]:
        d.append(np.abs(flat(im, bg)[sl, sl] - flat(r, bg)[sl, sl]).mean())
    return max(d)

def check_icons():
    try:
        from PIL import Image
    except ImportError:
        bad('아이콘', 'Pillow가 없어 그림 비교를 못 했습니다 (pip install pillow)'); return
    full, rounded = masters()
    for t in TP['icons']:
        p = t['path']; where = t['where']
        if not os.path.exists(os.path.join(ROOT, p)):
            bad('아이콘', f'{where}: 파일 없음 {p}'); continue
        im = Image.open(os.path.join(ROOT, p)).convert('RGBA')
        if im.size != (t['size'], t['size']):
            bad('아이콘', f'{where}: 크기 {im.size[0]}×{im.size[1]} (기준 {t["size"]})'); continue
        if t['type'] == 'rounded':
            d = icon_diff(im, rounded)
        elif t['type'] == 'full':
            d = icon_diff(im, full)
        else:  # 탭: 둥근 판 + 가장자리 옅은 선(Safari 받침 방지 예외). 안쪽 76%만 원본과 비교
            ref = full.resize((im.size[0] * 4,) * 2, Image.LANCZOS); ref.putalpha(squircle(ref.size[0]))
            d = icon_diff(im, ref, inner=0.76)
        lim = TOL[t['type']]
        (ok if d <= lim else bad)('아이콘', f'{where}: 기준 그림과 차이 {d:.1f} (허용 {lim})')

# ---------- 페이지: 아이콘 연결 ----------
def check_pages():
    pi = TP['page_icons']
    for page in TP['pages']:
        html = read(page)
        links = re.findall(r'<link[^>]+>', html)
        def has(rel, name, size=None):
            for l in links:
                if f'rel="{rel}"' in l and name in l and (size is None or f'sizes="{size}"' in l):
                    return True
            return False
        miss = []
        if not has('icon', pi['icon32'], '32x32'): miss.append('탭 32')
        if not has('icon', pi['icon96'], '96x96'): miss.append('탭 96')
        if not has('apple-touch-icon', pi['apple']): miss.append('iPhone 홈 화면')
        (bad if miss else ok)('페이지', f'{page}: ' + ('빠진 아이콘 연결 ' + ', '.join(miss) if miss else '아이콘 연결 3종 모두 있음'))
        for ref in sorted(set(re.findall(r'(?:src|href)="(?:/dropfit-download/)?((?:assets|fonts)/[^"?#]+)', html))):
            if not os.path.exists(os.path.join(ROOT, ref)):
                bad('페이지', f'{page}: 없는 파일을 가리킴 {ref}')
    idx = read('index.html')
    og = re.findall(r'og:image" content="([^"]+)"', idx); tw = re.findall(r'twitter:image" content="([^"]+)"', idx)
    (ok if og and og == tw else bad)('미리보기', f'카톡·SNS 미리보기 그림 주소 {og[0] if og else "없음"}' + ('' if og == tw else f' / twitter {tw}'))

# ---------- 버전: 랜딩·appcast·zip ----------
def check_version():
    idx = read('index.html')
    m = re.search(r"var VERSION = '([^']+)'", idx); land = m.group(1) if m else None
    ac = read('appcast.xml')
    m = re.search(r'<sparkle:shortVersionString>([^<]+)</', ac); acv = m.group(1) if m else None
    m = re.search(r'<sparkle:version>([^<]+)</', ac); acb = m.group(1) if m else None
    z = zipfile.ZipFile(os.path.join(ROOT, 'Dropfit-macOS.zip'))
    pl = [n for n in z.namelist() if n.endswith('Dropfit.app/Contents/Info.plist')]
    info = plistlib.loads(z.read(pl[0])) if pl else {}
    zv, zb = info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')
    same = land == acv == zv and acb == zb
    (ok if same else bad)('버전', f'랜딩 {land} · appcast {acv}({acb}) · 다운로드 zip {zv}({zb})')
    up = f'updates/Dropfit-{acv}-{acb}.zip'
    if not os.path.exists(os.path.join(ROOT, up)):
        bad('버전', f'업데이트 zip 없음 {up}'); return
    u = zipfile.ZipFile(os.path.join(ROOT, up))
    a = {n.split('Dropfit/', 1)[1]: z.read(n) for n in z.namelist() if n.startswith('Dropfit/Dropfit.app/') and not n.endswith('/')}
    b = {n: u.read(n) for n in u.namelist() if n.startswith('Dropfit.app/') and not n.endswith('/')}
    diff = [k for k in set(a) | set(b) if a.get(k) != b.get(k)]
    (ok if not diff else bad)('버전', '다운로드 zip과 업데이트 zip의 앱이 같음' if not diff else f'두 zip의 앱이 다름: {diff[:3]}')

# ---------- 문안: 금지어 ----------
BANNED = ['오브', '통과 보장', '평생 무료', '광고 규격 그대로']   # 품질 기술서 3장 '문안'
def check_words():
    for f in TP['pages'] + ['README.md']:
        txt = re.sub(r'<script[\s\S]*?</script>|<style[\s\S]*?</style>', '', read(f))
        hit = [w for w in BANNED if w in txt]
        (bad if hit else ok)('문안', f'{f}: ' + ('금지어 ' + ', '.join(hit) if hit else f'금지어 {len(BANNED)}개 없음'))

# ---------- 화면: 휴대폰 폭 가로 넘침 ----------
def check_render():
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        bad('화면', 'playwright가 없어 휴대폰 폭 점검을 못 했습니다 (pip install playwright && playwright install chromium)'); return
    import http.server, threading, functools
    class H(http.server.SimpleHTTPRequestHandler):   # 공개 주소처럼 /dropfit-download/ 아래로도 열리게
        def log_message(self, *a): pass
        def translate_path(self, path):
            return super().translate_path(path.replace('/dropfit-download/', '/', 1))
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(H, directory=ROOT))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{srv.server_address[1]}/'
    with sync_playwright() as pw:
        b = pw.chromium.launch(executable_path=os.environ.get('CHROME_PATH') or None)
        for page in TP['pages']:
            for w in (400, 1280):
                pg = b.new_page(viewport={'width': w, 'height': 900}, reduced_motion='reduce')
                pg.goto(base + page); pg.wait_for_timeout(600)
                over = pg.evaluate('document.documentElement.scrollWidth - innerWidth')
                (ok if over <= 0 else bad)('화면', f'{page} {w}px 폭: 가로 넘침 {max(over, 0)}px (기준 0)')
                pg.close()
        b.close()
    srv.shutdown()

# ---------- 확정값: 파일 지문·색 ----------
HEX = re.compile(r'#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b')
def colors(path):
    return sorted({c.lower() for c in HEX.findall(read(path))})

def check_ledger():
    path = os.path.join(B, 'ledger.json')
    if not os.path.exists(path):
        bad('확정값', 'brand/ledger.json 없음 (python3 brand/check.py --confirm)'); return
    led = load('ledger.json')
    changed = [p for p in TP['watched'] if led['files'].get(p) != (sha(p) if os.path.exists(os.path.join(ROOT, p)) else None)]
    if changed:
        bad('확정값', '확정 뒤 바뀐 파일: ' + ', '.join(changed) + ' → 정훈 확정 후 --confirm')
    else:
        ok('확정값', f'보이는 파일 {len(TP["watched"])}개가 확정값과 같음')
    if led.get('zip_bytes'):
        r = zip_size() / led['zip_bytes'] - 1
        (ok if abs(r) <= 0.20 else bad)('확정값', f'다운로드 zip {zip_size() / 1e6:.1f}MB, 확정값 대비 {r * 100:+.0f}% (20% 넘으면 원인 기록 후 확정)')
    for f in TP['color_files']:
        new = [c for c in colors(f) if c not in led['colors'].get(f, [])]
        (bad if new else ok)('색', f'{f}: ' + ('장부에 없는 새 색 ' + ' '.join(new) if new else f'색 {len(colors(f))}개 모두 장부 안'))

def og_v():
    m = re.search(r'og\.png\?v=(\d+)', read('index.html')); return m.group(1) if m else None

def zip_size():
    return os.path.getsize(os.path.join(ROOT, 'Dropfit-macOS.zip'))

def confirm():
    old = load('ledger.json') if os.path.exists(os.path.join(B, 'ledger.json')) else {}
    if old and old['files'].get('assets/og.png') != sha('assets/og.png') and old.get('og_v') == og_v():
        print('확정 안 함: 미리보기 그림(og.png)이 바뀌었는데 index.html의 og.png?v= 숫자가 그대로입니다. 카톡이 예전 그림을 계속 보여 줍니다.'); sys.exit(1)
    led = {'og_v': og_v(), 'zip_bytes': zip_size(), '_설명': '정훈이 확정한 상태의 지문. 바꾸려면 확정 후 python3 brand/check.py --confirm',
           'files': {p: sha(p) for p in TP['watched'] if os.path.exists(os.path.join(ROOT, p))},
           'colors': {f: colors(f) for f in TP['color_files']}}
    with open(os.path.join(B, 'ledger.json'), 'w', encoding='utf-8') as fp:
        json.dump(led, fp, ensure_ascii=False, indent=1); fp.write('\n')
    print(f'확정값 기록: 파일 {len(led["files"])}개, 색 파일 {len(led["colors"])}개')

# ---------- 공개 사이트 ----------
def check_live():
    for p in TP['watched']:
        url = LIVE + ('' if p == 'index.html' else p)
        try:
            req = urllib.request.Request(url + ('&' if '?' in url else '?') + 'check=1', headers={'User-Agent': 'dropfit-brand-check'})
            data = urllib.request.urlopen(req, timeout=60).read()
        except Exception as e:
            bad('공개 사이트', f'{p}: 열리지 않음 ({e})'); continue
        (ok if hashlib.sha256(data).hexdigest() == sha(p) else bad)('공개 사이트', f'{p}: ' + ('main과 같음' if hashlib.sha256(data).hexdigest() == sha(p) else 'main과 다름'))

def report():
    w = max(len(a) for _, a, _ in results) if results else 0
    lines = [f'{s} {a.ljust(w)}  {m}' for s, a, m in results]
    print('\n'.join(lines))
    fails = sum(1 for s, _, _ in results if s == '✗')
    print(f'\n{"통과" if not fails else f"{fails}건 다름"} · 점검 {len(results)}개')
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as f:
            f.write('### Dropfit 통일 점검\n\n' + '\n'.join(f'- {l}' for l in lines) + '\n')
    return 1 if fails else 0

if __name__ == '__main__':
    if '--confirm' in sys.argv:
        confirm(); sys.exit(0)
    if '--live' in sys.argv:
        check_live()
    else:
        check_icons(); check_pages(); check_version(); check_words(); check_ledger()
        if '--no-render' not in sys.argv: check_render()
    sys.exit(report())
