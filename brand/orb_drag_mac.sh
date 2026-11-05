#!/bin/bash
# 오브 끌어 옮기기 재현 (깨끗한 Mac CI 전용). 클리앙 제보(11/5): 처음 설치하고 오브를 끌어도 안 옮겨졌는데, 지웠다 다시 설치하니 됨.
#   bash brand/orb_drag_mac.sh 옛zip 새zip 보고서폴더
# 사람처럼 다운로드 폴더에 받은 앱(격리 표시)을 열고, 뜨는 창(Gatekeeper·응용 프로그램 폴더로 옮기기)에 답한 뒤
# 실제 마우스로 오브를 (-220, +160)pt 끌어 창이 실제로 옮겨졌는지 화면 서버 기준으로 잰다.
set -u
OLD="$1"; NEW="$2"; OUT="$3"; mkdir -p "$OUT"
HERE="$(cd "$(dirname "$0")" && pwd)"
M="$OUT/orb_mouse"; swiftc -O "$HERE/orb_mouse.swift" -o "$M" 2>"$OUT/swiftc.txt" || { cat "$OUT/swiftc.txt"; exit 1; }
DOM=app.dropfit.prototype
DX=-220; DY=160
ROWS=(); FAILS=0
log() { echo "$*" | tee -a "$OUT/log.txt"; }
# 멈출 수 있는 명령(권한 묻는 창 등)은 시간 제한을 둔다
t() { local n="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$n" "$@"; }
PRE="$(t 10 "$M" preflight)"; log "macOS $(sw_vers -productVersion) · $PRE"
shot() { case "$PRE" in *"화면 찍기 허용"*) t 5 screencapture -x "$1" 2>/dev/null;; esac; }

reset_all() {
  pkill -x Dropfit 2>/dev/null; sleep 1; pkill -9 -x Dropfit 2>/dev/null
  rm -rf /Applications/Dropfit.app ~/Applications/Dropfit.app ~/Downloads/Dropfit
  defaults delete $DOM >/dev/null 2>&1
}

unpack() {   # Safari처럼 다운로드 폴더에 풀고 격리 표시
  rm -rf ~/Downloads/Dropfit
  ditto -x -k "$1" ~/Downloads
  xattr -r -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;" ~/Downloads/Dropfit
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
  local verdict=bad; [ $mx -eq $DX ] && [ $my -eq $DY ] && verdict=ok
  put $verdict "$label: 이동 ($mx, $my)pt / 기대 ($DX, $DY) · 오브 말고 떠 있던 Dropfit 창 ${others}개 · 저장된 자리 $saved"
}

put() { local s="✓"; [ "$1" = ok ] || { s="✗"; FAILS=$((FAILS+1)); }; ROWS+=("$s $2"); log "  $s $2"; }

scenario_fresh() {   # 처음 설치: 다운로드 폴더에서 열기 → 옮기기 → 새 자리에서 다시 실행
  local v="$1" zip="$2" t="$1-처음"
  log "[$v] 처음 설치 (다운로드 폴더 → 옮기기), 2초 뒤와 10초 뒤 끌기"
  reset_all; unpack "$zip"; (open ~/Downloads/Dropfit/Dropfit.app &)
  wait_orb "$t" || { put bad "[$v] 처음 설치: 오브가 뜨지 않음"; return; }
  sleep 2; drag_test "$t-2s" "[$v] 처음 설치, 안내 말풍선이 떠 있는 2초 뒤"
  sleep 8; drag_test "$t-10s" "[$v] 처음 설치, 말풍선이 닫힌 10초 뒤"
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
  pkill -x Dropfit; sleep 1; rm -rf /Applications/Dropfit.app
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

scenario_update() {  # 0.6.6을 쓰던 Mac에 새 버전을 덮어씀 (자동 업데이트처럼 같은 자리 교체)
  local moved="$1" t="업데이트-$1"
  log "[0.6.6→새 버전] 업데이트 · 0.6.6에서 오브를 옮겨 둔 적 $moved"
  reset_all; W="$OUT/old"; rm -rf "$W"; mkdir -p "$W"; ditto -x -k "$OLD" "$W"
  ditto "$W/Dropfit/Dropfit.app" /Applications/Dropfit.app
  (open /Applications/Dropfit.app &); wait_orb "$t-old" || return
  sleep 9
  if [ "$moved" = 있음 ]; then drag_test "$t-old" "[0.6.6] 업데이트 전 옮겨 두기"; fi
  pkill -x Dropfit; sleep 2
  W2="$OUT/new"; rm -rf "$W2"; mkdir -p "$W2"; ditto -x -k "$NEW" "$W2"
  rm -rf /Applications/Dropfit.app; ditto "$W2/Dropfit/Dropfit.app" /Applications/Dropfit.app
  (open /Applications/Dropfit.app &); wait_orb "$t" || { put bad "업데이트: 오브가 뜨지 않음"; return; }
  sleep 2; drag_test "$t" "[0.6.6→새 버전] 업데이트 후 2초 뒤 (옮겨 둔 자리 $moved)"
}

log "--- 시작 $(date +%T)"
for pair in "0.6.6|$OLD" "새버전|$NEW"; do
  v="${pair%%|*}"; z="${pair#*|}"
  scenario_fresh "$v" "$z"
  scenario_reinstall "$v" "$z"
  scenario_wait "$v" "$z"
  scenario_stay "$v" "$z"
done
scenario_update 있음
scenario_update 없음
reset_all

{ echo "### 오브 끌어 옮기기 재현 · macOS $(sw_vers -productVersion) · $("$M" preflight)"; echo; for r in "${ROWS[@]}"; do echo "- $r"; done; echo; } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" >"$OUT/summary.md"
echo; printf '%s\n' "${ROWS[@]}"
exit 0
