# ANDROID.md — Architettura di Deployment su Android/Termux

> Documento per agenti AI: descrive la struttura completa del sistema EasyProxy
> quando eseguito su smartphone Android tramite Termux. Leggi tutto prima di
> toccare qualsiasi file relativo al deployment o alla configurazione.

---

## 1. Stack tecnologico e struttura a layer

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
│  │                                                   │   │
│  │  /root/EasyProxy/          ← codebase Python      │   │
│  │  /root/EasyProxy/flaresolverr/  ← solver JS/Py   │   │
│  │  /root/.easyproxy/easyproxy.log ← log principale │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
│  screen "easyproxy"  ← processo background persistente  │
└─────────────────────────────────────────────────────────┘
```

### Perché proot-distro?
Termux fornisce un ambiente Linux nativo ma senza accesso root e con un
filesystem parziale. Alcune dipendenze di EasyProxy (FFmpeg completo,
Chromium, `libgbm`, ecc.) non sono installabili direttamente in Termux.
`proot-distro` monta un'immagine Ubuntu arm64 dentro Termux via `proot`
(un chroot senza root), permettendo di usare `apt` normalmente.

---

## 2. Setup iniziale (one-shot)

Il setup completo avviene tramite un singolo script:

```bash
# Da eseguire UNA SOLA VOLTA in Termux
curl -sL https://raw.githubusercontent.com/Mr-Piovra/EasyProxy-Jay/main/termux_setup.sh | bash
```

Lo script esegue 5 fasi:

| Fase | Cosa fa |
|------|---------|
| 1/5 | Installa pacchetti Termux: `proot-distro`, `git`, `screen`, `wget`, `pulseaudio` |
| 2/5 | Installa Ubuntu arm64 via `proot-distro install ubuntu` |
| 3/4 | Dentro Ubuntu: installa Python 3, FFmpeg, Chromium, chromedriver, pip, dipendenze EasyProxy |
| 4/4 | Clona il repo `Mr-Piovra/EasyProxy-Jay` in `/root/EasyProxy/` dentro Ubuntu, installa `requirements.txt`, configura FlareSolverr |
| 5/5 | Crea comandi globali in Termux: `easyproxy`, `easyproxy-stop`, `easyproxy-logs`, `easyproxy-update` |

> **IMPORTANTE:** Il repo di riferimento è `Mr-Piovra/EasyProxy-Jay` (fork personale),
> NON `realbestia1/EasyProxy` (upstream originale). Questa distinzione è critica
> sia nello script che nei comandi di update.

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
