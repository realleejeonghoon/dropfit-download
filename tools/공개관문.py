#!/usr/bin/env python3
"""공개 관문: appcast.xml을 바꾸는 PR(새 버전 공개)은 같은 앱 버전으로 돈 '언어판 화면 점검'(lang-shots.yml)이
성공했고 세 언어 창 크기 다름이 0건일 때만 통과한다(정훈 님 2026-11-26 01:05 "이것 좀 지키자 제발").
1.0.2 때 이미 보인 크기 차이를 '결정 대기'로 두고 공개했다가 같은 날 1.0.3을 또 낸 일을 장치로 막는다.
사용: python3 tools/공개관문.py [기준가지, 기본 origin/main]  (GH_TOKEN·GITHUB_REPOSITORY 필요, CI 전용)
통과 근거를 찾는 법: lang-shots를 src=<Dropfit 가지>로 돌리면 기록에 '결과: 장면 N개 · 크기 다름·빠짐 0건 · 앱 <버전>(<빌드>)'가 남는다."""
import json, os, re, subprocess, sys

base = sys.argv[1] if len(sys.argv) > 1 else "origin/main"
repo = os.environ.get("GITHUB_REPOSITORY", "realleejeonghoon/dropfit-download")

def run(*a):
    return subprocess.run(a, capture_output=True, text=True)

changed = run("git", "diff", "--name-only", f"{base}...HEAD").stdout.split()
if "appcast.xml" not in changed:
    print("공개 관문: appcast.xml이 바뀌지 않음 (새 버전 공개 아님) · 통과")
    sys.exit(0)

feed = open("appcast.xml", encoding="utf-8").read()
ver = re.search(r"<sparkle:shortVersionString>([^<]+)<", feed)
build = re.search(r"<sparkle:version>([^<]+)<", feed)
if not (ver and build):
    print("✗ 공개 관문: appcast.xml에서 버전을 읽지 못함"); sys.exit(1)
want = f"앱 {ver.group(1)}({build.group(1)})"
print(f"공개 관문: 새 공개 {want} · 같은 버전의 언어판 화면 점검(세 언어 크기 다름 0건)을 찾습니다")

def gh(path):
    r = run("gh", "api", path)
    return r.stdout if r.returncode == 0 else ""

runs = json.loads(gh(f"repos/{repo}/actions/workflows/lang-shots.yml/runs?status=success&per_page=15") or "{}").get("workflow_runs", [])
for r in runs:
    jobs = json.loads(gh(f"repos/{repo}/actions/runs/{r['id']}/jobs") or "{}").get("jobs", [])
    for j in jobs:
        log = gh(f"repos/{repo}/actions/jobs/{j['id']}/logs")
        m = re.search(r"결과: 장면 (\d+)개 · 크기 다름·빠짐 (\d+)건 · " + re.escape(want), log)
        if m and m.group(2) == "0" and int(m.group(1)) > 0:
            print(f"  ✓ {r['html_url']} · 장면 {m.group(1)}개 · 크기 다름 0건 · {want}")
            sys.exit(0)

print(f"  ✗ {want}로 돈 언어판 화면 점검 성공 기록이 없습니다 (최근 성공 {len(runs)}개 확인).")
print("    lang-shots.yml을 inputs src=<이 버전의 Dropfit 가지>로 돌려 세 언어 크기 다름 0건을 만든 뒤 다시 돌려 주세요.")
print("    점검에서 보인 높이·여백·간격·문구 문제는 '결정 대기'로 두지 않고 이 공개에 고쳐 넣습니다(AGENTS.md 디자인 정밀 규칙).")
sys.exit(1)
