import asyncio
import glob
import uuid
import logging
import os
import re
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from typing import Dict, List, Optional, Any, Tuple
from urllib.parse import urlencode

import aiohttp

from services.recording_db import RecordingDB
from config import PORT, API_PASSWORD, DVR_SEGMENT_MINUTES, DVR_AUTO_RECORD

logger = logging.getLogger(__name__)


class StreamType(Enum):
    """Stream type classification for recording."""
    MPD = "mpd"           # DASH/MPD streams (converted to HLS by proxy)
    VAVOO = "vavoo"       # Vavoo.to HLS streams
    FREESHOT = "freeshot" # Freeshot/popcdn HLS streams
    SPORTSONLINE = "sportsonline"  # SportsOnline HLS streams
    GENERIC = "generic"   # Unknown/generic HLS streams


@dataclass
class StreamConfig:
    """Configuration for recording a stream."""
    video_url: str
    audio_url: Optional[str] = None
    stream_type: StreamType = StreamType.GENERIC
    needs_reconnect: bool = False
    needs_extended_probe: bool = False


class RecordingManager:
    """Manages FFmpeg recording processes for DVR functionality."""

    # Stream types that benefit from reconnection (proxy handles token refresh)
    RECONNECT_TYPES = {StreamType.VAVOO, StreamType.FREESHOT,
                       StreamType.SPORTSONLINE, StreamType.MPD}

    def __init__(self, recordings_dir: str, max_duration: int = 28800,
                 retention_days: int = 7):
        self.recordings_dir = recordings_dir
        self.max_duration = max_duration
        self.retention_days = retention_days
        self.db = RecordingDB(recordings_dir)
        self.processes: Dict[str, asyncio.subprocess.Process] = {}
        self.start_times: Dict[str, float] = {}
        # Ogni segmento dura DVR_SEGMENT_MINUTES minuti (default 10 = ~600MB)
        self.segment_seconds = DVR_SEGMENT_MINUTES * 60

        # Stato per Auto-Record Timeout
        self.last_accessed: Dict[str, float] = {}
        self.auto_recordings = set()
        self.manual_stops: Dict[str, float] = {}
        self.original_stream_urls: Dict[str, str] = {}
        
        # Ripristina lo stato delle sessioni in memoria per le registrazioni attive dal DB
        for rec in self.db.get_active_recordings():
            # Tratta tutte le registrazioni attive in background come auto-record
            # in modo che il timeout si applichi anche a loro
            self.auto_recordings.add(rec['id'])
            
            orig = rec.get('original_url')
            if orig:
                self.original_stream_urls[rec['id']] = orig

        if not os.path.exists(self.recordings_dir):
            os.makedirs(self.recordings_dir)

    # =========================================================================
    # Stream Type Detection
    # =========================================================================

    @staticmethod
    def _detect_stream_type(url: str) -> StreamType:
        """Detect the stream type based on URL patterns."""
        url_lower = url.lower()

        if '.mpd' in url_lower:
            return StreamType.MPD
        elif 'vavoo.to' in url_lower:
            return StreamType.VAVOO
        elif 'popcdn.day' in url_lower or 'freeshot' in url_lower:
            return StreamType.FREESHOT
        elif any(d in url_lower for d in ['sportsonline', 'sportzonline']):
            return StreamType.SPORTSONLINE

        return StreamType.GENERIC

    # =========================================================================
    # Stream Configuration Preparation
    # =========================================================================

    async def _prepare_stream_config(
        self,
        url: str,
        clearkey: Optional[str] = None
    ) -> StreamConfig:
        """
        Prepare stream configuration based on stream type.

        This is the main dispatcher that routes to type-specific handlers.
        All streams go through the local proxy for token refresh and authentication.
        """
        stream_type = self._detect_stream_type(url)

        if stream_type == StreamType.MPD:
            return await self._prepare_mpd_config(url, clearkey)
        else:
            return self._prepare_hls_config(url, stream_type)

    async def _prepare_mpd_config(
        self,
        url: str,
        clearkey: Optional[str] = None
    ) -> StreamConfig:
        """
        Prepare configuration for MPD/DASH streams.

        MPD streams are converted to HLS by the proxy and may have:
        - ClearKey DRM requiring decryption parameters
        - Separate audio tracks requiring dual-input FFmpeg
        """
        proxy_params = self._build_proxy_params(url)

        # Add ClearKey parameters for DRM-protected streams
        if clearkey and ':' in clearkey:
            key_id, key = clearkey.split(':', 1)
            proxy_params['key_id'] = key_id
            proxy_params['key'] = key
            logger.debug("🔐 MPD Recording with ClearKey decryption enabled")
        else:
            logger.warning("⚠️ MPD Recording without ClearKey - content may be encrypted")

        master_url = f"http://127.0.0.1:{PORT}/proxy/mpd/manifest.m3u8?{urlencode(proxy_params)}"
        logger.info(f"Recording MPD stream: {url[:80]}...")

        # Parse master playlist to extract separate audio track
        video_url, audio_url = await self._parse_master_playlist(master_url)

        if video_url is None:
            logger.warning("Failed to parse master playlist, using master URL directly")
            video_url = master_url
            audio_url = None
        else:
            logger.debug(f"Parsed MPD master: video=present, audio={'present' if audio_url else 'embedded'}")

        return StreamConfig(
            video_url=video_url,
            audio_url=audio_url,
            stream_type=StreamType.MPD,
            needs_reconnect=True,
            needs_extended_probe=True
        )

    def _prepare_hls_config(self, url: str, stream_type: StreamType) -> StreamConfig:
        """
        Prepare configuration for HLS streams (Vavoo, Freeshot, etc.).

        HLS streams typically have audio muxed with video, so no separate
        audio URL is needed.
        """
        proxy_params = self._build_proxy_params(url)
        video_url = f"http://127.0.0.1:{PORT}/proxy/hls/manifest.m3u8?{urlencode(proxy_params)}"

        logger.info(f"Recording HLS stream ({stream_type.value}): {url[:80]}...")

        return StreamConfig(
            video_url=video_url,
            audio_url=None,
            stream_type=stream_type,
            needs_reconnect=stream_type in self.RECONNECT_TYPES,
            needs_extended_probe=False
        )

    def _build_proxy_params(self, url: str) -> Dict[str, str]:
        """Build common proxy parameters."""
        params = {'d': url, 'no_bypass': '1'}
        if API_PASSWORD:
            params['api_password'] = API_PASSWORD
        return params

    # =========================================================================
    # Master Playlist Parsing
    # =========================================================================

    async def _parse_master_playlist(
        self,
        master_url: str
    ) -> Tuple[Optional[str], Optional[str]]:
        """
        Parse HLS master playlist to extract video and audio playlist URLs.

        Returns:
            Tuple of (video_playlist_url, audio_playlist_url)
            audio_playlist_url may be None if audio is embedded in video
        """
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(
                    master_url,
                    timeout=aiohttp.ClientTimeout(total=30)
                ) as resp:
                    if resp.status != 200:
                        logger.error(f"Failed to fetch master playlist: {resp.status}")
                        return None, None
                    content = await resp.text()

            video_url = None
            audio_url = None

            lines = content.strip().split('\n')
            for i, line in enumerate(lines):
                # Parse EXT-X-MEDIA for separate audio track
                if line.startswith('#EXT-X-MEDIA:') and 'TYPE=AUDIO' in line:
                    uri_match = re.search(r'URI="([^"]+)"', line)
                    if uri_match and audio_url is None:
                        if 'DEFAULT=YES' in line or audio_url is None:
                            audio_url = uri_match.group(1)

                # Parse EXT-X-STREAM-INF for video variant
                elif line.startswith('#EXT-X-STREAM-INF:'):
                    if i + 1 < len(lines):
                        next_line = lines[i + 1].strip()
                        if next_line and not next_line.startswith('#'):
                            video_url = next_line

            return video_url, audio_url

        except Exception as e:
            logger.error(f"Error parsing master playlist: {e}")
            return None, None

    # =========================================================================
    # FFmpeg Command Building
    # =========================================================================

    def _build_ffmpeg_command(
        self,
        config: StreamConfig,
        output_path: str,
        duration: Optional[int] = None
    ) -> List[str]:
        """
        Build FFmpeg command for recording based on stream configuration.
        Output è un pattern strftime per la segmentazione automatica:
          output_path deve contenere %Y%m%d_%H%M%S per funzionare con -f segment.
        """
        cmd = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel", "info",
            "-y",
        ]

        # Probe settings based on stream type
        if config.needs_extended_probe:
            cmd.extend([
                "-err_detect", "ignore_err",
                "-fflags", "+genpts+discardcorrupt+igndts+nobuffer",
                "-analyzeduration", "20000000",
                "-probesize", "20000000",
            ])
        else:
            cmd.extend([
                "-fflags", "+genpts+discardcorrupt+igndts",
                "-analyzeduration", "10000000",
                "-probesize", "10000000",
            ])

        # Network options
        if config.video_url.startswith('http'):
            cmd.extend(["-rw_timeout", "30000000"])

            if config.needs_reconnect:
                cmd.extend([
                    "-reconnect", "1",
                    "-reconnect_streamed", "1",
                    "-reconnect_delay_max", "2",
                ])

        # HLS-specific options
        if '.m3u8' in config.video_url.lower():
            cmd.extend(["-live_start_index", "-1"])

        # Duration limit totale (copre tutti i segmenti)
        if duration:
            cmd.extend(["-t", str(duration)])

        # Video input
        cmd.extend(["-i", config.video_url])

        # Separate audio input (for MPD with separate audio tracks)
        if config.audio_url:
            if config.audio_url.startswith('http'):
                cmd.extend(["-rw_timeout", "30000000"])
            cmd.extend(["-live_start_index", "-1"])
            cmd.extend(["-i", config.audio_url])

        # Stream mapping
        if config.audio_url:
            cmd.extend(["-map", "0:v:0", "-map", "1:a:0"])
            logger.debug("Using dual-input mode: video + separate audio")
        else:
            cmd.extend(["-map", "0:v:0", "-map", "0:a:0?"])

        # Output MP4 frammentato: l'indice è distribuito ad ogni keyframe
        # → il file è seekable in VLC sia durante la registrazione che dopo
        # → nessuna corruzione in caso di crash di FFmpeg (no moov atom finale)
        cmd.extend(["-c", "copy"])
        cmd.extend([
            "-f", "mp4",
            "-movflags", "frag_keyframe+empty_moov+default_base_moof",
            output_path
        ])

        return cmd

    # =========================================================================
    # Recording Lifecycle
    # =========================================================================

    async def start_recording(
        self,
        url: str,
        name: Optional[str] = None,
        duration: Optional[int] = None,
        clearkey: Optional[str] = None,
        is_auto: bool = False,
        original_stream_url: Optional[str] = None
    ) -> Optional[Dict[str, Any]]:
        """
        Start recording a stream.

        All streams go through the local proxy for authentication and token refresh.

        Args:
            url: Stream URL to record
            name: Human-readable name for the recording
            duration: Recording duration in seconds (None = max_duration)
            clearkey: ClearKey in format "key_id:key" for DRM-protected streams

        Returns:
            Recording info dict or None if failed
        """
        if not name:
            name = f"Recording {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M')}"

        recording_id = self._generate_recording_id()

        # Claim the recording (prevents duplicates)
        if not self.db.create_starting_entry(recording_id, name, url):
            logger.info(f"Recording already exists for URL: {url[:80]}...")
            return None

        filename = self._generate_filename(recording_id, name)
        file_path = os.path.join(self.recordings_dir, filename)

        # Apply duration limits
        if duration:
            duration = min(duration, self.max_duration)
        else:
            duration = self.max_duration

        # Prepare stream-specific configuration
        config = await self._prepare_stream_config(url)

        # Build FFmpeg command
        cmd = self._build_ffmpeg_command(config, file_path, duration)

        logger.info(f"Starting recording {recording_id}: {name}")
        logger.debug(f"FFmpeg command: {' '.join(cmd)}")

        try:
            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )

            self.processes[recording_id] = process
            self.start_times[recording_id] = time.time()
            
            if is_auto:
                self.auto_recordings.add(recording_id)
                self.last_accessed[recording_id] = time.time()
                if original_stream_url:
                    self.original_stream_urls[recording_id] = original_stream_url

            self.db.update_to_recording(
                recording_id=recording_id,
                file_path=file_path,
                headers=None,
                pid=process.pid,
                segment_pattern=None,
                original_url=original_stream_url
            )

            asyncio.create_task(self._monitor_recording(recording_id, process))

            return self.db.get_recording(recording_id)

        except Exception as e:
            logger.error(f"Failed to start recording {recording_id}: {e}")
            self.db.update_recording_status(recording_id, 'failed', str(e))
            return None

    async def stop_recording(self, recording_id: str, manual_stop: bool = True) -> bool:
        """
        Stop an active recording.

        Supports multi-worker: if process not in local dict, use PID from DB.
        """
        # Se lo sto fermando a mano, aggiungilo in blacklist temporanea
        if manual_stop:
            rec = self.db.get_recording(recording_id)
            if rec:
                import urllib.parse
                
                # Blacklist della sessione (base_path) invece dell'URL esatto
                orig_url = self.original_stream_urls.get(recording_id)
                if orig_url:
                    self.manual_stops[orig_url] = time.time()
                    parsed_orig = urllib.parse.urlparse(orig_url)
                    base_path = f"{parsed_orig.scheme}://{parsed_orig.netloc}{os.path.dirname(parsed_orig.path)}"
                    self.manual_stops[base_path] = time.time()
                    
                self.manual_stops[rec['url']] = time.time()
                
                # Aggiunge anche l'URL upstream estratto dal proxy_url se presente (fallback)
                parsed = urllib.parse.urlparse(rec['url'])
                qs = urllib.parse.parse_qs(parsed.query)
                if 'd' in qs:
                    d_url = qs['d'][0]
                    self.manual_stops[d_url] = time.time()
                    parsed_d = urllib.parse.urlparse(d_url)
                    d_base_path = f"{parsed_d.scheme}://{parsed_d.netloc}{os.path.dirname(parsed_d.path)}"
                    self.manual_stops[d_base_path] = time.time()

        recording = self.db.get_recording(recording_id)
        if not recording:
            logger.warning(f"Recording {recording_id} not found in database")
            return False

        # Rimuove subito il processo dal dizionario per segnalare al monitor
        # che lo stop è stato richiesto esplicitamente (evita race condition)
        process = self.processes.pop(recording_id, None)
        self.start_times.pop(recording_id, None)

        if process is not None:
            try:
                # Invia 'q' a FFmpeg per uno shutdown graceful
                if process.stdin and not process.stdin.is_closing():
                    try:
                        process.stdin.write(b'q')
                        await process.stdin.drain()
                    except Exception:
                        pass
                    try:
                        process.stdin.close()
                    except Exception:
                        pass

                # Aspetta terminazione graceful
                try:
                    await asyncio.wait_for(process.wait(), timeout=10.0)
                except asyncio.TimeoutError:
                    logger.warning(f"Recording {recording_id} didn't stop gracefully, terminating")
                    try:
                        process.terminate()
                    except Exception:
                        pass
                    try:
                        await asyncio.wait_for(process.wait(), timeout=5.0)
                    except asyncio.TimeoutError:
                        logger.warning(f"Recording {recording_id} didn't terminate, killing")
                        try:
                            process.kill()
                        except Exception:
                            pass
            except Exception as e:
                logger.error(f"Error stopping process: {e}")
                try:
                    process.terminate()
                except Exception:
                    pass
        else:
            # Process in un worker diverso — usa PID dal database
            pid = recording.get('pid')
            if pid and self.db.is_pid_running(pid):
                try:
                    import signal
                    os.kill(pid, signal.SIGTERM)
                    await asyncio.sleep(2)
                    if self.db.is_pid_running(pid):
                        os.kill(pid, signal.SIGKILL)
                    logger.debug(f"Stopped recording {recording_id} via PID {pid}")
                except ProcessLookupError:
                    logger.debug(f"Process {pid} already terminated")
                except Exception as e:
                    logger.error(f"Error killing process {pid}: {e}")

        self.db.update_recording_status(recording_id, 'stopped')

        if recording.get('file_path'):
            file_path = recording['file_path']
            if os.path.exists(file_path):
                started_at = recording.get('started_at')
                rec_duration = self._calculate_elapsed(started_at) if started_at else 0
                file_size = os.path.getsize(file_path)
                self.db.update_recording_file_info(recording_id, rec_duration, file_size)

        logger.info(f"Recording {recording_id} stopped")
        return True

    async def _monitor_recording(
        self,
        recording_id: str,
        process: asyncio.subprocess.Process
    ):
        """
        Monitor a recording process and update status when complete.

        Legge stderr in parallelo (drain) e aspetta la fine del processo con
        process.wait() invece di communicate() per evitare race condition con
        stop_recording(), che già interagisce con stdin e chiama process.wait().
        """
        start_time = self.start_times.get(recording_id, time.time())
        stderr_chunks = []

        async def _drain_stderr():
            """Legge stderr senza bloccare il main monitor task."""
            try:
                if process.stderr:
                    while True:
                        chunk = await process.stderr.read(4096)
                        if not chunk:
                            break
                        stderr_chunks.append(chunk)
            except Exception:
                pass

        try:
            # Legge stderr in parallelo e aspetta la fine del processo
            await asyncio.gather(
                _drain_stderr(),
                process.wait()
            )
        except asyncio.CancelledError:
            return
        except Exception as e:
            logger.error(f"Error monitoring recording {recording_id}: {e}")

        try:
            # Se recording_id non è più nei processi, significa che stop_recording()
            # ha già gestito la terminazione — non sovrascrivere il suo stato 'stopped'.
            if recording_id not in self.processes:
                # Pulizia finale e uscita senza toccare lo stato nel DB
                self.start_times.pop(recording_id, None)
                return

            stderr_text = b"".join(stderr_chunks).decode(errors="replace")
            if stderr_text:
                logger.debug(f"Recording {recording_id} FFmpeg output: {stderr_text[:1000]}")

            # returncode == 0 → completato; qualunque altro valore → fallito
            # (255 = FFmpeg uscito con 'q' — non dovrebbe arrivare qui se
            #  stop_recording ha già rimosso recording_id da self.processes)
            if process.returncode == 0:
                logger.info(f"Recording {recording_id} completed successfully")
                self.db.update_recording_status(recording_id, 'completed')
            else:
                stderr_text = stderr_text or ""
                error_msg = stderr_text[:500] if stderr_text else "Unknown error"
                logger.error(
                    f"Recording {recording_id} failed with code "
                    f"{process.returncode}: {error_msg}"
                )
                self.db.update_recording_status(recording_id, 'failed', error_msg)

            recording = self.db.get_recording(recording_id)
            if recording and recording.get('file_path'):
                rec_duration = int(time.time() - start_time)
                file_size = self.db.get_total_size(recording_id)
                self.db.update_recording_file_info(recording_id, rec_duration, file_size)

                # ✅ Timeout di inattività per auto-record
                if recording_id in self.auto_recordings:
                    timeout_mins = self.auto_record_timeout
                    last_acc = self.last_accessed.get(recording_id, time.time())
                    if timeout_mins > 0 and (time.time() - last_acc) > (timeout_mins * 60):
                        logger.info(f"🛑 DVR: Auto-stop per inattività stream su {recording_id}")
                        await self.stop_recording(recording_id, manual_stop=False)

        except Exception as e:
            logger.error(f"Error in monitor post-process for {recording_id}: {e}")
        finally:
            self.processes.pop(recording_id, None)
            self.start_times.pop(recording_id, None)

    async def delete_recording(self, recording_id: str) -> bool:
        """Delete a recording and its file."""
        if recording_id in self.processes:
            await self.stop_recording(recording_id)

        recording = self.db.get_recording(recording_id)
        if not recording:
            return False

        direct_path = recording.get('file_path')
        if direct_path and os.path.exists(direct_path):
            try:
                os.remove(direct_path)
            except Exception as e:
                logger.error(f"Error deleting file {direct_path}: {e}")

        # Rimuove anche la playlist M3U8 nativa se esiste (vecchi file)
        m3u8_path = os.path.join(self.recordings_dir, f"{recording_id}.m3u8")
        if os.path.exists(m3u8_path):
            try:
                os.remove(m3u8_path)
            except Exception:
                pass

        return self.db.delete_recording(recording_id)

    # =========================================================================
    # Recording Queries
    # =========================================================================

    def get_recording(self, recording_id: str) -> Optional[Dict[str, Any]]:
        """Get recording info by ID."""
        recording = self.db.get_recording(recording_id)
        return self._enrich_recording(recording) if recording else None

    def get_all_recordings(self, status: Optional[str] = None) -> List[Dict[str, Any]]:
        """Get all recordings, optionally filtered by status."""
        recordings = self.db.get_all_recordings(status=status)
        return [self._enrich_recording(rec) for rec in recordings]

    def get_active_recordings(self) -> List[Dict[str, Any]]:
        """Get currently active recordings."""
        recordings = self.db.get_all_recordings(status='recording')
        return [self._enrich_recording(rec) for rec in recordings
                if self._is_recording_active(rec)]

    def get_active_recording_by_url(self, url: str) -> Optional[Dict[str, Any]]:
        """Check if there's an active recording for the given URL."""
        for rec in self.get_active_recordings():
            if rec.get('url') == url:
                return rec
        return None

    def get_pending_recording_by_url(self, url: str) -> Optional[Dict[str, Any]]:
        """Check if there's a pending (starting or recording) entry for the given URL.

        This includes 'starting' entries that may be stuck from failed attempts.
        """
        all_recordings = self.db.get_all_recordings()
        for rec in all_recordings:
            if rec.get('url') == url and rec.get('status') in ('starting', 'recording'):
                return self._enrich_recording(rec)
        return None

    # =========================================================================
    # Cleanup and Maintenance
    # =========================================================================

    async def cleanup_old_recordings(self):
        """Delete recordings older than retention period."""
        old_recordings = self.db.get_old_recordings(self.retention_days)
        for recording in old_recordings:
            logger.info(f"Auto-deleting old recording: {recording['id']}")
            await self.delete_recording(recording['id'])

    async def cleanup_loop(self):
        """Periodically clean up old recordings."""
        while True:
            try:
                await self.cleanup_old_recordings()
            except Exception as e:
                logger.error(f"Error in cleanup loop: {e}")
            await asyncio.sleep(3600)

    async def shutdown(self):
        """Gracefully stop all recordings on shutdown."""
        logger.info("Shutting down RecordingManager...")
        for recording_id in list(self.processes.keys()):
            await self.stop_recording(recording_id)

    # =========================================================================
    # Helper Methods
    # =========================================================================

    def _generate_recording_id(self) -> str:
        """Generate a unique recording ID."""
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        unique_suffix = uuid.uuid4().hex[:8]
        return f"{timestamp}_{unique_suffix}"

    def _generate_filename(self, recording_id: str, name: str) -> str:
        """Genera un filename univoco per la registrazione."""
        safe_name = "".join(c for c in name if c.isalnum() or c in (' ', '-', '_')).strip()
        safe_name = safe_name.replace(' ', '_')[:50]
        if not safe_name:
            safe_name = "recording"
        return f"{recording_id}_{safe_name}.mp4"

    def _is_recording_active(self, recording: Dict[str, Any]) -> bool:
        """Check if a recording is actively running using DB-stored PID."""
        status = recording.get('status')
        if status not in ('recording', 'starting'):
            return False

        pid = recording.get('pid')
        if pid:
            return self.db.is_pid_running(pid)

        if status == 'starting':
            return True

        return recording.get('id') in self.processes

    def _calculate_elapsed(self, started_at: str) -> int:
        """Calculate elapsed seconds from ISO timestamp.

        Note: Database stores naive UTC timestamps, so we use naive comparison.
        """
        try:
            start = datetime.fromisoformat(started_at)
            # Database stores naive UTC, so compare with naive UTC
            now = datetime.utcnow() if start.tzinfo is None else datetime.now(timezone.utc)
            return int((now - start).total_seconds())
        except Exception:
            return 0

    def _enrich_recording(self, recording: Dict[str, Any]) -> Dict[str, Any]:
        """Add computed fields (is_active, elapsed_seconds, file_size_bytes) to a recording."""
        recording['is_active'] = self._is_recording_active(recording)
        if recording['is_active'] and recording.get('started_at'):
            recording['elapsed_seconds'] = self._calculate_elapsed(recording['started_at'])
        # ✅ DVR: Aggiorna file_size con la somma di tutti i segmenti in tempo reale
        total_size = self.db.get_total_size(recording['id'])
        if total_size > 0:
            recording['file_size_bytes'] = total_size
        return recording

    # =========================================================================
    # Auto-Record Toggle
    # =========================================================================

    @property
    def auto_record(self) -> bool:
        """Legge lo stato auto-record dal DB (persistente tra i restart).
        Fallback al valore di configurazione iniziale DVR_AUTO_RECORD.
        """
        val = self.db.get_dvr_config('auto_record')
        if val is None:
            return DVR_AUTO_RECORD  # valore dal .env / default False
        return val == 'true'

    @auto_record.setter
    def auto_record(self, enabled: bool) -> None:
        """Persiste lo stato auto-record nel DB."""
        self.db.set_dvr_config('auto_record', 'true' if enabled else 'false')
        icon = '🔴' if enabled else '⏹️'
        state = 'abilitato' if enabled else 'disabilitato'
        logger.info(f"{icon} Auto-DVR {state}")

    @property
    def auto_record_timeout(self) -> int:
        """Minuti di inattività prima che auto-record si fermi da solo."""
        val = self.db.get_dvr_config('auto_record_timeout')
        if val is None:
            return 5  # Default 5 minuti
        return int(val)

    @auto_record_timeout.setter
    def auto_record_timeout(self, minutes: int) -> None:
        self.db.set_dvr_config('auto_record_timeout', str(minutes))
        logger.info(f"⏱️ DVR: Timeout inattività impostato a {minutes} minuti")

    def touch_recording_by_url(self, stream_url: str):
        """Aggiorna il timestamp di accesso per l'auto-record timeout e rinnova la blacklist se l'utente sta ancora guardando."""
        for rec in self.get_active_recordings():
            if stream_url in rec.get('url', ''):
                rec_id = rec['id']
                if rec_id in self.auto_recordings:
                    self.last_accessed[rec_id] = time.time()
                    
        # Helper: controlla se due path appartengono alla stessa sessione
        def is_same_session(path1: str, path2: str) -> bool:
            return path1.startswith(path2) or path2.startswith(path1)
            
        # Se l'utente ha bloccato a mano lo stream, rinnova il blocco per la sessione
        import urllib.parse
        parsed = urllib.parse.urlparse(stream_url)
        base_path = f"{parsed.scheme}://{parsed.netloc}{os.path.dirname(parsed.path)}"
        
        if stream_url in self.manual_stops:
            self.manual_stops[stream_url] = time.time()
            
        for stop_path in list(self.manual_stops.keys()):
            if stop_path.startswith('http') and is_same_session(base_path, stop_path):
                self.manual_stops[stop_path] = time.time()
