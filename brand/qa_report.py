#!/usr/bin/env python3
"""매일 9시 점검(daily-qa.yml)의 작업 결과를 시트 한 줄로 바꾼다.

python3 brand/qa_report.py jobs.json run.json appcast.xml out.json
jobs.json = GitHub API runs/{id}/jobs, run.json = runs/{id}
나오는 것: 칸 이름 → 통과/실패/취소/건너뜀, 문제 내용, 공개 버전, 시각(KST).
"""
import json, re, sys
from datetime import datetime, timedelta, timezone

KST = timezone(timedelta(hours=9))
# 시트 칸 순서. (작업 이름 앞부분, 이름에 들어갈 글자) → 칸 이름
COLUMNS = [
    ('랜딩 통일', 'brand /', '공개 사이트'),
    ('앱 macOS 15', 'app /', 'macos-15'),
    ('앱 macOS 26', 'app /', 'macos-26'),
    ('보안 macOS 15', 'security /', 'macos-15'),
    ('보안 macOS 26', 'security /', 'macos-26'),
    ('끌어 옮기기 macOS 15', 'orb /', 'macos-15'),
    ('끌어 옮기기 macOS 26', 'orb /', 'macos-26'),
]
WORD = {'success': '통과', 'failure': '실패', 'cancelled': '취소', 'skipped': '건너뜀',
        'timed_out': '시간 초과', None: '끝나지 않음'}


def kst(s):
    if not s:
        return ''
    return datetime.fromisoformat(s.replace('Z', '+00:00')).astimezone(KST).strftime('%Y-%m-%d %H:%M')


def main(jobs_path, run_path, appcast_path, out_path):
    jobs = json.load(open(jobs_path, encoding='utf-8'))['jobs']
    run = json.load(open(run_path, encoding='utf-8'))
    try:
        vers = re.findall(r'shortVersionString>([^<]+)<', open(appcast_path, encoding='utf-8').read())
        version = vers[0] if vers else ''
    except OSError:
        version = ''

    checks, problems = {}, []
    for col, prefix, needle in COLUMNS:
        hit = [j for j in jobs if j['name'].startswith(prefix) and needle in j['name']]
        if not hit:
            checks[col] = '없음'
            problems.append(f'{col}: 작업이 만들어지지 않음')
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
    json.dump(out, open(out_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)


if __name__ == '__main__':
    main(*sys.argv[1:5])
