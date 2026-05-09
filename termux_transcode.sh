#!/data/data/com.termux/files/usr/bin/bash

# Termux Hardware Transcoding Script per EasyProxy
# Questo script sfrutta l'accelerazione hardware HEVC del tuo telefono Android

cd "$(dirname "$0")"

# Carica configurazione da .env se esiste
if [ -f ".env" ]; then
    source .env
fi

if [ -n "$1" ]; then
    RECORDINGS_DIR="$1"
else
    RECORDINGS_DIR=${RECORDINGS_DIR:-"recordings"}
fi

DB_FILE="$RECORDINGS_DIR/recordings.db"

if [ ! -d "$RECORDINGS_DIR" ]; then
    echo "Errore: Cartella $RECORDINGS_DIR non trovata."
    exit 1
fi

echo "Avvio controllo transcodifiche in $RECORDINGS_DIR (H264 Hardware @ 6Mbps)"

# Cerca tutti i file .ts e .mp4
for SRC_FILE in "$RECORDINGS_DIR"/*.ts "$RECORDINGS_DIR"/*.mp4; do
    if [ ! -f "$SRC_FILE" ]; then
        continue
    fi
    
    # Salta i file già compressi dall'hardware
    if [[ "$SRC_FILE" == *"_hw.mp4" ]]; then
        continue
    fi
    
    # Controlla se il file è in uso (modificato di recente)
    if [ $(($(date +%s) - $(stat -c %Y "$SRC_FILE"))) -lt 15 ]; then
        echo "⏳ File $SRC_FILE ancora in uso (modificato di recente), salto..."
        continue
    fi
    
    MP4_FILE="${SRC_FILE%.*}_hw.mp4"
    
    echo "🔄 Inizio transcodifica: $SRC_FILE -> $MP4_FILE"
    
    # Esegue ffmpeg nativo di Termux sfruttando h264_mediacodec
    # Nota: gli encoder MediaCodec non supportano i preset (es. fast), quindi alziamo il bitrate
    /data/data/com.termux/files/usr/bin/ffmpeg -hide_banner -y \
        -i "$SRC_FILE" \
        -pix_fmt nv12 \
        -c:v h264_mediacodec -b:v 4500k \
        -c:a copy \
        "$MP4_FILE"
        
    if [ $? -eq 0 ] && [ -f "$MP4_FILE" ]; then
        echo "✅ Transcodifica completata con successo!"
        
        # Aggiorna il database SQLite di EasyProxy
        if [ -f "$DB_FILE" ]; then
            if command -v sqlite3 > /dev/null 2>&1; then
                NEW_SIZE=$(stat -c%s "$MP4_FILE")
                
                # Prepariamo i path per SQLite sfuggendo agli apici singoli
                SQL_SRC_FILE=$(echo "$SRC_FILE" | sed "s/'/''/g")
                SQL_MP4_FILE=$(echo "$MP4_FILE" | sed "s/'/''/g")
                
                sqlite3 "$DB_FILE" "UPDATE recordings SET file_path = '$SQL_MP4_FILE', file_size_bytes = $NEW_SIZE WHERE file_path = '$SQL_SRC_FILE';"
                echo "💾 Database SQLite aggiornato."
            else
                echo "⚠️ Attenzione: comando 'sqlite3' non trovato in Termux. Installa con 'pkg install sqlite'."
            fi
        fi
        
        # Rimuovi file originale
        rm "$SRC_FILE"
        echo "🗑️ File originale rimosso."
    else
        echo "❌ Errore durante la transcodifica di $SRC_FILE"
        # Rimuovi il file parziale se esiste
        [ -f "$MP4_FILE" ] && rm "$MP4_FILE"
    fi
    echo "-----------------------------------"
done

echo "🎉 Controllo terminato."
