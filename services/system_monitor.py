import os
import time

class SystemMonitor:
    def __init__(self):
        self.last_net_time = time.time()
        self.last_net_bytes = self._get_net_bytes()
        self.last_cpu_time = time.time()
        self.last_cpu_times = self._get_cpu_times()
        
    def _get_net_bytes(self):
        try:
            with open('/proc/net/dev', 'r') as f:
                lines = f.readlines()[2:]
                down = 0
                up = 0
                for line in lines:
                    parts = line.split()
                    if len(parts) > 9 and parts[0] != 'lo:':
                        down += int(parts[1])
                        up += int(parts[9])
                return down, up
        except:
            return 0, 0
            
    def _get_cpu_times(self):
        try:
            with open('/proc/stat', 'r') as f:
                parts = f.readline().split()[1:]
                parts = [int(p) for p in parts]
                idle = parts[3] + parts[4]  # idle + iowait
                total = sum(parts)
                return idle, total
        except:
            return 0, 0
            
    def get_stats(self):
        now = time.time()
        dt = now - self.last_net_time
        
        # Network
        net_down, net_up = self._get_net_bytes()
        down_speed = 0
        up_speed = 0
        if dt > 0:
            down_speed = (net_down - self.last_net_bytes[0]) / dt  # bytes/s
            up_speed = (net_up - self.last_net_bytes[1]) / dt      # bytes/s
        
        self.last_net_time = now
        self.last_net_bytes = (net_down, net_up)
        
        # CPU
        cpu_idle, cpu_total = self._get_cpu_times()
        cpu_percent = 0
        dt_total = cpu_total - self.last_cpu_times[1]
        dt_idle = cpu_idle - self.last_cpu_times[0]
        if dt_total > 0:
            cpu_percent = 100 * (1.0 - dt_idle / dt_total)
            
        self.last_cpu_times = (cpu_idle, cpu_total)
        
        # RAM
        ram_percent = 0
        try:
            with open('/proc/meminfo', 'r') as f:
                meminfo = {}
                for line in f:
                    parts = line.split(':')
                    if len(parts) == 2:
                        meminfo[parts[0].strip()] = int(parts[1].split()[0])
                total = meminfo.get('MemTotal', 0)
                available = meminfo.get('MemAvailable', meminfo.get('MemFree', 0) + meminfo.get('Buffers', 0) + meminfo.get('Cached', 0))
                if total > 0:
                    ram_percent = ((total - available) / total) * 100
        except:
            pass
            
        # Storage
        storage_percent = 0
        try:
            st = os.statvfs('/sdcard') if os.path.exists('/sdcard') else os.statvfs('.')
            total = st.f_blocks * st.f_frsize
            free = st.f_bavail * st.f_frsize
            used = total - free
            if total > 0:
                storage_percent = (used / total) * 100
        except:
            pass
            
        return {
            "cpu_percent": round(cpu_percent, 1),
            "ram_percent": round(ram_percent, 1),
            "storage_percent": round(storage_percent, 1),
            "net_down_kbps": round(down_speed / 1024, 1), # kbps means kilobytes per second here for easier display
            "net_up_kbps": round(up_speed / 1024, 1)
        }
        
monitor = SystemMonitor()
