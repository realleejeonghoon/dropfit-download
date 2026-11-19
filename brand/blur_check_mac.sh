#!/bin/bash
# 인트로 바탕이 비치지 않는 원인 가르기(깨끗한 Mac CI 전용): 색이 강한 그림 창을 뒤에 두고 1.0 첫 실행 인트로를 찍는다.
# 그림이 흐리게 비치면 재질은 정상(앞선 사진은 검은 바탕 탓), 회색으로 덮이면 재질·가상 머신 문제.
if [ "${GITHUB_ACTIONS:-}" != true ]; then echo "멈춤: GitHub의 깨끗한 Mac 전용입니다."; exit 3; fi
set -u
ZIP="$1"; OUT="$2"; mkdir -p "$OUT"
KC="$HOME/Library/Keychains/journey.keychain-db"
security create-keychain -p j "$KC" 2>/dev/null; security list-keychains -d user -s "$KC"; security default-keychain -d user -s "$KC"; security unlock-keychain -p j "$KC"; security set-keychain-settings "$KC"
defaults write -g AppleLanguages -array ko-KR en-US
# GitHub Mac은 '투명도 줄이기'가 켜져 있다(1차 확인 1) → 끄고 찍는다. 끄지 못하면 그 결과도 남긴다
defaults read com.apple.universalaccess reduceTransparency > "$OUT/reduce-transparency-before.txt" 2>&1
defaults write com.apple.universalaccess reduceTransparency -bool false 2> "$OUT/reduce-transparency-write.txt"
sudo defaults write /Library/Preferences/com.apple.universalaccess reduceTransparency -bool false 2>> "$OUT/reduce-transparency-write.txt"
killall Dock SystemUIServer Finder cfprefsd >/dev/null 2>&1; sleep 4
# 색 띠 그림(빨강·노랑·초록·파랑) 1600x1000
python3 - "$OUT/stripes.ppm" <<'PY'
import sys
w,h=1600,1000; cols=[(230,40,40),(250,200,0),(30,170,60),(30,90,230)]
with open(sys.argv[1],'wb') as f:
    f.write(b'P6 %d %d 255\n'%(w,h))
    row=b''.join(bytes(cols[(x//100)%4]) for x in range(w)); f.write(row*h)
PY
sips -s format png "$OUT/stripes.ppm" --out "$OUT/stripes.png" >/dev/null
open -a Preview "$OUT/stripes.png"; sleep 4
screencapture -x "$OUT/blur-0-behind-only.png"
W="$(mktemp -d)"; ditto -x -k "$ZIP" "$W"; rm -rf /Applications/Dropfit.app; ditto "$W/Dropfit/Dropfit.app" /Applications/Dropfit.app; xattr -dr com.apple.quarantine /Applications/Dropfit.app
defaults delete app.dropfit.prototype >/dev/null 2>&1
(open --env DROPFIT_LANG=ko /Applications/Dropfit.app &)
sleep 1.5; screencapture -x "$OUT/blur-1-intro-head.png"
sleep 6;   screencapture -x "$OUT/blur-2-intro-slide.png"
system_profiler SPDisplaysDataType > "$OUT/display.txt" 2>&1
defaults read com.apple.universalaccess reduceTransparency > "$OUT/reduce-transparency-after.txt" 2>&1
ls "$OUT"
