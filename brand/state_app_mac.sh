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
put() { echo "$1 $2"; ROWS+=("$1 $2"); if [ "$1" = "✗" ]; then FAILS=$((FAILS+1)); fi; return 0; }
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
  defaults write $DOM usage.enabled -bool false   # 점검 Mac은 사용자가 아니다: 사용 통계(F-013)를 꺼서 설치·체험 수에 섞이지 않게 한다 (2026-11-21 정훈 님)
  for s in $DOM.trial $DOM.license; do security delete-generic-password -s "$s" >/dev/null 2>&1; done
  rm -f ~/Library/Logs/DiagnosticReports/Dropfit* 2>/dev/null
}

# 0.6에서 온 사용자 (11/24 QUALITY 7-2 빈칸): 0.6.12를 깔아 실제로 한 번 열어 그 판의 설정을 만든 뒤, 새 앱으로 바꿔 연다(Sparkle 설치 뒤와 같은 자리)
OLD06="${OLD06_ZIP:-}"
# 시험용 RSA 키와 그 키로 서명한 Pro 키 (실제 키와 무관). 'Pro 키' 상태는 설치한 앱의 공개 키 칸만 이 시험 키로 바꾸고 임시 서명한다
mk_test_key() {
  openssl genrsa -out "$OUT/tk.pem" 2048 2>/dev/null && openssl rsa -in "$OUT/tk.pem" -pubout -out "$OUT/tk.pub" 2>/dev/null || return 1
  b64u() { base64 | tr '+/' '-_' | tr -d '=\n'; }
  local body; body=$(printf '%s' '{"o":"STATE-CHECK","p":"pro","t":"2026-11-24"}' | b64u)
  echo "$body.$(printf '%s' "$body" | openssl dgst -sha256 -sign "$OUT/tk.pem" | b64u)"
}
defaults_snapshot() {   # 사용자가 정한 값만(체험·통계·업데이트 기록·창 자리 제외) 정렬한 줄로
  defaults export $DOM - 2>/dev/null | python3 -I -c 'import plistlib,sys
d=plistlib.loads(sys.stdin.buffer.read() or plistlib.dumps({}))
skip=("pro.","usage.","SU","NSWindow","NSStatusItem","NSNavPanel","orb.center")
for k in sorted(d):
    if not k.startswith(skip): print(k, "=", repr(d[k])[:120])'
}
has_item() { security find-generic-password -a dropfit -s "$DOM.$1" >/dev/null 2>&1; }   # 값은 읽지 않는다(허용 창 없음)
quit_app() { osascript -e 'tell application "Dropfit" to quit' >/dev/null 2>&1; sleep 2; pkill -x Dropfit 2>/dev/null; sleep 1; }
setup_state() {   # $1 = 상태 표시. 앱을 깔고 그 상태를 만든다
  case "$1" in
    06|06key)
      [ -n "$OLD06" ] && [ -f "$OLD06" ] || { put ✗ "$NAME: 0.6 zip이 주어지지 않음(OLD06_ZIP)"; return 1; }
      rm -rf "$OUT/o6"; mkdir -p "$OUT/o6"; ditto -x -k "$OLD06" "$OUT/o6"
      ditto --noextattr "$(find "$OUT/o6" -maxdepth 2 -name Dropfit.app -type d | head -1)" /Applications/Dropfit.app
      open /Applications/Dropfit.app; sleep 10
      quit_app
      defaults read $DOM orb.onboarded >/dev/null 2>&1 || defaults write $DOM orb.onboarded -bool true   # 0.6에서 첫 안내를 지난 분
      defaults_snapshot > "$OUT/06-before.txt"
      rm -rf /Applications/Dropfit.app; ditto --noextattr "$APP" /Applications/Dropfit.app
      if [ "$1" = 06key ]; then
        # 구입한 분이 메일의 '활성화' 버튼(dropfit://activate?key=…)을 누르는 길. 키체인 항목은 앱이 스스로 만든다
        # (security 명령으로 넣은 항목은 다른 앱이 읽을 때 허용 창이 떠 앱이 멈춘다: 11/24 첫 실행에서 창 0개·체험 시작일 없음)
        local key bad; key=$(mk_test_key) || { put ✗ "$NAME: 시험 키를 만들지 못함"; return 1; }
        bad="${key%?????}AAAAA"   # 서명 끝을 바꾼 키: 저장되면 안 된다
        /usr/libexec/PlistBuddy -c "Set :DFLicensePublicKey $(grep -v -- ----- "$OUT/tk.pub" | tr -d '\n')" /Applications/Dropfit.app/Contents/Info.plist
        codesign --force --deep -s - /Applications/Dropfit.app >/dev/null 2>&1
        open /Applications/Dropfit.app; sleep 8
        open "dropfit://activate?key=$bad"; sleep 3
        has_item license && put ✗ "$NAME: 서명이 틀린 키가 저장됨" || put ✓ "$NAME: 서명이 틀린 키는 저장하지 않음"
        open "dropfit://activate?key=$key"; sleep 3
        has_item license && put ✓ "$NAME: 메일 버튼의 키로 Pro 활성화(키체인에 저장)" || put ✗ "$NAME: 메일 버튼의 키가 저장되지 않음"
        quit_app
      fi ;;
    re3)   # 체험 3일째에 앱을 지우고 다시 받은 분: 설정은 없고 앱이 키체인에 남긴 체험 시작일만 있다 → 첫 실행 인트로, 체험은 이어서
      ditto --noextattr "$APP" /Applications/Dropfit.app
      REEPOCH=$(( $(date +%s) - 3 * 86400 ))
      defaults write $DOM pro.trialStart -date "$(date -u -r "$REEPOCH" '+%Y-%m-%d %H:%M:%S +0000')"
      defaults write $DOM orb.onboarded -bool true
      open /Applications/Dropfit.app
      for _ in $(seq 1 30); do has_item trial && break; sleep 0.5; done
      has_item trial || { put ✗ "$NAME: 앱이 키체인에 체험 시작일을 남기지 않음"; quit_app; return 1; }
      quit_app
      rm -rf /Applications/Dropfit.app; defaults delete $DOM >/dev/null 2>&1
      defaults write $DOM usage.enabled -bool false
      ditto --noextattr "$APP" /Applications/Dropfit.app ;;
    "") ditto --noextattr "$APP" /Applications/Dropfit.app ;;
    *)
      ditto --noextattr "$APP" /Applications/Dropfit.app
      defaults write $DOM pro.trialStart -date "$(date -u -v-"${1}"d '+%Y-%m-%d %H:%M:%S +0000')"
      defaults write $DOM orb.onboarded -bool true ;;   # 이미 쓰던 사용자: 첫 안내 없이 바로
  esac
}
# 상태별로 앱을 연 뒤 따로 보는 것
check_state() {
  case "$1" in
    06|06key)
      defaults read $DOM pro.trialStart >/dev/null 2>&1 && put ✓ "$NAME: 체험 시작일을 정해 둠" || put ✗ "$NAME: 체험 시작일이 없음"
      W=$(defaults read $DOM pro.welcomed 2>/dev/null || echo 0)
      [ "$W" = 1 ] && put ✓ "$NAME: 이미 쓰던 분께 체험 안내 한 번" || put ✗ "$NAME: 체험 안내가 뜨지 않음(pro.welcomed=$W)"
      [ "$1" = 06 ] || { has_item license && put ✓ "$NAME: 다시 열어도 Pro 키가 남아 있음" || put ✗ "$NAME: 다시 연 뒤 Pro 키가 사라짐"; }
      defaults_snapshot > "$OUT/06-after-$1.txt"
      LOST=$(comm -23 <(sort "$OUT/06-before.txt") <(sort "$OUT/06-after-$1.txt") | head -5 | tr '\n' ';')
      [ -z "$LOST" ] && put ✓ "$NAME: 0.6에서 정한 설정 $(wc -l < "$OUT/06-before.txt" | tr -d ' ')개 그대로" || put ✗ "$NAME: 0.6 설정이 바뀌거나 사라짐: $LOST" ;;
    re3)
      S=$(defaults read $DOM pro.trialStart 2>/dev/null)
      SE=$( [ -n "$S" ] && date -j -u -f '%Y-%m-%d %H:%M:%S +0000' "$S" +%s 2>/dev/null || echo 0)
      D=$(( SE - REEPOCH )); [ ${D#-} -le 5 ] && put ✓ "$NAME: 다시 깔아도 체험이 3일째에서 이어짐" || put ✗ "$NAME: 다시 깐 뒤 체험 시작일이 바뀜(${S:-없음}, 키체인과 ${D}초 차이)" ;;
  esac
  return 0
}

# 상태: 이름 · 표시(숫자 = 체험 시작 며칠 전, 빈칸 = 처음 설치, 06 = 0.6에서 옴, 06key = 0.6에서 옴+메일 버튼으로 Pro 활성화, re3 = 체험 중 다시 설치)
for st in "처음 설치:" "체험 중 3일째:3" "체험 끝:20" "0.6에서 옴:06" "0.6에서 옴 + Pro 키:06key" "체험 중 다시 설치(첫 실행):re3"; do
  NAME="${st%%:*}"; AGO="${st#*:}"
  log ""; log "▸ $NAME"
  reset_all
  setup_state "$AGO" || continue
  open /Applications/Dropfit.app
  PID=""; for _ in $(seq 1 40); do PID=$(pgrep -x Dropfit | head -1); [ -n "$PID" ] && break; sleep 0.5; done
  [ -n "$PID" ] || { put ✗ "$NAME: 20초 안에 앱이 켜지지 않음"; continue; }
  sleep 6
  # 처음 설치: 인트로(큰 창)가 떠 있으면 Esc로 닫는다 (사용자가 넘기는 것과 같음)
  if "$P" wins | grep -Eq "· 층 0 · ([89][0-9]{2}|[0-9]{4})x"; then t 5 "$P" press escape; sleep 2; fi
  # 이미 쓰던 사용자: 업데이트 뒤 처음 열 때 인사(로고 모션 약 6.4초)와 자리 반짝임 세 번(약 4.4초)이 한 번 지나간다(빌드 48).
  # 인사 창은 저절로 닫혀야 한다. 쉬는 동안 CPU는 인사·반짝임이 끝난 뒤에 잰다 (기준 2%는 그대로, 2026-11-24 정훈 님 결정)
  if [ -n "$AGO" ] && [ "$AGO" != re3 ]; then
    for _ in $(seq 1 30); do "$P" wins | grep -Eq "· 층 0 · ([89][0-9]{2}|[0-9]{4})x" || break; sleep 0.5; done
    "$P" wins | grep -Eq "· 층 0 · ([89][0-9]{2}|[0-9]{4})x" && put ✗ "$NAME: 업데이트 인사 창이 15초 안에 닫히지 않음"
    sleep 5
  fi
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
  check_state "$AGO"
  CR=$(ls ~/Library/Logs/DiagnosticReports/Dropfit* 2>/dev/null)
  [ -z "$CR" ] && put ✓ "$NAME: 충돌·멈춤 보고서 0개" || { put ✗ "$NAME: 보고서 $CR"; cp $CR "$OUT/" 2>/dev/null; }
done
reset_all

{ echo "### 사용자 상태 점검 · macOS $(sw_vers -productVersion) · Dropfit $VER ${TAG}"; echo; for r in "${ROWS[@]}"; do echo "- $r"; done; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
log ""; log "결과: $([ $FAILS = 0 ] && echo '✓ 모두 통과' || echo "✗ ${FAILS}건 실패")"
exit $([ $FAILS = 0 ] && echo 0 || echo 1)
