#!/bin/bash
# Dropfit 앱 실행 점검 (macOS 전용, 깨끗한 Mac에서). 품질 기술서 3장 '앱 빌드'.
#   bash brand/app_check_mac.sh 폴더      (폴더 안에 Dropfit-macOS.zip — app_check.py --out 이 남김)
# 재는 것: 인터넷에서 받은 것처럼 격리 표시를 붙인 뒤 서명·공증·Gatekeeper, 응용 프로그램에 설치 후 실행·종료·충돌 보고서,
# 화면 동작 점검(Dropfit --qa), 이 macOS가 실제로 보여 주는 앱 아이콘이 기준 그림(둥근 판, 고리 포함)과 같은지.
set -u
DIR="$(cd "$1" && pwd)"; HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/report"; mkdir -p "$OUT"
OS="$(sw_vers -productVersion)"
# 화면 크기(점 단위): 전체 / 메뉴 막대·Dock을 뺀 영역. 오브 자리·펼침 배치가 여기에 따라 달라진다
SCREEN="$(osascript -l JavaScript -e 'ObjC.import("AppKit"); var s=$.NSScreen.mainScreen; var f=s.frame, v=s.visibleFrame; f.size.width+"x"+f.size.height+" (보이는 영역 "+v.size.width+"x"+v.size.height+", 위쪽 "+(f.size.height-v.origin.y-v.size.height)+"pt)"' 2>/dev/null)"
FAILS=0; LINES=()
put() { if [ "$1" = ok ]; then LINES+=("✓ $2"); else LINES+=("✗ $2"); FAILS=$((FAILS+1)); fi; }

W="$DIR/work"; rm -rf "$W"; mkdir -p "$W"
ditto -x -k "$DIR/Dropfit-macOS.zip" "$W"
APP_SRC="$W/Dropfit/Dropfit.app"
[ -d "$APP_SRC" ] && put ok "zip 풀기: Dropfit/Dropfit.app 있음" || { put bad "zip 안에 Dropfit/Dropfit.app 없음"; }
xattr -r -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;" "$W/Dropfit"

codesign --verify --deep --strict "$APP_SRC" >"$OUT/codesign.txt" 2>&1 && put ok "서명 검증(--deep --strict) 통과" || put bad "서명 검증 실패: $(tail -1 "$OUT/codesign.txt")"
spctl --assess --type execute -vv "$APP_SRC" >"$OUT/spctl.txt" 2>&1
grep -q "accepted" "$OUT/spctl.txt" && grep -q "Notarized Developer ID" "$OUT/spctl.txt" \
  && put ok "Gatekeeper: 공증된 Developer ID로 허용" || put bad "Gatekeeper: $(tr '\n' ' ' <"$OUT/spctl.txt")"
xcrun stapler validate "$APP_SRC" >"$OUT/stapler.txt" 2>&1 && put ok "공증 티켓 첨부 확인(오프라인에서도 열림)" || put bad "공증 티켓 없음: $(tail -1 "$OUT/stapler.txt")"

APP=/Applications/Dropfit.app
rm -rf "$APP"; ditto "$APP_SRC" "$APP"
START=$(date +%s)
"$APP/Contents/MacOS/Dropfit" >"$OUT/run.txt" 2>&1 &
PID=$!; sleep 10
if kill -0 $PID 2>/dev/null; then put ok "실행 후 10초 동안 살아 있음"; kill $PID; sleep 2; else put bad "실행 10초 안에 종료됨: $(tail -2 "$OUT/run.txt" | tr '\n' ' ')"; fi

# 화면 동작 점검: 앱 안의 QASelfTest (드래그·펼침·놓기·접힘·진행·완료·거절·클릭). 최대 300초
"$APP/Contents/MacOS/Dropfit" --qa "$OUT/ui.txt" >"$OUT/qa-run.txt" 2>&1 &
QP=$!; for _ in $(seq 1 300); do kill -0 $QP 2>/dev/null || break; sleep 1; done
if kill -0 $QP 2>/dev/null; then kill $QP; put bad "화면 동작 점검이 300초 안에 끝나지 않음"
else wait $QP; RC=$?
  N_OK=$(grep -c "✓\|통과" "$OUT/ui.txt" 2>/dev/null || echo 0); N_BAD=$(grep -c "✗\|실패" "$OUT/ui.txt" 2>/dev/null || echo 0)
  [ $RC -eq 0 ] && put ok "화면 동작 점검(--qa) 통과 (확인 ${N_OK}줄)" || put bad "화면 동작 점검(--qa) 실패 ${N_BAD}줄: $(grep -m2 "✗\|실패" "$OUT/ui.txt" | tr '\n' ' ')"
fi

# 참고(합격 판정에 넣지 않음): 같은 점검을 오브를 화면 한가운데 두고 한 번 더. 처음 설치한 자리(오른쪽 위)에서만 다르면 자리 탓
DOM=app.dropfit.prototype
MID="$(osascript -l JavaScript -e 'ObjC.import("AppKit"); var v=$.NSScreen.mainScreen.visibleFrame; "{"+(v.origin.x+v.size.width/2)+", "+(v.origin.y+v.size.height/2)+"}"' 2>/dev/null)"
echo "처음 자리 설정: $(defaults read $DOM 2>&1 | tr '\n' ' ')" >"$OUT/position.txt"
defaults write $DOM orb.homeFraction "{0.5, 0.5}"; defaults write $DOM orb.center "$MID"
echo "한가운데 설정(orb.center): $MID" >>"$OUT/position.txt"
"$APP/Contents/MacOS/Dropfit" --qa "$OUT/ui-center.txt" >"$OUT/qa-center-run.txt" 2>&1 &
QP=$!
# 창 크기·자리 기록: 화면 서버가 아는 Dropfit 창 테두리(왼쪽 위 기준)를 0.05초마다 재서, 바뀔 때만 남긴다
osascript -l JavaScript >"$OUT/window-frames.txt" 2>&1 <<'JXA' &
ObjC.import('CoreGraphics'); ObjC.import('Foundation');
var last = '', out = [], t0 = Date.now();
for (var i = 0; i < 1200; i++) {
  var list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0))) || [];
  var b = list.filter(function (w) { return w.kCGWindowOwnerName === 'Dropfit'; })
              .map(function (w) { var r = w.kCGWindowBounds; return r.X + ',' + r.Y + ' ' + r.Width + 'x' + r.Height; }).join(' | ');
  if (b !== last) { out.push(((Date.now() - t0) / 1000).toFixed(2) + 's ' + (b || '(없음)')); last = b; }
  $.NSThread.sleepForTimeInterval(0.05);
}
out.slice(0, 80).join('\n');
JXA
WP=$!; for _ in $(seq 1 300); do kill -0 $QP 2>/dev/null || break; sleep 1; done
kill -0 $QP 2>/dev/null && kill $QP; wait $QP 2>/dev/null; RC2=$?; wait $WP 2>/dev/null
defaults delete $DOM orb.homeFraction 2>/dev/null; defaults delete $DOM orb.center 2>/dev/null
NOTE="참고: 오브를 화면 한가운데 두면 화면 동작 점검 $([ $RC2 -eq 0 ] && echo 통과 || echo "문제 $(grep -c "✗" "$OUT/ui-center.txt" 2>/dev/null || echo ?)건")"

CR=$(find ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports -name 'Dropfit*' -newermt "@$START" 2>/dev/null | head -3)
[ -z "$CR" ] && put ok "충돌 보고서 0개" || { put bad "충돌 보고서: $CR"; cp $CR "$OUT/" 2>/dev/null; }

# 이 macOS가 Finder·Dock에 보여 주는 아이콘을 그대로 꺼내 기준 그림과 비교 (512px, 32px)
for S in 512 32; do
osascript -l JavaScript >/dev/null 2>&1 <<EOF
ObjC.import('AppKit');
var img = \$.NSWorkspace.sharedWorkspace.iconForFile('$APP');
var s = $S; img.setSize(\$.NSMakeSize(s, s));
var rep = \$.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(null, s, s, 8, 4, true, false, \$.NSDeviceRGBColorSpace, 0, 0);
\$.NSGraphicsContext.saveGraphicsState;
\$.NSGraphicsContext.setCurrentContext(\$.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep));
img.drawInRectFromRectOperationFraction(\$.NSMakeRect(0, 0, s, s), \$.NSZeroRect, \$.NSCompositingOperationSourceOver, 1.0);
\$.NSGraphicsContext.restoreGraphicsState;
rep.representationUsingTypeProperties(\$.NSBitmapImageFileTypePNG, \$()).writeToFileAtomically('$OUT/os-icon-$S.png', true);
EOF
done
if [ -f "$OUT/os-icon-512.png" ]; then
  R=$(python3 - "$OUT" "$HERE/master/rounded-1024.png" <<'PY'
import sys, numpy as np
from PIL import Image
out, master = sys.argv[1], sys.argv[2]
ref = Image.open(master).convert('RGBA')
res = []
for s, tol in ((512, 3.0), (32, 4.0)):
    im = Image.open(f'{out}/os-icon-{s}.png').convert('RGBA').resize((s, s))
    a = np.asarray(im); corner = int(max(a[0, 0, 3], a[0, -1, 3], a[-1, 0, 3], a[-1, -1, 3]))
    r = ref.resize((s, s), Image.LANCZOS)
    d = []
    for bg in [(246, 246, 248), (29, 29, 31)]:
        f = lambda x: (lambda b: (b.alpha_composite(x), np.asarray(b.convert('RGB')).astype(float))[1])(Image.new('RGBA', (s, s), bg + (255,)))
        d.append(np.abs(f(im) - f(r)).mean())
    res.append(f"{'ok' if corner == 0 and max(d) <= tol else 'bad'}|이 macOS가 보여 주는 앱 아이콘 {s}px: 모서리 투명도 {corner}(기준 0), 기준 그림과 차이 {max(d):.1f}(허용 {tol})")
print('\n'.join(res))
PY
)
  while IFS='|' read -r st msg; do put "$st" "$msg"; done <<<"$R"
else put bad "앱 아이콘을 꺼내지 못함"; fi

pkill -x Dropfit 2>/dev/null
{ echo "### Dropfit 앱 실행 점검 · macOS $OS · 화면 ${SCREEN:-알 수 없음} · $(cat "$DIR/version.txt" 2>/dev/null)"; echo; for l in "${LINES[@]}"; do echo "- $l"; done; echo "- $NOTE"; echo; } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" >"$OUT/summary.md"
printf '%s\n' "${LINES[@]}"; echo "· $NOTE"; echo; echo "--- 화면 동작 점검 보고서 (화면 ${SCREEN:-?}) ---"; cat "$OUT/ui.txt" 2>/dev/null; echo; echo "--- 참고: 화면 한가운데에서 ---"; cat "$OUT/position.txt" 2>/dev/null; echo "창 테두리 변화(처음 80개):"; cat "$OUT/window-frames.txt" 2>/dev/null; grep "✗\|결과" "$OUT/ui-center.txt" 2>/dev/null; echo; [ $FAILS -eq 0 ] && echo "통과 · macOS $OS" || echo "${FAILS}건 다름 · macOS $OS"
exit $([ $FAILS -eq 0 ] && echo 0 || echo 1)
