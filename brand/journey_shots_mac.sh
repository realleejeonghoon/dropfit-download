#!/bin/bash
# 고객 여정 지도(접점 번호 A-01~I-04)에 넣을 앱·macOS 실제 화면을 찍는다 (깨끗한 Mac CI 전용).
#   bash brand/journey_shots_mac.sh 공개zip 결과폴더
# 공개 중인 zip을 사람처럼 다운로드 폴더에 받아 열고, 체험 중·체험 끝·기존 사용자·키 오류 상태를 만들어 한·영으로 찍는다.
# 이 점검은 /Applications의 Dropfit을 지우고 설정·키체인 항목을 초기화한다. GitHub의 깨끗한 Mac에서만 돈다
if [ "${GITHUB_ACTIONS:-}" != true ]; then echo "멈춤: GitHub의 깨끗한 Mac 전용입니다(설치된 Dropfit과 설정을 지움)."; exit 3; fi
set -u
ZIP="$1"; OUT="$2"; mkdir -p "$OUT"
HERE="$(cd "$(dirname "$0")" && pwd)"
I="$OUT/journey_input"; swiftc -O "$HERE/journey_input.swift" -o "$I" 2>"$OUT/swiftc.txt" || { cat "$OUT/swiftc.txt"; exit 1; }
DOM=app.dropfit.prototype
APP=/Applications/Dropfit.app
t() { local n="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$n" "$@"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
shot() {   # 파일 이름 = 접점 번호-언어-설명
  t 8 screencapture -x "$OUT/$1.png" 2>/dev/null && log "  📷 $1" || log "  ✗ 찍지 못함 $1"
  t 5 "$I" wins | grep -v "^Window Server\|^Wallpaper\|^TextInputMenuAgent" >"$OUT/$1.wins.txt"
}
orb() { t 5 "$I" wins | grep "^Dropfit " | awk -F' · ' '{split($4,a," "); split(a[1],p,","); split(a[2],s,"x"); if (s[1]==s[2] && s[1]>40 && s[1]<600) print p[1]+s[1]/2, p[2]+s[2]/2}' | head -1; }
wait_orb() { for _ in $(seq 1 60); do [ -n "$(orb)" ] && return 0; sleep 0.5; done; log "  ✗ 동그라미가 뜨지 않음"; return 1; }
quit_app() { pkill -x Dropfit 2>/dev/null; pkill -x CoreServicesUIAgent 2>/dev/null; sleep 1; pkill -9 -x Dropfit 2>/dev/null; sleep 0.5; }
reset_all() {
  quit_app
  rm -rf "$APP" ~/Applications/Dropfit.app ~/Downloads/Dropfit
  defaults delete $DOM >/dev/null 2>&1
  for s in app.dropfit.prototype.trial app.dropfit.prototype.license; do security delete-generic-password -s $s -a dropfit >/dev/null 2>&1; done
}
install_direct() { W="$(mktemp -d)"; ditto -x -k "$ZIP" "$W"; ditto "$W/Dropfit/Dropfit.app" "$APP"; xattr -dr com.apple.quarantine "$APP" 2>/dev/null; }
KC="$HOME/Library/Keychains/journey.keychain-db"
unlock() { security unlock-keychain -p j "$KC" 2>/dev/null; }
launch() {   # $1 = ko|en
  unlock; (open --env DROPFIT_LANG="$1" "$APP" &); wait_orb
}
trial_start() {   # $1 = 며칠 전에 체험을 시작한 것으로 둘지
  local ts; ts=$(( $(date +%s) - $1 * 86400 ))
  defaults write $DOM pro.trialStart -date "$(date -u -r $ts '+%Y-%m-%d %H:%M:%S +0000')"
}
preset_slots() {   # 칸 1 = 프리셋 '스마트스토어 · JPG · 2MB', 나머지는 기본 포맷 칸
  local name="$1" json
  json=$(python3 -c "
import json,uuid,sys
f=['jpeg','png','heic','webp','pdf','gif']
s=[{'id':str(uuid.uuid4()).upper(),'format':x,'name':'','place':{'shared':{}}} for x in f]
s[0]['name']=sys.argv[1]; s[0]['limit']=2000000
print(json.dumps(s,ensure_ascii=False))" "$name")
  defaults write $DOM slots.v1 -data "$(printf '%s' "$json" | xxd -p | tr -d '\n')"
}
sample() { [ -f ~/Desktop/sample.png ] || sips -s format png "$(ls /System/Library/Desktop\ Pictures/*.heic 2>/dev/null | head -1)" --resampleWidth 1600 --out ~/Desktop/sample.png >/dev/null 2>&1 || screencapture -x ~/Desktop/sample.png; }
front() { t 5 osascript -e 'tell application "Dropfit" to activate' >/dev/null 2>&1; sleep 0.6; }
open_settings() { front; t 5 "$I" key comma cmd; sleep 1.5
  local b; b=$(t 5 "$I" wins | grep "^Dropfit " | awk -F' · ' '{split($4,a," "); split(a[1],p,","); split(a[2],s,"x"); if (s[1]>300 && s[2]>300) print p[1]+s[1]/2, p[2]+s[2]/2}' | head -1)
  [ -n "$b" ] && { set -- $b; t 5 "$I" scroll "$1" "$2" -40; sleep 0.8; }
}
lang() {   # 시스템 창(Gatekeeper 등)도 고객 언어로
  if [ "$1" = ko ]; then defaults write -g AppleLanguages -array ko-KR en-US; defaults write -g AppleLocale ko_KR; sudo defaults write /Library/Preferences/.GlobalPreferences AppleLanguages -array ko-KR en-US
  else defaults write -g AppleLanguages -array en-US; defaults write -g AppleLocale en_US; sudo defaults write /Library/Preferences/.GlobalPreferences AppleLanguages -array en-US; fi
  killall Finder Dock SystemUIServer CoreServicesUIAgent cfprefsd >/dev/null 2>&1; sleep 4
}
gk_open() {   # Gatekeeper 창의 '열기' 버튼(오른쪽 아래)을 사람처럼 누른다
  local b; b=$(t 5 "$I" wins | grep "^CoreServicesUIAgent" | awk -F' · ' '{split($4,a," "); split(a[1],p,","); split(a[2],s,"x"); if (s[1]>150) print p[1]+s[1]*0.72, p[2]+s[2]-30}' | head -1)
  [ -n "$b" ] && { set -- $b; t 5 "$I" click "$1" "$2"; }
}
close_front() { t 5 "$I" key escape; sleep 0.5; t 5 "$I" key w cmd 2>/dev/null; sleep 0.5; }

# CI Mac의 로그인 키체인은 잠겨 있어 앱이 체험 기록을 쓸 때 암호 창이 뜬다 → 잠금 풀린 기본 키체인을 새로 둔다
security create-keychain -p j "$HOME/Library/Keychains/journey.keychain-db" 2>/dev/null
security list-keychains -d user -s "$HOME/Library/Keychains/journey.keychain-db"
security default-keychain -d user -s "$HOME/Library/Keychains/journey.keychain-db"
security unlock-keychain -p j "$HOME/Library/Keychains/journey.keychain-db"; security set-keychain-settings "$HOME/Library/Keychains/journey.keychain-db"
log "macOS $(sw_vers -productVersion) · 화면 $(system_profiler SPDisplaysDataType 2>/dev/null | grep -m1 Resolution | sed 's/^ *//')"
sample

for L in ko en; do
  log "=== $L"; lang $L
  # C-02·C-03·D-01·D-02: 처음 설치 (다운로드 폴더, 격리 표시 = 아직 Gatekeeper 창에서 열기를 누르지 않음)
  reset_all; rm -rf ~/Downloads/Dropfit; ditto -x -k "$ZIP" ~/Downloads
  xattr -r -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;" ~/Downloads/Dropfit
  unlock; (open --env DROPFIT_LANG="$L" ~/Downloads/Dropfit/Dropfit.app &)
  gk=0; mv_=0; intro=0
  for _ in $(seq 1 80); do
    w="$(t 5 "$I" wins)"
    if [ $gk -eq 0 ] && echo "$w" | grep -q "^CoreServicesUIAgent"; then sleep 1; shot "C-02-$L-gatekeeper"; gk_open; gk=1; sleep 2; continue; fi
    if [ $mv_ -eq 0 ]; then
      if echo "$w" | grep "^Dropfit " | awk -F' · ' '{split($4,a," "); split(a[2],s,"x"); split($2,l," "); if (l[2]==8 && s[1]>=200 && s[1]<=700 && s[2]>=120 && s[2]<=420) f=1} END{exit !f}'; then
        sleep 1; shot "C-03-$L-move-alert"; t 5 "$I" key return; mv_=1; sleep 4; continue; fi
    fi
    if echo "$w" | grep "^Dropfit " | awk -F' · ' '{split($4,a," "); split(a[2],s,"x"); if (s[1]>=800 && s[2]>=600) f=1} END{exit !f}'; then intro=1; break; fi
    sleep 0.5
  done
  log "  gatekeeper=$gk move=$mv_ intro=$intro"
  if [ $intro -eq 1 ]; then sleep 1.2; shot "D-01-$L-intro-head"; sleep 7; shot "D-02-$L-intro-slide"; t 5 "$I" key right; sleep 1.2; shot "D-02-$L-intro-slide2"; t 5 "$I" key escape; sleep 0.3; shot "D-02-$L-intro-closing"; sleep 1.5; fi
  wait_orb && { sleep 1; shot "E-01-$L-orb-idle"; }

  # E-01·E-02(체험 중): 파일을 Dock/Finder에서 넘기면 동그라미 자리에서 칸이 펼쳐진다
  (open -a "$APP" ~/Desktop/sample.png &); sleep 2.5; shot "E-01-$L-slots-open"
  c=$(orb); t 5 "$I" key escape; sleep 1

  # 우클릭 메뉴
  if [ -n "$c" ]; then set -- $c; t 5 "$I" rclick "$1" "$2"; sleep 1.2; shot "E-01-$L-right-menu"; t 5 "$I" key escape; sleep 0.8; fi

  # D-06: 설정 맨 아래 'Pro 체험 · N일 남음', ⌥를 누르면 '키 입력…'
  open_settings; shot "D-06-$L-settings-trial"
  t 5 "$I" opt down; sleep 0.8; shot "G-07-$L-settings-option"; t 5 "$I" opt up; sleep 0.4
  close_front

  # G-06 오류: 잘못된 키로 dropfit://activate
  (open "dropfit://activate?key=abc.def" &); sleep 2.5; shot "G-06-$L-activate-badkey"; sleep 6

  # E-02: 체험 중 프리셋 칸
  quit_app; preset_slots "$([ $L = ko ] && echo 스마트스토어 || echo Smartstore)"; launch $L && sleep 1
  (open -a "$APP" ~/Desktop/sample.png &); sleep 2.5; shot "E-02-$L-preset-trial"; t 5 "$I" key escape; sleep 1
  open_settings; shot "E-02-$L-settings-preset-trial"; close_front

  # D-05: 0.6.x에서 넘어온 분의 1.0 첫 실행 안내
  reset_all; install_direct; defaults write $DOM orb.onboarded -bool true; launch $L && { sleep 1.5; shot "D-05-$L-existing-user"; }

  # E-03·E-04·D-06(기본): 체험이 끝난 상태 (20일 전 시작)
  reset_all; install_direct; defaults write $DOM orb.onboarded -bool true; defaults write $DOM pro.welcomed -bool true
  trial_start 20; preset_slots "$([ $L = ko ] && echo 스마트스토어 || echo Smartstore)"
  launch $L && sleep 1.5; shot "E-03-$L-ended-orb"
  (open -a "$APP" ~/Desktop/sample.png &); sleep 2.5; shot "E-03-$L-ended-slots"; t 5 "$I" key escape; sleep 1
  open_settings; shot "E-04-$L-settings-ended"; t 5 "$I" opt down; sleep 0.8; shot "G-07-$L-settings-ended-option"; t 5 "$I" opt up; close_front

  # D-06: 체험 마지막 날 (13.5일 전 시작 → '1일 남음')
  quit_app; ts=$(( $(date +%s) - 1166400 )); defaults write $DOM pro.trialStart -date "$(date -u -r $ts '+%Y-%m-%d %H:%M:%S +0000')"
  launch $L && sleep 1; open_settings; shot "D-06-$L-settings-lastday"; close_front
done
quit_app
ls "$OUT"/*.png | wc -l | xargs echo "찍은 화면:" | tee -a "$OUT/log.txt"
