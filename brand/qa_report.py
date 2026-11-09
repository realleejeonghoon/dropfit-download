#!/usr/bin/env python3
"""매일 9시 점검(daily-qa.yml)의 작업 결과를 시트 한 줄로 바꾼다.

python3 brand/qa_report.py jobs.json run.json appcast.xml out.json [SECURITY.md]
jobs.json = GitHub API runs/{id}/jobs, run.json = runs/{id}
나오는 것: 칸 이름 → 통과/실패/취소/건너뜀, 문제 내용, 공개 버전, 시각(KST),
그리고 정훈 님께 가는 매일 보고 메일(brief_subject·brief_body: 사용자가 겪는 순서로 묶은 글).
SECURITY.md를 주면 '출시 차단 위험 열림 N건'(남은 위험 표에서 출시 차단=예, 상태≠끝남)을 센다.
"""
import json, re, sys
from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))
# 시트 칸 순서. (칸 이름, 작업 이름 앞부분, 찾을 글자). macos-… 는 이름 끝으로 맞춰 macos-15와 macos-15-intel이 섞이지 않게
COLUMNS = [
    ('랜딩 통일', 'brand /', '공개 사이트'),
    ('앱 macOS 15', 'app /', 'macos-15'),
    ('앱 macOS 26', 'app /', 'macos-26'),
    ('앱 Intel Mac', 'app /', 'macos-15-intel'),
    ('보안 macOS 15', 'security /', 'macos-15'),
    ('보안 macOS 26', 'security /', 'macos-26'),
    ('보안 Intel Mac', 'security /', 'macos-15-intel'),
    ('끌어 옮기기 macOS 15', 'orb /', 'macos-15'),
    ('끌어 옮기기 macOS 26', 'orb /', 'macos-26'),
    ('업데이트 macOS 15', 'update /', 'macos-15'),
    ('업데이트 macOS 26', 'update /', 'macos-26'),
    ('업데이트 Intel Mac', 'update /', 'macos-15-intel'),
    ('0.6에서 업데이트 macOS 15', 'update-old /', 'macos-15'),
    ('0.6에서 업데이트 macOS 26', 'update-old /', 'macos-26'),
    ('0.6에서 업데이트 Intel Mac', 'update-old /', 'macos-15-intel'),
    ('변환 품질 macOS 15', 'engine /', 'macos-15'),
    ('변환 품질 macOS 26', 'engine /', 'macos-26'),
    ('변환 품질 Intel Mac', 'engine /', 'macos-15-intel'),
]
# 매일 보고: 사용자가 겪는 순서로 칸을 묶는다 (이름, 설명, 칸 이름 앞부분)
BRIEF = [
    ('받기·설치·실행', '다운로드 파일, 서명, Apple 공증, 처음 열기, 기본 변환, 충돌', ['앱 ']),
    ('변환 품질', '결과물 화질·용량, Pro 기능, 망가진 파일', ['변환 품질 ']),
    ('Dropfit 끌어 옮기기', '바탕화면 동그라미 끌기', ['끌어 옮기기 ']),
    ('자동 업데이트', '바로 앞 버전과 0.6에서 최신으로', ['업데이트 ', '0.6에서 업데이트 ']),
    ('보안', '서명, 바깥 연결, 비밀 키', ['보안 ']),
    ('다운로드 페이지', '랜딩 문구·그림·신청 폼', ['랜딩 ']),
]
OSNAME = (('Intel Mac', 'Intel'), ('macOS 15', '15'), ('macOS 26', '26'))
WEEK = '월화수목금토일'


def open_risks(path):
    """SECURITY.md 남은 위험 표: | SR-xx | 내용 | 영향 | 출시 차단 | 담당 | 상태 | ... """
    try:
        text = open(path, encoding='utf-8').read()
    except (OSError, TypeError):
        return None
    n = []
    for line in text.splitlines():
        c = [x.strip() for x in line.strip().strip('|').split('|')]
        if len(c) >= 6 and re.fullmatch(r'SR-\d+', c[0]) and c[3] == '예' and not c[5].startswith('끝남'):
            n.append(c[0])
    return n


def brief(out, risks):
    ch = out['checks']
    lines, bad_total = [], 0
    for i, (name, what, prefixes) in enumerate(BRIEF, 1):
        cols = [c for c in out['columns'] if any(c.startswith(p) for p in prefixes)]
        if not cols:
            continue
        bad = [c for c in cols if ch.get(c) != '통과']
        bad_total += len(bad)
        if not bad:
            lines.append(f'{i}. {name}: 통과 ({what})')
        else:
            lines.append(f'{i}. {name}: 확인 필요 · ' + ', '.join(f'{c} {ch.get(c)}' for c in bad))
    try:
        d = datetime.strptime(out['started'], '%Y-%m-%d %H:%M')
        when = f'{d.month}/{d.day}({WEEK[d.weekday()]}) {d.strftime("%H:%M")}'
    except ValueError:
        when = out['started']
    n = len(out['problems'])
    head = '사용자 앱 이상 없음' if n == 0 else f'확인 필요 {n}건'
    body = [f'Dropfit 매일 점검 · {when}', f'{head} (공개 {out["version"]}, macOS 15·26·Intel 클라우드 Mac)', ''] + lines + ['']
    body.append('조치 필요: ' + ('없음' if n == 0 else ''))
    body += [f'- {p}' for p in out['problems']]
    if risks is not None:
        body.append(f'출시 차단 위험 열림 {len(risks)}건' + (f' ({", ".join(risks)})' if risks else ''))
    body.append('아직 못 보는 것: 사용자 Mac에서 실제로 난 충돌, macOS 14')
    out['brief_subject'] = f'[Dropfit 점검] {when} · {head}'
    out['brief_body'] = '\n'.join(body)


WORD = {'success': '통과', 'failure': '실패', 'cancelled': '취소', 'skipped': '건너뜀',
        'timed_out': '시간 초과', None: '끝나지 않음'}


def kst(s):
    if not s:
        return ''
    return datetime.fromisoformat(s.replace('Z', '+00:00')).astimezone(KST).strftime('%Y-%m-%d %H:%M')


def main(jobs_path, run_path, appcast_path, out_path, security_path=None):
    jobs = json.load(open(jobs_path, encoding='utf-8'))['jobs']
    run = json.load(open(run_path, encoding='utf-8'))
    try:
        vers = re.findall(r'shortVersionString>([^<]+)<', open(appcast_path, encoding='utf-8').read())
        version = vers[0] if vers else ''
    except OSError:
        version = ''

    checks, problems = {}, []
    for col, prefix, needle in COLUMNS:
        hit = [j for j in jobs if j['name'].startswith(prefix) and (j['name'].endswith(needle) if needle.startswith('macos') else needle in j['name'])]
        if not hit:
            checks[col] = '돌지 않음'
            problems.append(f'{col}: 점검이 돌지 않음')
            continue
        j = hit[0]
        word = WORD.get(j.get('conclusion'), j.get('conclusion') or '끝나지 않음')
        checks[col] = word
        if word != '통과':
            step = next((s['name'] for s in j.get('steps') or [] if s.get('conclusion') == 'failure'), '')
            why = f' ({step})' if step else (' (Mac을 받지 못함)' if word == '취소' and not j.get('steps') else '')
            problems.append(f'{col}: {word}{why}')

    starts = [j['started_at'] for j in jobs if j.get('started_at')]
    ends = [j['completed_at'] for j in jobs if j.get('completed_at')]
    out = {
        'run_id': str(run['id']),
        'run_url': run['html_url'],
        'trigger': 'Mac 9시' if run['event'] == 'workflow_dispatch' else 'GitHub 예약',
        'started': kst(min(starts)) if starts else kst(run.get('run_started_at')),
        'finished': kst(max(ends)) if ends else '',
        'version': version,
        'overall': '통과' if not problems else f'문제 {len(problems)}건',
        'columns': [c for c, _, _ in COLUMNS],
        'checks': checks,
        'problems': problems,
    }
    brief(out, open_risks(security_path))
    json.dump(out, open(out_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)


if __name__ == '__main__':
    main(*sys.argv[1:6])
