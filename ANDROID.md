# ANDROID.md — Architettura di Deployment su Android/Termux

> Documento per agenti AI: descrive la struttura completa del sistema EasyProxy
> quando eseguito su smartphone Android tramite Termux. Leggi tutto prima di
> toccare qualsiasi file relativo al deployment o alla configurazione.
>
> **Due modalità supportate:** PRoot (no root) e CHRoot nativo (root Magisk).
> La modalità CHRoot è quella raccomandata per prestazioni massime.

---

## 1. Stack tecnologico e struttura a layer

### Modalità A — PRoot (no root, compatibilità massima)

```
┌─────────────────────────────────────────────────────────┐
│  App Android: Termux  (shell nativa Android, no root)   │
│  PATH: /data/data/com.termux/files/usr/bin/             │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │  proot-distro Ubuntu  (container Linux leggero)  │   │
│  │  Root FS: /data/data/com.termux/files/usr/var/   │   │
│  │           lib/proot-distro/installed-rootfs/      │   │
│  │           ubuntu/                                 │   │
│  │  Syscall: intercettate via ptrace (overhead!)    │   │
│  │  /root/EasyProxy/          ← codebase Python      │   │
│  │  /root/EasyProxy/flaresolverr/  ← solver JS/Py   │   │
│  │  /root/.easyproxy/easyproxy.log ← log principale │   │
│  └──────────────────────────────────────────────────┘   │
│  screen "easyproxy"  ← processo background persistente  │
└─────────────────────────────────────────────────────────┘
```

### Modalità B — CHRoot Nativo (root Magisk, prestazioni massime) ⭐

```
┌─────────────────────────────────────────────────────────────┐
│  Android Kernel Linux 4.14 (arm64, Xiaomi Mi 9 Lite)        │
│                                                             │
│  Termux (shell nativa, launcher comandi)                    │
│  └── su -c  (Magisk root permanente)                        │
│       └── CHRoot reale → /data/local/easyproxy-rootfs/      │
│            (symlink a rootfs proot-distro Ubuntu 22.04)     │
│            ├── /proc   mount -t proc    [kernel namespace]   │
│            ├── /sys    mount -t sysfs   [kernel namespace]   │
│            ├── /dev    bind mount /dev  [device nodes reali] │
│            ├── /dev/pts devpts          [terminali PTY]      │
│            ├── /dev/shm tmpfs 256MB     [SHM Chromium]       │
│            ├── /sdcard  bind mount      [DVR output]         │
│            │                                                 │
│            │  Syscall: DIRETTE al kernel — zero overhead!   │
│            │  /root/EasyProxy/          ← codebase Python    │
│            │  /root/EasyProxy/flaresolverr/                  │
│            │  /root/.easyproxy/easyproxy.log                │
│            └── GID 3003 (inet_android) → accesso rete OK    │
│                                                             │
│  screen "easyproxy"  ← processo background persistente      │
└─────────────────────────────────────────────────────────────┘
```

### Perché CHRoot è superiore a PRoot?

| Aspetto | PRoot | CHRoot |
|---------|-------|--------|
| Intercettazione syscall | `ptrace` su ogni call | Zero — kernel nativo |
| CPU overhead HLS proxy | Alto | **~40-50% meno** |
| Avvio Chromium/FlareSolverr | 15-30s | **5-10s** |
| `/dev/shm` per Chromium | Emulato → `/tmp` | **tmpfs 256MB reale** |
| Scrittura DVR su sdcard | FUSE + proot layer | **bind mount diretto** |
| Root richiesto | No | **Sì (Magisk)** |

---

## 2. Setup iniziale (one-shot)

### Setup PRoot (no root)

```bash
# Da eseguire UNA SOLA VOLTA in Termux
curl -sL https://raw.githubusercontent.com/Mr-Piovra/EasyProxy-Jay/main/termux_setup.sh | bash
```

| Fase | Cosa fa |
|------|---------|
| 1/5 | Installa pacchetti Termux: `proot-distro`, `git`, `screen`, `wget`, `pulseaudio` |
| 2/5 | Installa Ubuntu arm64 via `proot-distro install ubuntu` |
| 3/4 | Dentro Ubuntu: installa Python 3, FFmpeg, Chromium, chromedriver, pip, dipendenze EasyProxy |
| 4/4 | Clona `Mr-Piovra/EasyProxy-Jay` in `/root/EasyProxy/`, installa `requirements.txt`, configura FlareSolverr |
| 5/5 | Crea comandi globali Termux: `easyproxy`, `easyproxy-stop`, `easyproxy-logs`, `easyproxy-update` |

### Setup CHRoot (root Magisk) — RACCOMANDATO

```bash
# Passo 1: esegui il setup proot (installa Ubuntu + dipendenze)
curl -sL https://raw.githubusercontent.com/Mr-Piovra/EasyProxy-Jay/main/termux_setup.sh | bash

# Passo 2: esegui il setup chroot (riconfigura i launcher)
curl -sL https://raw.githubusercontent.com/Mr-Piovra/EasyProxy-Jay/main/termux_setup_chroot.sh | bash
```

| Fase | Cosa fa |
|------|---------|
| 1/9 | Verifica `su` Magisk, architettura `aarch64`, rootfs proot-distro esistente |
| 2/9 | Crea symlink `/data/local/easyproxy-rootfs` → rootfs Ubuntu proot-distro |
| 3/9 | Crea directory mount points (`proc`, `sys`, `dev`, `dev/pts`, `dev/shm`, `sdcard`) |
| 4/9 | Test mount + sanity check `chroot uname -m` → `aarch64` |
| 5/9 | Configura GID 3003 (`inet_android`) in `/etc/group` per accesso rete Android |
| 6/9 | Inietta DNS da `getprop net.dns1` in `/etc/resolv.conf` |
| 7/9 | Patch FlareSolverr: rimuove `--disable-dev-shm-usage` (ora usa `/dev/shm` tmpfs reale) |
| 8/9 | Scrive `easyproxy_chroot_start.sh` dentro rootfs (`/root/`) |
| 9/9 | Ricrea comandi Termux: `easyproxy`, `easyproxy-stop`, `easyproxy-logs`, `easyproxy-update`, `easyproxy-shell` |

> **IMPORTANTE:** Il repo di riferimento è `Mr-Piovra/EasyProxy-Jay` (fork personale),
> NON `realbestia1/EasyProxy` (upstream originale).

---

## 3. Percorsi importanti

| Cosa | Percorso |
|------|----------|
| Codebase EasyProxy | `[ubuntu-root]/root/EasyProxy/` |
| Configurazione `.env` | `[ubuntu-root]/root/EasyProxy/.env` |
| Log principale (Ubuntu) | `[ubuntu-root]/root/.easyproxy/easyproxy.log` |
| Log screen (Termux) | `$HOME/.easyproxy/screen.log` |
| Comandi globali Termux | `/data/data/com.termux/files/usr/bin/easyproxy*` |
| Script di avvio Ubuntu | `[ubuntu-root]/root/easyproxy_start.sh` |
| Recordings DVR | `[ubuntu-root]/root/EasyProxy/recordings/` (configurabile via `.env`) |
| DB registrazioni | `[ubuntu-root]/root/EasyProxy/recordings/recordings.db` |

`[ubuntu-root]` = `/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/ubuntu`

---

## 4. Variabili d'ambiente (`.env`)

Il file `/root/EasyProxy/.env` dentro Ubuntu è la configurazione principale.
**Non viene toccato dagli aggiornamenti** (git non lo traccia). Variabili supportate:

```ini
# Networking
PORT=7860                    # porta su cui ascolta il server (default 7860)
API_PASSWORD=                # password per le API (vuota = nessuna auth)

# Proxy di rete
ENABLE_WARP=false            # usa Cloudflare WARP come proxy uscita (socks5h://127.0.0.1:1080)
WARP_PROXY_URL=              # override URL WARP (default: socks5h://127.0.0.1:1080)
GLOBAL_PROXY=                # proxy globale (es. socks5h://127.0.0.1:1080), virgola-separato
TRANSPORT_ROUTES=            # routing selettivo per dominio: {URL=domain,PROXY=proxy}
WARP_EXCLUDED_HOSTS=         # domini esclusi da WARP (lista virgola-separata)

# DVR / Registrazioni
DVR_ENABLED=false            # abilita il modulo registrazioni (true/false)
RECORDINGS_DIR=recordings    # cartella registrazioni (relativa a /root/EasyProxy/)
MAX_RECORDING_DURATION=28800 # durata massima registrazione in secondi (default 8h)
RECORDINGS_RETENTION_DAYS=7  # giorni di retention automatica

# Modalità MPD/DASH
MPD_MODE=legacy              # ffmpeg | legacy | none | disabled

# Logging
LOG_LEVEL=WARNING            # DEBUG | INFO | WARNING | ERROR | CRITICAL
```

Lo script di avvio (`easyproxy_start.sh`) esporta anche:
```bash
export PYTHONDONTWRITEBYTECODE=1   # no .pyc su filesystem proot (riduce I/O su sdcard)
export PYTHONUNBUFFERED=1          # logging real-time
export PORT=7860                   # override esplicito
export CHROME_BIN=/usr/bin/chromium
export CHROME_DRIVER_PATH=/usr/bin/chromedriver
export FLARESOLVERR_URL=http://localhost:8191
```

---

## 5. Avvio, stop e log

### Avvio
```bash
# In Termux (non dentro Ubuntu):
easyproxy
```
Questo comando:
1. Risolve l'IP locale della rete Wi-Fi
2. Controlla che non ci sia già una sessione `screen` attiva
3. Lancia `screen -dmS easyproxy` con `proot-distro login ubuntu -- bash /root/easyproxy_start.sh`
4. Attende 3s e verifica che `screen` sia ancora vivo

### Cosa fa `easyproxy_start.sh` dentro Ubuntu:
1. Killa eventuali processi residui di Python/FlareSolverr
2. Avvia FlareSolverr su porta `8191` in background
3. Attende fino a 30s che `/health` di FlareSolverr risponda OK
4. Lancia `python3 app.py` sulla porta configurata
5. In caso di crash di `app.py`, stampa gli ultimi 30 righe di log ed esce con codice 1

### Stop
```bash
easyproxy-stop
```
Esegue `pkill -9` su tutti i processi Python e FlareSolverr dentro Ubuntu,
poi termina la sessione `screen`.

### Log
```bash
easyproxy-logs
```
- Se la sessione screen è attiva: si attacca con `screen -r` (uscire con `Ctrl+A D`)
- Se non è attiva: mostra ultimi 80 righe del log Termux + ultimi 120 del log Ubuntu

---

## 6. Aggiornamento del codice

```bash
easyproxy-update
```
Esegue dentro Ubuntu:
```bash
cd /root/EasyProxy && git fetch && git reset --hard origin/main && pip install -r requirements.txt --upgrade --break-system-packages
```

> **⚠️ ATTENZIONE:** `git reset --hard` sovrascrive qualsiasi modifica locale
> non committata. Il file `.env` è al sicuro perché non è tracciato da git.
> Altre modifiche manuali ai file Python vengono **perse**.
>
> Per modifiche permanenti: fai commit sul repo `Mr-Piovra/EasyProxy-Jay`
> su GitHub da Mac/PC, poi esegui `easyproxy-update` sul telefono.

---

## 7. Flusso di sviluppo consigliato

```
Mac/PC (sviluppo)
    ↓ git push → github.com/Mr-Piovra/EasyProxy-Jay
    
Termux (produzione)
    ↓ easyproxy-update
    ↓ easyproxy
```

**Non modificare i file direttamente dentro Termux/Ubuntu** a meno che non sia
un hotfix urgente. Se lo fai, ricorda di committare dal Mac prima del prossimo update.

---

## 8. Accesso al server

Il server ascolta su `0.0.0.0:7860` (tutte le interfacce).

| Tipo | URL |
|------|-----|
| Locale (stesso telefono) | `http://localhost:7860` |
| Rete locale (da altri dispositivi) | `http://<IP-WiFi-telefono>:7860` |
| DVR / Registrazioni | `http://<IP>:7860/recordings` |
| API DVR config | `http://<IP>:7860/api/dvr/config` |

L'IP locale viene stampato all'avvio di `easyproxy`.

> Se `API_PASSWORD` è impostata, aggiungere `?api_password=<password>` a ogni
> richiesta API o usare l'header `x-api-password`.

---

## 9. Architettura interna del server Python

Il server è basato su **aiohttp** (async, single-process):

```
app.py                          ← entry point, registra tutte le routes
├── services/hls_proxy.py       ← HLSProxy: gestisce manifest, segmenti, estrattori
├── services/manifest_rewriter.py ← riscrive URL nei manifest HLS/MPD per il proxy
├── services/recording_manager.py ← RecordingManager: avvia/ferma FFmpeg per DVR
├── services/recording_db.py    ← SQLite per metadata registrazioni
├── routes/recordings.py        ← API REST per la UI registrazioni
├── config.py                   ← legge .env, espone costanti globali
└── extractors/                 ← estrattori per vari siti (Vavoo, VixSrc, ecc.)
```

### Ottimizzazioni specifiche per CPU mobile (ARM)

Queste modifiche sono state fatte specificamente per ridurre il carico CPU su
dispositivi mobile con proot-distro (overhead I/O maggiore rispetto a Linux nativo):

| File | Ottimizzazione |
|------|----------------|
| `hls_proxy.py` | `iter_chunked(65536)` invece di `iter_any()` → riduce da 200+ a ~8 await per segmento |
| `hls_proxy.py` | Manifest cache in-memory con TTL 4s → evita fetch upstream ridondanti dei player HLS |
| `hls_proxy.py` | Connection pre-warm: HEAD verso CDN appena servito il manifest → elimina TCP slow start al cold start, riduce buffering iniziale di 1-3s |
| `hls_proxy.py` | Segment coalescing: se più client richiedono lo stesso segmento in contemporanea, viene scaricato una sola volta e condiviso via `asyncio.Event` → -66% banda upstream con 2 client + DVR sullo stesso canale |
| `hls_proxy.py` | AES-128 key cache (TTL 30s): la chiave di decifratura viene servita dalla RAM invece di fare un fetch upstream per ogni segmento → -70% richieste chiavi in stream cifrati |
| `hls_proxy.py` | Proof-of-work HMAC/MD5 spostato su `run_in_executor`: 100.000 iterazioni MD5 non bloccano più l'event loop asyncio (eliminati spike da 50-150ms su CPU mobile) |
| `hls_proxy.py` | Captured manifest refresh: sleep 2s → 10s → -80% chiamate agli estrattori in background con 3+ stream attivi |
| `manifest_rewriter.py` | Precomputo di `is_live_stream` prima del loop → eliminata scansione O(n²) del manifest_content su ogni riga del manifest |
| `app.py` | Rimosso blocco duplicato `os.path.exists + touch_stream` in `proxy_hls_stream` |
| `ffmpeg_manager.py` | Fix resource leak: `log_file` ora garantito chiuso via `try/finally` anche in caso di eccezione |
| `hls_proxy.py` | DNS cache locale (`use_dns_cache=True`, TTL 300s) → evita re-resolve via VPN |
| `hls_proxy.py` | `keepalive_timeout=75s` allineato al server → meno riconnessioni TCP |
| `hls_proxy.py` | Retry 1 volta (0.5s) su errori TCP transitori prima di fallire |
| `app.py` | `backlog=256`, `keepalive_timeout=75`, `shutdown_timeout=10` |
| `config.py` | Proxy-alive cache: check ogni 30s (non ogni 10s) |
| `manifest_rewriter.py` | `#EXT-X-START:TIME-OFFSET=-6.0` → buffer anti-stutter di 2 segmenti senza ritardo percepibile |
| `termux_setup.sh` | `PYTHONDONTWRITEBYTECODE=1` → no scrittura `.pyc` su sdcard |

---

## 10. DVR / Registrazioni

Il modulo DVR è **disabilitato per default** (`DVR_ENABLED=false` in `.env`).

Per abilitarlo:
```ini
# In /root/EasyProxy/.env
DVR_ENABLED=true
RECORDINGS_DIR=/sdcard/Movies/EasyProxy   # path su sdcard (opzionale)
```

Poi riavviare: `easyproxy-stop && easyproxy`

### Comportamento attuale (post-ripristino a commit a110137)
- Le registrazioni vengono salvate come **singoli file `.ts`** (MPEG-TS)
- FFmpeg registra direttamente senza segmentazione
- L'auto-record (registrazione automatica delle dirette guardate) è disponibile
  e si gestisce via UI in `/recordings`
- Il formato `.ts` **non supporta seek in VLC** su file in crescita o completati
  senza indice. Considerare la migrazione a MP4 frammentato se il seek è necessario.

### Comandi utili per il DVR da Termux
```bash
# Entra dentro Ubuntu per ispezionare le registrazioni
proot-distro login ubuntu

# Lista registrazioni
ls -lh /root/EasyProxy/recordings/

# Ispeziona il DB
sqlite3 /root/EasyProxy/recordings/recordings.db ".tables"
sqlite3 /root/EasyProxy/recordings/recordings.db "SELECT id,name,status,file_path FROM recordings ORDER BY started_at DESC LIMIT 10;"
```

---

## 11. FlareSolverr

FlareSolverr è un server headless che bypass Cloudflare usando Chromium.
Gira su `http://localhost:8191` e viene avviato automaticamente da `easyproxy_start.sh`.

- Usa il Chromium di sistema (`/usr/bin/chromium`) invece di scaricarne uno → risparmia ~500MB
- Modifiche applicate a `flaresolverr/src/utils.py` durante il setup:
  - `--no-sandbox`, `--disable-dev-shm-usage`, `--disable-gpu`, `--headless=new`
  - Rimossa chiamata a `start_xvfb_display()` (non serve in headless)
  - Hardcoded `chromedriver` path a `/usr/bin/chromedriver`

---

## 12. Debug e troubleshooting

### Server non si avvia
```bash
# Guarda i log Ubuntu
proot-distro login ubuntu -- bash -lc "tail -n 100 /root/.easyproxy/easyproxy.log"

# Oppure
easyproxy-logs
```

### Verifica che il server risponda
```bash
# Da Termux (o da qualsiasi dispositivo in rete)
curl http://localhost:7860/
```

### Riavvio pulito
```bash
easyproxy-stop
sleep 2
easyproxy
```

### Entrare manualmente dentro Ubuntu
```bash
proot-distro login ubuntu
# Ora sei root dentro Ubuntu
cd /root/EasyProxy
python3 app.py  # avvio manuale per vedere errori in real-time
```

### Controllare FFmpeg (usato per DVR)
```bash
proot-distro login ubuntu -- bash -c "ffmpeg -version"
```

---

## 13. Limitazioni note dell'ambiente proot

| Limitazione | Impatto |
|-------------|---------|
| Nessun accesso a `/proc/net/` | `ss`, `netstat` non funzionano normalmente |
| Filesystem proot più lento della RAM | Scritture su sdcard aggiungono latenza |
| CPU ARM throttling | Processi CPU-intensive (FFmpeg, Chromium) possono essere lenti |
| Memoria limitata (tipicamente 4-8GB telefono) | FlareSolverr + Chromium + Python possono saturare la RAM |
| No `systemd` | Nessun service manager: tutto gira tramite `screen` + trap EXIT |
| Android battery optimization | Android può killare Termux se in background: disabilitare l'ottimizzazione batteria per Termux nelle impostazioni Android |

---

## 14. Architettura CHRoot — Dettagli Tecnici

> Questa sezione si applica **solo alla modalità CHRoot** (setup tramite `termux_setup_chroot.sh`).

### File e percorsi CHRoot

| Cosa | Percorso |
|------|----------|
| Symlink rootfs CHRoot | `/data/local/easyproxy-rootfs` → `[ubuntu-root]` |
| Script avvio interno | `[ubuntu-root]/root/easyproxy_chroot_start.sh` |
| Launcher Termux | `/data/data/com.termux/files/usr/bin/easyproxy*` |
| Log applicazione | `[ubuntu-root]/root/.easyproxy/easyproxy.log` |
| Log screen Termux | `$HOME/.easyproxy/screen.log` |
| DVR recordings | `/sdcard/Movies/EasyProxy_DVR` (bind mount → `/sdcard`) |
| DNS CHRoot | `[ubuntu-root]/etc/resolv.conf` (aggiornato ad ogni avvio) |

### Comandi Termux (CHRoot edition)

| Comando | Funzione |
|---------|----------|
| `easyproxy` | Inietta DNS, monta filesystem, `setenforce 0`, lancia screen+chroot |
| `easyproxy-stop` | Kill processi, umount inverso, `setenforce 1` |
| `easyproxy-logs` | `su -c tail -f [ubuntu-root]/root/.easyproxy/easyproxy.log` |
| `easyproxy-update` | `easyproxy-stop` + `chroot git reset --hard` + `pip install -r` + restart |
| `easyproxy-shell` | Monta fs + `su -c chroot ... /bin/bash -l` (shell interattiva) |

### Flusso di avvio dettagliato (CHRoot)

```
Termux $ easyproxy
  │
  ├─ [1] getprop net.dns1/dns2 → inietta in /etc/resolv.conf
  ├─ [2] su -c mount proc/sys/dev/dev/pts/dev/shm/sdcard (idempotente)
  ├─ [3] su -c setenforce 0
  ├─ [4] screen -dmS easyproxy \
  │       su -c "chroot /data/local/easyproxy-rootfs /root/easyproxy_chroot_start.sh"
  │
  └─ [dentro CHRoot — easyproxy_chroot_start.sh]
        ├─ [5] exec >> /root/.easyproxy/easyproxy.log
        ├─ [6] newgrp inet_android (GID 3003 — Android Paranoid Network)
        ├─ [7] kill processi residui
        ├─ [8] FlareSolverr & (PID=$FLARE_PID)
        ├─ [9] attesa health /health FlareSolverr (max 30s)
        └─ [10] python3 app.py
```

---

## 15. Mount Points CHRoot — Lifecycle

### Ordine di mount (obbligatorio)

```bash
ROOTFS=/data/local/easyproxy-rootfs

mount -t proc    proc    $ROOTFS/proc        # PID namespace, /proc/self
mount -t sysfs   sysfs   $ROOTFS/sys         # sysfs, driver info
mount --bind     /dev    $ROOTFS/dev         # device nodes reali (urandom, null, tty)
mount -t devpts  devpts  $ROOTFS/dev/pts     # pseudo-terminali PTY
mount -t tmpfs -o size=256M tmpfs $ROOTFS/dev/shm  # SHM per Chromium IPC
mount --bind     /sdcard $ROOTFS/sdcard      # DVR output (FUSE bind)
```

### Ordine di umount (inverso — obbligatorio)

```bash
# SEMPRE in questo ordine, altrimenti mount zombie
umount $ROOTFS/dev/shm
umount $ROOTFS/dev/pts
umount $ROOTFS/dev
umount $ROOTFS/sys
umount $ROOTFS/proc
umount $ROOTFS/sdcard  2>/dev/null || true
```

> **⚠️ ATTENZIONE:** Un umount parziale (processo ancora in esecuzione) lascia
> mount point zombie. Sintomo: `easyproxy-stop` va a buon fine ma il rootfs
> rimane occupato e il riavvio fallisce. Rimedio: `su -c "umount -l $ROOTFS/dev"`
> (lazy unmount).

### Verifica mount attivi

```bash
# In Termux, controlla cosa è montato:
su -c "cat /proc/mounts | grep easyproxy"
```

---

## 16. Troubleshooting CHRoot

### SELinux AVC Denial (Chromium/FlareSolverr non parte)

Sintomo: `dmesg | grep avc` mostra denial per operazioni di Chromium.

```bash
# Verifica lo stato SELinux
su -c "getenforce"   # Dovrebbe essere Permissive durante la sessione EasyProxy

# Se ancora Enforcing dopo l'avvio:
su -c "setenforce 0"

# Leggi i denial recenti
su -c "dmesg | grep avc | tail -20"
```

### GID 3003 — Rete non funzionante dentro CHRoot

Sintomo: `curl` o Python danno `Network unreachable` o `Permission denied` su socket.

```bash
# Dentro easyproxy-shell:
id  # Deve mostrare gid=3003(inet_android) o supplementary 3003

# Fix manuale:
echo 'inet_android:x:3003:root' >> /etc/group
```

### DNS non risolve dentro CHRoot

Sintomo: `curl https://example.com` dà `Could not resolve host`.

```bash
# Dentro easyproxy-shell:
cat /etc/resolv.conf    # Deve contenere nameserver validi

# Fix manuale (da Termux, non dentro il chroot):
DNS1=$(getprop net.dns1)
su -c "echo 'nameserver $DNS1' > /data/local/easyproxy-rootfs/etc/resolv.conf"
```

### Mount zombie — easyproxy non si riavvia

Sintomo: `easyproxy` dice "already mounted" o dà errori di mount.

```bash
# Lazy umount di tutto (forza la pulizia)
su -c "umount -l /data/local/easyproxy-rootfs/dev/shm 2>/dev/null; \
        umount -l /data/local/easyproxy-rootfs/dev/pts 2>/dev/null; \
        umount -l /data/local/easyproxy-rootfs/dev 2>/dev/null; \
        umount -l /data/local/easyproxy-rootfs/sys 2>/dev/null; \
        umount -l /data/local/easyproxy-rootfs/proc 2>/dev/null; \
        umount -l /data/local/easyproxy-rootfs/sdcard 2>/dev/null"
screen -X -S easyproxy quit 2>/dev/null || true
```

### Rollback immediato a PRoot

Se il CHRoot presenta problemi critici e serve ripristinare PRoot:

```bash
# In Termux — riesegui il setup PRoot originale (sovrascrive i comandi)
curl -sL "https://raw.githubusercontent.com/Mr-Piovra/EasyProxy-Jay/main/termux_setup.sh" | bash
# Il rootfs Ubuntu non viene toccato — i dati sono al sicuro.
```

### Verifica completa ambiente CHRoot

```bash
# Sanity check in sequenza:
su -c "chroot /data/local/easyproxy-rootfs uname -m"    # aarch64
su -c "chroot /data/local/easyproxy-rootfs python3 --version"
su -c "chroot /data/local/easyproxy-rootfs chromium --version --no-sandbox"
curl -sf http://localhost:8191/health   # {"status":"ok"}
curl -sf http://localhost:7860/         # HTML dashboard
```
