#!/bin/bash
# 다시 열기 시험 (Dropfit과 무관한 화면 없는 시험 앱). 앱이 스스로 끝난 뒤에도 "다시 열기"가 실행되는지 방식별로 센다.
#   A 자식 /bin/sh가 앱 종료를 기다림 (Dropfit 0.6.7 AppMover.relaunch와 같은 방식)
#   B 같은 셸을 새 세션(setsid)으로 · C macOS에 새 인스턴스를 열게 하고 그 인스턴스가 이전 앱 종료를 기다림
#   bash brand/relaunch_probe/run.sh 횟수
set -u
N=${1:-10}
D=$(cd "$(dirname "$0")" && pwd); OUT=$(mktemp -d)
A=$OUT/RelaunchTest.app; mkdir -p "$A/Contents/MacOS"
swiftc -O -o "$A/Contents/MacOS/RelaunchTest" "$D/main.swift" || { echo "컴파일 실패"; exit 1; }
cat > "$A/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.relaunch.probe</string><key>CFBundleExecutable</key><string>RelaunchTest</string>
<key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PL
codesign -s - --force "$A" 2>/dev/null
echo "macOS $(sw_vers -productVersion) · 방식마다 ${N}번"
declare -A OK=( [A]=0 [B]=0 [C]=0 )
for r in $(seq 1 "$N"); do
  for m in A B C; do
    f="$OUT/$m-$r.ok"
    open -n "$A" --args --mode $m "$f"
    for _ in $(seq 1 80); do [[ -f "$f" ]] && break; sleep 0.1; done
    if [[ -f "$f" ]]; then OK[$m]=$((OK[$m]+1)); else echo "  $r번째 $m: 앱이 끝난 뒤 다시 열기가 실행되지 않음 ✗"; fi
  done
done
for m in A B C; do echo "결과 $m: ${OK[$m]}/$N"; done
pkill -f RelaunchTest.app 2>/dev/null; rm -rf "$OUT"
