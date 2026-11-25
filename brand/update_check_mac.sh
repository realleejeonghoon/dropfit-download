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
FEED=${UPDATE_FEED:-https://realleejeonghoon.github.io/dropfit-download/appcast.xml}
# UPDATE_FEED를 주면 공개 전 소스 빌드를 시험한다(source-check: 시험 키로 서명한 로컬 목록, 임시 서명 앱). 그때는 중계·Gatekeeper 줄을 건너뛴다
LOCAL=$([ -n "${UPDATE_FEED:-}" ] && echo 1 || echo 0)
FAILS=0; LINES=()
put() { if [ "$1" = ok ]; then LINES+=("✓ $2"); else LINES+=("✗ $2"); FAILS=$((FAILS+1)); fi; }
ver() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }
build() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist" 2>/dev/null; }

echo "· $(date +%T) 목록 읽기"
# 공개 appcast의 최신 버전(받을 버전)
curl -sSL --max-time 60 "$FEED" >"$OUT/appcast.xml"
WANT_V=$(grep -o 'shortVersionString>[^<]*' "$OUT/appcast.xml" | head -1 | cut -d'>' -f2)
WANT_B=$(grep -o '<sparkle:version>[^<]*' "$OUT/appcast.xml" | head -1 | cut -d'>' -f2)
[ -n "$WANT_V" ] && put ok "$([ $LOCAL = 1 ] && echo "시험 목록(공개 전 소스)" || echo "공개 appcast") 최신: ${WANT_V}(${WANT_B})" || put bad "업데이트 목록에서 최신 버전을 읽지 못함"
# 사용 통계를 켠 사용자가 읽는 중계 목록. 중계는 GitHub 목록을 5분 기억하므로(worker.js cacheTtl 300) 공개 직후엔 옛 목록일 수 있다
# (11/20 빌드 46 공개 47초 뒤 macOS 26만 '240초 안에 못 받음', 다시 돌리자 4초). 6분 안에 같은 최신 버전이 되어야 한다 (통계 표시 s=1 없이 읽어 세지 않음)
if [ $LOCAL = 0 ]; then
RELAY_B=""; for i in $(seq 0 12); do
  RELAY_B=$(curl -sSL --max-time 20 "https://update.dropfit.kr/appcast.xml" 2>/dev/null | grep -o '<sparkle:version>[^<]*' | head -1 | cut -d'>' -f2)
  [ "$RELAY_B" = "$WANT_B" ] && break; sleep 30
done
[ "$RELAY_B" = "$WANT_B" ] && put ok "중계 목록(update.dropfit.kr)도 최신 ${WANT_B} ($((i * 30))초 뒤)" || put bad "중계 목록이 6분 지나도 ${RELAY_B:-읽지 못함} (기대 ${WANT_B})"
fi

echo "· $(date +%T) 옛 버전 설치"
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
# 시험 목록: 앞 단계의 소스 빌드(다른 서명)가 만든 체험·키 키체인 항목을 임시 서명 옛 앱이 읽으면 허용 창에서 멈춘다(11/24 Apple 칩: 앱 기록이 SecItemCopyMatching에서 끊기고 목록 요청 0번).
# 실제 사용자는 같은 서명의 앱이 만든 항목이라 창이 뜨지 않는다. 지우기만 하면 창 없이 끝난다
if [ $LOCAL = 1 ]; then for k in trial license; do security delete-generic-password -s "$DOM.$k" >/dev/null 2>&1 || :; done; fi
# 점검 Mac은 사용자가 아니다: 사용 통계(F-013)를 꺼서 설치·체험 수에 섞이지 않게 한다 (2026-11-21 정훈 님)
# 통계를 끄면 앱은 GitHub 목록을 직접 읽는다. 사용자가 거치는 중계 목록은 아래에서 따로 같은지 본다(s=1이 없는 요청은 세지 않음)
defaults write $DOM usage.enabled -bool false
defaults write $DOM SUEnableAutomaticChecks -bool YES
defaults write $DOM SUAutomaticallyUpdate -bool YES
defaults write $DOM SUHasLaunchedBefore -bool YES
defaults write $DOM SULastCheckTime -date '2020-01-01 00:00:00 +0000'
# 단계 공개(phasedRolloutInterval)의 첫 무리로 고정: Sparkle 무리 = SUUpdateGroupIdentifier % 7, 기다림 = 간격 × 무리.
# 새 시험 Mac은 무리가 무작위라 공개 첫날엔 6/7 확률로 '아직 받을 차례 아님'이 되어 시험이 헛실패한다(11/11).
defaults write $DOM SUUpdateGroupIdentifier -int 7
defaults write $DOM orb.onboarded -bool YES

echo "· $(date +%T) 옛 버전 실행, 새 버전 받기 기다림(최대 240초)"
N0=$(wc -l <"${UPDATE_SERVER_LOG:-/dev/null}" 2>/dev/null | tr -d " "); N0=${N0:-0}   # 앱을 켜기 전 서버 기록 줄 수(준비·스크립트가 읽은 줄은 빼고 센다)
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
# 시험 목록이면 서버 기록으로 앱이 실제로 목록·zip을 읽었는지 본다(받지도 않고 '그대로'면 서명 점검이 헛통과)
if [ $LOCAL = 1 ] && [ -n "${UPDATE_SERVER_LOG:-}" ]; then
  AFTER=$(tail -n +$((N0+1)) "$UPDATE_SERVER_LOG")
  grep -q 'GET /appcast.xml' <<<"$AFTER" && put ok "앱이 시험 목록을 읽음" || put bad "앱이 시험 목록을 한 번도 읽지 않음(업데이트 확인이 시작되지 않음)"
  grep -q 'GET /Dropfit-new.zip' <<<"$AFTER" && put ok "앱이 새 zip을 받음" || put bad "앱이 새 zip을 받지 않음"
fi
[ $READY = yes ] && put ok "실행 ${T}초 만에 새 버전을 받아 설치 준비" || put bad "240초 안에 새 버전을 받지 못함(캐시: $(ls ~/Library/Caches/$DOM 2>/dev/null | tr '\n' ' '))"
# 받지 못했으면 원인을 남긴다: 그 순간 두 목록의 버전, 앱이 남긴 시스템 기록(Sparkle 요청·오류) (11/21 정훈 '흔들림 해결 필요')
if [ $READY != yes ]; then
  echo "· $(date +%T) 실패 원인 모으기"
  for u in "$FEED" https://update.dropfit.kr/appcast.xml; do
    echo "$u → $(curl -sSL --max-time 20 "$u" | grep -o '<sparkle:version>[^<]*' | head -1 | cut -d'>' -f2) · $(curl -sSI --max-time 20 "$u" | grep -i '^\(age\|cache-control\|last-modified\|cf-cache-status\|x-cache\):' | tr -d '\r' | tr '\n' ' ')"
  done > "$OUT/feeds-at-fail.txt"
  perl -e 'alarm shift; exec @ARGV' 90 log show --last 6m --style compact --info --debug --predicate 'process == "Dropfit" OR subsystem CONTAINS "sparkle"' > "$OUT/syslog-at-fail.txt" 2>&1
  defaults read $DOM > "$OUT/defaults-at-fail.txt" 2>&1
  echo "--- 실패 순간 목록"; cat "$OUT/feeds-at-fail.txt"
  if [ $LOCAL = 1 ] && kill -0 $PID 2>/dev/null; then
    echo "--- 옛 앱 주 스레드 (멈춘 자리)"; sample $PID 1 -file "$OUT/sample.txt" >/dev/null 2>&1 || :
    grep -m1 -A25 'Thread_.*DispatchQueue_1\|com.apple.main-thread' "$OUT/sample.txt" 2>/dev/null | grep -oE '[A-Za-z_][A-Za-z0-9_:\.]+ \(in [^)]+\)' | head -12
  fi
  if [ $LOCAL = 1 ]; then
    echo "--- 옛 앱 Info.plist 업데이트 키"; for key in SUFeedURL SUPublicEDKey SURequireSignedFeed SUEnableAutomaticChecks; do echo "$key=$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" 2>&1 | cut -c1-60)"; done
    echo "--- 옛 앱 서명"; codesign -dv "$APP" 2>&1 | grep -E 'Signature|TeamIdentifier|flags|Format' | head -5
    echo "--- 시험 서버 기록"; tail -8 "${UPDATE_SERVER_LOG:-/dev/null}" 2>/dev/null
    echo "--- Dropfit 시스템 기록(거르지 않음, 끝 30줄)"; grep -v libMobileGestalt "$OUT/syslog-at-fail.txt" | tail -30 | cut -c1-220
  fi
  echo "--- 시스템 기록 (Sparkle·네트워크 줄, 끝 25줄)"; grep -i "sparkle\|appcast\|feed\|nsurl\|error\|fail" "$OUT/syslog-at-fail.txt" | tail -25
fi
find ~/Library/Caches/$DOM -maxdepth 4 2>/dev/null | head -40 >"$OUT/cache.txt"

echo "· $(date +%T) 앱 끄기·설치 기다림"
# 사용자가 앱을 끄면 설치된다
perl -e 'alarm shift; exec @ARGV' 20 osascript -e 'tell application "Dropfit" to quit' >/dev/null 2>&1; sleep 3
kill -0 $PID 2>/dev/null && { kill $PID; sleep 2; }
for i in $(seq 1 90); do [ "$(build "$APP")" = "$WANT_B" ] && break; sleep 1; done
NOW_V=$(ver "$APP"); NOW_B=$(build "$APP")
[ "$NOW_B" = "$WANT_B" ] && put ok "앱을 끈 뒤 ${NOW_V}(${NOW_B})로 바뀜" || put bad "앱을 끈 뒤에도 ${NOW_V}(${NOW_B}) 그대로(기대 ${WANT_V}(${WANT_B}))"

echo "· $(date +%T) 바뀐 앱 확인"
# 바뀐 앱이 온전한지: 서명·공증, 실행
codesign --verify --deep --strict "$APP" >"$OUT/codesign.txt" 2>&1 && put ok "업데이트된 앱 서명 검증 통과" || put bad "업데이트된 앱 서명 실패: $(tail -1 "$OUT/codesign.txt")"
spctl --assess --type execute -vv "$APP" >"$OUT/spctl.txt" 2>&1
# 임시 서명 앱(공개 전 소스)은 Gatekeeper 판정 대상이 아니다. 공개 zip은 매일 점검이 본다
[ $LOCAL = 1 ] || { grep -q accepted "$OUT/spctl.txt" && put ok "업데이트된 앱 Gatekeeper 허용" || put bad "업데이트된 앱 Gatekeeper: $(tr '\n' ' ' <"$OUT/spctl.txt")"; }
# 최신이 된 앱은 같은 업데이트를 다시 받지 않아야 한다 (2026-11-23 정훈 님 '반복 업데이트 확인'):
# 받아 둔 것을 비우고 마지막 확인을 옛날로 돌려, 열자마자 다시 확인하게 한 뒤 90초 동안 새로 받는지 본다
rm -rf ~/Library/Caches/$DOM/org.sparkle-project.Sparkle
defaults write $DOM SULastCheckTime -date '2020-01-01 00:00:00 +0000'
START=$(date +%s)
"$APP/Contents/MacOS/Dropfit" >"$OUT/run2.txt" 2>&1 &
P2=$!; sleep 10
kill -0 $P2 2>/dev/null && put ok "업데이트된 앱 실행 후 10초 동안 살아 있음" || put bad "업데이트된 앱이 10초 안에 종료됨"
# 반복 업데이트는 공개 목록·실제 서명 길에서 잰다(매일 점검·PR의 자동 업데이트 점검, Mac 3종). 2026-11-25 정훈 님 결정.
# 시험 목록(임시 서명) 길에서는 업데이트된 앱이 다시 확인을 시작하지 않아 잴 수 없었다(PR #129, 원인 미확인) → 이 길에서는 재지 않고 한 줄로 남긴다
if [ $LOCAL = 1 ]; then
  echo "· 시험 목록 길: 반복 업데이트는 공개 목록 점검(update-check)이 잼"
else
  # 키가 아직 없으면 defaults read가 실패해 LC가 빈 값이 된다(set -u만, set -e 아님) = '아직 확인 안 함'으로 셈
  CHECKED=no; AGAIN=no; LC=""
  for i in $(seq 1 80); do
    kill -0 $P2 2>/dev/null || break
    LC=$(defaults read $DOM SULastCheckTime 2>/dev/null)
    case "$LC" in 2020-*|"") ;; *) CHECKED=yes ;; esac
    find ~/Library/Caches/$DOM/org.sparkle-project.Sparkle -type d -name 'Installation' 2>/dev/null | grep -q . && { AGAIN=yes; break; }
    [ $CHECKED = yes ] && [ $i -ge 40 ] && break
    sleep 1
  done
  [ $CHECKED = yes ] && put ok "최신 앱이 다시 업데이트를 확인함 (마지막 확인 $LC)" || put bad "최신 앱이 90초 안에 업데이트를 확인하지 않음 (재업데이트 여부를 잴 수 없음)"
  [ $AGAIN = no ] && put ok "최신 앱(${NOW_B})은 같은 업데이트를 다시 받지 않음" || put bad "최신 앱(${NOW_B})이 업데이트를 또 받음: 반복 업데이트"
  # 다시 확인하지 않았으면 원인을 남긴다: 그 순간의 Sparkle 설정·설치 도우미 프로세스·앱 시스템 기록 (11/25 시험 목록에서만 확인 안 함)
  if [ $CHECKED != yes ]; then
    echo "--- 최신 앱이 다시 확인하지 않은 순간"
    echo "Sparkle 설정: $(defaults read $DOM 2>/dev/null | grep -E 'SU[A-Za-z]+' | tr -s ' \n' ' ' | cut -c1-400)"
    echo "설치 도우미: $(pgrep -lf 'Autoupdate|Installer|sparkle' 2>/dev/null | cut -c1-120 | tr '\n' ';')"
    echo "Info.plist: $(for key in SUFeedURL SUEnableAutomaticChecks SUScheduledCheckInterval; do printf '%s=%s ' "$key" "$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" 2>&1 | cut -c1-60)"; done)"
    perl -e 'alarm shift; exec @ARGV' 60 log show --last 3m --style compact --info --debug --predicate 'process == "Dropfit" OR process CONTAINS "Autoupdate" OR subsystem CONTAINS "sparkle"' > "$OUT/syslog-recheck.txt" 2>&1
    echo "--- 시스템 기록 (Sparkle·설치 줄, 끝 30줄)"; grep -v libMobileGestalt "$OUT/syslog-recheck.txt" | grep -i "sparkle\|update\|install\|appcast\|error" | tail -30 | cut -c1-220
  fi
fi
kill $P2 2>/dev/null
CR=$(find ~/Library/Logs/DiagnosticReports /Library/Logs/DiagnosticReports -name 'Dropfit*' -newermt "@$START" 2>/dev/null | head -3)
[ -z "$CR" ] && put ok "충돌 보고서 0개" || put bad "충돌 보고서: $CR"
pkill -x Dropfit 2>/dev/null

OS="$(sw_vers -productVersion)"
{ echo "### Dropfit 자동 업데이트 점검 · macOS $OS · ${FROM_V} → ${WANT_V}"; echo; for l in "${LINES[@]}"; do echo "- $l"; done; echo; } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" >"$OUT/summary.md"
printf '%s\n' "${LINES[@]}"; echo; echo "--- Sparkle 캐시 ---"; cat "$OUT/cache.txt"; echo "--- 첫 실행 출력 (끝 30줄) ---"; tail -30 "$OUT/run1.txt"
[ $FAILS -eq 0 ] && echo "통과 · macOS $OS" || echo "${FAILS}건 다름 · macOS $OS"
exit $([ $FAILS -eq 0 ] && echo 0 || echo 1)
