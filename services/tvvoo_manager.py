import aiohttp
import asyncio
import logging
import time
from typing import List, Dict, Any, Optional

logger = logging.getLogger(__name__)

class TvvooManager:
    """Manager to fetch TVVOO curated lists from GitHub and resolve streams via Vavoo."""
    def __init__(self):
        self.github_url = "https://raw.githubusercontent.com/qwertyuiop8899/tvvoo/main/src/channels/lists.json"
        self._cached_channels = []
        self._last_fetch_time = 0
        self._vavoo_catalog_cache = {}
        self._cache_ttl = 3600 * 12 # 12 hours
        self._catalog_ttl = 3600 * 2 # 2 hours
        
    async def get_italian_channels(self, force_refresh=False) -> List[Dict[str, Any]]:
        now = time.time()
        if not force_refresh and self._cached_channels and (now - self._last_fetch_time) < self._cache_ttl:
            return self._cached_channels
            
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(self.github_url, timeout=10) as resp:
                    if resp.status == 200:
                        data = await resp.json(content_type=None)
                        # Filter only Italy
                        italy_channels = [ch for ch in data if ch.get("country") == "Italy"]
                        # Sort alphabetically by name
                        self._cached_channels = sorted(italy_channels, key=lambda x: x.get("name", ""))
                        self._last_fetch_time = now
                        logger.info(f"Fetched {len(self._cached_channels)} Italian channels from Tvvoo GitHub")
                    else:
                        logger.error(f"Failed to fetch tvvoo channels: HTTP {resp.status}")
        except Exception as e:
            logger.error(f"Error fetching tvvoo channels: {e}")
            
        return self._cached_channels

    async def get_vavoo_url(self, channel_name: str) -> Optional[str]:
        """Resolves a curated channel name to a vavoo.to play URL by querying the Vavoo API."""
        catalog = await self._fetch_vavoo_catalog("Italy")
        
        target_name = self._cleanup_channel_name(channel_name).lower()
        
        # Exact match based on cleaned up name
        for item in catalog:
            item_name = self._cleanup_channel_name(item.get("name", "")).lower()
            if item_name == target_name:
                url = item.get("url") or item.get("play") or item.get("href") or item.get("link") or ""
                if url:
                    return str(url)
                    
        # Fallback to loose match if exact failed
        for item in catalog:
            item_name = self._cleanup_channel_name(item.get("name", "")).lower()
            if target_name in item_name or item_name in target_name:
                url = item.get("url") or item.get("play") or item.get("href") or item.get("link") or ""
                if url:
                    logger.debug(f"Fuzzy matched {channel_name} -> {item_name}")
                    return str(url)
                    
        logger.warning(f"Could not find url for channel {channel_name} in Vavoo Italy catalog")
        return None

    def _cleanup_channel_name(self, name: str) -> str:
        """Ported logic from tvvoo to strip common suffixes like (1), FHD, etc."""
        if not name:
            return "Unknown"
            
        import re
        n = name.strip()
        n = re.sub(r'(?i)\s*\[?\b(?:1080p|720p|4k|fhd|hd|sd)\b\]?', '', n)
        n = re.sub(r'(?i)\s*\[?\b(?:ita|it|italia)\b\]?', '', n)
        n = re.sub(r'(?i)\s*\(.*?\)', '', n)
        n = re.sub(r'(?i)\s+\d+$', '', n)
        n = re.sub(r'\s+', ' ', n)
        return n.strip()

    async def _fetch_vavoo_catalog(self, group: str, force_refresh=False) -> List[Dict]:
        now = time.time()
        cache_entry = self._vavoo_catalog_cache.get(group)
        if not force_refresh and cache_entry and (now - cache_entry['time']) < self._catalog_ttl:
            return cache_entry['data']
            
        from extractors.vavoo import VavooExtractor
        extractor = VavooExtractor(request_headers={})
        sig = await extractor._get_auth_signature()
        await extractor.close()
        
        if not sig:
            logger.error("Failed to get lokke auth signature for Vavoo catalog")
            return []
            
        headers = {
            'user-agent': 'VAVOO/2.6',
            'accept': 'application/json',
            'content-type': 'application/json; charset=utf-8',
            'accept-encoding': 'gzip',
            'mediahubmx-signature': sig
        }
        
        out = []
        cursor = 0
        try:
            async with aiohttp.ClientSession() as session:
                while cursor is not None:
                    body = {
                        "language": "de",
                        "region": "AT",
                        "catalogId": "iptv",
                        "id": "iptv",
                        "adult": False,
                        "search": "",
                        "sort": "name",
                        "filter": {"group": group},
                        "cursor": cursor,
                        "clientVersion": "3.0.2"
                    }
                    async with session.post('https://vavoo.to/mediahubmx-catalog.json', headers=headers, json=body, timeout=15) as resp:
                        if resp.status != 200:
                            break
                        data = await resp.json()
                        items = data.get("items", [])
                        out.extend(items)
                        cursor = data.get("nextCursor")
        except Exception as e:
            logger.error(f"Error fetching Vavoo catalog for {group}: {e}")
            
        if out:
            self._vavoo_catalog_cache[group] = {
                'data': out,
                'time': now
            }
            logger.info(f"Fetched {len(out)} items from Vavoo catalog for group {group}")
            
        return self._vavoo_catalog_cache.get(group, {}).get('data', [])
