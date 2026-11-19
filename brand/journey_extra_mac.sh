#!/bin/bash
# 고객 여정 지도 남은 앱 화면(D-04 첫 변환 뒤 말풍선, H-02 업데이트 창, H-03 Dock 메뉴, I-04 피드백 메일)을 깨끗한 Mac에서 찍는다.
#   bash brand/journey_extra_mac.sh 공개zip 이전판zip(0.6.12) 결과폴더
if [ "${GITHUB_ACTIONS:-}" != true ]; then echo "멈춤: GitHub의 깨끗한 Mac 전용입니다(설치된 Dropfit과 설정을 지움)."; exit 3; fi
set -u
ZIP="$1"; OLD="$2"; OUT="$3"; mkdir -p "$OUT"
HERE="$(cd "$(dirname "$0")" && pwd)"
I="$OUT/journey_input"; swiftc -O "$HERE/journey_input.swift" -o "$I" 2>"$OUT/swiftc.txt" || exit 1
DOM=app.dropfit.prototype; APP=/Applications/Dropfit.app
KC="$HOME/Library/Keychains/journey.keychain-db"
security create-keychain -p j "$KC" 2>/dev/null; security list-keychains -d user -s "$KC"; security default-keychain -d user -s "$KC"; security unlock-keychain -p j "$KC"; security set-keychain-settings "$KC"
defaults write com.apple.universalaccess reduceTransparency -bool false 2>/dev/null
t() { perl -e 'alarm shift; exec @ARGV' "$@"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
shot() { t 8 screencapture -x "$OUT/$1.png" && log "  📷 $1"; t 5 "$I" wins | grep -v "^Window Server\|^Wallpaper" >"$OUT/$1.wins.txt"; }
orb() { t 5 "$I" wins | grep "^Dropfit " | awk -F' · ' '{split($4,a," "); split(a[1],p,","); split(a[2],s,"x"); if (s[1]==s[2] && s[1]>40 && s[1]<600) print p[1]+s[1]/2, p[2]+s[2]/2}' | head -1; }
wait_orb() { for _ in $(seq 1 40); do [ -n "$(orb)" ] && return 0; sleep 0.5; done; log "  ✗ 동그라미 없음"; return 1; }
reset() { pkill -x Dropfit; sleep 1; rm -rf "$APP"; defaults delete $DOM >/dev/null 2>&1; security delete-generic-password -s app.dropfit.prototype.trial -a dropfit >/dev/null 2>&1; }
install() { W="$(mktemp -d)"; ditto -x -k "$1" "$W"; A=$(find "$W" -maxdepth 3 -name Dropfit.app | head -1); ditto "$A" "$APP"; xattr -dr com.apple.quarantine "$APP"; }
lang() {
  if [ "$1" = ko ]; then defaults write -g AppleLanguages -array ko-KR en-US; else defaults write -g AppleLanguages -array en-US; fi
  killall Finder Dock SystemUIServer cfprefsd >/dev/null 2>&1; sleep 4
}
[ -f ~/Desktop/sample.png ] || sips -s format png "$(ls /System/Library/Desktop\ Pictures/*.heic | head -1)" --resampleWidth 1600 --out ~/Desktop/sample.png >/dev/null 2>&1
dockmenu() {   # Dock의 Dropfit 아이콘 메뉴 열기(System Events). 안 되면 오류를 남긴다
  t 10 osascript -e 'tell application "System Events" to tell process "Dock" to perform action "AXShowMenu" of UI element "Dropfit" of list 1' 2>>"$OUT/osascript.txt"
}
for L in ko en; do
  log "=== $L"; lang $L
  # D-04: 새 사용자 첫 변환 (인트로는 이미 본 상태)
  # 새 사용자 그대로: 인트로를 Esc로 닫은 뒤 첫 변환 (orb.onboarded를 미리 켜면 기존 사용자 안내가 대신 뜸)
  reset; install "$ZIP"
  (open --env DROPFIT_LANG=$L "$APP" &)
  for _ in $(seq 1 40); do t 5 "$I" wins | grep -q "^Dropfit .*· [89][0-9][0-9]x[67][0-9][0-9]\|^Dropfit .*· 1024x" && break; sleep 0.5; done
  sleep 3; t 5 "$I" key escape; sleep 3; wait_orb; sleep 1
  (open -a "$APP" ~/Desktop/sample.png &); sleep 2.5; c=$(orb)
  if [ -n "$c" ]; then set -- $c; t 5 "$I" click $(( ${1%.*} - 55 )) $(( ${2%.*} + 50 )); sleep 2.5; shot "D-04-$L-after-first"; sleep 3; shot "D-04-$L-after-first-2"; fi
  # I-04: 우클릭 → 피드백 보내기… (켜진 항목만 아래 화살표로: 파일 선택·이미지 골라 자르기·바탕화면에 고정·로그인 시 열기·설정·피드백)
  c=$(orb); if [ -n "$c" ]; then set -- $c; t 5 "$I" rclick "$1" "$2"; sleep 1; for _ in 1 2 3 4 5 6 7 8; do t 5 "$I" key down; sleep 0.2; done; shot "I-04-$L-menu"; t 5 "$I" key return; sleep 6; shot "I-04-$L-mail"; pkill -x Mail; sleep 1; fi
  # H-02·H-03: 0.6.12를 설치하고 Dock 메뉴 '업데이트 확인…' (사람이 직접 누른 확인 = 단계 공개를 기다리지 않음)
  reset; install "$OLD"; defaults write $DOM orb.onboarded -bool true; defaults write $DOM SUHasLaunchedBefore -bool true; defaults write $DOM SUEnableAutomaticChecks -bool true
  (open --env DROPFIT_LANG=$L "$APP" &); wait_orb; sleep 2
  dockmenu; sleep 1.2; shot "H-03-$L-dock-menu"
  M=$([ $L = ko ] && echo "업데이트 확인…" || echo "Check for Updates…")
  t 10 osascript -e "tell application \"System Events\" to tell process \"Dock\" to click menu item \"$M\" of menu 1 of UI element \"Dropfit\" of list 1" 2>>"$OUT/osascript.txt" || true
  t 10 osascript -e 'tell application "System Events" to tell process "Dock" to get name of every menu item of menu 1 of UI element "Dropfit" of list 1' >>"$OUT/osascript.txt" 2>&1
  for k in $(seq 1 30); do sleep 1; t 5 "$I" wins | grep -q "^Dropfit .*· [4-9][0-9][0-9]x[3-9][0-9][0-9]" && break; done
  sleep 2; shot "H-02-$L-update-window"
  t 5 "$I" key escape; pkill -x Dropfit
done
reset
ls "$OUT"/*.png | wc -l | xargs echo "찍은 화면:" | tee -a "$OUT/log.txt"
