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

import ctypes
import ctypes.util
import os
import socket
import struct
import sys
import syslog
import time
from datetime import datetime
from typing import Optional, Tuple

# Constants
DEFAULT_NTP_PORT = 123
NTP_PACKET_SIZE = 48
NTP_UNIX_EPOCH_DIFF = 2208988800
DEFAULT_SERVER = "pool.ntp.org"
DEFAULT_TIMEOUT_MS = 2000
DEFAULT_RETRIES = 3


class Config:
    def __init__(self):
        self.server = DEFAULT_SERVER
        self.timeout_ms = DEFAULT_TIMEOUT_MS
        self.retries = DEFAULT_RETRIES
        self.verbose = False
        self.test_only = False
        self.use_syslog = False


def stderr_log(message: str) -> None:
    """Log message to stderr with timestamp — matches C's stderr_log format."""
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"{timestamp} {message}", file=sys.stderr, flush=True)


def syslog_log(priority: int, message: str) -> None:
    try:
        syslog.syslog(priority, message)
    except Exception:
        pass


def get_time_ms() -> int:
    return int(time.time() * 1000)


def build_ntp_request() -> bytes:
    # LI=0, VN=4, Mode=3 -> 0x23
    packet = bytearray(NTP_PACKET_SIZE)
    packet[0] = 0x23
    return bytes(packet)


def ntp_ts_to_unix_ms(data: bytes, offset: int) -> Optional[int]:
    if len(data) < offset + 8:
        return None
    sec, frac = struct.unpack("!II", data[offset:offset + 8])
    if sec < NTP_UNIX_EPOCH_DIFF:
        return None
    usec = (frac * 1_000_000) >> 32
    unix_sec = sec - NTP_UNIX_EPOCH_DIFF
    return unix_sec * 1000 + usec // 1000


def format_time(ms: int) -> str:
    """Format ms-since-epoch as local ISO string with ms suffix — matches C's %Y-%m-%dT%H:%M:%S%z."""
    sec = ms // 1000
    dt = datetime.fromtimestamp(sec).astimezone()   # local timezone, like C's localtime_r
    return f"{dt.strftime('%Y-%m-%dT%H:%M:%S%z')}.{ms % 1000:03d}"


def do_ntp_query(config: Config) -> Optional[Tuple[int, int, int, str]]:
    """
    Perform NTP query, return (local_before_ms, remote_ms, local_after_ms, server_addr)
    or None on failure.
    """
    try:
        addr_info = socket.getaddrinfo(
            config.server, DEFAULT_NTP_PORT,
            socket.AF_UNSPEC, socket.SOCK_DGRAM
        )
    except socket.gaierror:
        return None

    if not addr_info:
        return None

    for family, socktype, proto, _, sockaddr in addr_info:
        sock = None
        try:
            sock = socket.socket(family, socktype, proto)
            try:
                sock.settimeout(config.timeout_ms / 1000.0)
            except OSError as e:
                stderr_log(f"WARNING setsockopt SO_RCVTIMEO failed: {e}")
                sock.close()
                continue

            packet = build_ntp_request()
            local_before_ms = get_time_ms()
            sent = sock.sendto(packet, sockaddr)
            if sent != NTP_PACKET_SIZE:
                stderr_log("WARNING Failed to send NTP request")
                sock.close()
                continue

            try:
                data, addr = sock.recvfrom(NTP_PACKET_SIZE)
                local_after_ms = get_time_ms()
            except socket.timeout:
                sock.close()
                continue

            sock.close()

            if len(data) < NTP_PACKET_SIZE:
                continue

            mode = data[0] & 0x07
            if mode != 4:
                stderr_log(f"WARNING Invalid mode in NTP response: {mode}")
                continue

            stratum = data[1]
            if stratum == 0:
                stderr_log(f"WARNING Invalid stratum in NTP response: {stratum}")  # gap G
                continue

            version = (data[0] >> 3) & 0x07
            if version < 1 or version > 4:
                stderr_log(f"WARNING Invalid version in NTP response: {version}")
                continue

            remote_ms = ntp_ts_to_unix_ms(data, 40)
            if remote_ms is None:
                stderr_log("WARNING Invalid transmit timestamp in NTP response")  # gap G
                continue

            server_addr = addr[0] if isinstance(addr, tuple) else str(addr)
            return (local_before_ms, remote_ms, local_after_ms, server_addr)

        except Exception:
            if sock:
                sock.close()
            continue

    return None


def set_system_time(new_time_ms: int) -> Tuple[bool, str, str]:
    """Set system time. Returns (success, api_name, error_string)."""
    libc_name = ctypes.util.find_library('c')
    if not libc_name:
        return (False, "clock_settime", "libc not found")
    libc = ctypes.CDLL(libc_name, use_errno=True)

    # Try clock_settime first (matches C default)
    class Timespec(ctypes.Structure):
        _fields_ = [('tv_sec', ctypes.c_long), ('tv_nsec', ctypes.c_long)]

    ts = Timespec()
    ts.tv_sec = new_time_ms // 1000
    ts.tv_nsec = (new_time_ms % 1000) * 1_000_000
    if libc.clock_settime(0, ctypes.byref(ts)) == 0:  # CLOCK_REALTIME = 0
        return (True, "clock_settime", "")

    # Fallback to settimeofday
    class Timeval(ctypes.Structure):
        _fields_ = [('tv_sec', ctypes.c_long), ('tv_usec', ctypes.c_long)]

    tv = Timeval()
    tv.tv_sec = new_time_ms // 1000
    tv.tv_usec = (new_time_ms % 1000) * 1000
    if libc.settimeofday(ctypes.byref(tv), None) == 0:
        return (True, "settimeofday", "")

    # Both failed — return (False, last_api_tried, errno_string)
    errno = ctypes.get_errno()
    return (False, "settimeofday", os.strerror(errno) if errno else "unknown error")


def usage(prog: str) -> None:
    """Print usage — matches C's usage() output exactly."""
    print(f"Usage: {prog} [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp server]", file=sys.stderr)  # gap C
    print("  server       NTP server to query (default: pool.ntp.org)", file=sys.stderr)
    print("  -t timeout   Timeout in ms (default: 2000)", file=sys.stderr)
    print("  -r retries   Number of retries (default: 3)", file=sys.stderr)
    print("  -n           Test mode (no system time adjustment)", file=sys.stderr)
    print("  -v           Verbose output", file=sys.stderr)
    print("  -s           Enable syslog logging", file=sys.stderr)
    print("  -h           Show this help message", file=sys.stderr)
    sys.exit(0)


def run(config: Config) -> int:
    """Main logic — mirrors C main() structure exactly."""

    # Verbose debug fires before syslog is opened, matching C
    if config.verbose:
        stderr_log(f"DEBUG Using server: {config.server}")
        stderr_log(f"DEBUG Timeout: {config.timeout_ms} ms, Retries: {config.retries}, Syslog: {'on' if config.use_syslog else 'off'}")

    if config.use_syslog:
        syslog.openlog("ntp_client", syslog.LOG_PID | syslog.LOG_CONS, syslog.LOG_USER)

    result = None
    for attempt in range(config.retries):
        if config.verbose:
            stderr_log(f"DEBUG Attempt ({attempt + 1}) at NTP query on {config.server} ...")
        result = do_ntp_query(config)
        if result is not None:
            break
        time.sleep(0.2)  # gap D: always sleep, including after last attempt

    if result is None:
        stderr_log(f"ERROR Failed to contact NTP server {config.server} after {config.retries} attempts")
        if config.use_syslog:
            syslog_log(syslog.LOG_ERR, f"NTP query failed for {config.server} after {config.retries} attempts")
        return 2

    local_before_ms, remote_ms, local_after_ms, server_addr = result

    # Overflow guard on avg calculation — matches C's INT64_MAX check exactly
    if local_before_ms > (2**63 - 1) - local_after_ms:
        stderr_log("ERROR Time averaging would overflow, invalid timestamps.")
        if config.use_syslog:
            syslog_log(syslog.LOG_ERR, "Time averaging would overflow")
        return 1
    avg_local_ms = (local_before_ms + local_after_ms) // 2
    offset_ms = remote_ms - avg_local_ms
    roundtrip_ms = local_after_ms - local_before_ms

    # Parse remote time unconditionally before verbose block — matches C's execution order (gap F)
    remote_time_str = format_time(remote_ms)
    remote_year = datetime.fromtimestamp(remote_ms // 1000).year

    if config.verbose:
        stderr_log(f"DEBUG Server: {config.server} ({server_addr})")
        # local_before_ms for date, local_after_ms for ms suffix — matches C (gap K)
        local_time_str = format_time(local_before_ms)
        # replace ms suffix with local_after_ms % 1000, matching C's local_after_ms % 1000
        local_time_str = local_time_str[:-3] + f"{local_after_ms % 1000:03d}"
        stderr_log(f"DEBUG Local time: {local_time_str}")
        stderr_log(f"DEBUG Remote time: {remote_time_str}")
        stderr_log(f"DEBUG Local before(ms): {local_before_ms}")
        stderr_log(f"DEBUG Local after(ms): {local_after_ms}")
        stderr_log(f"DEBUG Estimated roundtrip(ms): {roundtrip_ms}")
        stderr_log(f"DEBUG Estimated offset remote - local(ms): {offset_ms}")
        if config.use_syslog:
            syslog_log(syslog.LOG_INFO, f"NTP server={config.server} addr={server_addr} offset_ms={offset_ms} rtt_ms={roundtrip_ms}")

    if roundtrip_ms < 0 or roundtrip_ms > 10000:
        stderr_log(f"ERROR Invalid roundtrip time: {roundtrip_ms} ms")
        if config.use_syslog:
            syslog_log(syslog.LOG_ERR, f"Invalid suspiciously long roundtrip time: {roundtrip_ms} ms")  # gap H
        return 1

    abs_offset = abs(offset_ms)
    if abs_offset > 0 and abs_offset < 500:
        if config.verbose:
            stderr_log("INFO Delta < 500ms, not setting system time.")
            if config.use_syslog:
                syslog_log(syslog.LOG_INFO, "Delta < 500ms, not setting system time")
        return 0

    if remote_year < 2025 or remote_year > 2200:
        stderr_log(f"ERROR Remote year is out of valid range (2025-2200): {remote_year}")
        if config.use_syslog:
            syslog_log(syslog.LOG_ERR, f"Remote year is out of valid range (2025-2200): {remote_year}")  # gap H
        return 1

    if config.test_only:
        return 0

    if os.getuid() != 0:
        stderr_log("WARNING Not root, not setting system time.")
        if config.use_syslog:
            syslog_log(syslog.LOG_WARNING, "Not root, not setting system time")
        return 0

    # Overflow guard on remote_ms + half_rtt — matches C's INT64_MAX check
    half_rtt = roundtrip_ms // 2
    if remote_ms > (2**63 - 1) - half_rtt:
        stderr_log("ERROR Time calculation would overflow, not adjusting system time.")
        if config.use_syslog:
            syslog_log(syslog.LOG_ERR, "Time calculation would overflow")
        return 1
    new_time_ms = remote_ms + half_rtt

    ok, api, err = set_system_time(new_time_ms)
    if ok:
        stderr_log(f"INFO System time set using {api} ({remote_time_str})")
        if config.use_syslog:
            syslog_log(syslog.LOG_INFO, f"System time set using {api} ({remote_time_str})")
        return 0
    else:
        stderr_log(f"ERROR Failed to adjust system time with {api}: {err}")  # gap C fixed
        if config.use_syslog:
            syslog_log(syslog.LOG_ERR, f"Failed to adjust system time with {api}: {err}")
        return 10


def main():
    config = Config()
    prog = sys.argv[0]
    i = 1

    while i < len(sys.argv):
        arg = sys.argv[i]
        if arg == "-h":
            usage(prog)
        elif arg == "-t":
            if i + 1 < len(sys.argv):
                try:
                    v = int(sys.argv[i + 1])
                    # gap A: invalid/0 resets to default, clamp max to 6000 — matches C
                    if v <= 0:
                        config.timeout_ms = DEFAULT_TIMEOUT_MS
                    elif v > 6000:
                        config.timeout_ms = 6000
                    else:
                        config.timeout_ms = v
                except ValueError:
                    pass
                i += 1
        elif arg == "-r":
            if i + 1 < len(sys.argv):
                try:
                    v = int(sys.argv[i + 1])
                    # gap A: invalid/0 resets to default, clamp max to 10 — matches C
                    if v <= 0:
                        config.retries = DEFAULT_RETRIES
                    elif v > 10:
                        config.retries = 10
                    else:
                        config.retries = v
                except ValueError:
                    pass
                i += 1
        elif arg == "-n":
            config.test_only = True
        elif arg == "-v":
            config.verbose = True
        elif arg == "-s":
            config.use_syslog = True
        elif not arg.startswith("-"):
            config.server = arg
        # gap B: unknown/combined flags silently ignored like C
        i += 1

    if config.test_only:
        config.use_syslog = False

    sys.exit(run(config))

if __name__ == "__main__":
    main()
