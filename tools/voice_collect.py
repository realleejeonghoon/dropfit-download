#!/usr/bin/env python3
"""고객의 말 매일 수집 (2026-11-25, 정훈 님 "글에서 이런 사람을 매일 서치하고 데이터를 수집해야해")

드롭핏이 푸는 고객 문제(P01~P18, 기준 문서 '드롭핏 고객 문제 목록')를 실제로 겪는 사람의 글을
공식 API·공개 피드에서만 모아, 문제 번호·언어·날짜·원문 발췌·출처 링크로 남긴다.
사람·Claude 토큰·정훈 님 Mac을 쓰지 않는다(GitHub Actions 매일 예약).

지키는 것
- 개인 식별 정보는 저장하지 않는다: 글쓴이 이름·아이디·프로필은 받지 않고, 발췌 안의 메일·전화·@아이디·주소는 가린다.
- 수집한 사람에게 연락하지 않는다(KISA). 이 파일은 원고가 '고객의 말'로 쓰이도록 표현과 빈도를 쌓는 용도다.
- 네이버 검색 API는 약관 7.3③(API로 얻은 정보의 저장·캐시 금지)에 따라 글 내용·링크를 저장하지 않고,
  문제 검색어별 전체 글 수(total)만 날마다 적어 하루 증가량을 본다.
- Reddit은 상업 이용에 서면 승인이 필요해(2025-11부터 새 클라이언트 승인제) 넣지 않는다.

출처: Stack Exchange(Ask Different·Super User, 내용 CC BY-SA), Hacker News(Algolia 공개 API),
      Qiita(공개 API, ja), 게시판 공개 RSS(MacRumors·클리앙·뽐뿌·하테나), 네이버 검색 API(숫자만, ko).
      Bluesky 공개 검색은 클라우드에서 403이라 꺼 둠(VOICE_BLUESKY=1로 켬)

사용: python3 tools/voice_collect.py <출력 폴더> [이전 기록 폴더]
환경 변수: NAVER_CLIENT_ID, NAVER_CLIENT_SECRET(없으면 네이버 건너뜀), VOICE_DAYS(기본 2)
"""
import datetime as dt, hashlib, json, os, re, sys, time, urllib.parse, urllib.request, gzip

KST = dt.timezone(dt.timedelta(hours=9))
NOW = dt.datetime.now(KST)
TODAY = NOW.strftime("%Y-%m-%d")
DAYS = int(os.environ.get("VOICE_DAYS", "2"))
SINCE = NOW - dt.timedelta(days=DAYS)
UA = "dropfit-voice-research/1.0 (+https://dropfit.kr)"

# ── 문제 분류 규칙: 위에서부터 먼저 걸리는 번호 하나. (번호, 정규식) 소문자 본문에 맞춤 ──
RULES = [
    ("P12", r"증명사진|여권 ?사진|passport photo|id photo|visa photo|証明写真|パスポート写真"),
    ("P15", r"\bsvg\b|\.ai\b|illustrator|일러스트 파일|\bpsd\b|イラレ"),
    ("P14", r"오프라인|인터넷 (없|안 되|차단)|사내망|offline|no internet|air.?gapped|オフライン|ネット(なし|接続なし)"),
    ("P18", r"실습실|여러 대|lab mac|computer lab|classroom mac|every mac in|複数台|パソコン室"),
    ("P16", r"첨부.{0,8}(용량|초과|25 ?mb)|attachment.{0,20}(too (large|big)|limit|25 ?mb)|添付.{0,8}(容量|上限|25)"),
    ("P01", r"heic|heif"),
    ("P08", r"webp"),
    ("P02", r"pdf.{0,12}(합치|합본|병합|하나로|묶)|(합치|병합).{0,6}pdf|(merge|combine|join).{0,15}pdfs?|pdfs?.{0,10}(merge|combin)|pdf.{0,6}(結合|まとめ|1つに|一つに)"),
    ("P04", r"pdf.{0,12}(용량|압축|줄이|크기|mb)|(compress|reduce|shrink).{0,15}pdf|pdf.{0,15}(too (large|big)|file size|smaller)|pdf.{0,6}(圧縮|容量|軽く|小さく)"),
    ("P05", r"pdf.{0,10}(jpg|jpeg|png|이미지로|사진으로)|pdf (to|into) (jpg|jpeg|png|image)|pdf.{0,6}(画像|jpg|jpeg|png)"),
    ("P06", r"(사진|이미지|jpg|jpeg|png|스캔).{0,10}pdf|(images?|photos?|jpe?gs?|pngs?|scans?) (to|into) (a )?pdf|(写真|画像|jpg|png).{0,6}pdf"),
    ("P07", r"png.{0,8}(jpg|jpeg)|(jpg|jpeg)만|jpg only|only (accepts?|allows?) jpe?g|png.{0,6}(jpg|jpeg)"),
    ("P11", r"(자르|크롭|비율).{0,10}(여러|일괄|한꺼번에)|(여러|일괄).{0,10}(자르|크롭)|batch crop|crop (multiple|many|all)|一括.{0,6}(トリミング|切り抜)"),
    ("P09", r"폴더.{0,10}(통째|한꺼번에|일괄|전부)|(수백|수십) ?장|batch convert|bulk convert|convert (a )?(whole |entire )?folder|hundreds of (photos|images)|一括(変換|処理)|フォルダごと"),
    ("P03", r"(사진|이미지|jpg).{0,12}(용량|압축|줄이|mb 이하|리사이즈)|(reduce|compress|shrink|resize).{0,15}(photos?|images?|pictures?|jpe?gs?)|(photos?|images?).{0,15}(too (large|big)|under \d+ ?mb|file size)|(写真|画像).{0,8}(容量|圧縮|小さく|軽く|リサイズ)"),
    ("P10", r"(규격|사이즈).{0,10}(매번|다시)|(every|each) (site|platform) (has|wants) (a )?different|毎回.{0,8}(サイズ|形式)"),
    ("P13", r"(올리기|업로드).{0,10}(찜찜|꺼려|불안)|(don'?t|do not) want to upload|privacy.{0,20}(online|upload) (tool|converter)|アップロード.{0,8}(不安|怖)"),
    ("P17", r"원본.{0,6}(덮어|사라)|overwr(ote|ite).{0,15}original|元の(ファイル|画像).{0,8}(上書き|消え)"),
]
RULES = [(p, re.compile(r, re.I)) for p, r in RULES]

PAIN = re.compile(
    r"안 ?(돼|되|올라|열려|열리)|어떻게|방법|못 ?(하|해|올)|불편|짜증|초과|넘어|제한|도와|급해|막혀|지원하지 않는"
    r"|can'?t|cannot|won'?t|how (do|can|to|would)|unable|too (large|big)|exceed|limit|annoying|frustrat|help|is there (a|any) way|struggl|keeps? failing|not supported|unsupported"
    r"|できない|できません|方法|どうやって|どうすれば|困|教えて|開けない|上限|超え|対応していない", re.I)
# 지금 쓰는 대안(정훈 님 11/25 "기존 대안과 다르게 어떻게 깔끔하게 끝내는지"): 글에 나온 것만 적는다
ALTS = [("미리보기", r"미리보기|preview\.app|\bpreview\b|プレビュー"), ("사진 앱", r"사진 앱|photos app|写真アプリ"),
        ("단축어·자동화", r"단축어|shortcuts?|automator|ショートカット"), ("터미널·sips", r"\bsips\b|terminal|imagemagick|ffmpeg|ターミナル"),
        ("iLovePDF", r"ilovepdf"), ("Smallpdf", r"smallpdf"), ("변환 사이트", r"변환 사이트|online converter|converter site|変換サイト|オンライン変換"),
        ("Acrobat", r"acrobat|어크로뱃|アクロバット"), ("Photoshop", r"photoshop|포토샵|フォトショ"), ("ImageOptim", r"imageoptim"),
        ("캡처", r"캡처|캡쳐|screenshot|スクショ")]
ALTS = [(n, re.compile(r, re.I)) for n, r in ALTS]
MAC = re.compile(r"\bmac|macbook|imac|macos|맥북|맥|아이맥|맥os|マック|マックブック", re.I)

# ── 검색어(출처별). 영어 Stack Exchange·HN, 일본어 Qiita, Bluesky 3개 언어 ──
SE_QUERIES = ["heic", "webp", "merge pdf", "combine pdf", "compress pdf", "reduce pdf size", "pdf to jpg",
              "images to pdf", "png to jpg", "batch convert images", "batch resize", "crop multiple images",
              "svg to png", "file too large upload", "passport photo size"]
HN_QUERIES = ["heic mac", "convert heic", "merge pdf mac", "compress pdf mac", "batch convert images mac", "webp mac"]
BSKY_QUERIES = {
    "en": ["heic", "webp jpg", "merge pdf", "compress pdf", "pdf too large", "batch convert images mac"],
    "ja": ["HEIC", "webp 変換", "PDF 結合", "PDF 圧縮", "画像 一括 変換", "写真 容量"],
    "ko": ["HEIC", "PDF 합치기", "PDF 용량", "사진 용량", "webp 변환"],
}
QIITA_QUERIES = ["HEIC", "PDF 結合 Mac", "PDF 圧縮 Mac", "画像 一括変換 Mac", "webp 変換 Mac"]
# 네이버(숫자만): 문제 번호 → 검색어
NAVER_QUERIES = [("P01", "HEIC JPG 변환"), ("P01", "아이폰 사진 HEIC 업로드 안됨"), ("P02", "PDF 합치기"),
                 ("P03", "사진 용량 줄이기"), ("P04", "PDF 용량 줄이기"), ("P05", "PDF JPG 변환"),
                 ("P06", "사진 PDF 변환"), ("P07", "PNG JPG 변환"), ("P08", "WEBP JPG 변환"),
                 ("P09", "사진 여러장 한번에 변환"), ("P11", "사진 여러장 한번에 자르기"),
                 ("P12", "증명사진 용량 줄이기"), ("P16", "메일 첨부 용량 초과")]

HEAD = ["수집일", "출처", "언어", "문제", "검색어", "글 날짜", "제목", "원문 발췌", "링크", "고통 신호", "맥 언급", "쓰는 대안"]
COUNT_HEAD = ["수집일", "언어", "문제", "출처", "새 글", "고통 신호 글", "맥 언급 글"]
NAVER_HEAD = ["수집일", "문제", "종류", "검색어", "전체 글 수", "전날 대비"]
STATUS_HEAD = ["수집일", "출처", "상태", "요청", "받은 글", "새 글", "메모"]


def get_json(url, headers=None, timeout=30):
    h = {"User-Agent": UA, "Accept": "application/json", "Accept-Encoding": "gzip"}
    h.update(headers or {})
    with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=timeout) as r:
        b = r.read()
        if r.headers.get("Content-Encoding") == "gzip" or b[:2] == b"\x1f\x8b":
            b = gzip.decompress(b)
        return json.loads(b.decode("utf-8"))


def strip_html(s):
    s = re.sub(r"<[^>]+>", " ", s or "")
    for a, b in (("&quot;", '"'), ("&#39;", "'"), ("&#x27;", "'"), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")):
        s = s.replace(a, b)
    return re.sub(r"\s+", " ", s).strip()


def mask(s):
    s = re.sub(r"[\w.+-]+@[\w-]+\.[\w.]+", "[메일]", s)
    s = re.sub(r"https?://\S+", "[주소]", s)
    s = re.sub(r"(?<![\w])@[\w.]{2,}", "@[아이디]", s)
    s = re.sub(r"\+?\d[\d\s().-]{8,}\d", "[번호]", s)
    return s


def excerpt(text, n=240):
    text = mask(strip_html(text))
    if len(text) <= n:
        return text
    m = None
    for _, rx in RULES:
        m = rx.search(text)
        if m:
            break
    start = max(0, (m.start() - n // 3) if m else 0)
    out = text[start:start + n]
    return ("…" if start else "") + out + "…"


def classify(text):
    for p, rx in RULES:
        if rx.search(text):
            return p
    return ""


def key(link):
    return hashlib.sha1(link.encode()).hexdigest()[:16]


class Run:
    def __init__(self, prev_dir):
        self.rows, self.status = [], []
        self.seen = set()
        if prev_dir:
            f = os.path.join(prev_dir, "seen.txt")
            if os.path.exists(f):
                self.seen = set(open(f).read().split())
        self.new_keys = set()

    def add(self, source, lang, query, date, title, body, link):
        k = key(link)
        if k in self.seen or k in self.new_keys:
            return 0
        text = f"{title} {body}"
        p = classify(text.lower())
        if not p:
            return 0
        self.new_keys.add(k)
        self.rows.append([TODAY, source, lang, p, query, date, mask(strip_html(title))[:160], excerpt(body or title),
                          link, "1" if PAIN.search(text) else "0", "1" if MAC.search(text) else "0",
                          ", ".join(n for n, rx in ALTS if rx.search(text))])
        return 1

    def note(self, source, ok, req, got, new, memo=""):
        self.status.append([TODAY, source, ok, str(req), str(got), str(new), memo[:200]])


def err(e):
    code = getattr(e, "code", "")
    return f"{type(e).__name__} {code}".strip()


def stackexchange(run):
    # 질문이 하루 몇 건뿐이라 최소 7일을 보고 중복은 seen으로 거름
    since = int(min(SINCE, NOW - dt.timedelta(days=7)).timestamp())
    for site, label, need_mac in (("apple", "Ask Different", False), ("superuser", "Super User", True)):
        req = got = new = 0
        memo = ""
        for q in SE_QUERIES:
            qq = q + (" mac" if need_mac else "")
            url = "https://api.stackexchange.com/2.3/search/excerpts?" + urllib.parse.urlencode(
                {"order": "desc", "sort": "creation", "q": qq, "site": site, "fromdate": since, "pagesize": 30})
            try:
                d = get_json(url); req += 1
            except Exception as e:
                memo = err(e); break
            for it in d.get("items", []):
                if it.get("item_type") != "question":
                    continue
                got += 1
                link = f"https://{site}.stackexchange.com/q/{it['question_id']}" if site == "apple" else f"https://superuser.com/q/{it['question_id']}"
                date = dt.datetime.fromtimestamp(it.get("creation_date", 0), KST).strftime("%Y-%m-%d")
                new += run.add(label, "en", q, date, it.get("title", ""), it.get("excerpt", ""), link)
            if d.get("backoff"):
                time.sleep(int(d["backoff"]) + 1)
            if d.get("quota_remaining", 99) < 5:
                memo = "할당량 거의 다 씀"; break
            time.sleep(0.4)
        run.note(label, "정상" if req else "오류", req, got, new, memo)


def hackernews(run):
    since = int(SINCE.timestamp())
    req = got = new = 0; memo = ""
    for q in HN_QUERIES:
        url = "https://hn.algolia.com/api/v1/search_by_date?" + urllib.parse.urlencode(
            {"query": q, "tags": "(story,comment)", "numericFilters": f"created_at_i>{since}", "hitsPerPage": 50})
        try:
            d = get_json(url); req += 1
        except Exception as e:
            memo = err(e); break
        for h in d.get("hits", []):
            got += 1
            link = f"https://news.ycombinator.com/item?id={h.get('objectID')}"
            new += run.add("Hacker News", "en", q, (h.get("created_at") or "")[:10],
                           h.get("title") or h.get("story_title") or "", h.get("comment_text") or h.get("story_text") or "", link)
        time.sleep(0.3)
    run.note("Hacker News", "정상" if req else "오류", req, got, new, memo)


def bluesky(run):
    since = SINCE.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    for lang, qs in BSKY_QUERIES.items():
        req = got = new = 0; memo = ""
        for q in qs:
            url = "https://public.api.bsky.app/xrpc/app.bsky.feed.searchPosts?" + urllib.parse.urlencode(
                {"q": q, "lang": lang, "since": since, "sort": "latest", "limit": 50})
            try:
                d = get_json(url); req += 1
            except Exception as e:
                memo = err(e); break
            for p in d.get("posts", []):
                got += 1
                uri = p.get("uri", "")  # at://did:plc:…/app.bsky.feed.post/rkey — 아이디(handle) 대신 DID로 링크
                m = re.match(r"at://([^/]+)/app\.bsky\.feed\.post/(\w+)", uri)
                if not m:
                    continue
                link = f"https://bsky.app/profile/{m.group(1)}/post/{m.group(2)}"
                rec = p.get("record", {})
                new += run.add("Bluesky", lang, q, (rec.get("createdAt") or "")[:10], "", rec.get("text", ""), link)
            time.sleep(0.5)
        run.note(f"Bluesky {lang}", "정상" if req else "오류", req, got, new, memo)


def qiita(run):
    since = SINCE.strftime("%Y-%m-%d")
    req = got = new = 0; memo = ""
    for q in QIITA_QUERIES:
        url = "https://qiita.com/api/v2/items?" + urllib.parse.urlencode({"query": f"{q} created:>={since}", "per_page": 20})
        try:
            d = get_json(url); req += 1
        except Exception as e:
            memo = err(e); break
        for it in d if isinstance(d, list) else []:
            got += 1
            body = (it.get("body") or "")[:3000]
            new += run.add("Qiita", "ja", q, (it.get("created_at") or "")[:10], it.get("title", ""), body, it.get("url", ""))
        time.sleep(1.0)
    run.note("Qiita", "정상" if req else "오류", req, got, new, memo)


# 공개 RSS(게시판이 구독용으로 내놓은 피드). 최신 글 몇십 개만 오므로 매일 읽어 거른다.
RSS = [
    ("MacRumors 포럼", "en", "https://forums.macrumors.com/forums/-/index.rss"),
    ("클리앙 맥당", "ko", "https://www.clien.net/service/board/cm_mac/rss"),
    ("뽐뿌 맥포럼", "ko", "https://www.ppomppu.co.kr/rss.php?id=mac"),
    ("하테나 북마크", "ja", "https://b.hatena.ne.jp/search/text?q=HEIC&mode=rss"),
    ("하테나 북마크", "ja", "https://b.hatena.ne.jp/search/text?q=PDF%20%E7%B5%90%E5%90%88&mode=rss"),
    ("하테나 북마크", "ja", "https://b.hatena.ne.jp/search/text?q=PDF%20%E5%9C%A7%E7%B8%AE&mode=rss"),
]


def rss(run):
    import xml.etree.ElementTree as ET
    stat = {}
    for label, lang, url in RSS:
        st = stat.setdefault(label, [0, 0, 0, ""])
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Encoding": "gzip"})
            with urllib.request.urlopen(req, timeout=30) as r:
                b = r.read()
            if b[:2] == b"\x1f\x8b":
                b = gzip.decompress(b)
            try:
                root = ET.fromstring(b)
            except ET.ParseError:  # 뽐뿌처럼 EUC-KR 피드: 한글 코드로 읽고 머리 선언을 뺀 뒤 다시
                txt = b.decode("cp949", "replace")
                root = ET.fromstring(re.sub(r"^<\?xml[^>]*\?>", "", txt.strip()).encode("utf-8"))
            st[0] += 1
        except Exception as e:
            st[3] = err(e); continue
        items = root.findall(".//item") or root.findall(".//{http://purl.org/rss/1.0/}item") or root.findall(".//{http://www.w3.org/2005/Atom}entry")
        for it in items:
            def t(*names):
                for n in names:
                    for el in it.iter():
                        if el.tag.split("}")[-1] == n and (el.text or el.get("href")):
                            return el.text or el.get("href")
                return ""
            st[1] += 1
            link = t("link") or ""
            date = t("pubDate", "date", "published", "updated")
            try:
                from email.utils import parsedate_to_datetime
                date = parsedate_to_datetime(date).astimezone(KST).strftime("%Y-%m-%d")
            except Exception:
                date = (date or "")[:10]
            st[2] += run.add(label, lang, "피드", date, t("title"), t("description", "summary", "encoded"), link.strip())
        time.sleep(0.5)
    for label, (req, got, new, memo) in stat.items():
        run.note(label, "정상" if req else "오류", req, got, new, memo)


def naver_totals(prev_dir):
    """글 내용·링크는 저장하지 않고 전체 글 수만(약관 7.3③). 전날 대비 = 하루 새 글 추정."""
    cid, sec = os.environ.get("NAVER_CLIENT_ID"), os.environ.get("NAVER_CLIENT_SECRET")
    if not (cid and sec):
        return [], ["", "네이버", "건너뜀", "0", "0", "0", "키 없음"]
    prev = {}
    f = os.path.join(prev_dir or "", "naver-latest.tsv")
    if prev_dir and os.path.exists(f):
        for line in open(f, encoding="utf-8").read().splitlines()[1:]:
            c = line.split("\t")
            if len(c) >= 5 and c[4].isdigit():
                prev[(c[2], c[3])] = int(c[4])
    h = {"X-NCP-APIGW-API-KEY-ID": cid, "X-NCP-APIGW-API-KEY": sec}
    rows, req, memo = [], 0, ""
    for p, q in NAVER_QUERIES:
        for kind in ("blog", "cafearticle"):  # kin(지식iN)은 API HUB 구독에 없음(11/25 시험 401)
            url = f"https://naverapihub.apigw.ntruss.com/search/v1/{kind}?" + urllib.parse.urlencode({"query": q, "display": 1, "format": "json"})
            try:
                d = get_json(url, h); req += 1
                total = int(d.get("total", 0))
                old = prev.get((kind, q))
                rows.append([TODAY, p, kind, q, str(total), "" if old is None else str(total - old)])
            except Exception as e:
                memo = err(e)
                rows.append([TODAY, p, kind, q, "", "오류 " + memo])
            time.sleep(0.15)
    return rows, [TODAY, "네이버(숫자만)", "정상" if req else "오류", str(req), str(len(rows)), "", memo]


def tsv(path, head, rows):
    with open(path, "w", encoding="utf-8") as f:
        f.write("\t".join(head) + "\n")
        for r in rows:
            f.write("\t".join(str(c).replace("\t", " ").replace("\n", " ") for c in r) + "\n")


def main(out, prev_dir=None):
    os.makedirs(out, exist_ok=True)
    run = Run(prev_dir)
    # Bluesky 공개 검색은 GitHub 클라우드에서 403(11/25 시험) → 로그인 키가 생길 때까지 끔
    fns = [stackexchange, hackernews, qiita, rss] + ([bluesky] if os.environ.get("VOICE_BLUESKY") else [])
    for fn in fns:
        try:
            fn(run)
        except Exception as e:
            run.note(fn.__name__, "오류", 0, 0, 0, err(e))
    nrows, nstat = naver_totals(prev_dir)
    run.status.append(nstat if nstat[0] else [TODAY] + nstat[1:])

    # 문제×언어×출처 집계
    agg = {}
    for r in run.rows:
        k = (r[2], r[3], r[1])
        a = agg.setdefault(k, [0, 0, 0])
        a[0] += 1; a[1] += int(r[9]); a[2] += int(r[10])
    counts = [[TODAY, l, p, s] + v for (l, p, s), v in sorted(agg.items())]

    run.rows.sort(key=lambda r: (r[2], r[3], -int(r[9]), r[1]))
    tsv(os.path.join(out, f"voice-{TODAY}.tsv"), HEAD, run.rows)
    tsv(os.path.join(out, f"counts-{TODAY}.tsv"), COUNT_HEAD, counts)
    tsv(os.path.join(out, f"naver-{TODAY}.tsv"), NAVER_HEAD, nrows)
    tsv(os.path.join(out, f"status-{TODAY}.tsv"), STATUS_HEAD, run.status)
    with open(os.path.join(out, "seen.txt"), "w") as f:
        f.write("\n".join(sorted(run.seen | run.new_keys)) + "\n")
    # 공개 기록(Actions 로그)에는 숫자만
    print(f"새 글 {len(run.rows)}건, 고통 신호 {sum(int(r[9]) for r in run.rows)}건")
    for s in run.status:
        print("  " + " | ".join(s[1:]))
    by_p = {}
    for r in run.rows:
        by_p[(r[2], r[3])] = by_p.get((r[2], r[3]), 0) + 1
    print("  문제별: " + ", ".join(f"{l} {p} {n}" for (l, p), n in sorted(by_p.items())))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("사용: voice_collect.py <출력 폴더> [이전 기록 폴더]")
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
