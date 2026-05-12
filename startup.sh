#!/data/data/com.termux/files/usr/bin/sh
export PATH=/data/data/com.termux/files/usr/bin:$PATH
termux-wake-lock

# --- 1. PULIZIA TOTALE (Simula un reset manuale) ---
# Uccidiamo tutto quello che potrebbe bloccare easyproxy/tvvoo
pkill -9 -f "cloudflared|easyproxy|tvvoo|proot|screen|python|node" > /dev/null 2>&1
# Rimuoviamo i file "fantasma" di screen che dicono che è già attivo
rm -rf ~/.screen/*
screen -wipe > /dev/null 2>&1

# 1. ATTESA E AVVIO EASYPROXY (25 secondi dal boot)
sleep 25
easyproxy &

# 2. AVVIO TVVOO (5s dopo EasyProxy — stessa CHRoot, mount già attivi)
sleep 5
tvvoo &

# 3. ATTESA E AVVIO CLOUDFLARE (Ulteriori 15s, totale ~45s dal boot)
sleep 15
cloudflared tunnel run --protocol http2 --token [TOKEN] &
