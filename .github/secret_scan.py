#!/usr/bin/env python3
"""Dropfit 비밀 값 검사 (2026-11-18 보안 점검, 정훈 님 "전부 넣기").

GitHub 자동 점검이 push·PR마다 돌린다. Claude 토큰도 정훈 님 Mac도 쓰지 않는다.
- 기본: 지금 판의 모든 파일에서 비밀 값(키·토큰·개인 키) 모양을 찾는다.
- --history: 모든 가지의 전체 기록에서 추가된 줄을 찾는다(매주 1회).
- Apps Script(.gs): 비밀 값을 실행 기록에 찍는 줄을 찾는다(11/18 디버거·실행 기록 노출 사고).

찾은 값은 출력하지 않는다. 파일·줄·종류와 앞 4글자만 적는다.
허용할 값은 .github/secret-allow.txt에 sha256(값)을 한 줄씩 적는다(공개 키 등). 값 자체는 적지 않는다.
표준 라이브러리만 쓴다(새 의존성 없음).
"""
import hashlib
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SELF = os.path.relpath(os.path.abspath(__file__), os.getcwd())

PATTERNS = {
    '개인 키 파일': r'-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----',
    'Paddle API 키': r'pdl_(?:sdbx|live)_apikey_[A-Za-z0-9_]{20,}',
    'Paddle 웹훅 비밀': r'pdl_ntfset_[A-Za-z0-9_]{20,}',
    'GitHub 토큰': r'\bgh[pousr]_[A-Za-z0-9]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{50,}',
    'AWS 키': r'\bAKIA[0-9A-Z]{16}\b',
    'Google API 키': r'\bAIza[0-9A-Za-z_-]{35}\b',
    'Google OAuth 토큰': r'\bya29\.[0-9A-Za-z_-]{30,}|\b1//0[0-9A-Za-z_-]{40,}',
    'Slack 토큰': r'\bxox[abprs]-[A-Za-z0-9-]{20,}',
    'Stripe 키': r'\b[sr]k_live_[A-Za-z0-9]{20,}',
    'clasp 로그인 파일': r'"refresh_token"\s*:\s*"[^"]{20,}"',
    # Sparkle EdDSA 비밀 키 모양(32바이트 base64). 공개 키도 같은 모양이라 허용 목록으로 뺀다
    'Ed25519 키 모양(44자)': r'(?<![A-Za-z0-9+/=])[A-Za-z0-9+/]{43}=(?![A-Za-z0-9+/=])',
    # 이름이 비밀인 변수에 긴 값을 직접 넣은 것
    '비밀 이름에 값 대입': r'(?i)\b[\w-]*(?:api[_-]?key|secret|token|password|passwd|private[_-]?key)[\w-]*["\']?\s*[:=]\s*["\'][A-Za-z0-9+/_=.-]{24,}["\']',
}
COMPILED = [(k, re.compile(v)) for k, v in PATTERNS.items()]

# 값이 아닌 자리 표시(예시) — 비밀 이름 대입 규칙에서만 뺀다
PLACEHOLDER = re.compile(r'(?i)(x{6,}|your|example|placeholder|dummy|sample|<|\$\{|__)')
# Paddle client-side token(test_…/live_…)은 결제창용 공개 값(paddle-config.js 설명)
PUBLIC_VALUE = re.compile(r'["\'](?:test|live)_[A-Za-z0-9]{20,40}["\']$')
# 개인 키는 머리 글자만이 아니라 본문(base64)이 붙어 있을 때만 본다. 코드 속 머리 글자 비교는 비밀이 아님
PEM_BODY = re.compile(r'^(?:\\n|\s|["\'+])*[A-Za-z0-9+/]{40,}')

# .gs: 실행 기록에 비밀을 찍는 줄
GS_LOG = re.compile(r'\b(?:Logger\.log|console\.(?:log|info|warn|error|debug))\s*\((.*)')
GS_SECRET_NAME = re.compile(r'(?i)\b(?:\w*api_?key\w*|\w*token\w*|\w*secret\w*|\w*password\w*|pem|private_?key\w*)\b')
GS_SECRET_WORD = re.compile(r'(?i)(token|secret|api.?key|private|password|비밀|토큰|붙여 넣을 값)')
GS_STRING = re.compile(r"'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"|`(?:\\.|[^`\\])*`")
GS_PROP = re.compile(r'getProperty\s*\(')

TEXT_LIMIT = 2_000_000


def load_allow():
    path = os.path.join(HERE, 'secret-allow.txt')
    if not os.path.exists(path):
        return set()
    with open(path, encoding='utf-8') as f:
        return {ln.split('#')[0].strip() for ln in f if ln.split('#')[0].strip()}


ALLOW = load_allow()


def sha(s):
    return hashlib.sha256(s.encode('utf-8')).hexdigest()


def scan_line(line, nxt=''):
    """(종류, 앞 4글자) 목록. nxt = 다음 줄(개인 키 본문 확인용)"""
    hits = []
    for name, rx in COMPILED:
        for m in rx.finditer(line):
            val = m.group(0)
            if sha(val) in ALLOW:
                continue
            if name == '개인 키 파일' and not (PEM_BODY.match(line[m.end():]) or PEM_BODY.match(nxt)):
                continue
            if name == '비밀 이름에 값 대입' and (PLACEHOLDER.search(val.split('=', 1)[-1].split(':', 1)[-1]) or PUBLIC_VALUE.search(val)):
                continue
            if name == 'Ed25519 키 모양(44자)' and not re.search(r'[0-9]', val):
                continue   # 글자만 이어진 문장·경로 조각은 키가 아님
            hits.append((name, val[:4]))
    return hits


def scan_gs_line(line):
    m = GS_LOG.search(line)
    if not m:
        return None
    args = m.group(1)
    literals = ' '.join(GS_STRING.findall(args))
    code = GS_STRING.sub("''", args)
    if GS_PROP.search(code):
        return '실행 기록에 스크립트 속성 값을 찍음'
    if GS_SECRET_NAME.search(code):
        return '실행 기록에 비밀 이름의 변수를 찍음'
    if GS_SECRET_WORD.search(literals) and re.search(r'\+\s*[A-Za-z_$]', code):
        return '실행 기록에 비밀로 보이는 값을 이어 붙여 찍음'
    return None


def is_text(data):
    return b'\0' not in data[:8000]


def scan_tree():
    files = subprocess.run(['git', 'ls-files', '-z'], capture_output=True, check=True).stdout.split(b'\0')
    problems = []
    for raw in files:
        if not raw:
            continue
        path = raw.decode('utf-8', 'replace')
        if path == SELF or not os.path.isfile(path) or os.path.getsize(path) > TEXT_LIMIT:
            continue
        with open(path, 'rb') as f:
            data = f.read()
        if not is_text(data):
            continue
        lines = data.decode('utf-8', 'replace').splitlines()
        for no, line in enumerate(lines, 1):
            for name, head in scan_line(line, lines[no] if no < len(lines) else ''):
                problems.append(f'{path}:{no}  {name}  ({head}…)')
            if path.endswith('.gs'):
                why = scan_gs_line(line)
                if why:
                    problems.append(f'{path}:{no}  {why}')
    return problems


def scan_history():
    out = subprocess.run(['git', 'log', '--all', '-p', '--no-color', '--no-ext-diff', '-U0', '--format=@@commit %h'],
                         capture_output=True, check=True).stdout.decode('utf-8', 'replace')
    problems, commit, path = [], '', ''
    rows = out.splitlines()
    for i, line in enumerate(rows):
        if line.startswith('@@commit '):
            commit = line.split()[1]
        elif line.startswith('+++ '):
            path = line[6:] if line.startswith('+++ b/') else line[4:]
        elif line.startswith('+') and not line.startswith('+++'):
            if path == SELF:
                continue
            nxt = rows[i + 1][1:] if i + 1 < len(rows) and rows[i + 1].startswith('+') else ''
            for name, head in scan_line(line[1:], nxt):
                problems.append(f'{commit} {path}  {name}  ({head}…)')
    return sorted(set(problems))


def main():
    history = '--history' in sys.argv
    problems = scan_history() if history else scan_tree()
    where = '전체 기록' if history else '지금 판'
    if problems:
        print(f'✗ 비밀 값 검사({where}): {len(problems)}건. 값은 적지 않았습니다.')
        for p in problems[:200]:
            print('  ' + p)
        print('\n할 일: ① 진짜 비밀이면 바로 교체(SECURITY.md ⑥) ② 공개 키처럼 공개해도 되는 값이면 '
              '.github/secret-allow.txt에 sha256만 추가 ③ .gs 로그면 값을 찍지 않게 고침')
        return 1
    print(f'✓ 비밀 값 검사({where}): 0건')
    return 0


if __name__ == '__main__':
    sys.exit(main())
