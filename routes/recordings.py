import json
import logging
import os
from aiohttp import web

from config import check_password

logger = logging.getLogger(__name__)


def setup_recording_routes(app, recording_manager):
    """Setup all recording-related routes."""

    async def handle_recordings_page(request):
        """Serve the recordings UI page."""
        template_path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            'templates', 'recordings.html'
        )
        try:
            with open(template_path, 'r', encoding='utf-8') as f:
                html = f.read()
                
            try:
                import subprocess
                repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                commit_hash = subprocess.check_output(['git', 'rev-parse', '--short', 'HEAD'], cwd=repo_dir, stderr=subprocess.DEVNULL).decode('utf-8').strip()
                commit_msg = subprocess.check_output(['git', 'log', '-1', '--pretty=%s'], cwd=repo_dir, stderr=subprocess.DEVNULL).decode('utf-8').strip()
                version_str = f"Commit: {commit_hash} - {commit_msg}"
            except Exception as e:
                version_str = f"Git Version Unknown ({e})"
                
            html = html.replace('<!-- GIT_VERSION_PLACEHOLDER -->', version_str)
            return web.Response(text=html, content_type='text/html')
        except FileNotFoundError:
            return web.Response(text="Recordings template not found",
                               status=404)

    async def handle_list_recordings(request):
        """GET /api/recordings - List all recordings."""
        if not check_password(request):
            return web.json_response({"error": "Unauthorized"}, status=401)

        status = request.query.get('status')
        recordings = recording_manager.get_all_recordings(status=status)

        return web.json_response({
            "recordings": recordings,
            "active_count": len([r for r in recordings if r.get('is_active')])
        })

    async def handle_get_recording(request):
        """GET /api/recordings/{id} - Get a specific recording."""
        if not check_password(request):
            return web.json_response({"error": "Unauthorized"}, status=401)

        recording_id = request.match_info['id']
        recording = recording_manager.get_recording(recording_id)

        if not recording:
            return web.json_response({"error": "Recording not found"},
                                    status=404)

        return web.json_response(recording)

    async def handle_start_recording(request):
        """POST /api/recordings/start - Start a new recording."""
        if not check_password(request):
            return web.json_response({"error": "Unauthorized"}, status=401)

        try:
            data = await request.json()
        except json.JSONDecodeError:
            return web.json_response({"error": "Invalid JSON"}, status=400)

        url = data.get('url')
        if not url:
            return web.json_response({"error": "URL is required"}, status=400)

        name = data.get('name')
        duration = data.get('duration')

        if duration:
            try:
                duration = int(duration)
            except ValueError:
                return web.json_response(
                    {"error": "Duration must be a number"}, status=400)

        recording = await recording_manager.start_recording(
            url=url,
            name=name,
            duration=duration
        )

        if recording:
            return web.json_response(recording, status=201)
        else:
            return web.json_response(
                {"error": "Failed to start recording"}, status=500)

    async def handle_stop_recording(request):
        """POST /api/recordings/{id}/stop - Stop an active recording."""
        if not check_password(request):
            return web.json_response({"error": "Unauthorized"}, status=401)

        recording_id = request.match_info['id']
        success = await recording_manager.stop_recording(recording_id)

        if success:
            recording = recording_manager.get_recording(recording_id)
            return web.json_response(recording)
        else:
            return web.json_response(
                {"error": "Recording not found or already stopped"},
                status=404)

    async def handle_delete_recording(request):
        """DELETE /api/recordings/{id} - Delete a recording."""
        if not check_password(request):
            return web.json_response({"error": "Unauthorized"}, status=401)

        recording_id = request.match_info['id']
        success = await recording_manager.delete_recording(recording_id)

        if success:
            return web.json_response({"success": True})
        else:
            return web.json_response({"error": "Recording not found"},
                                    status=404)

    async def handle_delete_recording_get(request):
        """GET /api/recordings/{id}/delete - Delete a recording via GET (for Stremio).

        Returns a simple video placeholder or redirect after deletion.
        """
        if not check_password(request):
            return web.json_response({"error": "Unauthorized"}, status=401)

        recording_id = request.match_info['id']
        success = await recording_manager.delete_recording(recording_id)

        if success:
            logger.debug(f"Recording {recording_id} deleted via GET request")
            # Return a simple message - Stremio will show "playback failed" but recording is deleted
            return web.Response(
                text="Recording deleted successfully. Close this and refresh the catalog.",
                content_type="text/plain",
                status=200
            )
        else:
            return web.json_response({"error": "Recording not found"}, status=404)

    async def handle_delete_all_recordings(request):
        """DELETE /api/recordings - Delete all recordings."""
        if not check_password(request):
            return web.json_response({"error": "Unauthorized"}, status=401)

        recordings = recording_manager.get_all_recordings()
        deleted = 0
        for rec in recordings:
            try:
                await recording_manager.delete_recording(rec['id'])
                deleted += 1
            except Exception as e:
                logger.warning(f"Failed to delete recording {rec['id']}: {e}")

        return web.json_response({"success": True, "deleted": deleted})

    async def handle_download_recording(request):
        """GET /api/recordings/{id}/download - Download a recording file."""
        if not check_password(request):
            return web.json_response({"error": "Unauthorized"}, status=401)

        recording_id = request.match_info['id']
        recording = recording_manager.get_recording(recording_id)

        if not recording:
            return web.json_response({"error": "Recording not found"},
                                    status=404)

        segments = recording_manager.db.get_segment_files(recording_id)
        if not segments:
            return web.json_response({"error": "Recording file not found"},
                                    status=404)

        # Determina l'estensione dal primo segmento
        first_seg = segments[0]
        ext = ".ts"
        content_type = "video/MP2T"
        if first_seg.endswith('.mp4'):
            ext = ".mp4"
            content_type = "video/mp4"

        safe_name = recording.get("name", "recording").replace(" ", "_")
        filename = f"{safe_name}{ext}"

        # Download concatena tutti i segmenti on-the-fly
        response = web.StreamResponse(
            status=200,
            headers={
                "Content-Type": content_type,
                "Content-Disposition": f'attachment; filename="{filename}"',
                "Access-Control-Allow-Origin": "*"
            }
        )
        await response.prepare(request)
        
        for seg in segments:
            try:
                with open(seg, 'rb') as f:
                    while True:
                        chunk = f.read(65536)
                        if not chunk:
                            break
                        await response.write(chunk)
            except Exception as e:
                logger.warning(f"Error reading segment {seg}: {e}")
                
        await response.write_eof()
        return response

    async def handle_stream_recording(request):
        """GET /api/recordings/{id}/stream - Stream a recording file.

        For completed recordings: uses efficient FileResponse.
        For active recordings: streams the growing file with chunked transfer,
        allowing users to watch while recording continues.
        """
        import asyncio

        if not check_password(request):
            return web.json_response({"error": "Unauthorized"}, status=401)

        recording_id = request.match_info['id']
        recording = recording_manager.get_recording(recording_id)

        if not recording:
            return web.json_response({"error": "Recording not found"},
                                    status=404)

        segments = recording_manager.db.get_segment_files(recording_id)
        if not segments:
            return web.json_response({"error": "Recording file not found"},
                                    status=404)

        is_active = recording.get('is_active', False)
        
        # Usa il manifest generato nativamente da FFmpeg per avere durate ESATTE
        db_file_path = recording.get('file_path', '')
        # Calcola lo stesso m3u8_path che usa recording_manager._build_ffmpeg_command
        m3u8_path = db_file_path.replace("%Y%m%d_%H%M%S", "playlist") + ".m3u8"
        
        if os.path.exists(m3u8_path):
            import re
            with open(m3u8_path, 'r') as f:
                content = f.read()
            
            # Riscrive i path relativi (es. file_001.ts) nel path API assoluto
            rewritten = re.sub(
                r'^(?!#)(.*\.ts)$',
                r'/api/recordings/' + recording_id + r'/segments/\1',
                content,
                flags=re.MULTILINE
            )
            return web.Response(
                text=rewritten, 
                content_type="application/vnd.apple.mpegurl",
                headers={"Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"}
            )
            
        # Fallback per vecchie registrazioni senza .m3u8 nativo
        m3u8 = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            f"#EXT-X-TARGETDURATION:{recording_manager.segment_seconds + 5}",
            "#EXT-X-MEDIA-SEQUENCE:0"
        ]
        
        if not is_active:
            m3u8.append("#EXT-X-PLAYLIST-TYPE:VOD")
            
        for seg in segments:
            filename = os.path.basename(seg)
            m3u8.append(f"#EXTINF:{recording_manager.segment_seconds}.0,")
            m3u8.append(f"/api/recordings/{recording_id}/segments/{filename}")
            
        if not is_active:
            m3u8.append("#EXT-X-ENDLIST")
            
        return web.Response(
            text="\n".join(m3u8), 
            content_type="application/vnd.apple.mpegurl",
            headers={"Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"}
        )

    async def handle_serve_segment(request):
        """GET /api/recordings/{id}/segments/{filename} - Serves an individual DVR segment."""
        # if not check_password(request):
        #     return web.json_response({"error": "Unauthorized"}, status=401)
        
        recording_id = request.match_info['id']
        filename = request.match_info['filename']
        
        # Validate filename to prevent path traversal
        if '/' in filename or '\\' in filename or '..' in filename:
            return web.json_response({"error": "Invalid filename"}, status=400)
            
        file_path = os.path.join(recording_manager.recordings_dir, filename)
        
        if not os.path.exists(file_path):
            return web.json_response({"error": "Segment not found"}, status=404)
            
        return web.FileResponse(
            file_path,
            headers={
                "Content-Type": "video/MP2T",
                "Access-Control-Allow-Origin": "*"
            }
        )

    async def handle_active_recordings(request):
        """GET /api/recordings/active - Get only active recordings."""
        if not check_password(request):
            return web.json_response({"error": "Unauthorized"}, status=401)

        recordings = recording_manager.get_active_recordings()
        return web.json_response({"recordings": recordings})

    async def handle_get_dvr_config(request):
        """GET /api/dvr/config - Legge la configurazione DVR corrente."""
        if not check_password(request):
            return web.json_response({"error": "Unauthorized"}, status=401)
        return web.json_response({
            "auto_record": recording_manager.auto_record,
            "auto_record_timeout": recording_manager.auto_record_timeout,
            "segment_minutes": recording_manager.segment_seconds // 60,
        })

    async def handle_set_dvr_config(request):
        """POST /api/dvr/config - Aggiorna la configurazione DVR.
        Body JSON: { "auto_record": true/false, "auto_record_timeout": 5 }
        """
        if not check_password(request):
            return web.json_response({"error": "Unauthorized"}, status=401)
        try:
            data = await request.json()
        except Exception:
            return web.json_response({"error": "Invalid JSON"}, status=400)
            
        if 'auto_record' in data:
            recording_manager.auto_record = bool(data['auto_record'])
        if 'auto_record_timeout' in data:
            recording_manager.auto_record_timeout = int(data['auto_record_timeout'])
            
        return web.json_response({
            "auto_record": recording_manager.auto_record,
            "auto_record_timeout": recording_manager.auto_record_timeout,
            "segment_minutes": recording_manager.segment_seconds // 60,
        })

    async def handle_record_via_get(request):
        """GET /record - Start recording and return a playable stream.

        This endpoint starts recording in the background and returns an HLS
        master playlist that points to the live stream. The user watches
        live TV while recording happens in the background.

        Query parameters:
            url: Stream URL to record (required, URL-encoded)
            name: Recording name (optional)
            duration: Duration in seconds (optional)

        Example:
            /record?url=https%3A%2F%2Fvavoo.to%2Fplay%2F...&name=Sky%20Sport&duration=3600
        """
        if not check_password(request):
            return web.json_response({"error": "Unauthorized"}, status=401)

        url = request.query.get('url')
        if not url:
            return web.json_response({"error": "URL is required"}, status=400)

        name = request.query.get('name')
        duration = request.query.get('duration')

        # ClearKey parameters for DRM-protected streams
        key_id = request.query.get('key_id')
        key = request.query.get('key')
        clearkey = None
        if key_id and key:
            clearkey = f"{key_id}:{key}"

        if duration:
            try:
                duration = int(duration)
            except ValueError:
                return web.json_response(
                    {"error": "Duration must be a number"}, status=400)

        # Start recording in the background
        recording = await recording_manager.start_recording(
            url=url,
            name=name,
            duration=duration,
            clearkey=clearkey
        )

        if not recording:
            # Check if there's a pending entry (starting or recording) for this URL
            pending = recording_manager.get_pending_recording_by_url(url)
            if pending:
                if pending.get('is_active'):
                    logger.debug(f"Already recording URL: {url}")
                else:
                    # Stuck 'starting' entry - clean it up and try again
                    logger.warning(f"Cleaning up stuck entry for URL: {url}")
                    await recording_manager.delete_recording(pending['id'])
                    # Try starting again
                    recording = await recording_manager.start_recording(
                        url=url,
                        name=name,
                        duration=duration,
                        clearkey=clearkey
                    )
                    if not recording:
                        logger.error(f"Failed to start recording after cleanup: {url}")
            # Even if recording failed, still redirect to live stream
            # so user can watch while we figure out what went wrong
            logger.debug(f"Recording may have failed, but redirecting to live stream anyway")

        # Build proxy URL to watch the live stream while recording
        from urllib.parse import urlencode

        api_password = request.query.get('api_password', '')

        proxy_params = {'d': url}
        if api_password:
            proxy_params['api_password'] = api_password
        if key_id:
            proxy_params['key_id'] = key_id
        if key:
            proxy_params['key'] = key

        # Use correct endpoint based on stream type
        if '.mpd' in url.lower():
            endpoint = "/proxy/mpd/manifest.m3u8"
        else:
            endpoint = "/proxy/hls/manifest.m3u8"

        proxy_url = f"{endpoint}?{urlencode(proxy_params)}"

        # Redirect to the live stream proxy
        raise web.HTTPFound(proxy_url)

    async def handle_stop_and_stream(request):
        """GET /record/stop/{id} - Stop an active recording and redirect to stream.

        This endpoint is designed for Stremio integration: when clicked,
        it stops the recording and immediately redirects to play the recorded content.
        """
        if not check_password(request):
            return web.json_response({"error": "Unauthorized"}, status=401)

        recording_id = request.match_info['id']
        recording = recording_manager.get_recording(recording_id)

        if not recording:
            return web.json_response({"error": "Recording not found"}, status=404)

        # Stop the recording if it's active
        if recording.get('is_active'):
            await recording_manager.stop_recording(recording_id)
            # Refresh recording data after stop
            recording = recording_manager.get_recording(recording_id)

        # Check if file exists and has content
        segments = recording_manager.db.get_segment_files(recording_id)
        if not segments:
            return web.json_response({"error": "Recording file not available yet"}, status=404)

        # Redirect to the stream endpoint (absolute URL for Stremio)
        scheme = request.headers.get('X-Forwarded-Proto', request.scheme)
        host = request.headers.get('X-Forwarded-Host', request.host)
        base_url = f"{scheme}://{host}"

        api_password = request.query.get('api_password', '')
        stream_url = f"{base_url}/api/recordings/{recording_id}/stream"
        if api_password:
            stream_url += f"?api_password={api_password}"

        raise web.HTTPFound(stream_url)

    # Register routes
    app.router.add_get('/recordings', handle_recordings_page)
    app.router.add_get('/record', handle_record_via_get)
    app.router.add_get('/record/stop/{id}', handle_stop_and_stream)
    app.router.add_get('/api/recordings', handle_list_recordings)
    app.router.add_get('/api/recordings/active', handle_active_recordings)
    app.router.add_post('/api/recordings/start', handle_start_recording)
    app.router.add_delete('/api/recordings/all', handle_delete_all_recordings)
    app.router.add_get('/api/recordings/{id}', handle_get_recording)
    app.router.add_post('/api/recordings/{id}/stop', handle_stop_recording)
    app.router.add_delete('/api/recordings/{id}', handle_delete_recording)
    app.router.add_get('/api/recordings/{id}/delete', handle_delete_recording_get)
    app.router.add_get('/api/recordings/{id}/download', handle_download_recording)
    app.router.add_get('/api/recordings/{id}/stream', handle_stream_recording)
    app.router.add_get('/api/recordings/{id}/segments/{filename}', handle_serve_segment)
    # ✅ DVR Config API
    app.router.add_get('/api/dvr/config', handle_get_dvr_config)
    app.router.add_post('/api/dvr/config', handle_set_dvr_config)

    logger.debug("Recording routes registered")
