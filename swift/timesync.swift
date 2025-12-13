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

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Constants
let NTP_PORT: UInt16 = 123
let NTP_PACKET_SIZE = 48
let NTP_UNIX_EPOCH_DIFF: UInt32 = 2208988800
let DEFAULT_SERVER = "pool.ntp.org"
let DEFAULT_TIMEOUT_MS = 2000
let DEFAULT_RETRIES = 3

// Configuration
struct Config {
    var server: String = DEFAULT_SERVER
    var timeoutMs: Int = DEFAULT_TIMEOUT_MS
    var retries: Int = DEFAULT_RETRIES
    var verbose: Bool = false
    var testOnly: Bool = false
    var useSyslog: Bool = false
}

// Logging functions
func stderrLog(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let timestamp = formatter.string(from: Date())
    fputs("\(timestamp) \(message)\n", stderr)
    fflush(stderr)
}

// Usage
func showUsage() {
    fputs("""
Usage: timesync [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp server]
  server       NTP server to query (default: pool.ntp.org)
  -t timeout   Timeout in ms (default: 2000)
  -r retries   Number of retries (default: 3)
  -n           Test mode (no system time adjustment)
  -v           Verbose output
  -s           Enable syslog logging
  -h           Show this help message
""", stderr)
    exit(0)
}

// Parse command line arguments
func parseArgs() -> Config {
    var config = Config()
    let args = CommandLine.arguments
    var i = 1
    
    while i < args.count {
        let arg = args[i]
        
        if arg == "-h" {
            showUsage()
        } else if arg == "-t" && i + 1 < args.count {
            i += 1
            if let timeout = Int(args[i]) {
                config.timeoutMs = max(1, min(6000, timeout))
            }
        } else if arg == "-r" && i + 1 < args.count {
            i += 1
            if let retries = Int(args[i]) {
                config.retries = max(1, min(10, retries))
            }
        } else if arg.hasPrefix("-") && arg.count > 1 && !arg.hasPrefix("--") {
            // Handle combined flags like -nv
            for char in arg.dropFirst() {
                switch char {
                case "h": showUsage()
                case "n": config.testOnly = true
                case "v": config.verbose = true
                case "s": config.useSyslog = true
                default: break
                }
            }
        } else if !arg.hasPrefix("-") {
            config.server = arg
        }
        
        i += 1
    }
    
    // Disable syslog in test mode
    if config.testOnly {
        config.useSyslog = false
    }
    
    return config
}

// Get current time in milliseconds
func getTimeMs() -> Int64 {
    var tv = timeval()
    gettimeofday(&tv, nil)
    return Int64(tv.tv_sec) * 1000 + Int64(tv.tv_usec) / 1000
}

// Build NTP request packet
func buildNtpRequest() -> [UInt8] {
    var packet = [UInt8](repeating: 0, count: NTP_PACKET_SIZE)
    packet[0] = 0x1b  // LI=0, VN=3, Mode=3 (client)
    return packet
}

// Parse NTP timestamp to Unix milliseconds
func ntpToUnixMs(_ buffer: [UInt8], offset: Int) -> Int64? {
    guard offset + 8 <= buffer.count else { return nil }
    
    let sec = UInt32(buffer[offset]) << 24 |
              UInt32(buffer[offset + 1]) << 16 |
              UInt32(buffer[offset + 2]) << 8 |
              UInt32(buffer[offset + 3])
    
    let frac = UInt32(buffer[offset + 4]) << 24 |
               UInt32(buffer[offset + 5]) << 16 |
               UInt32(buffer[offset + 6]) << 8 |
               UInt32(buffer[offset + 7])
    
    guard sec >= NTP_UNIX_EPOCH_DIFF else { return nil }
    
    let unixSec = UInt64(sec - NTP_UNIX_EPOCH_DIFF)
    let unixMs = (UInt64(frac) * 1000) >> 32
    
    return Int64(unixSec * 1000 + unixMs)
}

// Format time as ISO string
func formatTime(_ ms: Int64) -> String {
    let sec = ms / 1000
    let msec = ms % 1000
    let date = Date(timeIntervalSince1970: TimeInterval(sec))
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return "\(formatter.string(from: date))+0000.\(String(format: "%03d", msec))"
}

// Set system time (requires root)
func setSystemTime(_ ms: Int64) -> Bool {
    let sec = Int(ms / 1000)
    let usec = Int((ms % 1000) * 1000)
    
    var tv = timeval(tv_sec: sec, tv_usec: Int32(usec))
    let result = settimeofday(&tv, nil)
    
    return result == 0
}

// Perform NTP query
func doNtpQuery(config: Config) -> Int32 {
    if config.verbose {
        stderrLog("DEBUG Using server: \(config.server)")
        stderrLog("DEBUG Timeout: \(config.timeoutMs) ms, Retries: \(config.retries), Syslog: off")
    }
    
    var attempt = 1
    while attempt <= config.retries {
        if config.verbose {
            stderrLog("DEBUG Attempt (\(attempt)) at NTP query on \(config.server) ...")
        }
        
        // Resolve hostname
        guard let host = gethostbyname(config.server) else {
            stderrLog("ERROR Cannot resolve hostname: \(config.server)")
            if config.useSyslog {
            }
            return 2
        }
        
        guard let addressList = host.pointee.h_addr_list,
              let addressPtr = addressList[0] else {
            stderrLog("ERROR Cannot resolve hostname: \(config.server)")
            return 2
        }
        
        // Create socket
        let sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sockfd >= 0 else {
            stderrLog("ERROR Cannot create socket")
            return 2
        }
        
        defer { close(sockfd) }
        
        // Set timeout
        var timeout = timeval()
        timeout.tv_sec = config.timeoutMs / 1000
        timeout.tv_usec = Int32((config.timeoutMs % 1000) * 1000)
        setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        
        // Build server address
        var serverAddr = sockaddr_in()
        serverAddr.sin_family = sa_family_t(AF_INET)
        serverAddr.sin_port = NTP_PORT.bigEndian
        memcpy(&serverAddr.sin_addr, addressPtr, Int(host.pointee.h_length))
        
        // Get IP string for logging
        var ipStr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &serverAddr.sin_addr, &ipStr, socklen_t(INET_ADDRSTRLEN))
        let ipString = String(cString: ipStr)
        
        // Send NTP request
        let packet = buildNtpRequest()
        let localBefore = getTimeMs()
        
        let sendResult = packet.withUnsafeBytes { bufferPtr in
            withUnsafePointer(to: serverAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(sockfd, bufferPtr.baseAddress, NTP_PACKET_SIZE, 0,
                           sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        
        guard sendResult >= 0 else {
            if attempt < config.retries {
                usleep(200000)  // 200ms
                attempt += 1
                continue
            }
            stderrLog("ERROR Failed to send NTP request")
            return 2
        }
        
        // Receive response
        var response = [UInt8](repeating: 0, count: NTP_PACKET_SIZE)
        var fromAddr = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        
        let recvResult = response.withUnsafeMutableBytes { bufferPtr in
            withUnsafeMutablePointer(to: &fromAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    recvfrom(sockfd, bufferPtr.baseAddress, NTP_PACKET_SIZE, 0,
                            sockaddrPtr, &fromLen)
                }
            }
        }
        
        let localAfter = getTimeMs()
        
        guard recvResult == NTP_PACKET_SIZE else {
            if attempt < config.retries {
                usleep(200000)  // 200ms
                attempt += 1
                continue
            }
            stderrLog("ERROR Timeout waiting for NTP response")
            if config.useSyslog {
            }
            return 2
        }
        
        // Validate response
        let mode = response[0] & 0x07
        guard mode == 4 else {
            stderrLog("ERROR Invalid mode in NTP response: \(mode)")
            return 2
        }
        
        let stratum = response[1]
        guard stratum != 0 else {
            stderrLog("ERROR Invalid stratum in NTP response")
            return 2
        }
        
        // Parse transmit timestamp (bytes 40-47)
        guard let remoteMs = ntpToUnixMs(response, offset: 40) else {
            stderrLog("ERROR Invalid NTP timestamp")
            return 2
        }
        
        // Calculate offset and RTT
        let avgLocal = (localBefore + localAfter) / 2
        let offset = remoteMs - avgLocal
        let rtt = localAfter - localBefore
        
        if config.verbose {
            stderrLog("DEBUG Server: \(config.server) (\(ipString))")
            stderrLog("DEBUG Local before(ms): \(localBefore)")
            stderrLog("DEBUG Local after(ms): \(localAfter)")
            stderrLog("DEBUG Remote time(ms): \(remoteMs)")
            stderrLog("DEBUG Estimated roundtrip(ms): \(rtt)")
            stderrLog("DEBUG Estimated offset remote - local(ms): \(offset)")
            
            if config.useSyslog {
            }
        }
        
        // Validate RTT
        guard rtt >= 0 && rtt <= 10000 else {
            stderrLog("ERROR Invalid roundtrip time: \(rtt) ms")
            if config.useSyslog {
            }
            return 1
        }
        
        // Check if offset is small
        let absOffset = abs(offset)
        if absOffset > 0 && absOffset < 500 {
            if config.verbose {
                stderrLog("INFO Delta < 500ms, not setting system time.")
                if config.useSyslog {
                }
            }
            if config.useSyslog {
            }
            return 0
        }
        
        // Validate remote time year
        let remoteSec = remoteMs / 1000
        let remoteDate = Date(timeIntervalSince1970: TimeInterval(remoteSec))
        let calendar = Calendar.current
        let remoteYear = calendar.component(.year, from: remoteDate)
        
        guard remoteYear >= 2025 && remoteYear <= 2200 else {
            stderrLog("ERROR Remote year is out of valid range (2025-2200): \(remoteYear)")
            if config.useSyslog {
            }
            return 1
        }
        
        // Test mode
        if config.testOnly {
            if config.verbose {
                stderrLog("INFO Test mode: would adjust system time by \(offset) ms")
                if config.useSyslog {
                }
            }
            if config.useSyslog {
            }
            return 0
        }
        
        // Check if running as root
        if getuid() != 0 {
            stderrLog("WARNING Not root, not setting system time.")
            if config.useSyslog {
            }
            return 10
        }
        
        // Set system time
        if setSystemTime(remoteMs) {
            if config.verbose {
                stderrLog("INFO System time set (\(formatTime(remoteMs)))")
                if config.useSyslog {
                }
            }
            if config.useSyslog {
            }
            return 0
        } else {
            stderrLog("ERROR Failed to adjust system time")
            if config.useSyslog {
            }
            return 10
        }
    }
    
    if config.useSyslog {
    }
    return 2
}

// Main
let config = parseArgs()
let exitCode = doNtpQuery(config: config)
exit(exitCode)
