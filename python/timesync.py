#!/usr/bin/env python3
"""
timesync.py - Minimal SNTP client (RFC 5905 subset)

SPDX-License-Identifier: MIT
Copyright (c) 2025 tsupplis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Query server, print offset/delay in ms. Set system time if run as root and
offset is > 500ms.

Usage:
    ./timesync.py                    # query pool.ntp.org
    ./timesync.py -t 1500 -r 2 -s -v time.google.com
"""

import socket
import struct
import sys
import syslog
import time
from datetime import datetime, timezone
from typing import Optional, Tuple

# Constants
DEFAULT_NTP_PORT = 123
NTP_PACKET_SIZE = 48
NTP_UNIX_EPOCH_DIFF = 2208988800
DEFAULT_SERVER = "pool.ntp.org"
DEFAULT_TIMEOUT_MS = 2000
DEFAULT_RETRIES = 3


class Config:
    """Configuration for NTP client"""
    def __init__(self):
        self.server = DEFAULT_SERVER
        self.timeout_ms = DEFAULT_TIMEOUT_MS
        self.retries = DEFAULT_RETRIES
        self.verbose = False
        self.test_only = False
        self.use_syslog = False


def stderr_log(message: str) -> None:
    """Log message to stderr with timestamp"""
    now = datetime.now()
    timestamp = now.strftime("%Y-%m-%d %H:%M:%S")
    print(f"{timestamp} {message}", file=sys.stderr, flush=True)


def syslog_log(priority: int, message: str) -> None:
    """Log message to syslog"""
    try:
        syslog.syslog(priority, message)
    except Exception:
        pass


def get_time_ms() -> int:
    """Get current time in milliseconds since epoch"""
    return int(time.time() * 1000)


def build_ntp_request() -> bytes:
    """Build NTP request packet (48 bytes)"""
    # LI=0, VN=4, Mode=3 -> 0x23
    packet = bytearray(NTP_PACKET_SIZE)
    packet[0] = 0x23
    return bytes(packet)


def ntp_ts_to_unix_ms(data: bytes, offset: int) -> Optional[int]:
    """Convert NTP timestamp to Unix milliseconds"""
    if len(data) < offset + 8:
        return None
    
    # Extract 32-bit seconds and fractional parts (big-endian)
    sec, frac = struct.unpack("!II", data[offset:offset+8])
    
    if sec < NTP_UNIX_EPOCH_DIFF:
        return None
    
    # Convert fraction to microseconds
    usec = (frac * 1_000_000) >> 32
    unix_sec = sec - NTP_UNIX_EPOCH_DIFF
    
    return unix_sec * 1000 + usec // 1000


def format_time(ms: int) -> str:
    """Format milliseconds timestamp as ISO string"""
    sec = ms / 1000.0
    dt = datetime.fromtimestamp(sec, tz=timezone.utc)
    msec = ms % 1000
    return f"{dt.strftime('%Y-%m-%dT%H:%M:%S')}+0000.{msec:03d}"


def do_ntp_query(config: Config) -> Optional[Tuple[int, int, int, str]]:
    """
    Perform NTP query and return (local_before_ms, remote_ms, local_after_ms, server_addr)
    Returns None on failure
    """
    try:
        # Resolve server address
        addr_info = socket.getaddrinfo(
            config.server, DEFAULT_NTP_PORT,
            socket.AF_UNSPEC, socket.SOCK_DGRAM
        )
        
        if not addr_info:
            return None
        
        # Try each resolved address
        for family, socktype, proto, _, sockaddr in addr_info:
            sock = None
            try:
                sock = socket.socket(family, socktype, proto)
                
                # Set receive timeout
                timeout_sec = config.timeout_ms / 1000.0
                sock.settimeout(timeout_sec)
                
                # Send NTP request
                packet = build_ntp_request()
                local_before_ms = get_time_ms()
                sent = sock.sendto(packet, sockaddr)
                
                if sent != NTP_PACKET_SIZE:
                    sock.close()
                    continue
                
                # Receive response
                try:
                    data, addr = sock.recvfrom(NTP_PACKET_SIZE)
                    local_after_ms = get_time_ms()
                except socket.timeout:
                    sock.close()
                    continue
                
                sock.close()
                
                if len(data) < NTP_PACKET_SIZE:
                    continue
                
                # Validate response
                mode = data[0] & 0x07
                if mode != 4:
                    stderr_log(f"WARNING Invalid mode in NTP response: {mode}")
                    continue
                
                stratum = data[1]
                if stratum == 0:
                    stderr_log("WARNING Invalid stratum in NTP response")
                    continue
                
                version = (data[0] >> 3) & 0x07
                if version < 1 or version > 4:
                    stderr_log(f"WARNING Invalid version in NTP response: {version}")
                    continue
                
                # Extract transmit timestamp (bytes 40-47)
                remote_ms = ntp_ts_to_unix_ms(data, 40)
                if remote_ms is None:
                    stderr_log("WARNING Invalid transmit timestamp")
                    continue
                
                # Get server address string
                server_addr = addr[0] if isinstance(addr, tuple) else str(addr)
                
                return (local_before_ms, remote_ms, local_after_ms, server_addr)
                
            except Exception as e:
                if sock:
                    sock.close()
                continue
        
        return None
        
    except socket.gaierror:
        return None
    except Exception:
        return None


def set_system_time(new_time_ms: int) -> bool:
    """Set system time (requires root)"""
    try:
        import ctypes
        import ctypes.util
        
        # Try to use clock_settime (Linux/BSD)
        libc = ctypes.CDLL(ctypes.util.find_library('c'))
        
        class Timespec(ctypes.Structure):
            _fields_ = [('tv_sec', ctypes.c_long), ('tv_nsec', ctypes.c_long)]
        
        ts = Timespec()
        ts.tv_sec = new_time_ms // 1000
        ts.tv_nsec = (new_time_ms % 1000) * 1_000_000
        
        # CLOCK_REALTIME = 0
        result = libc.clock_settime(0, ctypes.byref(ts))
        return result == 0
        
    except Exception:
        # Fallback: try settimeofday
        try:
            import ctypes
            import ctypes.util
            
            libc = ctypes.CDLL(ctypes.util.find_library('c'))
            
            class Timeval(ctypes.Structure):
                _fields_ = [('tv_sec', ctypes.c_long), ('tv_usec', ctypes.c_long)]
            
            tv = Timeval()
            tv.tv_sec = new_time_ms // 1000
            tv.tv_usec = (new_time_ms % 1000) * 1000
            
            result = libc.settimeofday(ctypes.byref(tv), None)
            return result == 0
            
        except Exception:
            return False


def run(config: Config) -> int:
    """Main logic - returns exit code"""
    if config.verbose:
        stderr_log(f"DEBUG Using server: {config.server}")
        stderr_log(f"DEBUG Timeout: {config.timeout_ms} ms, Retries: {config.retries}, "
                  f"Syslog: {'on' if config.use_syslog else 'off'}")
    
    if config.use_syslog:
        syslog.openlog("ntp_client", syslog.LOG_PID | syslog.LOG_CONS, syslog.LOG_USER)
    
    # Attempt NTP query with retries
    result = None
    for attempt in range(config.retries):
        if config.verbose:
            stderr_log(f"DEBUG Attempt ({attempt + 1}) at NTP query on {config.server} ...")
        
        result = do_ntp_query(config)
        if result is not None:
            break
        
        # Small backoff before retry
        if attempt + 1 < config.retries:
            time.sleep(0.2)
    
    if result is None:
        stderr_log(f"ERROR Failed to contact NTP server {config.server} after {config.retries} attempts")
        if config.use_syslog:
            syslog_log(syslog.LOG_ERR, 
                      f"NTP query failed for {config.server} after {config.retries} attempts")
        return 2
    
    local_before_ms, remote_ms, local_after_ms, server_addr = result
    
    # Calculate offset and roundtrip
    avg_local_ms = (local_before_ms + local_after_ms) // 2
    offset_ms = remote_ms - avg_local_ms
    roundtrip_ms = local_after_ms - local_before_ms
    
    if config.verbose:
        stderr_log(f"DEBUG Server: {config.server} ({server_addr})")
        stderr_log(f"DEBUG Local time: {format_time(local_after_ms)}")
        stderr_log(f"DEBUG Remote time: {format_time(remote_ms)}")
        stderr_log(f"DEBUG Local before(ms): {local_before_ms}")
        stderr_log(f"DEBUG Local after(ms): {local_after_ms}")
        stderr_log(f"DEBUG Estimated roundtrip(ms): {roundtrip_ms}")
        stderr_log(f"DEBUG Estimated offset remote - local(ms): {offset_ms}")
        
        if config.use_syslog:
            syslog_log(syslog.LOG_INFO,
                      f"NTP server={config.server} addr={server_addr} "
                      f"offset_ms={offset_ms} rtt_ms={roundtrip_ms}")
    
    # Validate roundtrip
    if roundtrip_ms < 0 or roundtrip_ms > 10000:
        stderr_log(f"ERROR Invalid roundtrip time: {roundtrip_ms} ms")
        if config.use_syslog:
            syslog_log(syslog.LOG_ERR, f"Invalid roundtrip time: {roundtrip_ms} ms")
        return 1
    
    # Check if offset is small
    abs_offset = abs(offset_ms)
    if abs_offset > 0 and abs_offset < 500:
        if config.verbose:
            stderr_log("INFO Delta < 500ms, not setting system time.")
            if config.use_syslog:
                syslog_log(syslog.LOG_INFO, "Delta < 500ms, not setting system time")
        return 0
    
    # Validate remote time year
    remote_sec = remote_ms / 1000.0
    remote_dt = datetime.fromtimestamp(remote_sec, tz=timezone.utc)
    remote_year = remote_dt.year
    
    if remote_year < 2025 or remote_year > 2200:
        stderr_log(f"ERROR Remote year is out of valid range (2025-2200): {remote_year}")
        if config.use_syslog:
            syslog_log(syslog.LOG_ERR, f"Remote year out of range: {remote_year}")
        return 1
    
    if config.test_only:
        return 0
    
    # Check if running as root
    try:
        import os
        if os.getuid() != 0:
            stderr_log("WARNING Not root, not setting system time.")
            if config.use_syslog:
                syslog_log(syslog.LOG_WARNING, "Not root, not setting system time")
            return 0
    except AttributeError:
        # Windows doesn't have getuid
        stderr_log("WARNING Cannot check root status on this platform")
        return 0
    
    # Set system time
    half_rtt = roundtrip_ms // 2
    new_time_ms = remote_ms + half_rtt
    
    if set_system_time(new_time_ms):
        stderr_log(f"INFO System time set using clock_settime ({format_time(new_time_ms)})")
        if config.use_syslog:
            syslog_log(syslog.LOG_INFO, 
                      f"System time set using clock_settime ({format_time(new_time_ms)})")
        return 0
    else:
        stderr_log("ERROR Failed to adjust system time")
        if config.use_syslog:
            syslog_log(syslog.LOG_ERR, "Failed to adjust system time")
        return 10


def print_usage():
    """Print usage message matching C/OCaml versions"""
    print("Usage: timesync [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp server]", file=sys.stderr)
    print("  server       NTP server to query (default: pool.ntp.org)", file=sys.stderr)
    print("  -t timeout   Timeout in ms (default: 2000)", file=sys.stderr)
    print("  -r retries   Number of retries (default: 3)", file=sys.stderr)
    print("  -n           Test mode (no system time adjustment)", file=sys.stderr)
    print("  -v           Verbose output", file=sys.stderr)
    print("  -s           Enable syslog logging", file=sys.stderr)
    print("  -h           Show this help message", file=sys.stderr)
    sys.exit(0)


def main():
    """Parse arguments and run"""
    config = Config()
    i = 1
    
    while i < len(sys.argv):
        arg = sys.argv[i]
        
        if arg == "-h":
            print_usage()
        elif arg == "-t" and i + 1 < len(sys.argv):
            try:
                config.timeout_ms = max(1, min(6000, int(sys.argv[i + 1])))
                i += 1
            except ValueError:
                pass
        elif arg == "-r" and i + 1 < len(sys.argv):
            try:
                config.retries = max(1, min(10, int(sys.argv[i + 1])))
                i += 1
            except ValueError:
                pass
        elif arg.startswith("-") and not arg.startswith("--"):
            # Handle combined flags like -nv
            for c in arg[1:]:
                if c == "h":
                    print_usage()
                elif c == "n":
                    config.test_only = True
                elif c == "v":
                    config.verbose = True
                elif c == "s":
                    config.use_syslog = True
        elif not arg.startswith("-"):
            config.server = arg
        
        i += 1
    
    # Disable syslog in test mode
    if config.test_only:
        config.use_syslog = False
    
    sys.exit(run(config))


if __name__ == "__main__":
    main()
