#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# EasyProxy - Termux CHRoot Setup (Root Required)
# ============================================================
# Requisiti:
#   - Termux da F-Droid (NON dal Play Store)
#   - Root permanente via Magisk
#   - proot-distro ubuntu già installato (termux_setup.sh eseguito almeno una volta)
#     OPPURE rootfs Ubuntu arm64 da installare da zero
#
# Uso:
#   curl -sL https://raw.githubusercontent.com/Mr-Piovra/EasyProxy-Jay/main/termux_setup_chroot.sh | bash
#
# Dopo il setup, avvio con:
#   easyproxy
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
step() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# ─── Costanti ───────────────────────────────────────────────
PROOT_ROOTFS="$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"
CHROOT_LINK="/data/local/easyproxy-rootfs"
EP_DIR="/root/EasyProxy"
EP_REPO="https://github.com/Mr-Piovra/EasyProxy-Jay.git"
DVR_DIR="/sdcard/Movies/EasyProxy_DVR"

echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}  EasyProxy - CHRoot Setup (Root Required)    ${NC}"
echo -e "${CYAN}  Xiaomi Mi 9 Lite | arm64 | Magisk Root      ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo ""

# ─── PHASE 1: Prerequisiti ─────────────────────────────────
step "Phase 1/9: Verifica prerequisiti"

# Verifica accesso root
if ! su -c "echo root_ok" >/dev/null 2>&1; then
    err "Root non disponibile. Assicurati che Magisk sia installato e che Termux abbia il permesso di root in Magisk Manager."
fi
log "Root Magisk disponibile."

# Verifica architettura
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    err "Architettura non supportata: $ARCH. Richiesta aarch64."
fi
log "Architettura: $ARCH"

# Verifica rootfs proot-distro
if [ ! -d "$PROOT_ROOTFS" ]; then
    warn "Rootfs Ubuntu proot-distro non trovato in: $PROOT_ROOTFS"
    warn "Avvio installazione proot-distro Ubuntu come prerequisito..."
    pkg install -y proot-distro git screen wget curl 2>/dev/null || true
    proot-distro install ubuntu || err "Installazione proot-distro Ubuntu fallita."
    warn "ATTENZIONE: Esegui prima termux_setup.sh per installare Python/FFmpeg/Chromium dentro Ubuntu, poi riesegui questo script."
    err "Rootfs installato ma non configurato. Esegui prima: curl -sL https://raw.githubusercontent.com/Mr-Piovra/EasyProxy-Jay/main/termux_setup.sh | bash"
fi
log "Rootfs Ubuntu trovato: $PROOT_ROOTFS"

# Verifica screen
if ! command -v screen >/dev/null 2>&1; then
    info "Installazione screen..."
    pkg install -y screen
fi
log "screen disponibile."

# ─── PHASE 2: Symlink rootfs ────────────────────────────────
step "Phase 2/9: Configurazione percorso CHRoot"

# Crea /data/local se non esiste
su -c "mkdir -p /data/local" 2>/dev/null || true

# Gestione symlink esistente
if [ -L "$CHROOT_LINK" ]; then
    EXISTING_TARGET=$(su -c "readlink -f '$CHROOT_LINK'" 2>/dev/null || echo "")
    if [ "$EXISTING_TARGET" = "$(realpath "$PROOT_ROOTFS")" ]; then
        log "Symlink CHRoot già corretto: $CHROOT_LINK → $PROOT_ROOTFS"
    else
        warn "Symlink esistente punta a: $EXISTING_TARGET — aggiorno."
        su -c "rm '$CHROOT_LINK' && ln -s '$PROOT_ROOTFS' '$CHROOT_LINK'"
        log "Symlink aggiornato."
    fi
elif [ -d "$CHROOT_LINK" ]; then
    warn "$CHROOT_LINK è una directory, non un symlink. Rinomino in backup e creo symlink."
    su -c "mv '$CHROOT_LINK' '${CHROOT_LINK}.bak.$(date +%s)' && ln -s '$PROOT_ROOTFS' '$CHROOT_LINK'"
    log "Symlink creato (backup salvato)."
else
    su -c "ln -s '$PROOT_ROOTFS' '$CHROOT_LINK'"
    log "Symlink creato: $CHROOT_LINK → $PROOT_ROOTFS"
fi

# ─── PHASE 3: Directory mount points ───────────────────────
step "Phase 3/9: Creazione directory mount points"

# NOTA: dev/shm NON viene creata qui perché verrà nascosta dal successivo
# bind mount di /dev. Viene creata DOPO il bind in Phase 4.
for DIR in proc sys dev dev/pts sdcard; do
    su -c "mkdir -p '${CHROOT_LINK}/${DIR}'"
    log "  ✓ ${CHROOT_LINK}/${DIR}"
done

# ─── PHASE 4: Test mount + verifica CHRoot ──────────────────
step "Phase 4/9: Test mount e sanity check CHRoot"

# Porta SELinux in Permissive PRIMA dei mount (obbligatorio su MIUI enforcing)
# Questo è il motivo più comune per cui chroot fallisce su Android
su -c "setenforce 0" 2>/dev/null || warn "setenforce 0 fallito (SELinux già permissive o non disponibile)"
info "SELinux impostato a Permissive per il test."

# Funzione mount con log dell'errore reale
do_mount() {
    local OPTS="$1"; local SRC="$2"; local DST="$3"
    local OUT
    OUT=$(su -c "mountpoint -q '$DST' && echo already_mounted || mount $OPTS '$SRC' '$DST'" 2>&1)
    local RC=$?
    if echo "$OUT" | grep -q already_mounted; then
        info "Already mounted (skip): $DST"
    elif [ $RC -ne 0 ]; then
        warn "Mount fallito per '$DST': $OUT"
    fi
}

do_mount "-t proc"   "proc"   "${CHROOT_LINK}/proc"
do_mount "-t sysfs"  "sysfs"  "${CHROOT_LINK}/sys"

# Bind /dev prima, poi crea /dev/shm DENTRO il bind (Android /dev non ha shm)
su -c "mountpoint -q '${CHROOT_LINK}/dev' || mount --bind /dev '${CHROOT_LINK}/dev'" 2>/dev/null \
    || warn "Bind /dev fallito"

# Crea /dev/shm ora che /dev è bindato (crea nella /dev di Android, che è ok con root)
su -c "mkdir -p '${CHROOT_LINK}/dev/shm'" 2>/dev/null \
    || warn "mkdir /dev/shm fallito"

do_mount "-t devpts" "devpts" "${CHROOT_LINK}/dev/pts"
do_mount "-t tmpfs -o size=256M" "tmpfs" "${CHROOT_LINK}/dev/shm"

# Risolvi il symlink per il test chroot (alcune versioni di chroot non seguono symlink)
CHROOT_TARGET=$(su -c "readlink -f '${CHROOT_LINK}'" 2>/dev/null || echo "$PROOT_ROOTFS")
info "CHRoot target (resolved): $CHROOT_TARGET"

# Test CHRoot — mostra l'errore reale senza sopprimerlo
info "Esecuzione test chroot..."
CHROOT_OUT=$(su -c "chroot '$CHROOT_TARGET' /bin/uname -m" 2>&1)
CHROOT_RC=$?
if [ $CHROOT_RC -ne 0 ] || [ "$CHROOT_OUT" != "aarch64" ]; then
    echo -e "${RED}[ERR]${NC} CHRoot test fallito."
    echo "  Output:    '$CHROOT_OUT'"
    echo "  Exit code: $CHROOT_RC"
    echo ""
    echo "  Possibili cause:"
    echo "  1. SELinux denial: controlla con 'su -c dmesg | grep avc'"
    echo "  2. /bin/uname non eseguibile nel rootfs: verifica la data partition"
    echo "  3. Rootfs corrotto: ri-esegui termux_setup.sh"
    err "Setup interrotto. Risolvi il problema sopra e ri-esegui questo script."
fi
log "CHRoot funzionante: uname -m → $CHROOT_OUT"

# ─── PHASE 5: Rete Android (GID 3003 inet) ──────────────────
step "Phase 5/9: Configurazione Android Paranoid Network (GID 3003)"

# Usa il target risolto (realpath) per tutte le operazioni chroot successive
su -c "chroot '$CHROOT_TARGET' /bin/bash -c '
    # Aggiunge gruppo inet_android (GID 3003) se non esiste
    if ! grep -q \"^inet_android:\" /etc/group 2>/dev/null; then
        echo \"inet_android:x:3003:root\" >> /etc/group
        echo \"[OK] Gruppo inet_android (GID 3003) aggiunto a /etc/group\"
    else
        echo \"[OK] Gruppo inet_android già presente in /etc/group\"
    fi

    # Assicura che root sia membro del gruppo
    if ! grep -q \"^inet_android:.*root\" /etc/group 2>/dev/null; then
        sed -i \"s/^inet_android:x:3003:/inet_android:x:3003:root/\" /etc/group
        echo \"[OK] root aggiunto al gruppo inet_android\"
    fi
'"
log "Gruppo inet_android (GID 3003) configurato."

# ─── PHASE 6: DNS injection ─────────────────────────────────
step "Phase 6/9: Configurazione DNS dinamico"

# Legge DNS corrente dall'host Android
DNS1=$(getprop net.dns1 2>/dev/null || echo "1.1.1.1")
DNS2=$(getprop net.dns2 2>/dev/null || echo "8.8.8.8")
[ -z "$DNS1" ] && DNS1="1.1.1.1"
[ -z "$DNS2" ] && DNS2="8.8.8.8"

su -c "echo -e 'nameserver ${DNS1}\nnameserver ${DNS2}' > '${CHROOT_TARGET}/etc/resolv.conf'"
log "resolv.conf configurato: DNS1=$DNS1, DNS2=$DNS2"
info "(Il DNS viene aggiornato automaticamente ad ogni avvio di easyproxy)"

# ─── PHASE 7: Patch FlareSolverr per /dev/shm nativo ────────
step "Phase 7/9: Patch FlareSolverr per CHRoot (/dev/shm nativo)"

FLARE_UTILS="${CHROOT_TARGET}/root/EasyProxy/flaresolverr/src/utils.py"
if [ -f "$FLARE_UTILS" ]; then
    # Rimuove --disable-dev-shm-usage ora che /dev/shm è un tmpfs reale
    su -c "sed -i \"s|options.add_argument('--disable-dev-shm-usage'); ||g\" '$FLARE_UTILS'" 2>/dev/null || true
    su -c "sed -i \"s|; options.add_argument('--disable-dev-shm-usage')||g\" '$FLARE_UTILS'" 2>/dev/null || true
    # Assicura --no-sandbox (obbligatorio senza namespace)
    if ! su -c "grep -q \"no-sandbox\" '$FLARE_UTILS'" 2>/dev/null; then
        warn "--no-sandbox non trovato in utils.py — potrebbe causare crash di Chromium."
    else
        log "FlareSolverr: --no-sandbox presente, --disable-dev-shm-usage rimosso (ora usa tmpfs nativo)."
    fi
else
    warn "flaresolverr/src/utils.py non trovato. Verrà configurato al primo avvio."
fi

# ─── PHASE 8: Script di avvio interno al CHRoot ─────────────
step "Phase 8/9: Creazione easyproxy_chroot_start.sh"

su -c "cat > '${CHROOT_TARGET}/root/easyproxy_chroot_start.sh'" << 'CHROOT_START_EOF'
#!/bin/bash
# ============================================================
# EasyProxy - Script interno CHRoot
# Eseguito da: su -c "chroot /data/local/easyproxy-rootfs /root/easyproxy_chroot_start.sh"
# ============================================================
set -u

export HOME=/root
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PIP_BREAK_SYSTEM_PACKAGES=1
export PORT=7860
export ENABLE_WARP=false
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1

LOG_DIR="/root/.easyproxy"
LOG_FILE="$LOG_DIR/easyproxy.log"

mkdir -p "$LOG_DIR"

# Rotazione log: mantieni solo gli ultimi 1000 righe
if [ -f "$LOG_FILE" ]; then
    tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi
touch "$LOG_FILE"
exec >> "$LOG_FILE" 2>&1

# ── Aggiunge GID 3003 (Android inet) al processo corrente ──
# Necessario per aprire socket TCP/UDP in Android CHRoot
newgrp inet_android 2>/dev/null || true
# Fallback: sg non blocca se il gruppo non esiste
sg inet_android -c "echo '[OK] GID 3003 inet_android attivo'" 2>/dev/null || true

cleanup() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleanup: terminazione FlareSolverr..."
    kill "${FLARE_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT

echo ""
echo "=================================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] EasyProxy CHRoot bootstrap"
echo "=================================================="

# ── Rileva Chromium ───────────────────────────────────────
if [ -f "/usr/bin/chromium" ]; then
    export CHROME_BIN="/usr/bin/chromium"
elif [ -f "/usr/bin/chromium-browser" ]; then
    export CHROME_BIN="/usr/bin/chromium-browser"
else
    echo "[WARN] Chromium non trovato. FlareSolverr potrebbe fallire."
    export CHROME_BIN=""
fi
export CHROME_EXE_PATH="${CHROME_BIN}"
export CHROME_PATH="${CHROME_BIN}"
export CHROME_DRIVER_PATH="/usr/bin/chromedriver"
export FLARESOLVERR_URL="http://localhost:8191"

echo "Python:      $(python3 --version 2>/dev/null || echo 'MISSING')"
echo "Chromium:    ${CHROME_BIN:-MISSING}"
echo "Chromedriver: $(command -v chromedriver 2>/dev/null || echo 'MISSING')"
echo ""

# ── Verifica directory EasyProxy ──────────────────────────
if [ ! -d "/root/EasyProxy" ]; then
    echo "[FATAL] /root/EasyProxy non trovato."
    exit 1
fi

cd /root/EasyProxy

# ── Carica .env ───────────────────────────────────────────
if [ -f ".env" ]; then
    set -a
    # shellcheck disable=SC1091
    . .env
    set +a
fi
PORT="${PORT:-7860}"

# ── Kill processi residui ─────────────────────────────────
pkill -9 -f "python3.*(app|flaresolverr|easyproxy)" 2>/dev/null || true
pkill -9 -f "node.*flaresolverr" 2>/dev/null || true
sleep 1

# ── Crea directory DVR ────────────────────────────────────
RECORDINGS_DIR="${RECORDINGS_DIR:-/sdcard/Movies/EasyProxy_DVR}"
mkdir -p "$RECORDINGS_DIR" 2>/dev/null || true

# ── Avvia FlareSolverr ────────────────────────────────────
echo "Avvio FlareSolverr (headless, CHRoot)..."
cd /root/EasyProxy/flaresolverr && PORT=8191 python3 src/flaresolverr.py &
FLARE_PID=$!
cd /root/EasyProxy

echo "Attesa FlareSolverr ready (max 30s)..."
_flare_ready=0
for _i in $(seq 1 30); do
    if curl -sf http://localhost:8191/health > /dev/null 2>&1; then
        echo "[OK] FlareSolverr pronto dopo ${_i}s"
        _flare_ready=1
        break
    fi
    sleep 1
done
[ "$_flare_ready" -eq 0 ] && echo "[WARN] FlareSolverr non ha risposto in 30s — continuo comunque"

# ── Avvia EasyProxy ───────────────────────────────────────
echo "Avvio EasyProxy su porta $PORT..."
if ! python3 app.py; then
    echo ""
    echo "[CRITICAL] EasyProxy ha crashato!"
    echo "====== ULTIMI LOG ======"
    tail -n 30 "$LOG_FILE"
    echo "========================"
    exit 1
fi
CHROOT_START_EOF

su -c "chmod +x '${CHROOT_TARGET}/root/easyproxy_chroot_start.sh'"
log "easyproxy_chroot_start.sh scritto e reso eseguibile."

# ─── PHASE 9: Comandi Termux ────────────────────────────────
step "Phase 9/9: Creazione comandi Termux (chroot edition)"

CHROOT_ROOTFS_PATH="$CHROOT_TARGET"  # Usa il realpath (non il symlink) nei launcher

# ── easyproxy ───────────────────────────────────────────────
cat > "$PREFIX/bin/easyproxy" << EASYPROXY_EOF
#!/data/data/com.termux/files/usr/bin/bash
# EasyProxy launcher — CHRoot edition
ROOTFS="${CHROOT_ROOTFS_PATH}"
LOG_DIR="\$HOME/.easyproxy"
TERMUX_LOG="\$LOG_DIR/screen.log"

mkdir -p "\$LOG_DIR"

# Risolvi IP locale
LOCAL_IP=\$(ip route get 1.1.1.1 2>/dev/null | awk '{print \$7}')
[ -z "\$LOCAL_IP" ] && LOCAL_IP=\$(ifconfig wlan0 2>/dev/null | grep 'inet ' | awk '{print \$2}')
[ -z "\$LOCAL_IP" ] && LOCAL_IP="localhost"

if screen -list 2>/dev/null | grep -q "[.]easyproxy[[:space:]]"; then
    echo "EasyProxy è già in esecuzione."
    echo "   Log:  easyproxy-logs"
    echo "   Stop: easyproxy-stop"
    exit 0
fi

echo "Avvio EasyProxy (CHRoot mode)..."
echo "   Local:   http://localhost:7860"
echo "   Network: http://\${LOCAL_IP}:7860"
echo "   Log:     easyproxy-logs"
echo "   Stop:    easyproxy-stop"
echo ""

# ── Inietta DNS Android nel CHRoot ──────────────────────────
DNS1=\$(getprop net.dns1 2>/dev/null || echo "1.1.1.1")
DNS2=\$(getprop net.dns2 2>/dev/null || echo "8.8.8.8")
[ -z "\$DNS1" ] && DNS1="1.1.1.1"
[ -z "\$DNS2" ] && DNS2="8.8.8.8"
su -c "echo -e 'nameserver \${DNS1}\nnameserver \${DNS2}' > '\${ROOTFS}/etc/resolv.conf'" 2>/dev/null || true

# ── Monta filesystem (idempotente) ──────────────────────────
su -c "
    mountpoint -q '\${ROOTFS}/proc'    || mount -t proc proc '\${ROOTFS}/proc'
    mountpoint -q '\${ROOTFS}/sys'     || mount -t sysfs sysfs '\${ROOTFS}/sys'
    mountpoint -q '\${ROOTFS}/dev'     || mount --bind /dev '\${ROOTFS}/dev'
    mkdir -p '\${ROOTFS}/dev/shm' 2>/dev/null || true
    mountpoint -q '\${ROOTFS}/dev/pts' || mount -t devpts devpts '\${ROOTFS}/dev/pts'
    mountpoint -q '\${ROOTFS}/dev/shm' || mount -t tmpfs -o size=256M tmpfs '\${ROOTFS}/dev/shm'
    mountpoint -q '\${ROOTFS}/sdcard'  || mount --bind /sdcard '\${ROOTFS}/sdcard' 2>/dev/null || true
    setenforce 0 2>/dev/null || true
" 2>/dev/null

# ── Lancia CHRoot in screen ─────────────────────────────────
screen -L -Logfile "\$TERMUX_LOG" -dmS easyproxy \
    su -c "chroot '\${ROOTFS}' /root/easyproxy_chroot_start.sh"

sleep 4

if ! screen -list 2>/dev/null | grep -q "[.]easyproxy[[:space:]]"; then
    echo "EasyProxy è uscito durante l'avvio. Log screen:"
    tail -n 60 "\$TERMUX_LOG" 2>/dev/null || true
    echo ""
    echo "Log Ubuntu CHRoot:"
    su -c "tail -n 60 '\${ROOTFS}/root/.easyproxy/easyproxy.log'" 2>/dev/null || true
    exit 1
fi

echo "EasyProxy avviato con successo (CHRoot nativo)."
EASYPROXY_EOF
chmod +x "$PREFIX/bin/easyproxy"
log "Creato: easyproxy"

# ── easyproxy-stop ──────────────────────────────────────────
cat > "$PREFIX/bin/easyproxy-stop" << STOP_EOF
#!/data/data/com.termux/files/usr/bin/bash
ROOTFS="${CHROOT_ROOTFS_PATH}"

echo "Stop EasyProxy e unmount filesystem CHRoot..."

# Termina processi dentro CHRoot
su -c "
    pkill -9 -f 'python3.*(app|flaresolverr)' 2>/dev/null || true
    pkill -9 -f 'node.*flaresolverr' 2>/dev/null || true
    pkill -9 -f 'chroot.*easyproxy' 2>/dev/null || true
    sleep 1
    # Umount in ordine inverso obbligatorio
    umount '\${ROOTFS}/dev/shm'  2>/dev/null || true
    umount '\${ROOTFS}/dev/pts'  2>/dev/null || true
    umount '\${ROOTFS}/dev'      2>/dev/null || true
    umount '\${ROOTFS}/sys'      2>/dev/null || true
    umount '\${ROOTFS}/proc'     2>/dev/null || true
    umount '\${ROOTFS}/sdcard'   2>/dev/null || true
    setenforce 1 2>/dev/null || true
" 2>/dev/null

screen -X -S easyproxy quit 2>/dev/null || true
echo "Fermato."
STOP_EOF
chmod +x "$PREFIX/bin/easyproxy-stop"
log "Creato: easyproxy-stop"

# ── easyproxy-logs ──────────────────────────────────────────
cat > "$PREFIX/bin/easyproxy-logs" << LOGS_EOF
#!/data/data/com.termux/files/usr/bin/bash
ROOTFS="${CHROOT_ROOTFS_PATH}"
LOG_FILE="\${ROOTFS}/root/.easyproxy/easyproxy.log"

echo "Log EasyProxy CHRoot (Ctrl+C per uscire senza fermare il proxy):"
echo ""

if [ ! -f "\$LOG_FILE" ]; then
    echo "Nessun log trovato. EasyProxy potrebbe ancora avviarsi..."
    exit 0
fi

su -c "tail -n 120 -f '\$LOG_FILE'"
LOGS_EOF
chmod +x "$PREFIX/bin/easyproxy-logs"
log "Creato: easyproxy-logs"

# ── easyproxy-update ────────────────────────────────────────
cat > "$PREFIX/bin/easyproxy-update" << UPDATE_EOF
#!/data/data/com.termux/files/usr/bin/bash
ROOTFS="${CHROOT_ROOTFS_PATH}"

echo "Aggiornamento EasyProxy (CHRoot)..."
easyproxy-stop 2>/dev/null || true
sleep 2

su -c "chroot '\${ROOTFS}' /bin/bash -c '
    cd /root/EasyProxy &&
    git fetch &&
    git reset --hard origin/main &&
    pip install -r requirements.txt --upgrade --break-system-packages --quiet
    echo Aggiornamento completato.
'"

echo "Riavvio EasyProxy..."
easyproxy
UPDATE_EOF
chmod +x "$PREFIX/bin/easyproxy-update"
log "Creato: easyproxy-update"

# ── easyproxy-shell ─────────────────────────────────────────
cat > "$PREFIX/bin/easyproxy-shell" << SHELL_EOF
#!/data/data/com.termux/files/usr/bin/bash
# Entra nel CHRoot Ubuntu interattivamente (equivalente di: proot-distro login ubuntu)
ROOTFS="${CHROOT_ROOTFS_PATH}"

echo "Entrata nel CHRoot Ubuntu (root)..."
echo "Usa 'exit' per uscire."
echo ""

su -c "
    mountpoint -q '\${ROOTFS}/proc'    || mount -t proc proc '\${ROOTFS}/proc'
    mountpoint -q '\${ROOTFS}/sys'     || mount -t sysfs sysfs '\${ROOTFS}/sys'
    mountpoint -q '\${ROOTFS}/dev'     || mount --bind /dev '\${ROOTFS}/dev'
    mkdir -p '\${ROOTFS}/dev/shm' 2>/dev/null || true
    mountpoint -q '\${ROOTFS}/dev/pts' || mount -t devpts devpts '\${ROOTFS}/dev/pts'
    mountpoint -q '\${ROOTFS}/dev/shm' || mount -t tmpfs -o size=256M tmpfs '\${ROOTFS}/dev/shm'
    mountpoint -q '\${ROOTFS}/sdcard'  || mount --bind /sdcard '\${ROOTFS}/sdcard' 2>/dev/null || true
    chroot '\${ROOTFS}' /bin/bash -l
"
SHELL_EOF
chmod +x "$PREFIX/bin/easyproxy-shell"
log "Creato: easyproxy-shell (equivalente di 'proot-distro login ubuntu')"

# ── Umount test mounts ────────────────────────────────────────
step "Cleanup: umount mount points di test"

su -c "
    umount '${CHROOT_TARGET}/dev/shm'  2>/dev/null || true
    umount '${CHROOT_TARGET}/dev/pts'  2>/dev/null || true
    umount '${CHROOT_TARGET}/dev'      2>/dev/null || true
    umount '${CHROOT_TARGET}/sys'      2>/dev/null || true
    umount '${CHROOT_TARGET}/proc'     2>/dev/null || true
" 2>/dev/null
log "Mount di test smontati."

# ── .env DVR path ─────────────────────────────────────────────
ENV_FILE="${CHROOT_TARGET}/root/EasyProxy/.env"
if [ -f "$ENV_FILE" ]; then
    if ! grep -q "RECORDINGS_DIR" "$ENV_FILE" 2>/dev/null; then
        echo "RECORDINGS_DIR=${DVR_DIR}" >> "$ENV_FILE"
        log ".env: RECORDINGS_DIR impostato a ${DVR_DIR}"
    else
        warn ".env: RECORDINGS_DIR già configurato. Verifica manualmente se vuoi usare ${DVR_DIR}."
    fi
fi

# ─── Summary ────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  EasyProxy CHRoot Setup Completato!          ${NC}"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BLUE}Avvia:${NC}      easyproxy"
echo -e "  ${BLUE}Ferma:${NC}      easyproxy-stop"
echo -e "  ${BLUE}Log:${NC}        easyproxy-logs"
echo -e "  ${BLUE}Aggiorna:${NC}   easyproxy-update"
echo -e "  ${BLUE}Shell:${NC}      easyproxy-shell  (entra nel CHRoot)"
echo ""
echo -e "  ${CYAN}Rootfs CHRoot:${NC} ${CHROOT_LINK}"
echo -e "  ${CYAN}DVR output:${NC}   ${DVR_DIR}"
echo -e "  ${CYAN}Accesso:${NC}      http://localhost:7860"
echo ""
echo -e "  ${YELLOW}Nota:${NC} Primo avvio ~30s (Chromium init)"
echo ""
