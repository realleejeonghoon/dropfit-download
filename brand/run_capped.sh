#!/bin/bash
# 시간 제한 실행: bash brand/run_capped.sh 초 기록파일 명령…
# 명령을 자기 프로세스 무리로 돌리며 10초마다 새 줄을 작업 기록에 보이고, 제한을 넘기면 무리째 끝내고 124로 끝난다.
# (11/24 업데이트 단계가 출력 없이 12분 멈춤: 어디서 멈췄는지 보이게)
set -u
CAP=$1; LOG=$2; shift 2
: >"$LOG"
set -m
"$@" >"$LOG" 2>&1 </dev/null &
P=$!
set +m
shown=0; t=0
while kill -0 $P 2>/dev/null; do
  sleep 5; t=$((t+5))
  n=$(wc -l <"$LOG" | tr -d ' ')
  [ "$n" -gt "$shown" ] && { sed -n "$((shown+1)),${n}p" "$LOG" | cut -c1-200 | sed "s/^/  [${t}s] /"; shown=$n; }
  if [ $t -ge "$CAP" ]; then
    echo "  [${t}s] ${CAP}초 제한: 멈춘 자리에서 끝냄"; ps -o pid,etime,command -g $P 2>/dev/null | cut -c1-160
    kill -TERM -- -$P 2>/dev/null; sleep 2; kill -KILL -- -$P 2>/dev/null; wait $P 2>/dev/null; exit 124
  fi
done
wait $P; c=$?
n=$(wc -l <"$LOG" | tr -d ' '); [ "$n" -gt "$shown" ] && sed -n "$((shown+1)),${n}p" "$LOG" | cut -c1-200 | sed "s/^/  [${t}s] /"
exit $c
