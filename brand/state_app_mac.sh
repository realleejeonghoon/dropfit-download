#!/bin/bash
# 공개 앱을 실제 사용자 모드로 (점검 모드 --qa 없이) 상태별로 열어, 쉬는 동안과 설정 창을 연 동안의 CPU·메모리·저장을 잰다.
#   bash brand/state_app_mac.sh 앱zip 보고서폴더 [이름표]
# 계기: 11/20 빌드 39~42는 체험 중 사용자가 설정 창을 열면 다시 그리기가 끝없이 돌았다(CPU 58%, 멈춤).
# 다른 화면 점검은 모두 --qa(Pro 고정)라 체험 시계를 지나지 않아 놓쳤다. 이 점검은 사용자와 같은 길로 연다.
# 기준(QUALITY.md ⑦): 쉬는 동안 CPU 평균 2% 이하, 설정 창을 연 동안 3% 이하, 창은 1초 안에 뜸, 연 동안 체험 시각 저장 0번,
#                     메모리 200MB 이하, 충돌 0. (클라우드 Mac은 실제 Mac보다 느려 실제 목표 0.3초·1%보다 넉넉히 잡았다)
# /Applications의 Dropfit을 지우고 설정·키체인 항목을 초기화한다. GitHub의 깨끗한 Mac에서만 돈다
if [ "${GITHUB_ACTIONS:-}" != true ]; then echo "멈춤: GitHub의 깨끗한 Mac 전용입니다(설치된 Dropfit과 설정·체험 기록을 지움)."; exit 3; fi
set -u
ZIP="$1"; OUT="$2"; TAG="${3:-}"; mkdir -p "$OUT"
HERE="$(cd "$(dirname "$0")" && pwd)"
P="$OUT/state_probe"; swiftc -O "$HERE/state_probe.swift" -o "$P" 2>"$OUT/swiftc.txt" || { cat "$OUT/swiftc.txt"; exit 1; }
DOM=app.dropfit.prototype
t() { local n="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$n" "$@"; }
FAILS=0; ROWS=()
put() { echo "$1 $2"; ROWS+=("$1 $2"); [ "$1" = "✗" ] && FAILS=$((FAILS+1)); }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
cpu_s() { ps -o time= -p "$1" 2>/dev/null | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
cpu_pct() { local a b; a=$(cpu_s "$1"); sleep "$2"; b=$(cpu_s "$1"); awk -v a="$a" -v b="$b" -v s="$2" 'BEGIN{ if (a==""||b=="") print -1; else printf "%.1f", (b-a)/s*100 }'; }
le() { awk -v x="$1" -v y="$2" 'BEGIN{ exit !(x >= 0 && x <= y) }'; }

ditto -x -k "$ZIP" "$OUT/app"
APP="$OUT/app/Dropfit/Dropfit.app"
VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist"))"
log "macOS $(sw_vers -productVersion) · Dropfit $VER ${TAG}"

reset_all() {
  pkill -x Dropfit 2>/dev/null; sleep 1; pkill -9 -x Dropfit 2>/dev/null
  rm -rf /Applications/Dropfit.app; defaults delete $DOM >/dev/null 2>&1
  for s in $DOM.trial $DOM.license; do security delete-generic-password -s "$s" >/dev/null 2>&1; done
  rm -f ~/Library/Logs/DiagnosticReports/Dropfit* 2>/dev/null
}

# 상태: 이름 · 체험 시작(며칠 전, 빈칸 = 처음 설치)
for st in "처음 설치:" "체험 중 3일째:3" "체험 끝:20"; do
  NAME="${st%%:*}"; AGO="${st#*:}"
  log ""; log "▸ $NAME"
  reset_all
  ditto --noextattr "$APP" /Applications/Dropfit.app
  if [ -n "$AGO" ]; then
    defaults write $DOM pro.trialStart -date "$(date -u -v-"${AGO}"d '+%Y-%m-%d %H:%M:%S +0000')"
    defaults write $DOM orb.onboarded -bool true   # 이미 쓰던 사용자: 첫 안내 없이 바로
  fi
  open /Applications/Dropfit.app
  PID=""; for _ in $(seq 1 40); do PID=$(pgrep -x Dropfit | head -1); [ -n "$PID" ] && break; sleep 0.5; done
  [ -n "$PID" ] || { put ✗ "$NAME: 20초 안에 앱이 켜지지 않음"; continue; }
  sleep 6
  # 처음 설치: 인트로(큰 창)가 떠 있으면 Esc로 닫는다 (사용자가 넘기는 것과 같음)
  if "$P" wins | grep -Eq "· 층 0 · ([89][0-9]{2}|[0-9]{4})x"; then t 5 "$P" press escape; sleep 2; fi
  IDLE=$(cpu_pct "$PID" 10)
  le "$IDLE" 2 && put ✓ "$NAME: 쉬는 동안 CPU ${IDLE}% (기준 2% 이하)" || put ✗ "$NAME: 쉬는 동안 CPU ${IDLE}% (기준 2% 이하)"
  # 설정 창: ⌘, 를 누르고 뜨는 데 걸린 시간
  T0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time'); t 5 "$P" press comma
  OPENED=""; for _ in $(seq 1 40); do [ "$(t 3 "$P" settings)" = yes ] && { OPENED=$(perl -MTime::HiRes=time -e 'printf "%.3f", time'); break; }; sleep 0.05; done
  if [ -z "$OPENED" ]; then put ✗ "$NAME: ⌘, 뒤 2초 안에 설정 창이 뜨지 않음 (창: $("$P" wins | tr '\n' ';'))"
  else
    MS=$(awk -v a="$T0" -v b="$OPENED" 'BEGIN{ printf "%d", (b-a)*1000 - 300 }')   # 앱을 앞으로 하는 0.3초는 뺀다
    le "$MS" 1000 && put ✓ "$NAME: 설정 창이 ${MS}ms 만에 뜸 (기준 1초)" || put ✗ "$NAME: 설정 창이 ${MS}ms 만에 뜸 (기준 1초)"
    sleep 1
    SEEN1=$(defaults read $DOM pro.lastSeen 2>/dev/null || echo 없음)
    OPEN_CPU=$(cpu_pct "$PID" 5)
    SEEN2=$(defaults read $DOM pro.lastSeen 2>/dev/null || echo 없음)
    le "$OPEN_CPU" 3 && put ✓ "$NAME: 설정 창을 연 동안 CPU ${OPEN_CPU}% (기준 3% 이하)" || put ✗ "$NAME: 설정 창을 연 동안 CPU ${OPEN_CPU}% (기준 3% 이하)"
    [ "$SEEN1" = "$SEEN2" ] && put ✓ "$NAME: 설정 창을 연 5초 동안 체험 시각 저장 0번" || put ✗ "$NAME: 설정 창을 연 동안 체험 시각이 계속 저장됨 ($SEEN1 → $SEEN2)"
    t 5 "$P" press w; sleep 1
  fi
  RSS=$(ps -o rss= -p "$PID" 2>/dev/null | awk '{printf "%d", $1/1024}')
  le "${RSS:--1}" 200 && put ✓ "$NAME: 메모리 ${RSS}MB (기준 200MB 이하)" || put ✗ "$NAME: 메모리 ${RSS:-?}MB (기준 200MB 이하)"
  kill -0 "$PID" 2>/dev/null && put ✓ "$NAME: 끝까지 살아 있음" || put ✗ "$NAME: 점검 중 앱이 꺼짐"
  CR=$(ls ~/Library/Logs/DiagnosticReports/Dropfit* 2>/dev/null)
  [ -z "$CR" ] && put ✓ "$NAME: 충돌·멈춤 보고서 0개" || { put ✗ "$NAME: 보고서 $CR"; cp $CR "$OUT/" 2>/dev/null; }
done
reset_all

{ echo "### 사용자 상태 점검 · macOS $(sw_vers -productVersion) · Dropfit $VER ${TAG}"; echo; for r in "${ROWS[@]}"; do echo "- $r"; done; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
log ""; log "결과: $([ $FAILS = 0 ] && echo '✓ 모두 통과' || echo "✗ ${FAILS}건 실패")"
exit $([ $FAILS = 0 ] && echo 0 || echo 1)
