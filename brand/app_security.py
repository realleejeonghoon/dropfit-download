#!/usr/bin/env python3
"""Dropfit 앱 보안 점검 (깨끗한 Mac CI 전용, 품질 기술서 '보안').

  python3 brand/app_security.py --out 폴더          저장소의 Dropfit-macOS.zip 점검 (업데이트 PR마다)
  python3 brand/app_security.py --live --out 폴더   공개 주소에서 받은 zip 점검 (매일)

다섯 묶음, 기준값은 brand/security.json:
  서명      코드 파일 목록이 기준과 같음, 모든 코드가 우리 Developer ID·타임스탬프·강화된 런타임,
            권한(entitlements) 허용 목록 밖 0개, 바깥 라이브러리 불러오기 0개, 파일 권한 이상 0개, 공증
  업데이트  https 주소·서명된 목록만 받기·풀기 전 서명 확인·공개 키 지문, Sparkle 버전과 알려진 보안 결함
  바깥 연결 앱 본체에 통신 기능 0개, 앱 안 주소가 허용 목록뿐, 실제 실행 중 연결이 GitHub(업데이트 확인)뿐
  비밀      zip·저장소(전체 이력) 안 비밀 키·인증서·토큰 0개, Sparkle 비밀 키는 후보를 모두 공개 키로 대조
  기록      이 Mac 경로(/Users/…)가 앱에 남지 않음
비밀 값은 어디에도 찍지 않는다(종류·파일 이름만).
"""
import base64, hashlib, io, ipaddress, json, os, plistlib, re, shutil, subprocess, sys, tarfile, threading, time, urllib.request, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = json.load(open(os.path.join(ROOT, 'brand', 'security.json'), encoding='utf-8'))
LIVE = 'https://realleejeonghoon.github.io/dropfit-download/'
import platform
# Intel Mac 점검 기계(macos-15-intel)에서는 x64판
GITLEAKS = 'https://github.com/gitleaks/gitleaks/releases/download/v8.21.2/gitleaks_8.21.2_darwin_' + ('x64' if platform.machine() == 'x86_64' else 'arm64') + '.tar.gz'
results = []
def put(mark, area, msg): results.append((mark, area, msg))
ok = lambda c: '✓' if c else '✗'

def run(*a, **k):
    p = subprocess.run(a, capture_output=True, text=True, **k)
    return p.returncode, p.stdout, p.stderr

def fetch(url, token=False):
    h = {'User-Agent': 'dropfit-app-security'}
    if token and os.environ.get('GITHUB_TOKEN'): h['Authorization'] = 'Bearer ' + os.environ['GITHUB_TOKEN']
    return urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=120).read()

def vtuple(v): return tuple(int(x) for x in re.findall(r'\d+', v)[:3])

MACHO = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xfe\xed\xfa\xcf', b'\xbe\xba\xfe\xca'}

# ───────── 서명
def check_signing(app):
    code, scripts, oddexec, perms, links = [], [], [], [], []
    for d, dirs, files in os.walk(app):
        for n in files + dirs:
            p = os.path.join(d, n); rel = os.path.relpath(p, app)
            if os.path.islink(p):
                t = os.path.realpath(p)
                if not t.startswith(os.path.realpath(app) + os.sep): links.append(rel)
                continue
            st = os.lstat(p)
            if st.st_mode & 0o002 or st.st_mode & 0o6000: perms.append(f'{rel} {oct(st.st_mode)[-4:]}')
            if n not in files: continue
            head = open(p, 'rb').read(4)
            if head in MACHO: code.append(rel)
            elif head[:2] == b'#!': scripts.append(rel)
            elif st.st_mode & 0o111 and '_CodeSignature' not in rel: oddexec.append(rel)
    want = sorted(CFG['code'])
    extra, missing = sorted(set(code) - set(want)), sorted(set(want) - set(code))
    put(ok(not extra and not missing), '서명', f'코드 파일 {len(code)}개, 기준 {len(want)}개와 같음' if not extra and not missing
        else f'코드 파일이 기준과 다름: 더 있음 {extra[:3]} · 없음 {missing[:3]}')
    put(ok(not scripts and not oddexec), '서명', '스크립트·실행 표시 붙은 그 밖의 파일 0개' if not scripts and not oddexec
        else f'예상 밖 실행 파일: {(scripts + oddexec)[:4]}')
    put(ok(not perms and not links), '서명', '누구나 쓸 수 있는 파일·권한 상승 표시·앱 밖을 가리키는 링크 0개' if not perms and not links
        else f'파일 권한 이상: {(perms + links)[:4]}')

    rc, _, err = run('codesign', '--verify', '--deep', '--strict', app)
    put(ok(rc == 0), '서명', '앱 전체 서명 검증(--deep --strict) 통과' if rc == 0 else f'서명 검증 실패: {err.strip().splitlines()[-1:]}')
    bad_team, bad_auth, no_ts, no_rt, ents, bad_ent, ext_lib = [], [], [], [], {}, [], []
    for rel in code:
        p = os.path.join(app, rel)
        _, _, info = run('codesign', '-dvvv', p)
        team = (re.search(r'TeamIdentifier=(\S+)', info) or [None, '?'])[1]
        auth = (re.search(r'Authority=(.+)', info) or [None, '?'])[1]
        if team != CFG['team']: bad_team.append(f'{rel}:{team}')
        if not auth.startswith('Developer ID Application') or f'({CFG["team"]})' not in auth: bad_auth.append(rel)
        if 'Timestamp=' not in info: no_ts.append(rel)
        flags = (re.search(r'flags=0x([0-9a-f]+)', info) or [None, '0'])[1]
        is_exec = 'executable' in run('file', '-b', p)[1]
        if is_exec and not int(flags, 16) & 0x10000: no_rt.append(rel)
        _, xml, _ = run('codesign', '-d', '--entitlements', '-', '--xml', p)
        keys = sorted(plistlib.loads(xml.encode()).keys()) if xml.strip().startswith('<?xml') else []
        if keys: ents[rel] = keys
        bad_ent += [f'{os.path.basename(rel)}:{k}' for k in keys if k not in CFG['entitlements_allowed']]
        _, lc, _ = run('otool', '-l', p)
        for kind, path in re.findall(r'cmd (LC_(?:LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB|RPATH))\n.*?(?:name|path) (\S+)', lc, re.S):
            if not path.startswith(('/System/', '/usr/lib/', '@rpath/', '@executable_path/', '@loader_path/')):
                ext_lib.append(f'{os.path.basename(rel)}:{path}')
    put(ok(not bad_team and not bad_auth), '서명', f'코드 {len(code)}개 모두 우리 Developer ID({CFG["team"]})로 서명' if not bad_team and not bad_auth
        else f'다른 서명: {(bad_team + bad_auth)[:3]}')
    put(ok(not no_ts), '서명', f'코드 {len(code)}개 모두 Apple 타임스탬프 있음(인증서가 끝나도 서명 유효)' if not no_ts else f'타임스탬프 없음: {no_ts}')
    nexe = sum(1 for r in code if 'executable' in run('file', '-b', os.path.join(app, r))[1])
    put(ok(not no_rt), '서명', f'실행 파일 {nexe}개 모두 강화된 런타임 켜짐(다른 프로그램의 코드 주입 차단)' if not no_rt else f'강화된 런타임 꺼짐: {no_rt}')
    banned = [b for b in bad_ent if b.split(':', 1)[1] in CFG['entitlements_banned']]
    put(ok(not bad_ent), '서명', f'추가 권한(entitlements) {sum(len(v) for v in ents.values())}개 · 허용 목록 밖 0개(디버거 붙이기·라이브러리 검증 끄기 등 금지 권한 0개)'
        if not bad_ent else f'허용 목록 밖 권한 {len(bad_ent)}개{" (금지 권한 " + str(len(banned)) + "개)" if banned else ""}: {bad_ent[:4]}')
    put(ok(not ext_lib), '서명', '앱 밖 라이브러리 불러오기 0개(시스템·앱 안 Sparkle만)' if not ext_lib else f'앱 밖 라이브러리: {ext_lib[:3]}')
    rc, out, err = run('spctl', '--assess', '--type', 'execute', '-vv', app)
    s = out + err
    put(ok('accepted' in s and 'Notarized Developer ID' in s), '서명', 'Gatekeeper: Apple 공증을 받은 Developer ID로 허용' if 'Notarized' in s else f'Gatekeeper: {s.strip()[:120]}')
    return code

# ───────── 업데이트 안전장치
def check_update(app):
    info = plistlib.load(open(os.path.join(app, 'Contents/Info.plist'), 'rb'))
    feed = info.get('SUFeedURL', '')
    put(ok(feed == CFG['feed']), '업데이트', f'업데이트 주소 https·배포 주소와 같음' if feed == CFG['feed'] else f'업데이트 주소 다름: {feed}')
    put(ok(info.get('SURequireSignedFeed') is True), '업데이트', '서명된 업데이트 목록만 받기 켜짐' if info.get('SURequireSignedFeed') is True else '서명된 목록만 받기 꺼짐')
    put(ok(info.get('SUVerifyUpdateBeforeExtraction') is True), '업데이트', '업데이트 파일을 풀기 전에 서명 확인 켜짐' if info.get('SUVerifyUpdateBeforeExtraction') is True else '풀기 전 서명 확인 꺼짐')
    fp = hashlib.sha256(info.get('SUPublicEDKey', '').encode()).hexdigest()[:12]
    put(ok(fp == CFG['public_key_sha256_12']), '업데이트', f'업데이트 공개 키 지문 {fp} = 기준' if fp == CFG['public_key_sha256_12'] else f'업데이트 공개 키가 바뀜: 지문 {fp} (기준 {CFG["public_key_sha256_12"]})')
    ats = info.get('NSAppTransportSecurity') or {}
    put(ok(not ats), '업데이트', '암호화 안 된 연결 허용(ATS 예외) 0개' if not ats else f'ATS 예외: {list(ats)}')

    sp = plistlib.load(open(os.path.join(app, 'Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist'), 'rb'))
    ver = sp.get('CFBundleShortVersionString', '0')
    put(ok(vtuple(ver) >= vtuple(CFG['sparkle_min'])), '업데이트', f'Sparkle {ver} (보안 수정판 {CFG["sparkle_min"]} 이상)')
    try:
        adv = json.loads(fetch('https://api.github.com/repos/sparkle-project/Sparkle/security-advisories?per_page=100', token=True))
        hit = []
        for a in adv:
            for v in a.get('vulnerabilities') or [{}]:
                rng = v.get('vulnerable_version_range') or ''
                conds = [c.strip() for c in rng.split(',') if c.strip()]
                def sat(c):
                    m = re.match(r'(<=|>=|<|>|=)?\s*(\S+)', c); op, x = m.group(1) or '=', vtuple(m.group(2)); y = vtuple(ver)
                    return {'<': y < x, '<=': y <= x, '>': y > x, '>=': y >= x, '=': y == x}[op]
                if conds and all(sat(c) for c in conds): hit.append(f'{a.get("cve_id") or a.get("ghsa_id")} ({rng})')
        put(ok(not hit), '업데이트', f'Sparkle 공개 보안 결함 {len(adv)}건 중 {ver}에 해당 0건' if not hit else f'Sparkle {ver}에 해당하는 보안 결함 {len(hit)}건: {hit[:3]}')
    except Exception as e:
        put('△', '업데이트', f'Sparkle 보안 결함 목록을 받지 못함({type(e).__name__}) · 내일 다시 확인')
    try:
        tag = json.loads(fetch('https://api.github.com/repos/sparkle-project/Sparkle/releases/latest', token=True))['tag_name']
        newer = vtuple(tag) > vtuple(ver)
        put('△' if newer else '✓', '업데이트', f'Sparkle 새 판 {tag} 나옴 (지금 {ver}, 알림만 · 바꾸는 건 정훈 님 확정 뒤)' if newer else f'Sparkle 최신판 {tag} = 앱에 든 판')
    except Exception as e:
        put('△', '업데이트', f'Sparkle 최신판을 확인하지 못함({type(e).__name__})')

# ───────── 바깥 연결
def check_net_static(app, code):
    main = os.path.join(app, CFG['code'][0])
    _, und, _ = run('nm', '-u', main)
    syms = set(und.split())
    found = [s for s in CFG['net_symbols'] if (s in syms if s.startswith('_') else any(s in x for x in syms))]
    put(ok(not found), '바깥 연결', f'앱 본체에 통신 기능 0개 (가져다 쓰는 기능 {len(syms)}개 중) · 통신은 Sparkle 업데이트만' if not found
        else f'앱 본체가 통신 기능을 씀: {found}')
    hosts, mails = {}, set()
    for d, _, files in os.walk(app):
        for n in files:
            p = os.path.join(d, n)
            if '_CodeSignature' in p or os.path.islink(p): continue
            b = open(p, 'rb').read()
            for h in re.findall(rb'https?://([A-Za-z0-9.-]+)', b): hosts.setdefault(h.decode().lower(), os.path.basename(p))
            for m in re.findall(rb'mailto:([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+)', b): mails.add(m.decode().lower())
    hosts.pop('', None)
    bad = sorted(h for h in hosts if h not in CFG['url_hosts_allowed'])
    badm = sorted(m for m in mails if m not in CFG['mail_allowed'])
    put(ok(not bad and not badm), '바깥 연결', f'앱 안 주소 {len(hosts)}곳·메일 {len(mails)}곳 모두 허용 목록 (Apple 인증서·Sparkle 설명·배포 주소·피드백 메일)'
        if not bad and not badm else f'허용 목록 밖 주소: {(bad + badm)[:5]}')

def check_net_runtime(app_src, out):
    app = '/Applications/Dropfit.app'
    shutil.rmtree(app, ignore_errors=True); run('ditto', app_src, app)
    run('defaults', 'delete', 'app.dropfit.prototype')
    names = ('Dropfit', 'Autoupdat', 'Updater')   # lsof는 이름을 9자로 자른다
    seen, stop = {}, threading.Event()
    def sample():
        while not stop.is_set():
            _, o, _ = run('lsof', '-nP', '-i', '-F', 'pcn')
            cmd = ''
            for line in o.splitlines():
                if line[:1] == 'c': cmd = line[1:]
                elif line[:1] == 'n' and cmd.startswith(names) and '->' in line:
                    seen.setdefault(line[1:].split('->')[1], cmd)
            time.sleep(0.2)
    th = threading.Thread(target=sample, daemon=True); th.start()
    tcp = None
    try:
        tcp = subprocess.Popen(['sudo', '-n', 'tcpdump', '-i', 'pktap,all', '-k', 'NP', '-n', '-l', '-q', 'tcp or udp'],
                               stdout=open(os.path.join(out, 'tcpdump.txt'), 'w'), stderr=subprocess.DEVNULL)
    except Exception: pass
    time.sleep(2)
    p = subprocess.Popen([app + '/Contents/MacOS/Dropfit'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(25); p.terminate(); time.sleep(2)
    q = subprocess.Popen([app + '/Contents/MacOS/Dropfit', '--qa', os.path.join(out, 'qa.txt')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try: q.wait(300)
    except subprocess.TimeoutExpired: q.kill()
    time.sleep(2); stop.set(); th.join(3)
    if tcp: tcp.terminate()
    run('pkill', '-x', 'Dropfit')
    # tcpdump(pktap)은 프로세스 이름(proc·eproc)을 줄에 함께 적는다. Dropfit 쪽 줄에서 이 Mac이 아닌 쪽 주소를 모은다
    _, ifc, _ = run('ifconfig')
    mine = set(re.findall(r'inet6? ([0-9a-f.:]+)', ifc))
    shown = []
    try:
        for line in open(os.path.join(out, 'tcpdump.txt'), errors='replace'):
            if not any(f'{n}:' in line for n in names): continue
            m = re.search(r' ([0-9a-f.:]+)\.(\d+) > ([0-9a-f.:]+)\.(\d+):', line)
            if not m: continue
            if len(shown) < 12: shown.append(line.strip()[:220])
            a, b = (m.group(1), m.group(2)), (m.group(3), m.group(4))
            far = b if a[0] in mine else a if b[0] in mine else None
            if far: seen.setdefault(f'{far[0]}:{far[1]}', 'tcpdump')
    except OSError: pass
    if shown: print('--- tcpdump에서 Dropfit 쪽 줄 (처음 12개) ---\n' + '\n'.join(shown) + '\n')
    def addr(s): return s.rsplit(':', 1)[0].strip('[]')
    allowed = [ipaddress.ip_network(c) for c in CFG['net_allowed_cidrs']]
    good, local, dns, bad = [], [], [], []
    for s in seen:
        try: ip = ipaddress.ip_address(addr(s))
        except ValueError: bad.append(s); continue
        if ip.is_loopback: local.append(s)
        elif s.endswith(':53'): dns.append(s)          # 주소 이름 조회(GitHub 주소를 찾는 단계)
        elif any(ip in n for n in allowed): good.append(s)
        else: bad.append(s)
    json.dump({'connections': seen}, open(os.path.join(out, 'connections.json'), 'w'), ensure_ascii=False, indent=1)
    qa_ok = os.path.exists(os.path.join(out, 'qa.txt'))
    put(ok(not bad), '바깥 연결', f'실행 25초 + 화면 동작 점검({"끝남" if qa_ok else "보고서 없음"}) 동안 바깥 연결: GitHub(업데이트 확인) {len(good)}건 · 주소 조회 {len(dns)}건 · 그 밖 0건'
        if not bad else f'허용 밖 연결 {len(bad)}건: {bad[:4]} (GitHub {len(good)}건)')

# ───────── 비밀
B64 = re.compile(rb'(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=')
PAT = {'개인 키 파일 내용': rb'-----BEGIN [A-Z ]*PRIVATE KEY-----', 'GitHub 토큰': rb'gh[pousr]_[A-Za-z0-9]{36}|github_pat_\w{40,}',
       'AWS 키': rb'AKIA[0-9A-Z]{16}', 'Slack 토큰': rb'xox[baprs]-[0-9A-Za-z-]{10,}', 'Google API 키': rb'AIza[0-9A-Za-z_-]{35}'}
APW = re.compile(rb'(?<![a-z-])[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}(?![a-z-])')   # Apple 앱 전용 암호 꼴 (글자 파일에서만)
KEYEXT = ('.p12', '.pfx', '.pem', '.key', '.cer', '.der', '.mobileprovision', '.provisionprofile', '.keychain', '.keychain-db', '.env', '.p8')

def scan(blobs, pk, label):
    """blobs: (이름, 바이트). 비밀 패턴 수, Sparkle 비밀 키 후보 수·일치 수를 센다."""
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization as S
    hits, names, cand, match, users = [], [], 0, [], set()
    for name, b in blobs:
        if name.lower().endswith(KEYEXT): names.append(name)
        for k, rx in PAT.items():
            if re.search(rx, b): hits.append(f'{k}: {name}')
        if b'\x00' not in b[:8000] and APW.search(b):
            hits.append(f'앱 전용 암호 꼴: {name}')
        for m in set(B64.findall(b)):
            try: seed = base64.b64decode(m)
            except Exception: continue
            if len(seed) != 32: continue
            cand += 1
            pub = Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(S.Encoding.Raw, S.PublicFormat.Raw)
            if pub == pk: match.append(name)
        for u in re.findall(rb'/Users/([A-Za-z0-9._-]+)/', b):
            if label == 'zip' and u not in (b'runner', b'Shared'): users.add(name)
    return hits, names, cand, match, users

def check_secrets(app, pk, out):
    blobs = []
    for d, _, files in os.walk(app):
        for n in files:
            p = os.path.join(d, n)
            if not os.path.islink(p): blobs.append((os.path.relpath(p, app), open(p, 'rb').read()))
    hits, names, cand, match, users = scan(blobs, pk, 'zip')
    put(ok(not hits and not names), '비밀', f'앱 파일 {len(blobs)}개에 비밀 키·인증서·토큰 0개' if not hits and not names else f'앱 안 비밀 의심 {len(hits) + len(names)}건: {(names + hits)[:4]}')
    put(ok(not match), '비밀', f'Sparkle 비밀 키: 앱 안 후보 {cand}개를 공개 키로 모두 대조 → 일치 0개' if not match else f'앱 안에 Sparkle 비밀 키가 있음: {match}')
    put('✓' if not users else '△', '기록', '앱 안에 만든 Mac의 사용자 경로(/Users/…) 0곳' if not users else f'앱 안에 만든 Mac 경로가 남은 파일 {len(users)}개(사용자 이름이 보임): {sorted(users)[:3]}')

    # 저장소: 지금 파일 + 전체 이력의 모든 글자 파일(2MB 이하), 지금 zip 안 파일
    rb = []
    _, objs, _ = run('git', '-C', ROOT, 'rev-list', '--all', '--objects')
    shas = sorted({l.split()[0] for l in objs.splitlines() if l})
    pr = subprocess.run(['git', '-C', ROOT, 'cat-file', '--batch'], input='\n'.join(shas).encode() + b'\n', capture_output=True).stdout
    i, nblob = 0, 0
    while i < len(pr):
        j = pr.index(b'\n', i); sha, typ, size = pr[i:j].split(b' '); size = int(size)
        body = pr[j + 1:j + 1 + size]; i = j + 2 + size
        if typ == b'blob' and size < 2_000_000:
            nblob += 1; rb.append((f'이력 {sha[:8].decode()}', body))
    for z in [os.path.join(ROOT, 'Dropfit-macOS.zip')] + [os.path.join(ROOT, 'updates', f) for f in os.listdir(os.path.join(ROOT, 'updates'))]:
        if z.endswith('.zip'):
            with zipfile.ZipFile(z) as zf:
                rb += [(f'{os.path.basename(z)}:{n}', zf.read(n)) for n in zf.namelist() if not n.endswith('/')]
    hits, names, cand, match, _ = scan(rb, pk, 'repo')
    _, tree, _ = run('git', '-C', ROOT, 'ls-files')
    names += [f for f in tree.split('\n') if f.lower().endswith(KEYEXT)]
    put(ok(not hits and not names), '비밀', f'공개 저장소 이력 글자 파일 {nblob}개·zip 안 파일에 비밀 키·인증서·토큰 0개' if not hits and not names
        else f'저장소 비밀 의심 {len(hits) + len(names)}건: {(names + hits)[:4]}')
    put(ok(not match), '비밀', f'Sparkle 비밀 키: 저장소 후보 {cand}개를 공개 키로 모두 대조 → 일치 0개' if not match else f'저장소에 Sparkle 비밀 키: {match[:3]}')
    try:
        t = os.path.join(out, 'gitleaks'); os.makedirs(t, exist_ok=True)
        tarfile.open(fileobj=io.BytesIO(fetch(GITLEAKS))).extract('gitleaks', t)
        rep = os.path.join(out, 'gitleaks.json')
        rc, o, e = run(os.path.join(t, 'gitleaks'), 'detect', '--source', ROOT, '--redact', '--no-banner',
                       '--report-format', 'json', '--report-path', rep, '--log-opts=--all')
        found = json.load(open(rep)) if os.path.exists(rep) else []
        n = int((re.search(r'(\d+) commits scanned', o + e) or [0, 0])[1])
        put(ok(rc == 0 and not found), '비밀', f'gitleaks 8.21.2: 커밋 {n}개 전체 이력 비밀 0건' if rc == 0 and not found
            else f'gitleaks 비밀 의심 {len(found)}건: {[f["RuleID"] + " " + f["File"] for f in found][:4]}')
    except Exception as e:
        put('△', '비밀', f'gitleaks를 돌리지 못함({type(e).__name__}) · 위 직접 검사로 대신함')

def main():
    # 이 점검은 /Applications의 Dropfit을 지우고 새로 깔며 Dropfit 설정을 초기화한다. GitHub의 깨끗한 Mac에서만 돈다
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        print('멈춤: 이 점검은 GitHub의 깨끗한 Mac 전용입니다(설치된 Dropfit을 지우고 설정을 초기화함). 실제로 쓰는 Mac에서는 돌리지 마세요.'); sys.exit(3)
    out = sys.argv[sys.argv.index('--out') + 1] if '--out' in sys.argv else os.path.join(ROOT, '.sec-out')
    live = '--live' in sys.argv
    os.makedirs(out, exist_ok=True)
    zp = os.path.join(out, 'Dropfit-macOS.zip')
    if live: open(zp, 'wb').write(fetch(LIVE + 'Dropfit-macOS.zip'))
    else: shutil.copy(os.path.join(ROOT, 'Dropfit-macOS.zip'), zp)
    w = os.path.join(out, 'work'); shutil.rmtree(w, ignore_errors=True); os.makedirs(w)
    run('ditto', '-x', '-k', zp, w)
    app = os.path.join(w, 'Dropfit', 'Dropfit.app')
    info = plistlib.load(open(os.path.join(app, 'Contents/Info.plist'), 'rb'))
    ver = f'{info["CFBundleShortVersionString"]}({info["CFBundleVersion"]})'
    pk = base64.b64decode(info['SUPublicEDKey'])
    code = check_signing(app)
    check_update(app)
    check_net_static(app, code)
    check_net_runtime(app, out)
    check_secrets(app, pk, out)

    os_ver = run('sw_vers', '-productVersion')[1].strip()
    wd = max(len(a) for _, a, _ in results)
    lines = [f'{m} {a.ljust(wd)}  {msg}' for m, a, msg in results]
    fails = sum(1 for m, _, _ in results if m == '✗'); notes = sum(1 for m, _, _ in results if m == '△')
    tail = f'{"통과" if not fails else f"{fails}건 다름"} · 점검 {len(results)}개{f" · 알림 {notes}개" if notes else ""} · Dropfit {ver} · macOS {os_ver}'
    print('\n'.join(lines) + '\n\n' + tail)
    with open(os.path.join(out, 'summary.md'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n\n' + tail + '\n')
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as f:
            f.write(f'### Dropfit 앱 보안 점검{" (공개본)" if live else ""} · {ver} · macOS {os_ver}\n\n' + '\n'.join(f'- {l}' for l in lines) + f'\n\n{tail}\n')
    sys.exit(1 if fails else 0)

if __name__ == '__main__':
    main()
