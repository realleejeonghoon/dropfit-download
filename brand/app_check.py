#!/usr/bin/env python3
"""Dropfit 앱 배포본 점검 (품질 기술서 3장 '앱 빌드').

  python3 brand/app_check.py          저장소의 zip·업데이트 zip·appcast 점검 (PR마다)
  python3 brand/app_check.py --live   공개 주소에서 실제로 받아 점검 + main과 같은지 (매일)

재는 것: 버전 세 곳 일치, 다운로드 zip 구성, 두 zip의 앱이 같은지, 업데이트 zip Sparkle 서명,
appcast 서명(SURequireSignedFeed), appcast 길이·최소 macOS가 앱과 같은지.
macOS 실행 점검(서명·공증·Gatekeeper·실행·화면 점검·아이콘)은 app_check_mac.sh가 맡는다.
--out 폴더 를 주면 점검한 zip을 그 폴더에 Dropfit-macOS.zip 으로 남긴다(맥 점검이 이어 받음).
"""
import base64, hashlib, os, plistlib, re, shutil, sys, urllib.request, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIVE = 'https://realleejeonghoon.github.io/dropfit-download/'
RAW = 'https://github.com/realleejeonghoon/dropfit-download/raw/main/Dropfit-macOS.zip'
results = []
def put(good, area, msg): results.append(('✓' if good else '✗', area, msg))

def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'dropfit-app-check'})
    return urllib.request.urlopen(req, timeout=120).read()

def local(path):
    with open(os.path.join(ROOT, path), 'rb') as f: return f.read()

def main():
    live = '--live' in sys.argv
    out = sys.argv[sys.argv.index('--out') + 1] if '--out' in sys.argv else None
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    except ImportError:
        print('cryptography가 필요합니다 (pip install cryptography)'); sys.exit(2)

    feed = fetch(LIVE + 'appcast.xml') if live else local('appcast.xml')
    dl = fetch(LIVE + 'Dropfit-macOS.zip') if live else local('Dropfit-macOS.zip')
    if live:
        put(feed == local('appcast.xml'), '공개본', 'appcast가 main과 ' + ('같음' if feed == local('appcast.xml') else '다름'))
        put(dl == local('Dropfit-macOS.zip'), '공개본', '랜딩 다운로드 zip이 main과 ' + ('같음' if dl == local('Dropfit-macOS.zip') else '다름'))
        raw = fetch(RAW)
        put(raw == dl, '공개본', '고정 다운로드 주소(raw) zip이 랜딩 zip과 ' + ('같음' if raw == dl else '다름'))

    z = zipfile.ZipFile(__import__('io').BytesIO(dl))
    names = [n for n in z.namelist() if not n.endswith('/')]
    top = sorted({n.split('/')[1] for n in names if n.startswith('Dropfit/') and n.count('/') >= 1})
    show = lambda n: n.encode('cp437').decode('utf-8', 'replace') if not n.isascii() else n   # ditto zip은 한글 이름 표시 깃발이 없음
    put(all(n.startswith('Dropfit/') for n in names) and 'Dropfit.app' in top, 'zip 구성', f'Dropfit 폴더 안: {", ".join(map(show, top))}')
    info = plistlib.loads(z.read('Dropfit/Dropfit.app/Contents/Info.plist'))
    ver, build = info['CFBundleShortVersionString'], info['CFBundleVersion']

    m = lambda pat: (re.search(pat, feed) or [None, b''])[1].decode()
    fver, fbuild = m(rb'<sparkle:shortVersionString>([^<]+)<'), m(rb'<sparkle:version>([^<]+)<')
    fmin, flen = m(rb'<sparkle:minimumSystemVersion>([^<]+)<'), m(rb'length="(\d+)"')
    furl, fsig = m(rb'<enclosure url="([^"]+)"'), m(rb'sparkle:edSignature="([^"]+)"')
    idx = (local('index.html') if not live else fetch(LIVE)).decode()
    lver = (re.search(r"var VERSION = '([^']+)'", idx) or [None, '?'])[1]
    put(ver == fver == lver and build == fbuild, '버전', f'앱 {ver}({build}) · appcast {fver}({fbuild}) · 랜딩 {lver}')
    put(fmin == info.get('LSMinimumSystemVersion'), '버전', f'최소 macOS: appcast {fmin} · 앱 {info.get("LSMinimumSystemVersion")}')

    up = fetch(furl) if live else local(furl.replace(LIVE, ''))
    put(str(len(up)) == flen, '업데이트', f'업데이트 zip 크기 {len(up):,}B · appcast 기록 {int(flen or 0):,}B')
    pk = Ed25519PublicKey.from_public_bytes(base64.b64decode(info['SUPublicEDKey']))
    try:
        pk.verify(base64.b64decode(fsig), up); put(True, '업데이트', '업데이트 zip Sparkle 서명 유효')
    except Exception:
        put(False, '업데이트', '업데이트 zip Sparkle 서명 무효 → 사용자 업데이트 실패')
    i = feed.find(b'<!-- sparkle-signatures:')
    try:
        sig = re.search(rb'edSignature: (\S+)', feed[i:]).group(1)
        pk.verify(base64.b64decode(sig), feed[:i]); put(True, '업데이트', 'appcast 서명 유효')
    except Exception:
        put(False, '업데이트', 'appcast 서명 없음·무효 → 앱이 업데이트 정보를 거부')
    u = zipfile.ZipFile(__import__('io').BytesIO(up))
    a = {n.split('Dropfit/', 1)[1]: z.read(n) for n in names if n.startswith('Dropfit/Dropfit.app/')}
    b = {n: u.read(n) for n in u.namelist() if n.startswith('Dropfit.app/') and not n.endswith('/')}
    diff = [k for k in set(a) | set(b) if a.get(k) != b.get(k)]
    put(not diff, '업데이트', '다운로드 zip과 업데이트 zip의 앱이 같음' if not diff else f'두 zip의 앱이 다름 {len(diff)}개: {diff[:3]}')
    put(True, '지문', f'다운로드 zip SHA-256 {hashlib.sha256(dl).hexdigest()[:16]}… {len(dl):,}B')

    if out:
        os.makedirs(out, exist_ok=True)
        with open(os.path.join(out, 'Dropfit-macOS.zip'), 'wb') as f: f.write(dl)
        with open(os.path.join(out, 'version.txt'), 'w') as f: f.write(f'{ver} {build}\n')

    w = max(len(x[1]) for x in results)
    lines = [f'{s} {a.ljust(w)}  {msg}' for s, a, msg in results]
    print('\n'.join(lines))
    fails = sum(1 for s, _, _ in results if s == '✗')
    print(f'\n{"통과" if not fails else f"{fails}건 다름"} · 점검 {len(results)}개')
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as f:
            f.write(f'### Dropfit 앱 배포본 점검{" (공개본)" if live else ""}\n\n' + '\n'.join(f'- {l}' for l in lines) + '\n\n')
    sys.exit(1 if fails else 0)

if __name__ == '__main__':
    try:
        main()
    except OSError as e:   # 공개 주소가 열리지 않음
        print(f'✗ 공개본  받을 수 없음: {e}'); sys.exit(1)
