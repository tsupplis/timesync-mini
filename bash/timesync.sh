#!/bin/bash
#
# timesync - Minimal SNTP client (RFC 5905 subset)
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 tsupplis

set -euo pipefail

# Default configuration
SERVER="pool.ntp.org"
PORT=123
TIMEOUT_MS=2000
RETRIES=3
VERBOSE=0
TEST_MODE=0
USE_SYSLOG=0

# NTP constants
NTP_UNIX_EPOCH=2208988800
NTP_PACKET_SIZE=48

# Logging functions
log_stderr() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_syslog() {
    if [[ $USE_SYSLOG -eq 1 ]]; then
        logger -t ntp_client -p "user.$1" "$2"
    fi
}

# Show usage
show_usage() {
    cat >&2 << EOF
Usage: timesync [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp server]
  server       NTP server to query (default: pool.ntp.org)
  -t timeout   Timeout in ms (default: 2000)
  -r retries   Number of retries (default: 3)
  -n           Test mode (no system time adjustment)
  -v           Verbose output
  -s           Enable syslog logging
  -h           Show this help message
EOF
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h)
            show_usage
            ;;
        -t)
            TIMEOUT_MS="$2"
            shift 2
            ;;
        -r)
            RETRIES="$2"
            shift 2
            ;;
        -*)
            # Handle combined flags like -nv
            flags="${1#-}"
            for ((i=0; i<${#flags}; i++)); do
                flag="${flags:$i:1}"
                case "$flag" in
                    h) show_usage ;;
                    n) TEST_MODE=1 ;;
                    v) VERBOSE=1 ;;
                    s) USE_SYSLOG=1 ;;
                esac
            done
            shift
            ;;
        *)
            SERVER="$1"
            shift
            ;;
    esac
done

# Disable syslog in test mode
[[ $TEST_MODE -eq 1 ]] && USE_SYSLOG=0

[[ $VERBOSE -eq 1 ]] && log_stderr "DEBUG Using server: $SERVER"
[[ $VERBOSE -eq 1 ]] && log_stderr "DEBUG Timeout: ${TIMEOUT_MS} ms, Retries: ${RETRIES}, Syslog: $([ $USE_SYSLOG -eq 1 ] && echo on || echo off)"

# Get current time in milliseconds since epoch
get_time_ms() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS: gdate if available, otherwise python
        if command -v gdate >/dev/null 2>&1; then
            gdate +%s%3N
        else
            python3 -c 'import time; print(int(time.time() * 1000))'
        fi
    else
        # Linux/BSD
        date +%s%3N 2>/dev/null || date +%s000
    fi
}

# Build NTP request packet (48 bytes, first byte is 0x1B)
build_ntp_packet() {
    printf '\x1b'
    printf '\x00%.0s' {1..47}
}

# Parse NTP timestamp from response
parse_ntp_timestamp() {
    local response="$1"
    local offset=$2
    
    # Extract 8 bytes starting at offset
    local bytes="${response:$((offset*2)):16}"
    
    # Convert hex to decimal (big-endian 32-bit integers)
    local sec_hex="${bytes:0:8}"
    local frac_hex="${bytes:8:8}"
    
    local sec=$((0x$sec_hex))
    local frac=$((0x$frac_hex))
    
    # Convert to Unix time (milliseconds)
    local unix_sec=$((sec - NTP_UNIX_EPOCH))
    local unix_ms=$((frac * 1000 / 4294967296))
    
    echo $((unix_sec * 1000 + unix_ms))
}

# Perform NTP query
do_ntp_query() {
    local attempt=1
    
    while [[ $attempt -le $RETRIES ]]; do
        [[ $VERBOSE -eq 1 ]] && log_stderr "DEBUG Attempt ($attempt) at NTP query on $SERVER ..."
        
        # Resolve hostname (or use IP directly)
        local ip="$SERVER"
        
        # Try to resolve if it's not already an IP
        if [[ ! "$SERVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ip=$(getent hosts "$SERVER" 2>/dev/null | awk '{print $1; exit}')
            [[ -z "$ip" ]] && ip=$(dig +short "$SERVER" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
            [[ -z "$ip" ]] && ip=$(host "$SERVER" 2>/dev/null | awk '/has address/ {print $4; exit}')
            [[ -z "$ip" ]] && ip=$(nslookup "$SERVER" 2>/dev/null | awk '/^Address: / && !/127\.0\.0\.1/ {print $2; exit}')
        fi
        
        if [[ -z "$ip" ]]; then
            log_stderr "ERROR Cannot resolve hostname: $SERVER"
            return 2
        fi
        
        # Create NTP packet
        local packet
        packet=$(build_ntp_packet)
        
        # Get time before send
        local local_before
        local_before=$(get_time_ms)
        
        # Send/receive using socat (more reliable for UDP than nc)
        local response
        local timeout_sec=$((TIMEOUT_MS / 1000))
        [[ $timeout_sec -lt 1 ]] && timeout_sec=2
        
        if ! command -v socat >/dev/null 2>&1; then
            log_stderr "ERROR socat not found (required for UDP operations)"
            log_stderr "ERROR Install with: brew install socat (macOS) or apt install socat (Linux)"
            return 2
        fi
        
        # Send NTP packet and receive response
        response=$( (printf '\x1b'; printf '\x00%.0s' {1..47}) | \
            timeout ${timeout_sec}s socat - UDP:"$ip":"$PORT",so-rcvtimeo=${timeout_sec} 2>/dev/null | \
            xxd -p -c 256)
        
        local socat_rc=$?
        
        # Get time after receive
        local local_after
        local_after=$(get_time_ms)
        
        if [[ $socat_rc -ne 0 || -z "$response" || ${#response} -lt $((NTP_PACKET_SIZE * 2)) ]]; then
            if [[ $attempt -lt $RETRIES ]]; then
                sleep 0.2
                ((attempt++))
                continue
            else
                log_stderr "ERROR Timeout or invalid response from NTP server"
                log_syslog err "Timeout or invalid response from NTP server"
                return 2
            fi
        fi
        
        # Validate response (mode should be 4, stratum should be > 0)
        local first_byte="${response:0:2}"
        local mode=$((0x$first_byte & 0x07))
        local stratum_hex="${response:2:2}"
        local stratum=$((0x$stratum_hex))
        
        if [[ $mode -ne 4 ]]; then
            log_stderr "ERROR Invalid mode in NTP response: $mode"
            return 2
        fi
        
        if [[ $stratum -eq 0 ]]; then
            log_stderr "ERROR Invalid stratum in NTP response"
            return 2
        fi
        
        # Parse transmit timestamp (bytes 40-47)
        local remote_ms
        remote_ms=$(parse_ntp_timestamp "$response" 40)
        
        # Calculate offset and RTT
        local avg_local=$(( (local_before + local_after) / 2 ))
        local offset=$((remote_ms - avg_local))
        local rtt=$((local_after - local_before))
        
        [[ $VERBOSE -eq 1 ]] && log_stderr "DEBUG Server: $SERVER ($ip)"
        [[ $VERBOSE -eq 1 ]] && log_stderr "DEBUG Local before(ms): $local_before"
        [[ $VERBOSE -eq 1 ]] && log_stderr "DEBUG Local after(ms): $local_after"
        [[ $VERBOSE -eq 1 ]] && log_stderr "DEBUG Remote time(ms): $remote_ms"
        [[ $VERBOSE -eq 1 ]] && log_stderr "DEBUG Estimated roundtrip(ms): $rtt"
        [[ $VERBOSE -eq 1 ]] && log_stderr "DEBUG Estimated offset remote - local(ms): $offset"
        
        [[ $VERBOSE -eq 1 ]] && log_syslog info "NTP server=$SERVER addr=$ip offset_ms=$offset rtt_ms=$rtt"
        
        # Validate RTT
        if [[ $rtt -lt 0 || $rtt -gt 10000 ]]; then
            log_stderr "ERROR Invalid roundtrip time: $rtt ms"
            log_syslog err "Invalid roundtrip time: $rtt ms"
            return 1
        fi
        
        # Check if offset is small
        local abs_offset=${offset#-}
        if [[ $abs_offset -lt 500 && $abs_offset -gt 0 ]]; then
            [[ $VERBOSE -eq 1 ]] && log_stderr "INFO Delta < 500ms, not setting system time."
            [[ $VERBOSE -eq 1 ]] && log_syslog info "Delta < 500ms, not setting system time"
            return 0
        fi
        
        # Test mode
        if [[ $TEST_MODE -eq 1 ]]; then
            [[ $VERBOSE -eq 1 ]] && log_stderr "INFO Test mode: would adjust system time by $offset ms"
            [[ $VERBOSE -eq 1 ]] && log_syslog info "Test mode: would adjust system time by $offset ms"
            return 0
        fi
        
        # Set system time
        local new_time_sec=$((remote_ms / 1000))
        local new_time_ms=$((remote_ms % 1000))
        
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            date -u -r "$new_time_sec" "+%m%d%H%M%y.%S" | xargs sudo date -u >/dev/null 2>&1
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            # Linux
            date -u -d "@$new_time_sec" "+%m%d%H%M%Y.%S" | xargs sudo date -u >/dev/null 2>&1
        else
            # BSD
            sudo date -u -r "$new_time_sec" >/dev/null 2>&1
        fi
        
        if [[ $? -eq 0 ]]; then
            [[ $VERBOSE -eq 1 ]] && log_stderr "INFO System time adjusted by $offset ms"
            [[ $VERBOSE -eq 1 ]] && log_syslog info "System time adjusted by $offset ms"
            return 0
        else
            log_stderr "ERROR Failed to adjust system time"
            log_syslog err "Failed to adjust system time"
            return 10
        fi
    done
}

# Main execution
do_ntp_query
exit $?
