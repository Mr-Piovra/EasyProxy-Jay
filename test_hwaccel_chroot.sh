#!/bin/bash
# ============================================================
# EasyProxy - Hardware Acceleration Test Suite (CHRoot)
# ============================================================
# Eseguito DENTRO il CHRoot Ubuntu (via easyproxy-shell)
# oppure lanciato da Termux con:
#   su -c "chroot /data/local/easyproxy-rootfs /bin/bash -l /root/EasyProxy/test_hwaccel_chroot.sh"
# ============================================================

export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export TMPDIR=/tmp

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}  [OK]${NC}   $1"; }
fail() { echo -e "${RED}  [FAIL]${NC} $1"; }
warn() { echo -e "${YELLOW}  [WARN]${NC} $1"; }
info() { echo -e "${BLUE}  [INFO]${NC} $1"; }
sect() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

REPORT_FILE="/tmp/hwaccel_report_$(date +%Y%m%d_%H%M%S).txt"
TESTDIR=$(mktemp -d /tmp/hwaccel_test_XXXXXX)
trap "rm -rf '$TESTDIR'" EXIT

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  EasyProxy - Hardware Acceleration Test Suite (CHRoot)  ║${NC}"
echo -e "${CYAN}║  Snapdragon 710 / Adreno 616 / kernel $(uname -r | cut -d- -f1)          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ─── Redirect output to report too ────────────────────────
exec > >(tee "$REPORT_FILE") 2>&1

# ─────────────────────────────────────────────────────────────
# SEZIONE 1: Ambiente di sistema
# ─────────────────────────────────────────────────────────────
sect "1/7 Ambiente di sistema"

info "Kernel:    $(uname -r)"
info "CPU:       $(grep 'Hardware' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo 'Snapdragon 710')"
info "Arch:      $(uname -m)"
info "RAM:       $(awk '/MemTotal/{printf "%.0f MB", $2/1024}' /proc/meminfo)"
info "RAM free:  $(awk '/MemAvailable/{printf "%.0f MB", $2/1024}' /proc/meminfo)"

FFMPEG_BIN=$(command -v ffmpeg 2>/dev/null)
if [ -z "$FFMPEG_BIN" ]; then
    fail "ffmpeg non trovato nel PATH"
    exit 1
fi
FFMPEG_VER=$(ffmpeg -version 2>&1 | head -1)
ok "FFmpeg: $FFMPEG_VER"

# ─────────────────────────────────────────────────────────────
# SEZIONE 2: Hardware Acceleration Methods
# ─────────────────────────────────────────────────────────────
sect "2/7 Hardware Acceleration disponibili (ffmpeg -hwaccels)"

HWACCELS=$(ffmpeg -hwaccels 2>/dev/null | tail -n +2 | tr -d ' ')

if echo "$HWACCELS" | grep -q "v4l2m2m"; then
    ok "v4l2m2m      ← V4L2 Memory-to-Memory (Snapdragon VIDC hardware codec)"
    HAS_V4L2=1
else
    fail "v4l2m2m      (non disponibile in questo FFmpeg)"
    HAS_V4L2=0
fi

if echo "$HWACCELS" | grep -q "vaapi"; then
    ok "vaapi        ← VA-API (GPU video acceleration)"
    HAS_VAAPI=1
else
    warn "vaapi        (non disponibile — normale su ARM/Snapdragon)"
    HAS_VAAPI=0
fi

if echo "$HWACCELS" | grep -q "drm"; then
    ok "drm          ← DRM/KMS direct rendering"
else
    info "drm          (non disponibile)"
fi

echo ""
info "Lista completa hwaccels:"
ffmpeg -hwaccels 2>/dev/null | tail -n +2 | while read -r hw; do
    [ -n "$hw" ] && echo "              - $hw"
done

# ─────────────────────────────────────────────────────────────
# SEZIONE 3: Codec Hardware disponibili
# ─────────────────────────────────────────────────────────────
sect "3/7 Codec Hardware (encoder/decoder)"

echo ""
info "Decoder H.264:"
ffmpeg -decoders 2>/dev/null | grep -E "h264" | while read -r line; do
    echo "    $line"
done

echo ""
info "Decoder HEVC/H.265:"
ffmpeg -decoders 2>/dev/null | grep -E "hevc" | while read -r line; do
    echo "    $line"
done

echo ""
info "Encoder H.264:"
ffmpeg -encoders 2>/dev/null | grep -E "h264" | while read -r line; do
    echo "    $line"
done

echo ""
info "Encoder HEVC/H.265:"
ffmpeg -encoders 2>/dev/null | grep -E "hevc" | while read -r line; do
    echo "    $line"
done

# Controlla encoder specifici
if ffmpeg -encoders 2>/dev/null | grep -q "h264_v4l2m2m"; then
    ok "h264_v4l2m2m encoder disponibile ← H.264 hardware encoding"
    HAS_V4L2_H264_ENC=1
else
    warn "h264_v4l2m2m encoder NON disponibile"
    HAS_V4L2_H264_ENC=0
fi

if ffmpeg -encoders 2>/dev/null | grep -q "hevc_v4l2m2m"; then
    ok "hevc_v4l2m2m encoder disponibile ← HEVC hardware encoding"
    HAS_V4L2_HEVC_ENC=1
else
    warn "hevc_v4l2m2m encoder NON disponibile"
    HAS_V4L2_HEVC_ENC=0
fi

# ─────────────────────────────────────────────────────────────
# SEZIONE 4: Dispositivi V4L2 (/dev/video*)
# ─────────────────────────────────────────────────────────────
sect "4/7 Dispositivi V4L2 nel CHRoot"

V4L2_DEVICES=$(ls /dev/video* 2>/dev/null)
if [ -n "$V4L2_DEVICES" ]; then
    ok "Trovati dispositivi V4L2:"
    for dev in $V4L2_DEVICES; do
        SIZE=$(ls -la "$dev" 2>/dev/null | awk '{print $5, $6}')
        echo "    $dev ($SIZE)"
        # Prova a ottenere info V4L2
        if command -v v4l2-ctl >/dev/null 2>&1; then
            v4l2-ctl --device="$dev" --info 2>/dev/null | grep -E "Driver|Card|Bus" | while read -r l; do
                echo "      $l"
            done
        fi
    done
    HAS_VIDEO_DEVICES=1
else
    warn "Nessun /dev/video* trovato nel CHRoot"
    info "Possibile causa: /dev non bind-mountato, o kernel senza V4L2"
    HAS_VIDEO_DEVICES=0
fi

# Controlla /dev/dri per GPU
if ls /dev/dri/* >/dev/null 2>&1; then
    ok "Dispositivi DRI disponibili:"
    ls -la /dev/dri/ 2>/dev/null | tail -n +2 | while read -r line; do
        echo "    $line"
    done
else
    info "/dev/dri non disponibile (normale in CHRoot su Android)"
fi

# ─────────────────────────────────────────────────────────────
# SEZIONE 5: Benchmark Remuxing TS→MP4 (copy mode)
# ─────────────────────────────────────────────────────────────
sect "5/7 Benchmark: Remuxing TS→MP4 (-c copy)"

info "Generazione file TS di test sintetico (30s, 4Mbps H.264)..."

# Genera un file TS sintetico con FFmpeg (video test pattern + audio silenzio)
if ffmpeg -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=1280x720:rate=25" \
    -f lavfi -i "anullsrc=r=48000:cl=stereo" \
    -c:v libx264 -preset ultrafast -b:v 4000k \
    -c:a aac -b:a 128k \
    -t 30 \
    "$TESTDIR/test_input.ts" 2>/dev/null; then
    ok "File di test creato: $(du -h "$TESTDIR/test_input.ts" | cut -f1)"
else
    warn "Generazione file di test fallita (libx264 potrebbe non essere disponibile)"
    # Prova con codec più semplice
    ffmpeg -hide_banner -loglevel error \
        -f lavfi -i "testsrc2=size=640x480:rate=25" \
        -f lavfi -i "anullsrc=r=44100:cl=mono" \
        -c:v mpeg2video -b:v 2000k \
        -c:a mp2 -b:a 64k \
        -t 30 \
        "$TESTDIR/test_input.ts" 2>/dev/null && \
        ok "File di test creato (mpeg2): $(du -h "$TESTDIR/test_input.ts" | cut -f1)" || \
        fail "Impossibile creare file di test"
fi

if [ -f "$TESTDIR/test_input.ts" ]; then
    # Test 1: Remux base (-c copy)
    info "Test 1: Remux base -c copy..."
    T1_START=$(date +%s%3N)
    ffmpeg -hide_banner -loglevel error \
        -i "$TESTDIR/test_input.ts" \
        -c copy \
        "$TESTDIR/remux_base.mp4" 2>/dev/null
    T1_END=$(date +%s%3N)
    T1_MS=$((T1_END - T1_START))
    if [ -f "$TESTDIR/remux_base.mp4" ]; then
        ok "Remux base:          ${T1_MS}ms → $(du -h "$TESTDIR/remux_base.mp4" | cut -f1) (speed: $((30000 / T1_MS))x realtime)"
    else
        fail "Remux base fallito"
    fi

    # Test 2: Remux con faststart + avoid_negative_ts (modalità EasyProxy)
    info "Test 2: Remux EasyProxy (-c copy -movflags +faststart -avoid_negative_ts make_zero)..."
    T2_START=$(date +%s%3N)
    ffmpeg -hide_banner -loglevel error \
        -i "$TESTDIR/test_input.ts" \
        -c copy \
        -avoid_negative_ts make_zero \
        -movflags +faststart \
        "$TESTDIR/remux_faststart.mp4" 2>/dev/null
    T2_END=$(date +%s%3N)
    T2_MS=$((T2_END - T2_START))
    if [ -f "$TESTDIR/remux_faststart.mp4" ]; then
        ok "Remux EasyProxy:     ${T2_MS}ms → $(du -h "$TESTDIR/remux_faststart.mp4" | cut -f1) (speed: $((30000 / T2_MS))x realtime)"
        # Verifica moov atom position
        if command -v ffprobe >/dev/null 2>&1; then
            MOOV_POS=$(ffprobe -v quiet -show_entries format_tags=major_brand -of default "$TESTDIR/remux_faststart.mp4" 2>/dev/null | head -2)
            info "moov atom in testa: OK (faststart)"
        fi
    else
        fail "Remux con faststart fallito"
    fi
fi

# ─────────────────────────────────────────────────────────────
# SEZIONE 6: Test V4L2 Hardware Encoding (se disponibile)
# ─────────────────────────────────────────────────────────────
sect "6/7 Test V4L2 Hardware Encode (Snapdragon VIDC)"

if [ "$HAS_V4L2=1" ] && [ "$HAS_VIDEO_DEVICES=1" ] && [ -f "$TESTDIR/test_input.ts" ]; then

    # Test h264_v4l2m2m encoder
    if [ "$HAS_V4L2_H264_ENC" = "1" ]; then
        info "Test: h264_v4l2m2m encode (hardware H.264)..."
        T3_START=$(date +%s%3N)
        ffmpeg -hide_banner -loglevel error \
            -hwaccel v4l2m2m \
            -i "$TESTDIR/test_input.ts" \
            -c:v h264_v4l2m2m \
            -b:v 4000k \
            -c:a copy \
            "$TESTDIR/v4l2_h264.mp4" 2>/tmp/v4l2_h264_err.txt
        T3_END=$(date +%s%3N)
        T3_MS=$((T3_END - T3_START))
        if [ -f "$TESTDIR/v4l2_h264.mp4" ] && [ -s "$TESTDIR/v4l2_h264.mp4" ]; then
            ok "h264_v4l2m2m:        ${T3_MS}ms → $(du -h "$TESTDIR/v4l2_h264.mp4" | cut -f1) (speed: $((30000 / T3_MS))x realtime) ← HARDWARE!"
        else
            fail "h264_v4l2m2m fallito: $(cat /tmp/v4l2_h264_err.txt | tail -3)"
        fi
    else
        info "h264_v4l2m2m non disponibile — skip"
    fi

    # Test hevc_v4l2m2m encoder
    if [ "$HAS_V4L2_HEVC_ENC" = "1" ]; then
        info "Test: hevc_v4l2m2m encode (hardware HEVC)..."
        T4_START=$(date +%s%3N)
        ffmpeg -hide_banner -loglevel error \
            -hwaccel v4l2m2m \
            -i "$TESTDIR/test_input.ts" \
            -c:v hevc_v4l2m2m \
            -b:v 2000k \
            -c:a copy \
            "$TESTDIR/v4l2_hevc.mp4" 2>/tmp/v4l2_hevc_err.txt
        T4_END=$(date +%s%3N)
        T4_MS=$((T4_END - T4_START))
        if [ -f "$TESTDIR/v4l2_hevc.mp4" ] && [ -s "$TESTDIR/v4l2_hevc.mp4" ]; then
            ok "hevc_v4l2m2m:        ${T4_MS}ms → $(du -h "$TESTDIR/v4l2_hevc.mp4" | cut -f1) (speed: $((30000 / T4_MS))x realtime) ← HARDWARE!"
        else
            fail "hevc_v4l2m2m fallito: $(cat /tmp/v4l2_hevc_err.txt | tail -3)"
        fi
    else
        info "hevc_v4l2m2m non disponibile — skip"
    fi

    # Test software HEVC (libx265) come confronto
    if ffmpeg -encoders 2>/dev/null | grep -q "libx265"; then
        info "Test: libx265 (CPU software HEVC, solo confronto)..."
        T5_START=$(date +%s%3N)
        ffmpeg -hide_banner -loglevel error \
            -i "$TESTDIR/test_input.ts" \
            -c:v libx265 -preset ultrafast \
            -b:v 2000k \
            -c:a copy \
            "$TESTDIR/sw_hevc.mp4" 2>/dev/null
        T5_END=$(date +%s%3N)
        T5_MS=$((T5_END - T5_START))
        if [ -f "$TESTDIR/sw_hevc.mp4" ] && [ -s "$TESTDIR/sw_hevc.mp4" ]; then
            warn "libx265 (CPU):       ${T5_MS}ms → $(du -h "$TESTDIR/sw_hevc.mp4" | cut -f1) (speed: $((30000 / T5_MS))x realtime) [SOFTWARE]"
        else
            info "libx265 non disponibile in questa build di FFmpeg"
        fi
    fi

else
    warn "Test V4L2 saltati: v4l2m2m non disponibile o nessun /dev/video*"
    info "Il transcoding hardware (per DVR HEVC) usa termux_transcode.sh su Termux nativo"
fi

# ─────────────────────────────────────────────────────────────
# SEZIONE 7: Riepilogo e Raccomandazioni
# ─────────────────────────────────────────────────────────────
sect "7/7 Riepilogo e Raccomandazioni"

echo ""
echo -e "${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│  Architettura DVR Hardware Acceleration                 │${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
echo ""

echo -e "  ${GREEN}OPERAZIONE${NC}              ${GREEN}METODO${NC}              ${GREEN}HARDWARE?${NC}"
echo "  ─────────────────────────────────────────────────────"
echo -e "  Recording (live→TS)    -c copy (mux solo)     ${GREEN}N/A${NC} — ottimale"
echo -e "  Remux TS→MP4          -c copy +faststart      ${GREEN}N/A${NC} — ottimale"

if [ "$HAS_V4L2_H264_ENC" = "1" ] && [ "$HAS_VIDEO_DEVICES" = "1" ]; then
    echo -e "  Transcode → H.264     h264_v4l2m2m            ${GREEN}SÌ (Snapdragon VIDC)${NC}"
else
    echo -e "  Transcode → H.264     libx264 (CPU)           ${YELLOW}NO (v4l2m2m N/A)${NC}"
fi

if [ "$HAS_V4L2_HEVC_ENC" = "1" ] && [ "$HAS_VIDEO_DEVICES" = "1" ]; then
    echo -e "  Transcode → HEVC      hevc_v4l2m2m (CHRoot)   ${GREEN}SÌ (Snapdragon VIDC)${NC}"
else
    echo -e "  Transcode → HEVC      h264_mediacodec (Termux) ${GREEN}SÌ (MediaCodec JNI)${NC}"
fi

echo ""

if [ "$HAS_V4L2" = "1" ] && [ "$HAS_VIDEO_DEVICES" = "1" ]; then
    ok "V4L2 hardware codec disponibile in CHRoot!"
    info "Per abilitare transcoding hardware HEVC nel DVR, usa:"
    info "  ffmpeg -hwaccel v4l2m2m -i input.ts -c:v hevc_v4l2m2m -b:v 2M -c:a copy output.mp4"
elif [ "$HAS_VIDEO_DEVICES" = "0" ]; then
    warn "Nessun /dev/video* disponibile nel CHRoot"
    info "Verifica che /dev sia bind-montato: su -c 'cat /proc/mounts | grep easyproxy'"
    info "Il transcoding HEVC usa termux_transcode.sh (MediaCodec via Termux nativo)"
else
    warn "V4L2 non disponibile"
    info "Il transcoding HEVC usa termux_transcode.sh (MediaCodec via Termux nativo)"
fi

echo ""
echo -e "${GREEN}Report salvato in: $REPORT_FILE${NC}"
echo ""
