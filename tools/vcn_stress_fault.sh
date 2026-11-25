#!/bin/bash
# VCN 解码并发阶梯 / 损坏流容错 / 建毁循环压测（补充 vda_hwtest-stress.sh）。
# 只读 ioreg + 跑 ffmpeg/VideoToolbox；不装 kext、不补丁、不重启。
# 判据：跑完后 ResetCount / ResourceFailures 不增长，无 gpuRestart/watchdog/panic。
set -u
export PATH="$HOME/.local/bin:$HOME/.local/ffmpeg:$PATH"
OUT=/tmp/nred-vcn-stress
mkdir -p "$OUT"
SRC="${1:-/tmp/vda-hwtest-expanded.Yftfef/h264-720p.mp4}"
LOOPS="${LOOPS:-20}"

need_src() {
  if [[ ! -s "$SRC" ]]; then
    SRC="$OUT/stress-720p.mp4"
    ffmpeg -hide_banner -y -f lavfi -i testsrc2=size=1280x720:rate=30 -t 3 -pix_fmt nv12 "$SRC" \
      >"$OUT/make-src.log" 2>&1
  fi
}

count() { # $1=prop -> value (0 if missing)
  local v
  v=$(ioreg -l -w0 -r -n IGPU 2>/dev/null | grep -oE "\"$1\"[[:space:]]*=[[:space:]]*[0-9]+" | grep -oE "[0-9]+$" | head -1)
  echo "${v:-0}"
}

snapshot() { # $1=label
  echo "--- $1 ---"
  for p in NRedVCNResetCount NRedVCNResourceFailures NRedVCNQuotaFallbacks NRedVCNActiveContexts \
           NRedVCNMaxContexts NRedVCNSkipReplayRetired; do
    echo "$p = $(count "$p")"
  done
}

need_src
snapshot "baseline"

# 1) 并发阶梯：1 / 2 / 4 / 6 路同时解码到 null。
echo
echo "== parallel ladder =="
for N in 1 2 4 6; do
  pids=()
  for ((p=1; p<=N; p++)); do
    ffmpeg -nostdin -hide_banner -loglevel error -hwaccel videotoolbox -i "$SRC" -frames:v 30 -f null - \
      >"$OUT/par-${N}-${p}.log" 2>&1 &
    pids+=($!)
  done
  fail=0
  for pid in "${pids[@]}"; do wait "$pid" || fail=1; done
  echo "parallel=${N}: $([[ $fail -eq 0 ]] && echo OK || echo SOME_FAIL)"
done
snapshot "after parallel"

# 2) 损坏流容错：截断到 30%、中段翻转 64 字节。观察是否报错回退而非挂死/复位。
echo
echo "== fault streams =="
cp "$SRC" "$OUT/truncated.mp4"
TRUNC=$(($(stat -f%z "$SRC") * 30 / 100))
dd if="$SRC" of="$OUT/truncated.mp4" bs=1 count="$TRUNC" >/dev/null 2>&1
cp "$SRC" "$OUT/corrupt.mp4"
python3 - "$OUT/corrupt.mp4" <<'PY'
import sys,os
p=sys.argv[1]; b=bytearray(open(p,'rb').read())
o=min(len(b)//2, 4096)
for i in range(64): b[o+i] ^= 0xFF
open(p,'wb').write(b)
PY
for f in truncated corrupt; do
  ffmpeg -nostdin -hide_banner -loglevel error -hwaccel videotoolbox -i "$OUT/$f.mp4" -frames:v 30 -f null - \
    >"$OUT/$f.log" 2>&1
  echo "$f: rc=$? (non-zero decode error is acceptable; must not hang/panic)"
done
snapshot "after fault"

# 3) 建毁循环：反复创建/销毁解码器单帧。
echo
echo "== create/destroy loop (n=$LOOPS) =="
loopfail=0
for ((i=1; i<=LOOPS; i++)); do
  ffmpeg -nostdin -hide_banner -loglevel error -hwaccel videotoolbox -i "$SRC" -frames:v 1 -f null - \
    >"$OUT/loop-${i}.log" 2>&1 || loopfail=1
done
echo "loops=$LOOPS fail=$loopfail"
snapshot "after loop"

# 4) 复位 / 看门狗 / panic 扫描（本启动至今）。
echo
echo "== reset / watchdog scan =="
log show --last boot --style compact --info --debug \
  --predicate 'eventMessage CONTAINS[c] "gpuRestart" OR eventMessage CONTAINS[c] "VCN reset" OR eventMessage CONTAINS[c] "watchdog"' \
  2>/dev/null | grep -v "log show" | head -20 || true
echo "done. artifacts: $OUT"
