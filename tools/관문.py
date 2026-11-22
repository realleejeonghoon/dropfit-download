#!/usr/bin/env python3
"""관문: 바뀐 파일을 규정.json으로 검사한다. 의존성 없음(표준 라이브러리만).
사용: python3 tools/관문.py [기준가지, 기본 origin/main]
CI에서는 PR_BODY 환경 변수(PR 본문)를 확정 표시 검사에 쓴다."""
import fnmatch, json, os, subprocess, sys

ROOT = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip() or "."
os.chdir(ROOT)
R = json.load(open("규정.json", encoding="utf-8"))
base = sys.argv[1] if len(sys.argv) > 1 else "origin/main"

def git(*a):
    return subprocess.run(["git", "-c", "core.quotepath=false", *a], capture_output=True, text=True).stdout

def match(path, pats):
    return any(fnmatch.fnmatch(path, p) or (p.endswith("/**") and path.startswith(p[:-3] + "/")) for p in pats)

changed = [l for l in git("diff", "--name-only", f"{base}...HEAD").splitlines() if l]
added = set(git("diff", "--name-only", "--diff-filter=A", f"{base}...HEAD").splitlines())
note = os.environ.get("PR_BODY", "") + "\n" + git("log", "--format=%B", f"{base}..HEAD")
confirmed = R["확정표시"] in note

problems, warns, tools, areas = [], [], [], {}
# 검사 약화: 더해진 줄에 건너뛰기·실패 무시 표시가 있거나 점검 파일이 지워짐
cur = ""
for line in git("diff", "-U0", f"{base}...HEAD").splitlines():
    if line.startswith("+++ "):
        cur = line[6:] if line.startswith("+++ b/") else ""
        continue
    if cur in ("규정.json", "tools/관문.py"):
        continue
    if line.startswith("+") and any(k in line for k in R["검사약화_표시"]):
        problems.append(f"검사 약화 의심: {line[1:].strip()[:80]} (정훈 님 확정 필요)")
for f in git("diff", "--name-only", "--diff-filter=D", f"{base}...HEAD").splitlines():
    if any(match(f, a["보호"]) for a in R["영역"]):
        problems.append(f"보호 파일 삭제: {f}")
for f in changed:
    if match(f, R["영역밖_무시"]):
        continue
    hit = [a for a in R["영역"] if match(f, a["범위"])]
    if not hit:
        warns.append(f"영역 없음: {f} (규정.json 범위에 넣거나 범위 밖 변경인지 확인)")
        continue
    a = hit[0]
    areas.setdefault(a["이름"], []).append(f)
    for t in a["1차"]:
        if t not in tools:
            tools.append(t)
    if f not in added and any(match(f, x["보호"]) for x in hit):
        base_name = os.path.basename(f.rstrip("/"))
        has_backup = any(p.startswith(R["백업폴더"]) and os.path.basename(p) == base_name for p in added)
        if not has_backup:
            problems.append(f"보호 파일 백업 없음: {f} → {R['백업폴더']}<버전>-빌드<번호>-<무엇>전/{base_name}")
        if not confirmed:
            problems.append(f"보호 파일 확정 표시 없음: {f} → PR 본문이나 커밋에 '{R['확정표시']} 날짜 정훈 님 결정' 한 줄")

print(f"관문 · 기준 {base} · 바뀐 파일 {len(changed)}개 · 모드 {R['모드']}")
for n, fs in areas.items():
    print(f"  영역 {n}: {len(fs)}개")
failed_tools = []
for t in tools:
    r = subprocess.run(t, shell=True, capture_output=True, text=True)
    ok = r.returncode == 0
    print(f"  1차 {'✓' if ok else '✗'} {t}")
    if not ok:
        failed_tools.append(t)
        print("    " + "\n    ".join((r.stdout + r.stderr).strip().splitlines()[-5:]))
problems += [f"1차 실패: {t}" for t in failed_tools]
for p in problems:
    print(f"  ✗ {p}")
for w in warns:
    print(f"  ! {w}")
print(f"결과: 막음 {len(problems)}건 · 경고 {len(warns)}건")
summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a", encoding="utf-8") as s:
        s.write(f"### 관문 막음 {len(problems)}건 · 경고 {len(warns)}건\n" + "".join(f"- ✗ {p}\n" for p in problems) + "".join(f"- ! {w}\n" for w in warns))
sys.exit(1 if problems else 0)
