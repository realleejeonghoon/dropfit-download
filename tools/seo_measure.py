#!/usr/bin/env python3
"""매일 AI·검색 노출 측정(SEO·GEO·AEO). 표준 라이브러리만 쓴다.

ChatGPT(OpenAI 응답 API + 웹 검색), Gemini(구글 검색 근거), 네이버 블로그·웹 검색 API에
같은 질문을 던지고, 마케팅 시트 '07_AI관측' 22열 형식(머리글 없음, 탭 구분) 한 줄씩 쓴다.
키가 없는 플랫폼은 건너뛰고 그 사실만 적는다. 키 값은 어디에도 찍지 않는다.

사용: python3 tools/seo_measure.py <출력 TSV 경로>
환경 변수: OPENAI_API_KEY, GEMINI_API_KEY, NAVER_CLIENT_ID, NAVER_CLIENT_SECRET
           (선택) OPENAI_MODEL, GEMINI_MODEL
구글 AI 개요·구글 순위(G·P의 GOOGLE_*)는 공식 API가 없어 수동 측정으로 남긴다.
"""
import datetime as dt, json, os, re, sys, time, urllib.parse, urllib.request

KST = dt.timezone(dt.timedelta(hours=9))
NOW = dt.datetime.now(KST)
STAMP = NOW.strftime("%Y%m%dT%H%M")
WEEK = (NOW.date() - dt.timedelta(days=NOW.weekday())).isoformat()
PROFILE, ROUTE = "API-GHA", "API"

# 측정 ID는 수동 측정과 같다(Q001~Q005). Q006~Q010은 '전체 측정일' 문항을 API로는 매일 묻는다.
QUESTIONS = [
    ("Q001", "비브랜드", "ko", "맥에서 사진 용량 줄이는 앱 추천해줘"),
    ("Q002", "비브랜드", "ko", "맥에서 PDF 여러 개 합치는 앱 추천"),
    ("Q003", "브랜드", "ko", "드롭핏 맥 앱이 뭐야?"),
    ("Q004", "비브랜드", "en", "best app to compress images on Mac"),
    ("Q005", "브랜드", "en", "What is Dropfit for Mac?"),
    ("Q006", "비브랜드", "ko", "맥북에서 HEIC를 JPG로 한 번에 바꾸는 방법"),
    ("Q007", "비브랜드", "ko", "맥 이미지 변환 앱 뭐가 좋아?"),
    ("Q008", "비브랜드", "ko", "업로드하지 않고 맥에서 이미지 용량 줄이는 방법"),
    ("Q009", "비브랜드", "en", "convert HEIC to JPG on Mac app"),
    ("Q010", "비브랜드", "en", "merge PDFs on Mac without uploading"),
]
# 네이버: 문제 검색어 P001~P007(수동 측정과 같은 ID) + 브랜드 N001~N002
NAVER_QUERIES = [
    ("P001", "비브랜드", "PDF 합치기"), ("P002", "비브랜드", "맥북 PDF 합치기"),
    ("P003", "비브랜드", "사진 용량 줄이기"), ("P004", "비브랜드", "PDF 용량 줄이기"),
    ("P005", "비브랜드", "이미지 PDF 변환"), ("P006", "비브랜드", "PDF JPG 변환"),
    ("P007", "비브랜드", "사진 업로드 용량 초과"),
    ("N001", "브랜드", "드롭핏"), ("N002", "브랜드", "dropfit"),
]
OWN_HOSTS = ("dropfit.kr", "realleejeonghoon.github.io", "blog.naver.com/miles_cch")
BRANDS = ["ImageOptim", "Clop", "Permute", "Squoosh", "TinyPNG", "PDF Expert", "Smallpdf",
          "iLovePDF", "Zipic", "Smol", "Optimage", "XnConvert", "Adobe Acrobat", "PDFgear",
          "Image Size", "Retrobatch", "Photoscape", "미리보기", "Preview", "Tangerine", "Compressor"]
PRODUCT_WORDS = ("이미지", "사진", "PDF", "변환", "용량", "image", "convert", "HEIC", "compress")
FITNESS_WORDS = ("운동", "피트니스", "fitness", "workout", "헬스")


def clean(s, n=300):
    return re.sub(r"\s+", " ", str(s or "")).strip()[:n]


def post(url, body, headers, timeout=120):
    req = urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json", **headers})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def get(url, headers, timeout=30):
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout) as r:
        return json.load(r)


def err_text(e):
    if hasattr(e, "code"):
        try:
            msg = json.loads(e.read().decode()).get("error", {})
            msg = " ".join(str(msg.get(k, "")) for k in ("message", "details")).strip() if isinstance(msg, dict) else msg
        except Exception:
            msg = ""
        return f"HTTP {e.code} {clean(msg, 120)}"
    return clean(repr(e), 120)


def judge(text, urls):
    """브랜드 언급: 'Dropfit/드롭핏'이 나오고 변환 앱 맥락이며 운동 앱 설명이 아닐 때 1."""
    t = text or ""
    own = [u for u in urls if any(h in u for h in OWN_HOSTS)]
    named = re.search(r"dropfit|드롭핏", t, re.I)
    product = any(w.lower() in t.lower() for w in PRODUCT_WORDS)
    fitness_only = any(w.lower() in t.lower() for w in FITNESS_WORDS) and not own
    mention = 1 if own or (named and product and not fitness_only) else 0
    with_brands = [b for b in BRANDS if b.lower() in t.lower()]
    note = "운동 앱 등 동명 설명" if named and not mention else ""
    return mention, (1 if own else 0), own, [u for u in urls if u not in own], with_brands, note


def row(mid, platform, group, lang, status, **k):
    rid = f"{mid}_{platform}_{STAMP}_1"
    cells = [NOW.strftime("%Y-%m-%d %H:%M"), WEEK, rid, mid, platform, group, lang, "KR", PROFILE, ROUTE, "1",
             status, k.get("aio", ""), k.get("mention", ""), k.get("cited", ""), k.get("rank", ""),
             k.get("depth", "자동판정"), ", ".join(k.get("own", [])[:3]), ", ".join(k.get("ext", [])[:5]),
             ", ".join(k.get("brands", [])), clean(k.get("evidence", "")), clean(k.get("memo", ""), 160)]
    return "\t".join(c.replace("\t", " ").replace("\n", " ") for c in cells)


def chatgpt(q, lang):
    key = os.environ["OPENAI_API_KEY"]
    models = [m for m in [os.environ.get("OPENAI_MODEL"), "gpt-5-mini", "gpt-4.1-mini"] if m]
    last = None
    for model in models:
        for tool in ("web_search", "web_search_preview"):
            try:
                d = post("https://api.openai.com/v1/responses",
                         {"model": model, "input": q, "tools": [{"type": tool}]},
                         {"Authorization": f"Bearer {key}"})
            except Exception as e:  # 모델·도구 이름이 바뀌었을 때 다음 후보로
                last = err_text(e)
                if getattr(e, "code", 0) in (400, 404):
                    continue
                raise RuntimeError(last)
            text, urls = [], []
            for item in d.get("output", []):
                for c in item.get("content", []) or []:
                    if c.get("type") == "output_text":
                        text.append(c.get("text", ""))
                        urls += [a.get("url", "") for a in c.get("annotations", []) if a.get("url")]
            return " ".join(text), list(dict.fromkeys(urls)), f"{model}/{tool}"
    raise RuntimeError(last or "모델 없음")


def gemini(q, lang):
    key = os.environ["GEMINI_API_KEY"]
    models = [m for m in [os.environ.get("GEMINI_MODEL"), "gemini-2.5-flash", "gemini-flash-latest"] if m]
    last = None
    for model in models:
        try:
            d = post(f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
                     {"contents": [{"parts": [{"text": q}]}], "tools": [{"google_search": {}}]},
                     {"x-goog-api-key": key})
        except Exception as e:
            last = err_text(e)
            if getattr(e, "code", 0) in (400, 404):
                continue
            raise RuntimeError(last)
        cand = (d.get("candidates") or [{}])[0]
        text = " ".join(p.get("text", "") for p in cand.get("content", {}).get("parts", []))
        chunks = cand.get("groundingMetadata", {}).get("groundingChunks", []) or []
        # 근거 주소는 구글 중계 주소라, 출처 이름(대개 도메인)을 함께 남긴다
        urls = [c.get("web", {}).get("title") or c.get("web", {}).get("uri", "") for c in chunks]
        return text, list(dict.fromkeys(u for u in urls if u)), model
    raise RuntimeError(last or "모델 없음")


def naver(kind, q):
    # 2026-09부터 검색 API는 NAVER API HUB(네이버 클라우드)로 옮겨 감. 개발자센터 키는 쓸 수 없음
    h = {"X-NCP-APIGW-API-KEY-ID": os.environ["NAVER_CLIENT_ID"], "X-NCP-APIGW-API-KEY": os.environ["NAVER_CLIENT_SECRET"]}
    d = get(f"https://naverapihub.apigw.ntruss.com/search/v1/{kind}?" + urllib.parse.urlencode({"query": q, "display": 100, "format": "json"}), h)
    items = d.get("items", [])
    for i, it in enumerate(items, 1):
        link = (it.get("link", "") + " " + it.get("bloggerlink", "")).lower()
        if any(h_ in link for h_ in OWN_HOSTS):
            return i, it.get("link", ""), len(items)
    return None, "", len(items)


def main(out):
    have = lambda *ks: all(os.environ.get(k) for k in ks)
    lines, skipped = [], []
    for name, fn, keys in (("CHATGPT", chatgpt, ("OPENAI_API_KEY",)), ("GEMINI", gemini, ("GEMINI_API_KEY",))):
        if not have(*keys):
            skipped.append(name)
            continue
        for mid, group, lang, q in QUESTIONS:
            try:
                text, urls, used = fn(q, lang)
                m, c, own, ext, br, note = judge(text, urls)
                lines.append(row(mid, name, group, lang, "정상", mention=str(m), cited=str(c), own=own, ext=ext,
                                 brands=br, evidence=text, memo=" · ".join(x for x in (used, note) if x)))
            except Exception as e:
                lines.append(row(mid, name, group, lang, "오류", depth="", memo=err_text(e)))
            time.sleep(1)
    if have("NAVER_CLIENT_ID", "NAVER_CLIENT_SECRET"):
        for kind, plat in (("blog", "NAVER_BLOG"), ("webkr", "NAVER_WEB")):
            for mid, group, q in NAVER_QUERIES:
                try:
                    rank, link, n = naver(kind, q)
                    lines.append(row(mid, plat, group, "ko", "정상", mention="1" if rank else "0",
                                     cited="1" if rank else "0", rank=str(rank or ""), own=[link] if link else [],
                                     depth=f"상위 {n}개", evidence=f"검색어: {q}"))
                except Exception as e:
                    lines.append(row(mid, plat, group, "ko", "오류", depth="", memo=err_text(e)))
                time.sleep(0.2)
    else:
        skipped.append("NAVER")
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))
    errs = {}
    for l in lines:
        c = l.split("\t")
        if c[11] == "오류":
            errs.setdefault(f"{c[4]}: {c[21]}", 0)
            errs[f"{c[4]}: {c[21]}"] += 1
    for k, n in errs.items():  # 오류 문구만(키 값은 err_text가 담지 않음)
        print(f"오류 {n}건 · {k}")
    ok = sum("\t정상\t" in l for l in lines)
    mention = sum(l.split("\t")[13] == "1" for l in lines if "\t정상\t" in l)
    print(f"측정 {len(lines)}줄 · 정상 {ok} · 언급·노출 {mention} · 키 없어 건너뜀: {', '.join(skipped) or '없음'}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as s:
            s.write(f"### AI·검색 측정 {NOW:%Y-%m-%d %H:%M} KST\n- {len(lines)}줄, 정상 {ok}, 언급·노출 {mention}\n"
                    f"- 키 없어 건너뜀: {', '.join(skipped) or '없음'}\n")
    return 0 if ok or not lines else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else f"data/seo/07_AI관측-{NOW:%Y-%m-%d}-22열.tsv"))
