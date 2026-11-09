#!/bin/bash
# Dropfit 자동 업데이트 실제 과정 점검 (깨끗한 Mac CI 전용). 품질 기술서 '업데이트'.
#   bash brand/update_check_mac.sh 옛zip 보고서폴더
# 사용자 Mac과 같은 길: 바로 앞 버전을 응용 프로그램 폴더에 깔고 '자동으로 업데이트'를 켠 채 실행 →
# Sparkle이 공개 appcast를 보고 새 버전을 받아 서명을 확인 → 앱을 끄면 설치 → 다시 열었을 때 새 버전인지.
# 이 점검은 /Applications의 Dropfit을 지우고 새로 깔며 Dropfit 설정을 초기화한다. GitHub의 깨끗한 Mac에서만 돈다
if [ "${GITHUB_ACTIONS:-}" != true ]; then echo "멈춤: 이 점검은 GitHub의 깨끗한 Mac 전용입니다(설치된 Dropfit을 지우고 설정을 초기화함). 실제로 쓰는 Mac에서는 돌리지 마세요."; exit 3; fi
set -u
OLD="$1"; OUT="$2"; mkdir -p "$OUT"
DOM=app.dropfit.prototype
APP=/Applications/Dropfit.app
FEED=https://realleejeonghoon.github.io/dropfit-download/appcast.xml
FAILS=0; LINES=()
put() { if [ "$1" = ok ]; then LINES+=("✓ $2"); else LINES+=("✗ $2"); FAILS=$((FAILS+1)); fi; }
ver() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }
build() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist" 2>/dev/null; }

# 공개 appcast의 최신 버전(받을 버전)
curl -sSL --max-time 60 "$FEED" >"$OUT/appcast.xml"
WANT_V=$(grep -o 'shortVersionString>[^<]*' "$OUT/appcast.xml" | head -1 | cut -d'>' -f2)
WANT_B=$(grep -o '<sparkle:version>[^<]*' "$OUT/appcast.xml" | head -1 | cut -d'>' -f2)
[ -n "$WANT_V" ] && put ok "공개 appcast 최신: ${WANT_V}(${WANT_B})" || put bad "공개 appcast에서 최신 버전을 읽지 못함"

# 바로 앞 버전 설치 (격리 표시 없이: Gatekeeper 창은 앱 점검이 따로 본다)
pkill -x Dropfit 2>/dev/null; rm -rf "$APP"
W="$OUT/old"; rm -rf "$W"; mkdir -p "$W"; ditto -x -k "$OLD" "$W"
SRC="$(find "$W" -maxdepth 2 -name Dropfit.app -type d | head -1)"
[ -d "$SRC" ] || { echo "옛 zip에 Dropfit.app 없음"; exit 1; }
ditto "$SRC" "$APP"
FROM_V=$(ver "$APP"); FROM_B=$(build "$APP")
put ok "시작 버전: ${FROM_V}(${FROM_B}) 설치"
[ "$FROM_B" != "$WANT_B" ] || put bad "옛 버전과 최신 버전이 같아 업데이트를 잴 수 없음"

# 사용자가 '자동으로 업데이트'를 켜 둔 상태 + 마지막 확인이 오래전 = 실행하자마자 확인
defaults delete $DOM >/dev/null 2>&1
defaults write $DOM SUEnableAutomaticChecks -bool YES
defaults write $DOM SUAutomaticallyUpdate -bool YES
defaults write $DOM SUHasLaunchedBefore -bool YES
defaults write $DOM SULastCheckTime -date '2020-01-01 00:00:00 +0000'
defaults write $DOM orb.onboarded -bool YES

"$APP/Contents/MacOS/Dropfit" >"$OUT/run1.txt" 2>&1 &
PID=$!
# 받기·서명 확인·풀기가 끝날 때까지(최대 240초). Sparkle은 다 받으면 설치 준비 파일을 캐시에 둔다
READY=no
for i in $(seq 1 240); do
  kill -0 $PID 2>/dev/null || break
  if find ~/Library/Caches/$DOM/org.sparkle-project.Sparkle -type d -name 'Installation' 2>/dev/null | grep -q . \
     || find ~/Library/Caches/$DOM/org.sparkle-project.Sparkle -name '*.app' -path '*Installation*' 2>/dev/null | grep -q .; then READY=yes; T=$i; break; fi
  sleep 1
done
sleep 5
[ $READY = yes ] && put ok "실행 ${T}초 만에 새 버전을 받아 설치 준비" || put bad "240초 안에 새 버전을 받지 못함(캐시: $(ls ~/Library/Caches/$DOM 2>/dev/null | tr '\n' ' '))"
find ~/Library/Caches/$DOM -maxdepth 4 2>/dev/null | head -40 >"$OUT/cache.txt"

# 사용자가 앱을 끄면 설치된다
osascript -e 'tell application "Dropfit" to quit' >/dev/null 2>&1; sleep 3
kill -0 $PID 2>/dev/null && { kill $PID; sleep 2; }
for i in $(seq 1 90); do [ "$(build "$APP")" = "$WANT_B" ] && break; sleep 1; done
NOW_V=$(ver "$APP"); NOW_B=$(build "$APP")
[ "$NOW_B" = "$WANT_B" ] && put ok "앱을 끈 뒤 ${NOW_V}(${NOW_B})로 바뀜" || put bad "앱을 끈 뒤에도 ${NOW_V}(${NOW_B}) 그대로(기대 ${WANT_V}(${WANT_B}))"

# 바뀐 앱이 온전한지: 서명·공증, 실행
codesign --verify --deep --strict "$APP" >"$OUT/codesign.txt" 2>&1 && put ok "업데이트된 앱 서명 검증 통과" || put bad "업데이트된 앱 서명 실패: $(tail -1 "$OUT/codesign.txt")"
spctl --assess --type execute -vv "$APP" >"$OUT/spctl.txt" 2>&1
grep -q accepted "$OUT/spctl.txt" && put ok "업데이트된 앱 Gatekeeper 허용" || put bad "업데이트된 앱 Gatekeeper: $(tr '\n' ' ' <"$OUT/spctl.txt")"
START=$(date +%s)
"$APP/Contents/MacOS/Dropfit" >"$OUT/run2.txt" 2>&1 &
P2=$!; sleep 10
kill -0 $P2 2>/dev/null && { put ok "업데이트된 앱 실행 후 10초 동안 살아 있음"; kill $P2; } || put bad "업데이트된 앱이 10초 안에 종료됨"
CR=$(find ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports -name 'Dropfit*' -newermt "@$START" 2>/dev/null | head -3)
[ -z "$CR" ] && put ok "충돌 보고서 0개" || put bad "충돌 보고서: $CR"
pkill -x Dropfit 2>/dev/null

OS="$(sw_vers -productVersion)"
{ echo "### Dropfit 자동 업데이트 점검 · macOS $OS · ${FROM_V} → ${WANT_V}"; echo; for l in "${LINES[@]}"; do echo "- $l"; done; echo; } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" >"$OUT/summary.md"
printf '%s\n' "${LINES[@]}"; echo; echo "--- Sparkle 캐시 ---"; cat "$OUT/cache.txt"; echo "--- 첫 실행 출력 (끝 30줄) ---"; tail -30 "$OUT/run1.txt"
[ $FAILS -eq 0 ] && echo "통과 · macOS $OS" || echo "${FAILS}건 다름 · macOS $OS"
exit $([ $FAILS -eq 0 ] && echo 0 || echo 1)
