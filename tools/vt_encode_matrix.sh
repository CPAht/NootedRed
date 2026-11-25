#!/bin/bash
# VideoToolbox 硬编全参数验收矩阵（R5600H / VCN2.2 / NootedRed）。
# 用法: ./vt_encode_matrix.sh [源720p] [源1080p]
set -u
export PATH="$HOME/.local/bin:$HOME/.local/ffmpeg:$PATH"
OUT=/tmp/nred-enc-matrix
mkdir -p "$OUT"
SRC720="${1:-/tmp/vda-hwtest-expanded.Yftfef/h264-720p.mp4}"
SRC1080="${2:-/tmp/vda-hwtest-expanded.Yftfef/h264-1080p.mp4}"

run() {
  local tag="$1"; local src="$2"; shift 2
  local log="$OUT/$tag.log"; local out="$OUT/$tag.mp4"
  echo "=== $tag ==="
  ffmpeg -hide_banner -y -i "$src" -c:v "$@" -allow_sw 0 -an "$out" >"$log" 2>&1
  local rc=$?
  local size=0; [ -f "$out" ] && size=$(stat -f%z "$out")
  local frames="NA"
  if [ "$size" -gt 0 ]; then
    frames=$(ffmpeg -hide_banner -i "$out" -f null - 2>&1 >/dev/null | grep -oE "frame= *[0-9]+" | tail -1 | grep -oE "[0-9]+")
  fi
  local err=""; err=$(grep -iE "error|-12704|failed|cannot allocate" "$log" | head -2)
  printf "rc=%s size=%s frames=%s %s\n" "$rc" "$size" "${frames:-NA}" "${err:+ERR:$err}"
}

run e1-h264-main-vbr-720   "$SRC720"  h264_videotoolbox -profile:v main -b:v 3M
run e2-h264-high-cbr-720   "$SRC720"  h264_videotoolbox -profile:v high -constant_bit_rate 1 -b:v 3M
run e3-h264-baseline-rt-720 "$SRC720" h264_videotoolbox -profile:v baseline -realtime 1 -prio_speed 1
run e4-h264-quality-720     "$SRC720"  h264_videotoolbox -q:v 60
run e5-hevc-main-vbr-720    "$SRC720"  hevc_videotoolbox -profile:v main -b:v 4M
run e6-hevc-main10-720      "$SRC720"  hevc_videotoolbox -profile:v main10 -b:v 4M
run e7-h264-vbr-1080        "$SRC1080" h264_videotoolbox -b:v 5M
run e8-hevc-main-1080       "$SRC1080" hevc_videotoolbox -profile:v main -b:v 5M

echo "=== E9 并发 2x h264 720p ==="
ffmpeg -hide_banner -y -i "$SRC720" -c:v h264_videotoolbox -b:v 3M -allow_sw 0 -an "$OUT/e9a-conc.mp4" >"$OUT/e9a.log" 2>&1 &
P1=$!
ffmpeg -hide_banner -y -i "$SRC720" -c:v h264_videotoolbox -b:v 3M -allow_sw 0 -an "$OUT/e9b-conc.mp4" >"$OUT/e9b.log" 2>&1 &
P2=$!
wait $P1; R1=$?; wait $P2; R2=$?
for x in a b; do
  f="$OUT/e9${x}-conc.mp4"; s=0; [ -f "$f" ] && s=$(stat -f%z "$f")
  echo "e9${x}: rc=$([ "$x" = a ] && echo $R1 || echo $R2) size=$s"
done
grep -iE "error|-12704|failed" "$OUT/e9a.log" "$OUT/e9b.log" | head -4 || true

echo "=== 编码后 GPU 复位/失败计数 ==="
ioreg -l -w0 -r -c IGPU 2>/dev/null | grep -oE '"NRed(VCNResetCount|ResourceFailures|QuotaFallbacks|ActiveContexts)"[[:space:]]*=[[:space:]]*[0-9]+' | sort -u
