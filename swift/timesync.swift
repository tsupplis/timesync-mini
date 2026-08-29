#!/usr/bin/env swift
//
// timesync.swift - Minimal SNTP client (RFC 5905 subset)
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 tsupplis
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// Swift port of the C implementation
//
// Build:
//   swiftc -O -o timesync timesync.swift
//
// Usage:
//   ./timesync                    # query pool.ntp.org
//   ./timesync -t 1500 -r 2 -v time.google.com

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Constants

let NTP_PORT: UInt16 = 123
let NTP_PACKET_SIZE = 48
let NTP_UNIX_EPOCH_DIFF: UInt64 = 2208988800
let DEFAULT_SERVER = "pool.ntp.org"
let DEFAULT_TIMEOUT_MS = 2000
let DEFAULT_RETRIES = 3

// MARK: - Config

struct Config {
    var server: String = DEFAULT_SERVER
    var timeoutMs: Int = DEFAULT_TIMEOUT_MS
    var retries: Int = DEFAULT_RETRIES
    var verbose: Bool = false
    var testOnly: Bool = false
    var useSyslog: Bool = false
}

// MARK: - Logging

/// Log to stderr with timestamp — matches C's stderr_log format: "YYYY-MM-DD HH:MM:SS <message>"
func stderrLog(_ message: String) {
    var now = time(nil)
    var tm = tm()
    localtime_r(&now, &tm)
    var buf = [CChar](repeating: 0, count: 32)
    strftime(&buf, buf.count, "%Y-%m-%d %H:%M:%S", &tm)
    let timestamp = String(cString: buf)
    fputs("\(timestamp) \(message)\n", stderr)
}

/// Write a message to syslog at the given priority.
/// Uses vsyslog+withVaList to work around Swift's restriction on variadic C functions.
func syslogWrite(_ priority: Int32, _ message: String) {
    message.withCString { msg in
        withVaList([msg]) { args in vsyslog(priority, "%s", args) }
    }
}

// MARK: - Usage

func showUsage() {
    let prog = CommandLine.arguments[0]
    fputs("Usage: \(prog) [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp server]\n", stderr)
    fputs("  server       NTP server to query (default: pool.ntp.org)\n", stderr)
    fputs("  -t timeout   Timeout in ms (default: 2000)\n", stderr)
    fputs("  -r retries   Number of retries (default: 3)\n", stderr)
    fputs("  -n           Test mode (no system time adjustment)\n", stderr)
    fputs("  -v           Verbose output\n", stderr)
    fputs("  -s           Enable syslog logging\n", stderr)
    fputs("  -h           Show this help message\n", stderr)
    exit(0)
}

// MARK: - Argument parsing

func parseArgs() -> Config {
    var config = Config()
    let args = CommandLine.arguments
    var i = 1

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h":
            showUsage()
        case "-t":
            i += 1
            if i < args.count, let v = Int(args[i]) {
                // invalid/0 resets to default, >6000 clamps — matches C
                if v <= 0 { config.timeoutMs = DEFAULT_TIMEOUT_MS }
                else if v > 6000 { config.timeoutMs = 6000 }
                else { config.timeoutMs = v }
            }
        case "-r":
            i += 1
            if i < args.count, let v = Int(args[i]) {
                // invalid/0 resets to default, >10 clamps — matches C
                if v <= 0 { config.retries = DEFAULT_RETRIES }
                else if v > 10 { config.retries = 10 }
                else { config.retries = v }
            }
        case "-n": config.testOnly = true
        case "-v": config.verbose = true
        case "-s": config.useSyslog = true
        default:
            if !arg.hasPrefix("-") { config.server = arg }
            // unknown flags silently ignored like C
        }
        i += 1
    }

    if config.testOnly { config.useSyslog = false }
    return config
}

// MARK: - Time helpers

/// Current time in ms since Unix epoch — mirrors C's gettimeofday().
func getTimeMs() -> Int64 {
    var tv = timeval()
    gettimeofday(&tv, nil)
    return Int64(tv.tv_sec) * 1000 + Int64(tv.tv_usec) / 1000
}

/// Format ms-since-epoch as local ISO string with ms suffix — matches C's %Y-%m-%dT%H:%M:%S%z.
func formatTime(_ ms: Int64) -> String {
    var secs = time_t(ms / 1000)
    var tm = tm()
    localtime_r(&secs, &tm)
    var buf = [CChar](repeating: 0, count: 64)
    strftime(&buf, buf.count, "%Y-%m-%dT%H:%M:%S%z", &tm)
    let msSuffix = String(format: "%03d", Int(ms % 1000))
    return String(cString: buf) + "." + msSuffix
}

// MARK: - NTP protocol

/// Build a 48-byte NTP request packet — LI=0, VN=4, Mode=3 → 0x23, matching C.
func buildNtpRequest() -> [UInt8] {
    var packet = [UInt8](repeating: 0, count: NTP_PACKET_SIZE)
    packet[0] = 0x23
    return packet
}

/// Convert 8-byte big-endian NTP timestamp at buf[offset] to Unix ms.
func ntpTsToUnixMs(_ buf: [UInt8], offset: Int) -> Int64? {
    guard offset + 8 <= buf.count else { return nil }
    let sec = UInt64(buf[offset]) << 24 | UInt64(buf[offset+1]) << 16
            | UInt64(buf[offset+2]) << 8  | UInt64(buf[offset+3])
    let frac = UInt64(buf[offset+4]) << 24 | UInt64(buf[offset+5]) << 16
             | UInt64(buf[offset+6]) << 8  | UInt64(buf[offset+7])
    guard sec >= NTP_UNIX_EPOCH_DIFF else { return nil }
    let usec = (frac * 1_000_000) >> 32
    let unixSec = sec - NTP_UNIX_EPOCH_DIFF
    return Int64(unixSec * 1000 + usec / 1000)
}

// MARK: - NTP query

struct NtpResponse {
    let localBeforeMs: Int64
    let remoteMs: Int64
    let localAfterMs: Int64
    let serverAddr: String
}

/// Single NTP query attempt. Returns NtpResponse on success, nil on any failure.
func doNtpQuery(server: String, timeoutMs: Int) -> NtpResponse? {
    // Resolve server — mirrors C's getaddrinfo(AF_UNSPEC, SOCK_DGRAM)
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_DGRAM
    var res: UnsafeMutablePointer<addrinfo>? = nil
    guard getaddrinfo(server, String(NTP_PORT), &hints, &res) == 0, let addrList = res else { return nil }
    defer { freeaddrinfo(addrList) }

    var rp: UnsafeMutablePointer<addrinfo>? = addrList
    while let node = rp {
        defer { rp = node.pointee.ai_next }

        let sockfd = socket(node.pointee.ai_family, node.pointee.ai_socktype, node.pointee.ai_protocol)
        guard sockfd >= 0 else { continue }
        defer { close(sockfd) }

        // Set receive timeout — mirrors C's setsockopt SO_RCVTIMEO
        var tv = timeval()
        tv.tv_sec = timeoutMs / 1000
        tv.tv_usec = Int32((timeoutMs % 1000) * 1000)
        if setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) < 0 {
            stderrLog("WARNING setsockopt SO_RCVTIMEO failed: \(String(cString: strerror(errno)))")
            continue
        }

        let packet = buildNtpRequest()
        let localBefore = getTimeMs()

        // Send
        let sent = packet.withUnsafeBytes { bytes in
            sendto(sockfd, bytes.baseAddress, NTP_PACKET_SIZE, 0,
                   node.pointee.ai_addr, node.pointee.ai_addrlen)
        }
        guard sent == NTP_PACKET_SIZE else {
            stderrLog("WARNING Failed to send NTP request")
            continue
        }

        // Receive
        var buf = [UInt8](repeating: 0, count: NTP_PACKET_SIZE)
        var srcAddr = sockaddr_storage()
        var srcLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let recvd = buf.withUnsafeMutableBytes { bytes in
            withUnsafeMutablePointer(to: &srcAddr) { srcPtr in
                srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(sockfd, bytes.baseAddress, NTP_PACKET_SIZE, 0, sockPtr, &srcLen)
                }
            }
        }
        let localAfter = getTimeMs()

        guard recvd >= NTP_PACKET_SIZE else { continue }

        // Validate mode = 4 (server)
        let mode = buf[0] & 0x07
        guard mode == 4 else {
            stderrLog("WARNING Invalid mode in NTP response: \(mode)")
            continue
        }
        // Validate stratum != 0
        let stratum = buf[1]
        guard stratum != 0 else {
            stderrLog("WARNING Invalid stratum in NTP response: \(stratum)")
            continue
        }
        // Validate version 1-4
        let version = (buf[0] >> 3) & 0x07
        guard (1...4).contains(version) else {
            stderrLog("WARNING Invalid version in NTP response: \(version)")
            continue
        }
        // Extract transmit timestamp at bytes 40-47
        guard let remoteMs = ntpTsToUnixMs(buf, offset: 40) else {
            stderrLog("WARNING Invalid transmit timestamp in NTP response")
            continue
        }

        // Compose server address string from the source address
        var ipStr = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        withUnsafePointer(to: &srcAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                switch Int32(sa.pointee.sa_family) {
                case AF_INET:
                    ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        var addr = $0.pointee.sin_addr
                        inet_ntop(AF_INET, &addr, &ipStr, socklen_t(INET6_ADDRSTRLEN))
                    }
                case AF_INET6:
                    ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        var addr = $0.pointee.sin6_addr
                        inet_ntop(AF_INET6, &addr, &ipStr, socklen_t(INET6_ADDRSTRLEN))
                    }
                default: break
                }
            }
        }
        let serverAddrStr = String(cString: ipStr)

        return NtpResponse(localBeforeMs: localBefore, remoteMs: remoteMs,
                           localAfterMs: localAfter, serverAddr: serverAddrStr)
    }
    return nil
}

// MARK: - Set system time

func setSystemTime(_ ms: Int64) -> Bool {
    var tv = timeval()
    tv.tv_sec = Int(ms / 1000)
    tv.tv_usec = Int32((ms % 1000) * 1000)
    return settimeofday(&tv, nil) == 0
}

// MARK: - Main logic

func run(_ config: Config) -> Int32 {
    // Verbose debug fires before syslog is opened — matching C
    if config.verbose {
        stderrLog("DEBUG Using server: \(config.server)")
        stderrLog("DEBUG Timeout: \(config.timeoutMs) ms, Retries: \(config.retries), Syslog: \(config.useSyslog ? "on" : "off")")
    }

    if config.useSyslog {
        openlog("ntp_client", LOG_PID | LOG_CONS, LOG_USER)
        // Mirror C's atexit(closelog) — close syslog on process exit
        atexit { closelog() }
    }

    var response: NtpResponse? = nil
    for attempt in 0..<config.retries {
        if config.verbose {
            stderrLog("DEBUG Attempt (\(attempt + 1)) at NTP query on \(config.server) ...")
        }
        if let r = doNtpQuery(server: config.server, timeoutMs: config.timeoutMs) {
            response = r
            break
        }
        // Backoff fires on every failure including after last attempt — matches C
        usleep(200_000)
    }

    guard let resp = response else {
        stderrLog("ERROR Failed to contact NTP server \(config.server) after \(config.retries) attempts")
        if config.useSyslog {
            syslogWrite(LOG_ERR, "NTP query failed for \(config.server) after \(config.retries) attempts")
        }
        return 2
    }

    // Overflow guard on avg calculation — matches C's INT64_MAX check
    guard resp.localBeforeMs <= Int64.max - resp.localAfterMs else {
        stderrLog("ERROR Time averaging would overflow, invalid timestamps.")
        if config.useSyslog { syslogWrite(LOG_ERR, "Time averaging would overflow") }
        return 1
    }
    let avgLocalMs = (resp.localBeforeMs + resp.localAfterMs) / 2
    let offsetMs   = resp.remoteMs - avgLocalMs
    let roundtripMs = resp.localAfterMs - resp.localBeforeMs

    // Parse remote time unconditionally before verbose block — matches C's execution order
    let remoteTimeStr = formatTime(resp.remoteMs)
    var remoteSecs = time_t(resp.remoteMs / 1000)
    var remoteTm = tm()
    localtime_r(&remoteSecs, &remoteTm)
    let remoteYear = Int(remoteTm.tm_year) + 1900

    if config.verbose {
        stderrLog("DEBUG Server: \(config.server) (\(resp.serverAddr))")
        // local time: date from localBeforeMs, ms suffix from localAfterMs — matches C
        var localSecs = time_t(resp.localBeforeMs / 1000)
        var localTm = tm()
        localtime_r(&localSecs, &localTm)
        var localBuf = [CChar](repeating: 0, count: 64)
        strftime(&localBuf, localBuf.count, "%Y-%m-%dT%H:%M:%S%z", &localTm)
        let localMsSuffix = String(format: "%03d", Int(resp.localAfterMs % 1000))
        let localTimeStr = String(cString: localBuf) + "." + localMsSuffix
        stderrLog("DEBUG Local time: \(localTimeStr)")
        stderrLog("DEBUG Remote time: \(remoteTimeStr)")
        stderrLog("DEBUG Local before(ms): \(resp.localBeforeMs)")
        stderrLog("DEBUG Local after(ms): \(resp.localAfterMs)")
        stderrLog("DEBUG Estimated roundtrip(ms): \(roundtripMs)")
        stderrLog("DEBUG Estimated offset remote - local(ms): \(offsetMs)")
        if config.useSyslog {
            syslogWrite(LOG_INFO, "NTP server=\(config.server) addr=\(resp.serverAddr) offset_ms=\(offsetMs) rtt_ms=\(roundtripMs)")
        }
    }

    // Roundtrip sanity check
    guard roundtripMs >= 0 && roundtripMs <= 10000 else {
        stderrLog("ERROR Invalid roundtrip time: \(roundtripMs) ms")
        if config.useSyslog {
            syslogWrite(LOG_ERR, "Invalid suspiciously long roundtrip time: \(roundtripMs) ms")
        }
        return 1
    }

    // Delta < 500ms: skip adjustment
    if abs(offsetMs) > 0 && abs(offsetMs) < 500 {
        if config.verbose {
            stderrLog("INFO Delta < 500ms, not setting system time.")
            if config.useSyslog { syslogWrite(LOG_INFO, "Delta < 500ms, not setting system time") }
        }
        return 0
    }

    // Year range check
    guard remoteYear >= 2025 && remoteYear <= 2200 else {
        stderrLog("ERROR Remote year is out of valid range (2025-2200): \(remoteYear)")
        if config.useSyslog {
            syslogWrite(LOG_ERR, "Remote year is out of valid range (2025-2200): \(remoteYear)")
        }
        return 1
    }

    if config.testOnly { return 0 }

    // Root check
    guard getuid() == 0 else {
        stderrLog("WARNING Not root, not setting system time.")
        if config.useSyslog { syslogWrite(LOG_WARNING, "Not root, not setting system time") }
        return 0
    }

    // Overflow guard on remote_ms + half_rtt — matches C's INT64_MAX check
    let halfRtt = roundtripMs / 2
    guard resp.remoteMs <= Int64.max - halfRtt else {
        stderrLog("ERROR Time calculation would overflow, not adjusting system time.")
        if config.useSyslog { syslogWrite(LOG_ERR, "Time calculation would overflow") }
        return 1
    }
    let newTimeMs = resp.remoteMs + halfRtt

    let api = "settimeofday"
    if setSystemTime(newTimeMs) {
        stderrLog("INFO System time set using \(api) (\(remoteTimeStr))")
        if config.useSyslog { syslogWrite(LOG_INFO, "System time set using \(api) (\(remoteTimeStr))") }
        return 0
    } else {
        stderrLog("ERROR Failed to adjust system time with \(api): \(String(cString: strerror(errno)))")
        if config.useSyslog {
            syslogWrite(LOG_ERR, "Failed to adjust system time with \(api): \(String(cString: strerror(errno)))")
        }
        return 10
    }
}

// MARK: - Entry point

let config = parseArgs()
exit(run(config))
