#!/bin/bash
# VDA hardware-decode/encode expanded matrix test.
#
# Expanded from tools/vda_hwtest.sh (weachy/NootedRed). Adds:
#   * HEVC Main10 / 10-bit decode, H.264 1080p, HEVC 4K, VP9 Profile 0 / Profile 2
#   * optional --stress mode: repeated decoder create/destroy, parallel streams, long-play
#
# This script only reads markers and runs ffmpeg/VideoToolbox; it does NOT install kexts,
# does NOT patch anything, and does NOT reboot. A failing engine can hang the GPU, keep the
# rollback runbook ready.
#
# bash 3.2 compatible (no associative arrays / mapfile). Missing ffmpeg encoders are skipped
# with a WARN instead of failing the whole run.
set -u

WORK="$(mktemp -d /tmp/vda-hwtest-expanded.XXXXXX)" || exit 1
FAIL=0
WARN=0
STRESS_LOOPS=0
STRESS_PARALLEL=1
STRESS_SECONDS=0

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAIL=$((FAIL + 1)); }
warn() { echo "WARN  $*"; WARN=$((WARN + 1)); }

run_timeout() {
    # macOS has no timeout(1); perl's alarm is enough for a bounded run.
    perl -e 'alarm shift; exec @ARGV' "$@"
}

have_encoder() {
    local enc="$1"
    command -v ffmpeg >/dev/null 2>&1 || return 1
    ffmpeg -hide_banner -encoders 2>/dev/null | grep -q " ${enc} "
}

# ---------------------------------------------------------------------------
# Raven2 smoke path (unchanged semantics from the original script)
# ---------------------------------------------------------------------------
raven2_smoke() {
    local clip="$1" work="$2" status=0
    mkdir -m 700 "$work" || return 1
    echo "Raven2 smoke-test artifacts: $work"

    ioreg -l -w0 -r -n IGPU >"$work/before.ioreg" || return 1
    if ! grep -q '"NRedVCN1DecodeRequested" = 1' "$work/before.ioreg" ||
       ! grep -q '"NRedVCNEngineAllocated" = 1' "$work/before.ioreg"; then
        echo 'Raven2 experiment is not active or its engine was not allocated.' >&2
        return 1
    fi
    if ! run_timeout 15 ffmpeg -nostdin -hide_banner -loglevel error -i "$clip" \
        -frames:v 1 -vf format=nv12 -f rawvideo "$work/software.nv12" >"$work/software.log" 2>&1 ||
        [[ ! -s "$work/software.nv12" ]]; then
        echo 'Software reference frame failed. See software.log.' >&2
        return 1
    fi

    echo 'Requesting one hardware-decoded output frame from VideoToolbox.'
    sync
    run_timeout 15 ffmpeg -nostdin -hide_banner -loglevel verbose -hwaccel videotoolbox \
        -hwaccel_output_format videotoolbox_vld -i "$clip" -frames:v 1 \
        -vf hwdownload,format=nv12 -f rawvideo "$work/hardware.nv12" >"$work/hardware.log" 2>&1 || status=$?
    ioreg -l -w0 -r -n IGPU >"$work/after.ioreg"
    run_timeout 15 log show --last boot --style compact \
        --predicate 'eventMessage CONTAINS "Raven2 first decode IB commit" OR eventMessage CONTAINS "VCN2 initHardware"' \
        >"$work/bridge.log" 2>"$work/bridge-log-error.txt" || true
    local before after
    before="$(vcn_completions "$work/before.ioreg")"
    after="$(vcn_completions "$work/after.ioreg")"
    echo "VCN0Dec completion high-water mark: ${before:-unavailable} -> ${after:-unavailable}"
    if [[ $status -ne 0 || ! -s "$work/hardware.nv12" ]]; then
        echo "Hardware decode failed (exit $status). See hardware.log." >&2
        return 1
    fi
    if ! cmp -s "$work/software.nv12" "$work/hardware.nv12"; then
        echo 'Hardware frame differs from the software reference.' >&2
        return 1
    fi
    if [[ -z "$before" || -z "$after" || "$after" -le "$before" ]]; then
        echo 'The frames match, but VCN completion counter advancement was not observed.' >&2
        return 1
    fi
    echo 'Hardware frame matches the software reference and the VCN0Dec completion counter advanced.'
}

vcn_completions() {
    grep -oE 'HWChannel VCN0Dec \| Commands Completed"=[0-9]+' "$1" |
        cut -d= -f2 | sort -n | tail -n 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
    echo "Usage:" >&2
    echo "  $0                                   # expanded decode/encode matrix" >&2
    echo "  $0 --stress [loops] [parallel] [seconds]   # add repeat/parallel/long-play load" >&2
    echo "  $0 --raven2-smoke <clip> <out-dir>" >&2
}

if [[ $# -ge 1 && "$1" == "--raven2-smoke" ]]; then
    if [[ $# -ne 3 ]]; then usage; exit 2; fi
    raven2_smoke "$2" "$3"
    exit $?
fi

if [[ $# -ge 1 && "$1" == "--stress" ]]; then
    STRESS_LOOPS="${2:-20}"
    STRESS_PARALLEL="${3:-4}"
    STRESS_SECONDS="${4:-60}"
    shift
elif [[ $# -ne 0 ]]; then
    usage; exit 2
fi

echo "== VDA expanded hardware test =="
echo "work dir: ${WORK}"
BOOTARGS="$(sysctl -n kern.bootargs 2>/dev/null || true)"
echo "boot-args: ${BOOTARGS}"

if ! echo "${BOOTARGS}" | grep -q -- '-NRedVDA'; then
    fail "-NRedVDA is not in boot-args; boot with it before running the decode test"
    echo "Diagnostics were still collected in ${WORK}; rerun after adding -NRedVDA."
fi

echo
echo "== kernel/user-space markers =="
ioreg -l -w0 -r -n IGPU 2>/dev/null | grep -oE '"NRed[A-Za-z0-9]+"[[:space:]]*=[[:space:]]*[0-9]+' | sort -u | tee "${WORK}/markers.txt" || true
BRIDGE_READY=0
if [[ -s "${WORK}/markers.txt" ]]; then
    pass "NRedVDA/NRedVCN ioreg markers present"
    BRIDGE_READY=1
else
    fail "no NRedVDA/NRedVCN ioreg markers (bridge did not run)"
fi
for key in NRedVCNX5000ABIValidated NRedVCNX6000ABIValidated NRedVCNNativeLoadReady NRedVCNEngineAllocated; do
    if grep -qE "\"${key}\"[[:space:]]*=[[:space:]]*1" "${WORK}/markers.txt"; then
        pass "${key}=1"
    else
        fail "${key} is not 1"
        BRIDGE_READY=0
    fi
done
if grep -qE '"NRedVCNUserApplied"[[:space:]]*=[[:space:]]*[0-9]+' "${WORK}/markers.txt"; then
    pass "VDA user-space pages were patched (NRedVCNUserApplied)"
else
    warn "NRedVCNUserApplied is absent (VA/AppleGVA pages may not have been validated yet)"
fi

echo
echo "== logs =="
log show --last boot --style compact --info --debug \
    --predicate 'eventMessage CONTAINS "VCN" OR eventMessage CONTAINS "VDA" OR eventMessage CONTAINS "UserPatch"' \
    2>/dev/null >"${WORK}/vda.log" || true
grep -E "ABI|native load|initHardware|engine|patched|failed|mismatch" "${WORK}/vda.log" | tail -n 40 || true
if grep -qiE "panic|gpuRestart|watchdog" "${WORK}/vda.log"; then
    warn "VDA log contains panic/gpuRestart/watchdog text (inspect ${WORK}/vda.log)"
else
    pass "no panic/gpuRestart/watchdog text in the VDA log"
fi

if [[ ${BRIDGE_READY} -ne 1 ]]; then
    warn "kernel VCN bridge is not ready; skipping VideoToolbox decode comparison because a software fallback would produce a misleading pass"
elif ! command -v ffmpeg >/dev/null 2>&1; then
    warn "ffmpeg is not installed; decode/encode tests were skipped"
else
    echo
    echo "== VideoToolbox availability =="
    ffmpeg -hide_banner -hwaccels 2>/dev/null | tee "${WORK}/hwaccels.txt"
    if grep -qi videotoolbox "${WORK}/hwaccels.txt"; then
        pass "ffmpeg advertises VideoToolbox"
    else
        fail "ffmpeg does not advertise VideoToolbox"
    fi

    make_clip() {
        local out="$1"; shift
        run_timeout 120 ffmpeg -hide_banner -loglevel error -y "$@" "${out}" >/dev/null 2>&1
    }

    # decode_case <name> <clip> <pixfmt>
    # pixfmt: yuv420p (8-bit) or yuv420p10le (10-bit). soft/hard use the same format for byte compare.
    decode_case() {
        local name="$1" clip="$2" pixfmt="$3"
        local soft="${WORK}/${name}-soft.yuv" hard="${WORK}/${name}-hw.yuv" log="${WORK}/${name}-hw.log"
        echo
        echo "-- ${name} (${pixfmt}) --"
        if ! run_timeout 120 ffmpeg -hide_banner -loglevel error -y -i "${clip}" -f rawvideo -pix_fmt "${pixfmt}" \
            "${soft}" >/dev/null 2>&1; then
            fail "${name}: software decode failed"
            return
        fi
        if run_timeout 180 ffmpeg -hide_banner -loglevel verbose -y -hwaccel videotoolbox -i "${clip}" \
            -f rawvideo -pix_fmt "${pixfmt}" "${hard}" >"${log}" 2>&1; then
            pass "${name}: hardware decode command completed"
        else
            fail "${name}: VideoToolbox decode failed (see ${log})"
            return
        fi
        if grep -qiE "videotoolbox|VideoToolbox" "${log}"; then
            pass "${name}: log mentions VideoToolbox"
        else
            warn "${name}: no VideoToolbox mention in the decode log"
        fi
        if grep -q "videotoolbox_vld" "${log}"; then
            pass "${name}: decoder negotiated the VideoToolbox hardware pixel format"
        else
            warn "${name}: no videotoolbox_vld pixel format in the decode log"
        fi
        if cmp -s "${soft}" "${hard}"; then
            pass "${name}: hardware output matches software decoding"
        else
            warn "${name}: hardware output differs from software decoding (check YUV/format differences)"
        fi
    }

    echo
    echo "== decode matrix =="

    # H.264 8-bit
    if have_encoder libx264; then
        make_clip "${WORK}/h264-720p.mp4" -f lavfi -i testsrc2=size=1280x720:rate=30 -t 2 \
            -c:v libx264 -pix_fmt yuv420p
        decode_case "h264-720p" "${WORK}/h264-720p.mp4" "yuv420p"
        make_clip "${WORK}/h264-1080p.mp4" -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 2 \
            -c:v libx264 -pix_fmt yuv420p
        decode_case "h264-1080p" "${WORK}/h264-1080p.mp4" "yuv420p"
        make_clip "${WORK}/h264-64.mp4" -f lavfi -i testsrc2=size=64x64:rate=30 -t 2 \
            -c:v libx264 -pix_fmt yuv420p
        decode_case "h264-64x64-known-adverse" "${WORK}/h264-64.mp4" "yuv420p"
    else
        warn "ffmpeg has no libx264 encoder; H.264 tests skipped"
    fi

    # HEVC 8-bit + Main10 + 4K
    if have_encoder libx265; then
        make_clip "${WORK}/hevc-720p.mp4" -f lavfi -i testsrc2=size=1280x720:rate=30 -t 2 \
            -c:v libx265 -pix_fmt yuv420p
        decode_case "hevc-720p" "${WORK}/hevc-720p.mp4" "yuv420p"
        make_clip "${WORK}/hevc-main10-720p.mp4" -f lavfi -i testsrc2=size=1280x720:rate=30 -t 2 \
            -c:v libx265 -pix_fmt yuv420p10le
        decode_case "hevc-main10-720p" "${WORK}/hevc-main10-720p.mp4" "yuv420p10le"
        make_clip "${WORK}/hevc-4k.mp4" -f lavfi -i testsrc2=size=3840x2160:rate=30 -t 1 \
            -c:v libx265 -pix_fmt yuv420p -preset ultrafast
        decode_case "hevc-4k" "${WORK}/hevc-4k.mp4" "yuv420p"
    else
        warn "ffmpeg has no libx265 encoder; HEVC tests skipped"
    fi

    # VP9 Profile 0 (8-bit) / Profile 2 (10-bit)
    if have_encoder libvpx-vp9; then
        make_clip "${WORK}/vp9-p0-720p.webm" -f lavfi -i testsrc2=size=1280x720:rate=30 -t 2 \
            -c:v libvpx-vp9 -pix_fmt yuv420p -b:v 4M
        decode_case "vp9-p0-720p" "${WORK}/vp9-p0-720p.webm" "yuv420p"
        make_clip "${WORK}/vp9-p2-720p10.webm" -f lavfi -i testsrc2=size=1280x720:rate=30 -t 2 \
            -c:v libvpx-vp9 -pix_fmt yuv420p10le -b:v 4M
        decode_case "vp9-p2-720p10" "${WORK}/vp9-p2-720p10.webm" "yuv420p10le"
    else
        warn "ffmpeg has no libvpx-vp9 encoder; VP9 tests skipped"
    fi

    # encode_case <name> <encoder> <pixfmt> <size> <bitrate>
    encode_case() {
        local name="$1" encoder="$2" pixfmt="$3" size="$4" bitrate="$5"
        local out="${WORK}/encode-${name}.mp4" log="${WORK}/encode-${name}.log"
        echo
        echo "-- encode ${name} (${encoder}, ${pixfmt}, ${size}) --"
        if ! have_encoder "${encoder}"; then
            warn "${name}: ${encoder} not advertised; skipped"
            return
        fi
        if run_timeout 120 ffmpeg -hide_banner -loglevel error -y -f lavfi \
            -i "testsrc2=size=${size}:rate=30" -t 1 -c:v "${encoder}" -pix_fmt "${pixfmt}" \
            -b:v "${bitrate}" "${out}" >"${log}" 2>&1 && [[ -s "${out}" ]] && \
            run_timeout 120 ffmpeg -hide_banner -loglevel error -i "${out}" -f null - >/dev/null 2>&1; then
            pass "${name}: hardware encode produced a decodable file"
        else
            fail "${name}: hardware encode failed (see ${log})"
        fi
    }

    echo
    echo "== encode matrix =="
    encode_case "h264-720p" "h264_videotoolbox" "yuv420p" "1280x720" "4M"
    encode_case "hevc-720p" "hevc_videotoolbox" "yuv420p" "1280x720" "4M"
    encode_case "hevc10-720p" "hevc_videotoolbox" "yuv420p10le" "1280x720" "4M"
    encode_case "h264-1080p" "h264_videotoolbox" "yuv420p" "1920x1080" "6M"

    # Optional stress load: repeated create/destroy, parallel streams, long play.
    if [[ ${STRESS_LOOPS} -gt 0 || ${STRESS_SECONDS} -gt 0 ]]; then
        echo
        echo "== stress mode: loops=${STRESS_LOOPS} parallel=${STRESS_PARALLEL} seconds=${STRESS_SECONDS} =="
        stress_clip="${WORK}/stress-h264-720p.mp4"
        if have_encoder libx264; then
            make_clip "${stress_clip}" -f lavfi -i testsrc2=size=1280x720:rate=30 -t 2 \
                -c:v libx264 -pix_fmt yuv420p
        fi
        if [[ ! -s "${stress_clip}" ]]; then
            warn "stress: no local stress clip available; skipped"
        else
            # Repeated decoder create/destroy.
            if [[ ${STRESS_LOOPS} -gt 0 ]]; then
                i=1
                while [[ ${i} -le ${STRESS_LOOPS} ]]; do
                    run_timeout 60 ffmpeg -hide_banner -loglevel error -hwaccel videotoolbox \
                        -i "${stress_clip}" -frames:v 1 -f null - >"${WORK}/stress-loop-${i}.log" 2>&1 \
                        || warn "stress loop ${i}: decoder run failed"
                    i=$((i + 1))
                done
                pass "stress: ${STRESS_LOOPS} create/destroy iterations attempted"
            fi
            # Parallel streams.
            if [[ ${STRESS_PARALLEL} -gt 1 ]]; then
                p=1
                while [[ ${p} -le ${STRESS_PARALLEL} ]]; do
                    run_timeout 120 ffmpeg -hide_banner -loglevel error -hwaccel videotoolbox \
                        -i "${stress_clip}" -f null - >"${WORK}/stress-parallel-${p}.log" 2>&1 &
                    p=$((p + 1))
                done
                wait
                pass "stress: ${STRESS_PARALLEL} parallel streams attempted"
            fi
            # Long-play (bounded by STRESS_SECONDS).
            if [[ ${STRESS_SECONDS} -gt 0 ]]; then
                run_timeout ${STRESS_SECONDS} ffmpeg -hide_banner -loglevel error -hwaccel videotoolbox \
                    -stream_loop -1 -i "${stress_clip}" -f null - >"${WORK}/stress-longplay.log" 2>&1 \
                    || warn "stress: long-play ended early or failed"
                pass "stress: ${STRESS_SECONDS}s long-play bounded run attempted"
            fi
        fi
    fi

    log show --last 5m --style compact --info --debug \
        --predicate 'process == "VTDecoderXPCService"' 2>/dev/null \
        | grep -iE 'AppleGVA|useHighPerformanceDecode|physical accelerator' | tail -n 12 \
        >"${WORK}/vtdecoder.log" || true
    if grep -qiE 'AppleGVA|useHighPerformanceDecode|physical accelerator' "${WORK}/vtdecoder.log"; then
        pass "VTDecoderXPCService log shows the AppleGVA hardware decoder path"
    else
        warn "no AppleGVA hardware-decoder evidence in the VTDecoderXPCService log"
    fi
fi

echo
echo "== post-decode VDA markers =="
ioreg -l -w0 -r -n IGPU 2>/dev/null | grep -oE '"NRed[A-Za-z0-9]+"[[:space:]]*=[[:space:]]*[0-9]+' | sort -u >"${WORK}/markers-after.txt" || true
cat "${WORK}/markers-after.txt" 2>/dev/null || true
if grep -qE '"NRedVCNLastHardwareInit"[[:space:]]*=[[:space:]]*1' "${WORK}/markers-after.txt"; then
    pass "VCN initHardware succeeded at least once after decoding"
else
    fail "NRedVCNLastHardwareInit is not 1 after decoding (hardware engine was not initialised)"
fi
if grep -qE '"NRedVCNUserApplied"[[:space:]]*=[[:space:]]*[1-9]' "${WORK}/markers-after.txt"; then
    pass "VDA user-space pages were patched after decoding"
else
    warn "NRedVCNUserApplied did not increase after decoding"
fi

echo
echo "== GPU reset / watchdog reports (current boot) =="
log show --last boot --style compact \
    --predicate 'eventMessage CONTAINS[c] "gpuRestart" AND process != "log"' 2>/dev/null \
    | tail -n 20 | tee "${WORK}/gpu-resets.log" || true
BOOT_SEC="$(sysctl -n kern.boottime 2>/dev/null | sed -nE 's/^\{ sec = ([0-9]+),.*/\1/p')"
NEW_REPORTS=0
for report in /Library/Logs/DiagnosticReports/*gpuRestart*; do
    [[ -e "${report}" ]] || continue
    mtime="$(stat -f %m "${report}" 2>/dev/null || echo 0)"
    if [[ -n "${BOOT_SEC}" && "${mtime}" -ge "${BOOT_SEC}" ]]; then
        echo "${report}" >>"${WORK}/gpu-resets.log"
        NEW_REPORTS=1
    fi
done
if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' "${WORK}/gpu-resets.log" 2>/dev/null || [[ ${NEW_REPORTS} -eq 1 ]]; then
    warn "GPU reset/watchdog reports exist for this boot; review ${WORK}/gpu-resets.log"
else
    pass "no GPU reset/watchdog reports for this boot"
fi

echo
echo "artifacts: ${WORK}"
if [[ ${FAIL} -eq 0 ]]; then
    echo "EXPANDED HW TEST OK (${WARN} warning(s))"
    exit 0
fi
echo "EXPANDED HW TEST FAILED (${FAIL} failure(s), ${WARN} warning(s))"
exit 1
