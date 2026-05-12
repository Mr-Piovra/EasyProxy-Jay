#!/bin/bash
# ============================================================
# EasyProxy — tvvoo CHRoot Setup
# Stremio Vavoo addon hosted natively on Android
# ============================================================
# Esegui da Termux come utente normale (NON su):
#   bash termux_setup_tvvoo.sh
# ============================================================

set -euo pipefail

# ─── Colori ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}  $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log()  { echo -e "${BLUE}[INFO]${NC} $1"; }
step() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
ROOTFS_LINK="/data/local/easyproxy-rootfs"
ROOTFS=$(su -c "readlink -f '$ROOTFS_LINK'" 2>/dev/null) || \
    ROOTFS="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/ubuntu"

TVVOO_REPO="https://github.com/qwertyuiop8899/tvvoo"
TVVOO_DIR="/root/tvvoo"
TVVOO_PORT="${TVVOO_PORT:-7019}"
TVVOO_START_SCRIPT="/root/tvvoo_chroot_start.sh"

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  tvvoo CHRoot Setup — Stremio Vavoo Addon    ║${NC}"
echo -e "${CYAN}║  Android / CHRoot Ubuntu / Node.js 18 LTS   ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
echo ""

# ─── Prerequisiti ─────────────────────────────────────────
step "Phase 1/6: Verifica prerequisiti"

[ "$(id -u)" = "0" ] && err "Non eseguire come root. Usa l'utente Termux normale."
su -c "echo ok" >/dev/null 2>&1 || err "Root non disponibile. Necessario per CHRoot."
[ -d "$ROOTFS" ] || err "Rootfs CHRoot non trovato: $ROOTFS\nEsegui prima termux_setup_chroot.sh"

ok "Rootfs: $ROOTFS"
ok "Porta tvvoo: $TVVOO_PORT"

# Verifica mount (proc necessario per npm)
PROC_MOUNTED=$(su -c "mountpoint -q '$ROOTFS/proc' && echo yes || echo no" 2>/dev/null)
if [ "$PROC_MOUNTED" = "no" ]; then
    log "Esecuzione mount di sistema per CHRoot..."
    su -c "
        mountpoint -q '$ROOTFS/proc' || mount -t proc proc '$ROOTFS/proc'
        mountpoint -q '$ROOTFS/sys'  || mount -t sysfs sysfs '$ROOTFS/sys'
        mountpoint -q '$ROOTFS/dev'  || mount --bind /dev '$ROOTFS/dev'
        mkdir -p '$ROOTFS/dev/shm'
        mountpoint -q '$ROOTFS/dev/shm' || mount -t tmpfs -o size=256M tmpfs '$ROOTFS/dev/shm'
        setenforce 0 2>/dev/null || true
    " 2>/dev/null
    ok "Mount di sistema attivi"
else
    ok "Mount di sistema già attivi"
fi

# ─── Node.js 18 LTS ───────────────────────────────────────
step "Phase 2/6: Installazione Node.js 18 LTS"

NODE_VERSION=$(su -c "chroot '$ROOTFS' /bin/bash -c '
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    node --version 2>/dev/null || echo none
'" 2>/dev/null | tr -d '\r')

if echo "$NODE_VERSION" | grep -qE "^v(1[89]|2[0-9])"; then
    ok "Node.js già installato: $NODE_VERSION"
else
    log "Installazione Node.js 18 LTS (NodeSource repository)..."
    su -c "chroot '$ROOTFS' /bin/bash -c '
        export HOME=/root
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        export DEBIAN_FRONTEND=noninteractive
        export TMPDIR=/tmp

        # Installa dipendenze base
        apt-get update -qq 2>/dev/null
        apt-get install -y curl gnupg git --quiet 2>/dev/null

        # NodeSource repo per Node.js 18
        if ! [ -f /etc/apt/sources.list.d/nodesource.list ]; then
            curl -fsSL https://deb.nodesource.com/setup_18.x | bash - 2>/dev/null
        fi
        apt-get install -y nodejs --quiet 2>/dev/null
        node --version
        npm --version
    '" 2>&1 | grep -v "^$" | tail -5
    ok "Node.js installato"
fi

# Verifica git
GIT_OK=$(su -c "chroot '$ROOTFS' /bin/bash -c '
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    command -v git >/dev/null 2>&1 && echo yes || echo no
'" 2>/dev/null | tr -d '\r')
if [ "$GIT_OK" = "no" ]; then
    log "Installazione git..."
    su -c "chroot '$ROOTFS' /bin/bash -c '
        export DEBIAN_FRONTEND=noninteractive
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        apt-get install -y git --quiet 2>/dev/null
    '" 2>/dev/null
fi
ok "git disponibile"

# ─── Clone/Update tvvoo ───────────────────────────────────
step "Phase 3/6: Setup repository tvvoo"

TVVOO_EXISTS=$(su -c "test -d '$ROOTFS$TVVOO_DIR/.git' && echo yes || echo no" 2>/dev/null)

if [ "$TVVOO_EXISTS" = "yes" ]; then
    log "Repository tvvoo già presente — aggiornamento..."
    su -c "chroot '$ROOTFS' /bin/bash -c '
        export HOME=/root
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        export TMPDIR=/tmp
        cd $TVVOO_DIR
        git fetch --quiet
        git reset --hard origin/main --quiet
        echo git_updated
    '" 2>/dev/null | grep -q "git_updated" && ok "Repository aggiornato" || warn "Aggiornamento git fallito (continuo)"
else
    log "Clone tvvoo da GitHub..."
    su -c "chroot '$ROOTFS' /bin/bash -c '
        export HOME=/root
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        export TMPDIR=/tmp
        git clone --quiet $TVVOO_REPO $TVVOO_DIR
        echo clone_ok
    '" 2>/dev/null | grep -q "clone_ok" || err "Clone tvvoo fallito. Verifica la connessione."
    ok "Repository clonato"
fi

# ─── Build ────────────────────────────────────────────────
step "Phase 4/6: Build TypeScript → JavaScript"

log "npm install + npm run build (può richiedere 1-2 minuti)..."
BUILD_OUT=$(su -c "chroot '$ROOTFS' /bin/bash -c '
    export HOME=/root
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export TMPDIR=/tmp
    export NODE_ENV=production
    cd $TVVOO_DIR
    npm install --quiet 2>&1
    npm run build 2>&1
    echo BUILD_DONE
'" 2>/dev/null)

echo "$BUILD_OUT" | grep -q "BUILD_DONE" || err "Build fallita:\n$(echo "$BUILD_OUT" | tail -10)"
ok "Build completata"

# ─── Startup script CHRoot ────────────────────────────────
step "Phase 5/6: Creazione script di avvio"

su -c "cat > '$ROOTFS$TVVOO_START_SCRIPT'" << 'CHROOT_START_EOF'
#!/bin/bash
# tvvoo CHRoot startup script
# Eseguito DENTRO il CHRoot Ubuntu

export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export TMPDIR=/tmp
export XDG_RUNTIME_DIR=/tmp/xdg-runtime
export DBUS_SESSION_BUS_ADDRESS=disabled:0
export NODE_ENV=production

mkdir -p /tmp/xdg-runtime
mkdir -p /root/.tvvoo

LOG_FILE="/root/.tvvoo/tvvoo.log"
PIDFILE="/root/.tvvoo/tvvoo.pid"

TVVOO_PORT="${TVVOO_PORT:-7019}"
TVVOO_DIR="/root/tvvoo"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

# ── Auto-updater giornaliero ─────────────────────────────
auto_update_loop() {
    while true; do
        sleep 86400  # controlla ogni 24h
        log "[AutoUpdate] Controllo aggiornamenti GitHub..."

        LOCAL=$(git -C "$TVVOO_DIR" rev-parse HEAD 2>/dev/null)
        REMOTE=$(git -C "$TVVOO_DIR" ls-remote origin main 2>/dev/null | cut -f1)

        if [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
            log "[AutoUpdate] Nuova versione disponibile — aggiornamento..."
            git -C "$TVVOO_DIR" fetch --quiet && \
            git -C "$TVVOO_DIR" reset --hard origin/main --quiet

            cd "$TVVOO_DIR"
            npm install --quiet 2>/dev/null
            npm run build --quiet 2>/dev/null && \
                log "[AutoUpdate] Build completata. Riavvio tvvoo..." || \
                log "[AutoUpdate] Build fallita — nessun riavvio."

            # Riavvia il processo principale
            kill -SIGTERM "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || true
            sleep 2
            PORT=$TVVOO_PORT node "$TVVOO_DIR/dist/addon.js" >> "$LOG_FILE" 2>&1 &
            echo $! > "$PIDFILE"
            log "[AutoUpdate] tvvoo riavviato (PID: $(cat "$PIDFILE"))"
        else
            log "[AutoUpdate] Nessun aggiornamento disponibile."
        fi
    done
}

# ── Avvio ────────────────────────────────────────────────
log "=================================="
log "tvvoo v$(node -e "console.log(require('$TVVOO_DIR/package.json').version)" 2>/dev/null || echo '?') avvio"
log "Porta: $TVVOO_PORT"
log "=================================="

if [ ! -f "$TVVOO_DIR/dist/addon.js" ]; then
    log "[ERR] dist/addon.js non trovato. Esegui prima il setup."
    exit 1
fi

# Avvia auto-updater in background
auto_update_loop &
UPDATER_PID=$!

# Avvia tvvoo
cd "$TVVOO_DIR"
PORT=$TVVOO_PORT node dist/addon.js >> "$LOG_FILE" 2>&1 &
TVVOO_PID=$!
echo $TVVOO_PID > "$PIDFILE"
log "tvvoo avviato (PID: $TVVOO_PID)"

# Attendi — exit quando tvvoo muore
wait $TVVOO_PID
EXIT_CODE=$?
kill $UPDATER_PID 2>/dev/null || true
log "[CRITICAL] tvvoo terminato (exit: $EXIT_CODE)"
CHROOT_START_EOF

su -c "chmod +x '$ROOTFS$TVVOO_START_SCRIPT'"
ok "Script di avvio: $TVVOO_START_SCRIPT"

# ─── Comandi Termux ───────────────────────────────────────
step "Phase 6/6: Creazione comandi Termux"

CHROOT_ROOTFS_PATH="$ROOTFS"

# ── tvvoo (start) ────────────────────────────────────────
cat > "$PREFIX/bin/tvvoo" << TVVOO_EOF
#!/data/data/com.termux/files/usr/bin/bash
ROOTFS="\$(su -c "readlink -f /data/local/easyproxy-rootfs" 2>/dev/null || echo "$CHROOT_ROOTFS_PATH")"
TVVOO_LOG="\$HOME/.tvvoo_screen.log"

# Verifica se già in esecuzione
if screen -list 2>/dev/null | grep -q "tvvoo"; then
    echo "tvvoo già in esecuzione. Usa tvvoo-stop per fermarlo."
    exit 0
fi

echo "Avvio tvvoo (CHRoot mode)..."
echo "   Locale:  http://localhost:${TVVOO_PORT}"
echo "   Stremio: http://localhost:${TVVOO_PORT}/manifest.json"
echo "   Log:     tvvoo-logs"
echo "   Stop:    tvvoo-stop"

# Assicura mount attivi (condivisi con EasyProxy se in esecuzione)
su -c "
    mountpoint -q '\${ROOTFS}/proc' || mount -t proc proc '\${ROOTFS}/proc'
    mountpoint -q '\${ROOTFS}/sys'  || mount -t sysfs sysfs '\${ROOTFS}/sys'
    mountpoint -q '\${ROOTFS}/dev'  || mount --bind /dev '\${ROOTFS}/dev'
    mkdir -p '\${ROOTFS}/dev/shm'
    mountpoint -q '\${ROOTFS}/dev/shm' || mount -t tmpfs -o size=256M tmpfs '\${ROOTFS}/dev/shm'
    setenforce 0 2>/dev/null || true
" 2>/dev/null

screen -L -Logfile "\$TVVOO_LOG" -dmS tvvoo \
    su -c "chroot '\${ROOTFS}' $TVVOO_START_SCRIPT"

sleep 3
if screen -list 2>/dev/null | grep -q "tvvoo"; then
    echo "tvvoo avviato con successo."
else
    echo "[ERR] tvvoo non si è avviato. Controlla: tvvoo-logs"
fi
TVVOO_EOF

# ── tvvoo-stop ────────────────────────────────────────────
cat > "$PREFIX/bin/tvvoo-stop" << 'STOP_EOF'
#!/data/data/com.termux/files/usr/bin/bash
echo "Arresto tvvoo..."
screen -S tvvoo -X quit 2>/dev/null || true
pkill -f "tvvoo_chroot_start" 2>/dev/null || true
echo "Fermato."
STOP_EOF

# ── tvvoo-logs ────────────────────────────────────────────
cat > "$PREFIX/bin/tvvoo-logs" << LOGS_EOF
#!/data/data/com.termux/files/usr/bin/bash
ROOTFS="\$(su -c "readlink -f /data/local/easyproxy-rootfs" 2>/dev/null || echo "$CHROOT_ROOTFS_PATH")"
LOG="\${ROOTFS}/root/.tvvoo/tvvoo.log"
echo "Log tvvoo (Ctrl+C per uscire):"
if [ -f "\$LOG" ]; then
    tail -f "\$LOG"
else
    echo "(log non ancora disponibile — tvvoo è in esecuzione?)"
fi
LOGS_EOF

# ── tvvoo-update ──────────────────────────────────────────
cat > "$PREFIX/bin/tvvoo-update" << UPDT_EOF
#!/data/data/com.termux/files/usr/bin/bash
ROOTFS="\$(su -c "readlink -f /data/local/easyproxy-rootfs" 2>/dev/null || echo "$CHROOT_ROOTFS_PATH")"

echo "Aggiornamento tvvoo..."
tvvoo-stop 2>/dev/null || true
sleep 2

su -c "chroot '\${ROOTFS}' /bin/bash -c '
    export HOME=/root
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export TMPDIR=/tmp
    export NODE_ENV=production

    LOCAL=\$(git -C /root/tvvoo rev-parse HEAD 2>/dev/null)
    REMOTE=\$(git -C /root/tvvoo ls-remote origin main 2>/dev/null | cut -f1)

    if [ \"\$LOCAL\" = \"\$REMOTE\" ]; then
        echo \"[OK] Già alla versione più recente (\${LOCAL:0:8}). Nessun aggiornamento.\"
    else
        echo \"Nuova versione disponibile. Aggiornamento...\"
        cd /root/tvvoo
        git fetch --quiet && git reset --hard origin/main
        npm install --quiet
        npm run build
        echo \"[OK] Aggiornamento completato.\"
    fi
'"

echo "Riavvio tvvoo..."
tvvoo
UPDT_EOF

# ── tvvoo-shell ───────────────────────────────────────────
cat > "$PREFIX/bin/tvvoo-shell" << SHELL_EOF
#!/data/data/com.termux/files/usr/bin/bash
ROOTFS="\$(su -c "readlink -f /data/local/easyproxy-rootfs" 2>/dev/null || echo "$CHROOT_ROOTFS_PATH")"
su -c "chroot '\${ROOTFS}' /bin/bash -l"
SHELL_EOF

chmod +x "$PREFIX/bin/tvvoo" "$PREFIX/bin/tvvoo-stop" \
         "$PREFIX/bin/tvvoo-logs" "$PREFIX/bin/tvvoo-update" \
         "$PREFIX/bin/tvvoo-shell"

ok "Creati: tvvoo, tvvoo-stop, tvvoo-logs, tvvoo-update, tvvoo-shell"

# ─── Riepilogo ─────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Setup tvvoo completato!                     ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}Avvia:${NC}    tvvoo"
echo -e "  ${GREEN}Ferma:${NC}    tvvoo-stop"
echo -e "  ${GREEN}Log:${NC}      tvvoo-logs"
echo -e "  ${GREEN}Update:${NC}   tvvoo-update"
echo -e "  ${GREEN}Shell:${NC}    tvvoo-shell"
echo ""
echo -e "  Locale:   ${BLUE}http://localhost:${TVVOO_PORT}/manifest.json${NC}"
echo -e "  Stremio:  ${BLUE}https://jayandroidtvvoo.dpdns.org/manifest.json${NC}"
echo ""
echo -e "  ${YELLOW}Auto-update:${NC} check GitHub ogni 24h, rebuild + restart automatico"
echo ""
