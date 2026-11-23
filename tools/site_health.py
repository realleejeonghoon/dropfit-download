#!/usr/bin/env python3
"""dropfit.kr 검색 노출 매일 점검 (토큰·Mac 없음, GitHub Actions에서 실행).

잡는 오류(11/23 실제로 나온 것들):
  1) 사이트맵에 있는 쪽이 200이 아니거나 noindex·다른 주소 canonical이라 색인될 수 없음
  2) robots.txt가 검색·AI 로봇을 막음
  3) 자바스크립트를 안 돌리는 로봇에게 판매 상태가 틀리게 보임(정적 data-sale 값이 날짜와 다름)
  4) 사이트 저장소에 있는 가이드가 사이트맵에 빠짐 (--site <dropfit-site 경로>)
  5) llms.txt가 안 열림

사용: python3 tools/site_health.py [--site 경로] [--out 결과.tsv]
하나라도 ✗이면 종료 코드 1 → GitHub가 실패 메일을 보낸다.
"""
import argparse, datetime, os, re, sys, time, urllib.request, urllib.error

BASE = "https://dropfit.kr"
UA = {"googlebot": "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
      "gptbot": "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)"}
KST = datetime.timezone(datetime.timedelta(hours=9))
NOINDEX_OK = {"/pro/", "/en/pro/", "/activate/", "/en/activate/"}  # 일부러 noindex, 사이트맵에 넣지 않는 쪽

fails, rows = [], []


def get(url, ua="googlebot", tries=3):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA[ua]})
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status, dict(r.headers), r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers or {}), ""
        except Exception as e:  # 네트워크 흔들림은 다시 시도
            if i == tries - 1:
                return 0, {}, str(e)
            time.sleep(3)


def bad(what, detail):
    fails.append(f"✗ {what}: {detail}")


def expected_sale(now):
    # 기념가 ~2026-12-31 23:59 KST, 이후 정가. (사이트 head 스크립트와 같은 기준)
    return "launch" if now < datetime.datetime(2027, 1, 1, tzinfo=KST) else "regular"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--site")
    ap.add_argument("--out")
    a = ap.parse_args()
    now = datetime.datetime.now(KST)

    st, _, robots = get(BASE + "/robots.txt")
    if st != 200:
        bad("robots.txt", f"응답 {st}")
    else:
        agent, blocked = None, []
        for line in robots.splitlines():
            k, _, v = line.partition(":")
            k, v = k.strip().lower(), v.strip()
            if k == "user-agent":
                agent = v
            elif k == "disallow" and v == "/":
                blocked.append(agent)
        if blocked:
            bad("robots.txt", f"전체 차단: {', '.join(map(str, blocked))}")

    st, _, sm = get(BASE + "/sitemap.xml")
    locs = re.findall(r"<loc>\s*([^<\s]+)\s*</loc>", sm) if st == 200 else []
    if not locs:
        bad("sitemap.xml", f"응답 {st}, 주소 {len(locs)}개")

    for url in locs:
        path = url.replace(BASE, "") or "/"
        st, hd, html = get(url)
        robots_hdr = (hd.get("X-Robots-Tag") or hd.get("x-robots-tag") or "").lower()
        meta = re.search(r'<meta[^>]+name=["\']robots["\'][^>]*content=["\']([^"\']+)', html, re.I)
        canon = re.search(r'<link[^>]+rel=["\']canonical["\'][^>]*href=["\']([^"\']+)', html, re.I)
        note = []
        if st != 200:
            note.append(f"응답 {st}")
        if "noindex" in robots_hdr or (meta and "noindex" in meta.group(1).lower()):
            note.append("noindex")
        if canon and canon.group(1) != url:
            note.append(f"canonical→{canon.group(1)}")
        if st == 200 and not canon:
            note.append("canonical 없음")
        for n in note:
            bad(path, n)
        rows.append((path, str(st), "ok" if not note else ";".join(note)))

    want = expected_sale(now)
    for path, soon in (("/", "곧 판매 시작"), ("/en/", "Coming soon")):
        st, _, html = get(BASE + path)
        m = re.search(r'<html[^>]*data-sale=["\'](\w+)', html)
        got = m.group(1) if m else "없음"
        if got != want:
            bad(f"{path} 정적 판매 상태", f"data-sale={got}, 오늘 기준 {want} (JS 없는 로봇에 '{soon}'로 보임)")
        rows.append((path + " data-sale", got, "ok" if got == want else f"want {want}"))

    st, _, _ = get(BASE + "/llms.txt", ua="gptbot")
    if st != 200:
        bad("/llms.txt", f"GPTBot 응답 {st}")

    if a.site:
        have = {u.replace(BASE, "") for u in locs}
        for root, _, files in os.walk(a.site):
            rel = os.path.relpath(root, a.site).replace(os.sep, "/")
            if "index.html" in files and re.match(r"^(en/)?guide(/|$)", rel) and "backup" not in rel:
                p = "/" + rel + "/"
                if p not in have:
                    bad("사이트맵 빠짐", p)

    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write("시각\t주소\t응답\t판정\n")
            for r in rows:
                f.write(now.strftime("%Y-%m-%d %H:%M") + "\t" + "\t".join(r) + "\n")

    print(f"dropfit.kr 검색 노출 점검 {now:%Y-%m-%d %H:%M} KST · 사이트맵 {len(locs)}쪽")
    if fails:
        print("\n".join(fails))
        sys.exit(1)
    print("✓ 전부 통과 (robots·사이트맵 응답·noindex·canonical·정적 판매 상태·llms.txt)")


if __name__ == "__main__":
    main()
