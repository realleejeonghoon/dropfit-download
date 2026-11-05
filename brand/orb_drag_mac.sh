#!/bin/bash
# 오브 끌어 옮기기 재현 (깨끗한 Mac CI 전용). 클리앙 제보(11/5): 처음 설치하고 오브를 끌어도 안 옮겨졌는데, 지웠다 다시 설치하니 됨.
#   bash brand/orb_drag_mac.sh 옛zip 새zip 보고서폴더
# 사람처럼 다운로드 폴더에 받은 앱(격리 표시)을 열고, 뜨는 창(Gatekeeper·응용 프로그램 폴더로 옮기기)에 답한 뒤
# 실제 마우스로 오브를 (-220, +160)pt 끌어 창이 실제로 옮겨졌는지 화면 서버 기준으로 잰다.
# 이 점검은 /Applications의 Dropfit을 지우고 새로 깔며 Dropfit 설정을 초기화한다. GitHub의 깨끗한 Mac에서만 돈다
if [ "${GITHUB_ACTIONS:-}" != true ]; then echo "멈춤: 이 점검은 GitHub의 깨끗한 Mac 전용입니다(설치된 Dropfit을 지우고 설정을 초기화함). 실제로 쓰는 Mac에서는 돌리지 마세요."; exit 3; fi
set -u
OLD="$1"; NEW="$2"; OUT="$3"; mkdir -p "$OUT"
HERE="$(cd "$(dirname "$0")" && pwd)"
M="$OUT/orb_mouse"; swiftc -O "$HERE/orb_mouse.swift" -o "$M" 2>"$OUT/swiftc.txt" || { cat "$OUT/swiftc.txt"; exit 1; }
DOM=app.dropfit.prototype
# 처음부터 끝까지 시스템 기록을 받아 둔다(다시 열기 실패 원인용): sh(다시 열기 도우미)·open·Dropfit, launchd·runningboardd가 Dropfit을 언급한 줄
sudo -n log stream --style compact --info --debug \
  --predicate 'process == "sh" OR process == "open" OR process == "Dropfit" OR process == "xattr" OR ((process == "launchd" OR process == "runningboardd" OR process == "syspolicyd" OR process == "launchservicesd") AND (eventMessage CONTAINS[c] "dropfit" OR eventMessage CONTAINS[c] "/bin/sh"))' \
  >"$OUT/stream.txt" 2>&1 &
STREAM_PID=$!
DX=-220; DY=160
# 이름표: zip 속 앱의 버전(빌드). 옛 줄은 비교용이라 실패로 세지 않는다
zver() { local d; d="$(mktemp -d)"; ditto -x -k "$1" "$d"; local pl="$d/Dropfit/Dropfit.app/Contents/Info.plist"
  echo "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$pl")($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$pl"))"; rm -rf "$d"; }
OV="공개 $(zver "$OLD")"; NV="새 $(zver "$NEW")"
ROWS=(); FAILS=0
log() { echo "$*" | tee -a "$OUT/log.txt"; }
# 멈출 수 있는 명령(권한 묻는 창 등)은 시간 제한을 둔다
t() { local n="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$n" "$@"; }
PRE="$(t 10 "$M" preflight)"; log "macOS $(sw_vers -productVersion) · $PRE"
shot() { case "$PRE" in *"화면 찍기 허용"*) t 5 screencapture -x "$1" 2>/dev/null;; esac; }

reset_all() {
  pkill -x Dropfit 2>/dev/null; pkill -x CoreServicesUIAgent 2>/dev/null; sleep 1; pkill -9 -x Dropfit 2>/dev/null
  rm -rf /Applications/Dropfit.app ~/Applications/Dropfit.app ~/Downloads/Dropfit
  defaults delete $DOM >/dev/null 2>&1
}

unpack() {   # Safari처럼 다운로드 폴더에 풀고 격리 표시
  rm -rf ~/Downloads/Dropfit
  ditto -x -k "$1" ~/Downloads
  # 00c3 = 인터넷에서 받음 + 사용자가 Gatekeeper 창에서 [열기]를 이미 누름. (CI에서는 그 창의 버튼을 누를 수 없어 누른 뒤 상태로 시작)
  # 이 상태에서도 macOS는 앱을 임시 위치(App Translocation)에서 실행한다 = 실제 사용자의 첫 실행과 같다
  xattr -r -w com.apple.quarantine "00c3;$(printf %x "$(date +%s)");Safari;" ~/Downloads/Dropfit
}

running() { ps -axo pid=,command= | grep "Dropfit.app/Contents/MacOS/Dropfit" | grep -v grep | sed 's/^ *//' | awk '{p=$1; $1=""; print p":"$0}' | tr '\n' ';'; }

# 뜨는 창에 답하며 오브가 나타날 때까지 (최대 40초). 답한 창은 기록한다
wait_orb() {
  local tag="$1" answered="" i lastsig=""
  local end=$((SECONDS + 40)); i=0
  while [ $SECONDS -lt $end ]; do i=$((i+1))
    if [ "$(t 5 "$M" orb)" != none ]; then
      # 오브가 뜬 뒤에도 옮기기 질문 창이 함께 떠 있을 수 있으니 한 번 더 본다
      if "$M" wins | grep -q "^Dropfit · 층 0 "; then :; fi
      log "  · 오브 나타남 ($((40 - end + SECONDS))초) · 답한 창: ${answered:-없음} · 실행 중: $(running)"
      return 0
    fi
    local w; w="$(t 5 "$M" wins)"
    local sig; sig="$(echo "$w" | grep -v '^Window Server\|^Dock\|^Control Center\|^SystemUIServer\|^Spotlight\|^Wallpaper\|^TextInputMenuAgent\|^Notification' | sed 's/ · [-0-9]*,[-0-9]* / · /' | sort | tr '\n' ',')"
    [ "$sig" != "${lastsig:-}" ] && { log "    $((40 - end + SECONDS))초 창: ${sig:-없음}"; lastsig="$sig"; }
    if echo "$w" | grep -q "^CoreServicesUIAgent"; then
      shot "$OUT/$tag-gatekeeper.png"
      t 5 "$M" key return; answered="$answered Gatekeeper(열기)"; sleep 1.5; continue
    fi
    if echo "$w" | grep -q "^Dropfit "; then
      shot "$OUT/$tag-alert.png"
      echo "$w" | grep "^Dropfit " >>"$OUT/$tag-alert-wins.txt"
      t 5 "$M" key return; answered="$answered 옮길까요(옮기기)"; sleep 2; continue
    fi
    sleep 0.5
  done
  log "  ✗ 40초 안에 오브가 나타나지 않음 · 실행 중: $(running)"; t 5 "$M" wins >"$OUT/$tag-nowin.txt"
  log "    화면에 있는 창:"; sed 's/^/      /' "$OUT/$tag-nowin.txt" | tee -a "$OUT/log.txt"
  # 원인 기록: 앱이 어디에 있는지(옮기기가 됐는지), 남은 프로세스, 다시 열기(open) 앞뒤 시스템 기록
  {
    echo "    앱 위치: /Applications $( [ -d /Applications/Dropfit.app ] && echo 있음 || echo 없음 ) · 다운로드 $( [ -d "$HOME/Downloads/Dropfit/Dropfit.app" ] && echo 있음 || echo 없음 )"
    echo "    격리 표시(/Applications): $(xattr -p com.apple.quarantine /Applications/Dropfit.app 2>/dev/null || echo 없음)"
    echo "    관련 프로세스:"; ps -axo pid,ppid,stat,lstart,command | grep -i 'dropfit\|/usr/bin/open\|kill -0' | grep -v grep | sed 's/^/      /'
    echo "    받아 둔 시스템 기록(마지막 120줄):"; grep -v 'orb_mouse' "$OUT/stream.txt" | tail -120 | sed 's/^/      /'
    echo "    시스템 기록(최근 90초, open·sh·Dropfit·LaunchServices·실행 정책):"
    sudo -n log show --last 90s --style compact --info \
      --predicate 'process == "open" OR process == "sh" OR process == "Dropfit" OR subsystem == "com.apple.launchservices" OR (process == "syspolicyd" AND eventMessage CONTAINS[c] "dropfit") OR (process == "launchd" AND eventMessage CONTAINS[c] "dropfit") OR (process == "runningboardd" AND eventMessage CONTAINS[c] "dropfit")' \
      2>&1 | grep -v 'orb_mouse\|XPC_ERROR on connection from our client\|re-boostrap client' | tail -150 | sed 's/^/      /'
  } >"$OUT/$tag-diag.txt" 2>&1
  tee -a "$OUT/log.txt" <"$OUT/$tag-diag.txt"
  return 1
}

# 오브 한가운데를 눌러 끌고, 창이 실제로 옮겨졌는지
drag_test() {
  local tag="$1" label="$2"
  local b a; b=($("$M" orb))
  [ "${b[0]}" = none ] && { put bad "$label: 오브 없음"; return; }
  local cx=$((b[0] + b[2] / 2)) cy=$((b[1] + b[3] / 2))
  local others; others="$("$M" wins | grep '^Dropfit ' | grep -v " ${b[2]}x${b[3]}$" | wc -l | tr -d ' ')"
  shot "$OUT/$tag-before.png"
  t 10 "$M" drag $cx $cy $DX $DY; sleep 1
  a=($("$M" orb))
  local mx=$((a[0] - b[0])) my=$((a[1] - b[1]))
  local saved; saved="$(defaults read $DOM orb.center 2>/dev/null || echo 없음)"
  local after; after="$("$M" wins | grep '^Dropfit ' | grep -v " ${a[2]}x${a[3]}$" | wc -l | tr -d ' ')"
  local verdict=bad; [ $mx -eq $DX ] && [ $my -eq $DY ] && verdict=ok
  put $verdict "$label: 이동 ($mx, $my)pt / 기대 ($DX, $DY) · 말풍선 등 다른 Dropfit 창 끌기 전 ${others}개→뒤 ${after}개 · 저장된 자리 $saved"
}

# 실패로 치는 것은 이 PR의 새 버전뿐 (공개 버전 줄은 비교용 기록)
put() { local s="✓"; [ "$1" = ok ] || { s="✗"; case "$2" in "[${OV}]"*) ;; *) FAILS=$((FAILS+1));; esac; }; ROWS+=("$s $2"); log "  $s $2"; }

scenario_fresh() {   # 처음 설치: 다운로드 폴더에서 열기 → 옮기기 → 새 자리에서 다시 실행
  local v="$1" zip="$2" t="$1-처음"
  log "[$v] 처음 설치 (다운로드 폴더 → 옮기기), 2초 뒤와 10초 뒤 끌기"
  reset_all; unpack "$zip"; (open ~/Downloads/Dropfit/Dropfit.app &)
  wait_orb "$t" || { put bad "[$v] 처음 설치: 오브가 뜨지 않음"; return; }
  sleep 2; drag_test "$t-2s" "[$v] 처음 설치, 안내 말풍선이 떠 있는 2초 뒤"
  sleep 0.5; drag_test "$t-4s" "[$v] 처음 설치, 바로 한 번 더 (약 4초 뒤)"
  sleep 5; drag_test "$t-10s" "[$v] 처음 설치, 말풍선이 닫힌 10초 뒤"
  log "  · 설정: $(defaults read $DOM 2>/dev/null | tr -s ' \n' ' ')"
}

scenario_wait() {    # 처음 설치 후 아무것도 누르지 않고 기다렸다가 끌기
  local v="$1" zip="$2" t="$1-기다림"
  log "[$v] 처음 설치 후 12초 기다렸다가 처음 끌기"
  reset_all; unpack "$zip"; (open ~/Downloads/Dropfit/Dropfit.app &)
  wait_orb "$t" || { put bad "[$v] 처음 설치(기다림): 오브가 뜨지 않음"; return; }
  sleep 12; drag_test "$t" "[$v] 처음 설치, 12초 뒤 첫 끌기"
}

scenario_reinstall() {  # 지우고 다시 설치 (설정은 남음)
  local v="$1" zip="$2" t="$1-다시"
  log "[$v] 지웠다 다시 설치 (설정 남음)"
  pkill -x Dropfit; pkill -x CoreServicesUIAgent 2>/dev/null; sleep 1; rm -rf /Applications/Dropfit.app
  unpack "$zip"; (open ~/Downloads/Dropfit/Dropfit.app &)
  wait_orb "$t" || { put bad "[$v] 다시 설치: 오브가 뜨지 않음"; return; }
  sleep 2; drag_test "$t" "[$v] 지웠다 다시 설치, 2초 뒤"
}

scenario_stay() {    # '그대로 두기': 다운로드 폴더(임시 위치)에서 그대로 실행
  local v="$1" zip="$2" t="$1-그대로"
  log "[$v] 옮기지 않고 다운로드 폴더에서 실행 (임시 위치)"
  reset_all; unpack "$zip"; defaults write $DOM mover.dontAsk -bool true
  (open ~/Downloads/Dropfit/Dropfit.app &)
  wait_orb "$t" || { put bad "[$v] 그대로 두기: 오브가 뜨지 않음"; return; }
  sleep 2; drag_test "$t-2s" "[$v] 옮기지 않고 실행, 2초 뒤"
  sleep 8; drag_test "$t-10s" "[$v] 옮기지 않고 실행, 10초 뒤"
}

scenario_update() {  # 공개 버전을 쓰던 Mac에 새 버전을 덮어씀 (자동 업데이트처럼 같은 자리 교체)
  local moved="$1" t="업데이트-$1"
  log "[${OV}→${NV}] 업데이트 · 옛 버전에서 오브를 옮겨 둔 적 $moved"
  reset_all; W="$OUT/old"; rm -rf "$W"; mkdir -p "$W"; ditto -x -k "$OLD" "$W"
  ditto "$W/Dropfit/Dropfit.app" /Applications/Dropfit.app
  (open /Applications/Dropfit.app &); wait_orb "$t-old" || return
  sleep 9
  if [ "$moved" = 있음 ]; then drag_test "$t-old" "[${OV}] 업데이트 전 옮겨 두기"; fi
  pkill -x Dropfit; sleep 2
  W2="$OUT/new"; rm -rf "$W2"; mkdir -p "$W2"; ditto -x -k "$NEW" "$W2"
  rm -rf /Applications/Dropfit.app; ditto "$W2/Dropfit/Dropfit.app" /Applications/Dropfit.app
  (open /Applications/Dropfit.app &); wait_orb "$t" || { put bad "업데이트: 오브가 뜨지 않음"; return; }
  sleep 2; drag_test "$t" "[${OV}→${NV}] 업데이트 후 2초 뒤 (옮겨 둔 자리 $moved)"
}

log "--- 시작 $(date +%T)"
# 매일 점검(공개 버전 하나)에서는 같은 zip이므로 한 번만, 실패로 센다
PAIRS=("${OV}|$OLD" "${NV}|$NEW"); cmp -s "$OLD" "$NEW" && { NV="공개 $(zver "$NEW")"; OV="같은 버전"; PAIRS=("${NV}|$NEW"); }
for pair in "${PAIRS[@]}"; do
  v="${pair%%|*}"; z="${pair#*|}"
  scenario_fresh "$v" "$z"
  scenario_reinstall "$v" "$z"
  scenario_wait "$v" "$z"
  scenario_stay "$v" "$z"
done
if [ ${#PAIRS[@]} -gt 1 ]; then scenario_update 있음; scenario_update 없음; fi
reset_all

{ echo "### 오브 끌어 옮기기 재현 · macOS $(sw_vers -productVersion) · $("$M" preflight)"; echo; for r in "${ROWS[@]}"; do echo "- $r"; done; echo; } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" >"$OUT/summary.md"
echo; printf '%s\n' "${ROWS[@]}"; echo
[ $FAILS -eq 0 ] && echo "새 버전 통과" || echo "새 버전 ${FAILS}건 다름"
exit $([ $FAILS -eq 0 ] && echo 0 || echo 1)
