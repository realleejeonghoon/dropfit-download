#!/bin/bash
# 공개 전 소스 빌드로 '이전 공개 빌드 → 새 빌드' 실제 업데이트를 시험할 준비 (깨끗한 Mac CI 전용, 11/24 QUALITY 7-2 빈칸 ①)
#   bash brand/update_local_prep.sh 옛zip 새앱(.app) Sparkle폴더 작업폴더 [bad]
# 실제 서명 키는 정훈 님 Mac 키체인에만 있으므로 쓰지 않는다. 이 실행에서만 쓰는 시험 EdDSA 키를 파일로 만들어(edsign.swift, 키체인 안 씀)
#  ① 옛 공개 앱과 새 앱의 공개 키 칸(SUPublicEDKey)·목록 주소(SUFeedURL)를 시험 키·이 Mac의 로컬 목록으로 바꾸고 임시 서명
#  ② 새 앱 zip을 시험 키로 서명해 로컬 목록(appcast.xml)을 만들어 127.0.0.1에서 내준다.
# 그 뒤 update_check_mac.sh가 사용자와 같은 길(자동 확인 → 받기 → 서명 확인 → 끌 때 설치 → 새 버전으로 열림)을 잰다.
# 'bad'를 주면 서명을 일부러 틀리게 만든다: 이 경우 업데이트가 되면 안 된다(점검이 살아 있는지 확인용).
# 새 빌드 번호가 옛 것보다 크지 않으면(소스가 아직 번호를 올리기 전) 시험 사본만 옛 번호+1로 올린다.
if [ "${GITHUB_ACTIONS:-}" != true ]; then echo "멈춤: GitHub의 깨끗한 Mac 전용입니다(키체인에 시험 키를 만들고 로컬 서버를 엽니다)."; exit 3; fi
set -euo pipefail
OLD="$1"; NEW="$2"; SP="$3"; W="$4"; MODE="${5:-good}"
PORT=8765; FEED="http://127.0.0.1:$PORT/appcast.xml"
rm -rf "$W"; mkdir -p "$W/old" "$W/new" "$W/www"
PB=/usr/libexec/PlistBuddy
HERE="$(cd "$(dirname "$0")" && pwd)"
swiftc -O "$HERE/edsign.swift" -o "$W/edsign" 2>"$W/edsign-build.txt" || { cat "$W/edsign-build.txt"; echo "✗ 시험 키 도구 컴파일 실패"; exit 1; }
PUB=$("$W/edsign" key "$W/ed.key")
[ -n "$PUB" ] || { echo "✗ 시험 키를 만들지 못함"; exit 1; }
patch_app() {  # 앱 → 시험 키·로컬 목록, 임시 서명
  $PB -c "Set :SUPublicEDKey $PUB" -c "Set :SUFeedURL $FEED" "$1/Contents/Info.plist"
  # 로컬 목록(http://127.0.0.1)을 읽게 시험 사본에만 로컬 통신 허용 (공개 앱은 https만 씀)
  # Sparkle은 https가 아닌 목록이면 그 주소가 ATS 예외(NSExceptionDomains)에 있는지 본다 [추정, 11/24 첫 실행 240초 안에 못 받음]
  $PB -c "Delete :NSAppTransportSecurity" "$1/Contents/Info.plist" >/dev/null 2>&1 || :
  $PB -c "Add :NSAppTransportSecurity dict" -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" \
      -c "Add :NSAppTransportSecurity:NSExceptionDomains dict" -c "Add :NSAppTransportSecurity:NSExceptionDomains:127.0.0.1 dict" \
      -c "Add :NSAppTransportSecurity:NSExceptionDomains:127.0.0.1:NSExceptionAllowsInsecureHTTPLoads bool true" "$1/Contents/Info.plist"
  codesign --force --deep -s - "$1" >/dev/null 2>&1
}
ditto -x -k "$OLD" "$W/old/x"
OA="$(find "$W/old/x" -maxdepth 2 -name Dropfit.app -type d | head -1)"
mkdir -p "$W/old/zip/Dropfit"; ditto "$OA" "$W/old/zip/Dropfit/Dropfit.app"; patch_app "$W/old/zip/Dropfit/Dropfit.app"
OB=$($PB -c 'Print :CFBundleVersion' "$OA/Contents/Info.plist")
(cd "$W/old/zip" && ditto -c -k --keepParent Dropfit "$W/old.zip")

ditto "$NEW" "$W/new/Dropfit.app"; NA="$W/new/Dropfit.app"
NB=$($PB -c 'Print :CFBundleVersion' "$NA/Contents/Info.plist"); NV=$($PB -c 'Print :CFBundleShortVersionString' "$NA/Contents/Info.plist")
if [ "$NB" -le "$OB" ] 2>/dev/null; then
  echo "· 소스 빌드 번호 ${NB}가 공개 ${OB}보다 크지 않아 시험 사본만 $((OB + 1))로 올림"; NB=$((OB + 1))
  $PB -c "Set :CFBundleVersion $NB" "$NA/Contents/Info.plist"
fi
patch_app "$NA"
(cd "$W/new" && ditto -c -k --sequesterRsrc --keepParent Dropfit.app "$W/www/Dropfit-new.zip")
SIG="sparkle:edSignature=\"$("$W/edsign" sign "$W/ed.key" "$W/www/Dropfit-new.zip")\" length=\"$(stat -f%z "$W/www/Dropfit-new.zip")\""
# bad: 같은 키로 다른 파일(옛 zip)에 한 서명을 붙인다 → 형식은 맞고 내용이 틀린 서명
[ "$MODE" = bad ] && SIG="sparkle:edSignature=\"$("$W/edsign" sign "$W/ed.key" "$W/old.zip")\" length=\"$(stat -f%z "$W/www/Dropfit-new.zip")\""
cat > "$W/www/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>Dropfit (CI 시험)</title>
<item><title>$NV</title><pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
<sparkle:version>$NB</sparkle:version><sparkle:shortVersionString>$NV</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
<description><![CDATA[CI 시험]]></description>
<enclosure url="http://127.0.0.1:$PORT/Dropfit-new.zip" $SIG type="application/octet-stream"/></item>
</channel></rss>
XML
# 목록 자체 서명: 앱이 SURequireSignedFeed라 서명 없는 목록은 거부한다(11/24 실행 기록 "no EdDSA signature in the appcast").
# 공개 appcast와 같은 꼴: 끝에 <!-- sparkle-signatures: … --> (서명 범위 = 그 앞 전부)
FS=$("$W/edsign" sign "$W/ed.key" "$W/www/appcast.xml"); FL=$(stat -f%z "$W/www/appcast.xml")
printf '<!-- sparkle-signatures:\nedSignature: %s\nlength: %s\n-->\n' "$FS" "$FL" >> "$W/www/appcast.xml"
if pgrep -f "http.server $PORT" >/dev/null; then pkill -f "http.server $PORT"; sleep 1; fi
(cd "$W/www" && nohup python3 -m http.server $PORT --bind 127.0.0.1 >"$W/http.txt" 2>&1 &)
for _ in $(seq 1 20); do curl -sf "$FEED" >/dev/null && break; sleep 0.5; done
curl -sf "$FEED" >/dev/null || { echo "✗ 로컬 목록 서버가 뜨지 않음"; exit 1; }
echo "준비: 공개 ${OB} → 소스 ${NV}(${NB}) · 목록 ${FEED} · 서명 ${MODE}"
