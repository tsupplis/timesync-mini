/*
 * timesync - Minimal SNTP client (RFC 5905 subset)
 *
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2025 tsupplis
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 * Rust port of the C implementation
 *
 * Build:
 *   cargo build --release
 *
 * Usage:
 *   ./timesync                    # query pool.ntp.org
 *   ./timesync -t 1500 -r 2 -v time.google.com
 */

use std::env;
use std::net::{ToSocketAddrs, UdpSocket};
use std::process;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use syslog::{Facility, Formatter3164};

const NTP_PORT: u16 = 123;
const NTP_PACKET_SIZE: usize = 48;
const NTP_UNIX_EPOCH_DIFF: u64 = 2208988800;
const DEFAULT_SERVER: &str = "pool.ntp.org";
const DEFAULT_TIMEOUT_MS: u64 = 2000;
const DEFAULT_RETRIES: u32 = 3;

struct Config {
    server: String,
    timeout_ms: u64,
    retries: u32,
    verbose: bool,
    test_only: bool,
    use_syslog: bool,
    syslog_writer: Option<Box<syslog::Logger<syslog::LoggerBackend, syslog::Formatter3164>>>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            server: DEFAULT_SERVER.to_string(),
            timeout_ms: DEFAULT_TIMEOUT_MS,
            retries: DEFAULT_RETRIES,
            verbose: false,
            test_only: false,
            use_syslog: false,
            syslog_writer: None,
        }
    }
}

struct NtpResponse {
    local_before_ms: i64,
    remote_ms: i64,
    local_after_ms: i64,
    server_addr: String,
}

/* Log to stderr with timestamp prefix — mirrors C's stderr_log().
   Usage: stderr_log!("INFO foo"); or stderr_log!("INFO val={}", x); */
macro_rules! stderr_log {
    ($($arg:tt)*) => {
        $crate::stderr_log_impl(&format!($($arg)*))
    };
}

/* Inner implementation — called by the macro. Uses time()+localtime_r+strftime like C. */
fn stderr_log_impl(message: &str) {
    unsafe {
        let now = libc::time(std::ptr::null_mut());
        let prefix = if now == -1 {
            "TIME_UNAVAILABLE".to_string()
        } else {
            let mut tm: libc::tm = std::mem::zeroed();
            if libc::localtime_r(&now, &mut tm).is_null() {
                "TIME_UNAVAILABLE".to_string()
            } else {
                let mut buf = [0u8; 32];
                let fmt = b"%Y-%m-%d %H:%M:%S\0";
                let n = libc::strftime(buf.as_mut_ptr() as *mut libc::c_char, buf.len(), fmt.as_ptr() as *const libc::c_char, &tm);
                if n == 0 { "TIME_FORMAT_ERROR".to_string() } else { std::str::from_utf8(&buf[..n]).unwrap_or("TIME_FORMAT_ERROR").to_string() }
            }
        };
        eprintln!("{} {}", prefix, message);
    }
}

/* Parse ms-since-epoch with a single localtime_r call — mirrors C's single remote_tm / local_tm.
   Returns (year, formatted_string) where formatted_string is "%Y-%m-%dT%H:%M:%S%z.mmm".
   On localtime_r failure: returns (None, "").           — matches C's "" init for local_time_str,
                                                            and None signals fatal error for remote_tm.
   On strftime failure:    returns (Some(year), "TIME_FORMAT_ERROR.mmm"). */
fn parse_time_ms(ms: i64, ms_suffix: i64) -> (Option<i32>, String) {
    unsafe {
        let secs = (ms / 1000) as libc::time_t;
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&secs, &mut tm).is_null() {
            return (None, String::new());
        }
        let year = Some(tm.tm_year + 1900);
        let mut buf = [0u8; 64];
        let fmt = b"%Y-%m-%dT%H:%M:%S%z\0";
        let n = libc::strftime(buf.as_mut_ptr() as *mut libc::c_char, buf.len(), fmt.as_ptr() as *const libc::c_char, &tm);
        if n == 0 {
            return (year, format!("TIME_FORMAT_ERROR.{:03}", ms_suffix % 1000));
        }
        let s = std::str::from_utf8(&buf[..n]).unwrap_or("TIME_FORMAT_ERROR");
        (year, format!("{}.{:03}", s, ms_suffix % 1000))
    }
}

fn build_ntp_request() -> [u8; NTP_PACKET_SIZE] {
    let mut packet = [0u8; NTP_PACKET_SIZE];
    // LI=0 (no warning), VN=4 (version), Mode=3 (client) -> 0b00100011 = 0x23
    packet[0] = 0x23;
    packet
}

fn ntp_ts_to_unix_ms(buf: &[u8]) -> Option<i64> {
    if buf.len() < 8 { return None; }
    let sec = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as u64;
    let frac = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]) as u64;
    if sec < NTP_UNIX_EPOCH_DIFF { return None; }
    let usec = (frac * 1_000_000) >> 32;
    let unix_sec = sec - NTP_UNIX_EPOCH_DIFF;
    Some((unix_sec * 1000 + usec / 1000) as i64)
}

fn system_time_to_ms(time: SystemTime) -> Option<i64> {
    match time.duration_since(UNIX_EPOCH) {
        Ok(d) => Some(d.as_millis() as i64),
        Err(_) => None,
    }
}

fn do_ntp_query(server: &str, timeout_ms: u64) -> Result<NtpResponse, String> {
    let addr_str = format!("{}:{}", server, NTP_PORT);
    let addrs: Vec<_> = addr_str
        .to_socket_addrs()
        .map_err(|e| format!("Failed to resolve {}: {}", server, e))?
        .collect();

    if addrs.is_empty() {
        return Err(format!("No addresses found for {}", server));
    }

    for addr in addrs {
        let bind_addr = if addr.is_ipv6() { "[::]:0" } else { "0.0.0.0:0" };
        let socket = match UdpSocket::bind(bind_addr) {
            Ok(s) => s,
            Err(_) => continue,
        };

        if let Err(e) = socket.set_read_timeout(Some(Duration::from_millis(timeout_ms))) {
            stderr_log!("WARNING setsockopt SO_RCVTIMEO failed: {}", e);
            continue;
        }

        let packet = build_ntp_request();
        let before = SystemTime::now();

        if socket.send_to(&packet, addr).is_err() {
            stderr_log!("WARNING Failed to send NTP request");
            continue;
        }

        let mut buf = [0u8; NTP_PACKET_SIZE];
        let (size, peer) = match socket.recv_from(&mut buf) {
            Ok(r) => r,
            Err(_) => continue,
        };
        let after = SystemTime::now();

        if size < NTP_PACKET_SIZE { continue; }

        if (buf[0] & 0x07) != 4 {
            stderr_log!("WARNING Invalid mode in NTP response: {}", buf[0] & 0x07);
            continue;
        }
        if buf[1] == 0 {
            stderr_log!("WARNING Invalid stratum in NTP response: {}", buf[1]);
            continue;
        }
        let protocol_version = (buf[0] >> 3) & 0x07;
        if !(1..=4).contains(&protocol_version) {
            stderr_log!("WARNING Invalid version in NTP response: {}", protocol_version);
            continue;
        }

        let remote_ms = match ntp_ts_to_unix_ms(&buf[40..48]) {
            Some(ms) => ms,
            None => { stderr_log!("WARNING Invalid transmit timestamp in NTP response"); continue; }
        };

        let local_before_ms = match system_time_to_ms(before) { Some(ms) => ms, None => continue };
        let local_after_ms  = match system_time_to_ms(after)  { Some(ms) => ms, None => continue };

        return Ok(NtpResponse { local_before_ms, remote_ms, local_after_ms, server_addr: peer.ip().to_string() });
    }

    Err(format!("Failed to query {}", server))
}

fn set_system_time(time_ms: i64) -> Result<(), String> {
    #[cfg(all(unix, not(feature = "use_settimeofday")))]
    unsafe {
        let ts = libc::timespec {
            tv_sec: (time_ms / 1000) as libc::time_t,
            tv_nsec: ((time_ms % 1000) * 1_000_000) as libc::c_long,
        };
        return if libc::clock_settime(libc::CLOCK_REALTIME, &ts) == 0 { Ok(()) }
               else { Err(std::io::Error::last_os_error().to_string()) };
    }

    #[cfg(all(unix, feature = "use_settimeofday"))]
    unsafe {
        #[repr(C)]
        struct Timeval { tv_sec: libc::time_t, tv_usec: libc::suseconds_t }
        let tv = Timeval { tv_sec: (time_ms / 1000) as libc::time_t, tv_usec: ((time_ms % 1000) * 1000) as libc::suseconds_t };
        return if libc::settimeofday(&tv as *const Timeval as *const libc::timeval, std::ptr::null()) == 0 { Ok(()) }
               else { Err(std::io::Error::last_os_error().to_string()) };
    }

    #[cfg(not(unix))]
    Err("Setting system time is only supported on Unix-like systems".to_string())
}

fn usage(prog: &str) {
    eprintln!("Usage: {} [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp server]", prog);
    eprintln!("  server       NTP server to query (default: pool.ntp.org)");
    eprintln!("  -t timeout   Timeout in ms (default: 2000)");
    eprintln!("  -r retries   Number of retries (default: 3)");
    eprintln!("  -n           Test mode (no system time adjustment)");
    eprintln!("  -v           Verbose output");
    eprintln!("  -s           Enable syslog logging");
    eprintln!("  -h           Show this help message");
}

fn main() {
    let mut config = Config::default();
    let args: Vec<String> = env::args().collect();
    let prog_name = args[0].clone();

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "-t" => {
                i += 1;
                if i < args.len() {
                    let v: i64 = args[i].parse().unwrap_or(0);
                    config.timeout_ms = if v <= 0 { DEFAULT_TIMEOUT_MS } else if v > 6000 { 6000 } else { v as u64 };
                }
            }
            "-r" => {
                i += 1;
                if i < args.len() {
                    let v: i32 = args[i].parse().unwrap_or(0);
                    config.retries = if v <= 0 { DEFAULT_RETRIES } else if v > 10 { 10 } else { v as u32 };
                }
            }
            "-n" => config.test_only = true,
            "-v" => config.verbose = true,
            "-s" => config.use_syslog = true,
            "-h" => { usage(&prog_name); process::exit(0); }
            arg if !arg.starts_with('-') => { config.server = arg.to_string(); }
            _ => {}
        }
        i += 1;
    }

    if config.test_only { config.use_syslog = false; }

    // Verbose debug fires before syslog is opened, matching C behaviour
    if config.verbose {
        stderr_log!("DEBUG Using server: {}", config.server);
        stderr_log!("DEBUG Timeout: {} ms, Retries: {}, Syslog: {}", config.timeout_ms, config.retries, if config.use_syslog { "on" } else { "off" });
    }

    if config.use_syslog {
        let formatter = Formatter3164 { facility: Facility::LOG_USER, hostname: None, process: "ntp_client".into(), pid: std::process::id() };
        match syslog::unix(formatter) {
            Ok(writer) => { config.syslog_writer = Some(Box::new(writer)); }
            Err(e) => { stderr_log!("WARNING Failed to initialize syslog: {}", e); config.use_syslog = false; }
        }
    }

    let mut success = false;
    let mut response: Option<NtpResponse> = None;

    for attempt in 0..config.retries {
        if config.verbose {
            stderr_log!("DEBUG Attempt ({}) at NTP query on {} ...", attempt + 1, config.server);
        }
        match do_ntp_query(&config.server, config.timeout_ms) {
            Ok(resp) => { response = Some(resp); success = true; break; }
            Err(_)   => { std::thread::sleep(Duration::from_millis(200)); }
        }
    }

    if !success {
        stderr_log!("ERROR Failed to contact NTP server {} after {} attempts", config.server, config.retries);
        if let Some(ref mut w) = config.syslog_writer {
            let _ = w.err(format!("NTP query failed for {} after {} attempts", config.server, config.retries));
        }
        process::exit(2);
    }

    let resp = response.unwrap();

    // Overflow guard on avg calculation
    let avg_local_ms = match resp.local_before_ms.checked_add(resp.local_after_ms) {
        Some(sum) => sum / 2,
        None => {
            stderr_log!("ERROR Time averaging would overflow, invalid timestamps.");
            if let Some(ref mut w) = config.syslog_writer { let _ = w.err("Time averaging would overflow".to_string()); }
            process::exit(1);
        }
    };

    let offset_ms    = resp.remote_ms - avg_local_ms;
    let roundtrip_ms = resp.local_after_ms - resp.local_before_ms;

    // Single localtime_r call for remote time — fatal if it fails, mirroring C
    let (remote_year_opt, remote_time_str) = parse_time_ms(resp.remote_ms, resp.remote_ms);
    let remote_year = match remote_year_opt {
        Some(y) => y,
        None => {
            stderr_log!("ERROR Could not parse remote time, not adjusting system time.");
            if let Some(ref mut w) = config.syslog_writer { let _ = w.err("Could not parse remote time, not adjusting system time".to_string()); }
            process::exit(1);
        }
    };

    if config.verbose {
        stderr_log!("DEBUG Server: {} ({})", config.server, resp.server_addr);
        // Single localtime_r call for local time, mirroring C's single local_tm
        let (_, local_time_str) = parse_time_ms(resp.local_before_ms, resp.local_after_ms);
        stderr_log!("DEBUG Local time: {}", local_time_str);
        stderr_log!("DEBUG Remote time: {}", remote_time_str);
        stderr_log!("DEBUG Local before(ms): {}", resp.local_before_ms);
        stderr_log!("DEBUG Local after(ms): {}", resp.local_after_ms);
        stderr_log!("DEBUG Estimated roundtrip(ms): {}", roundtrip_ms);
        stderr_log!("DEBUG Estimated offset remote - local(ms): {}", offset_ms);
        if let Some(ref mut w) = config.syslog_writer {
            let _ = w.info(format!("NTP server={} addr={} offset_ms={} rtt_ms={}", config.server, resp.server_addr, offset_ms, roundtrip_ms));
        }
    }

    // Roundtrip sanity check
    if roundtrip_ms < 0 || roundtrip_ms > 10000 {
        stderr_log!("ERROR Invalid roundtrip time: {} ms", roundtrip_ms);
        if let Some(ref mut w) = config.syslog_writer { let _ = w.err(format!("Invalid suspiciously long roundtrip time: {} ms", roundtrip_ms)); }
        process::exit(1);
    }

    // Delta < 500ms: skip adjustment
    if offset_ms.abs() > 0 && offset_ms.abs() < 500 {
        if config.verbose {
            stderr_log!("INFO Delta < 500ms, not setting system time.");
            if let Some(ref mut w) = config.syslog_writer { let _ = w.info("Delta < 500ms, not setting system time".to_string()); }
        }
        process::exit(0);
    }

    // Year range check
    if remote_year < 2025 || remote_year > 2200 {
        stderr_log!("ERROR Remote year is out of valid range (2025-2200): {}", remote_year);
        if let Some(ref mut w) = config.syslog_writer { let _ = w.err(format!("Remote year is out of valid range (2025-2200): {}", remote_year)); }
        process::exit(1);
    }

    if config.test_only { process::exit(0); }

    // Root check
    #[cfg(unix)]
    unsafe {
        if libc::getuid() != 0 {
            stderr_log!("WARNING Not root, not setting system time.");
            if let Some(ref mut w) = config.syslog_writer { let _ = w.warning("Not root, not setting system time".to_string()); }
            process::exit(0);
        }
    }

    // Overflow guard on remote_ms + half_rtt
    let half_rtt = roundtrip_ms / 2;
    let new_time_ms = match resp.remote_ms.checked_add(half_rtt) {
        Some(t) => t,
        None => {
            stderr_log!("ERROR Time calculation would overflow, not adjusting system time.");
            if let Some(ref mut w) = config.syslog_writer { let _ = w.err("Time calculation would overflow".to_string()); }
            process::exit(1);
        }
    };

    #[cfg(all(unix, not(feature = "use_settimeofday")))] let api = "clock_settime";
    #[cfg(all(unix, feature = "use_settimeofday"))]      let api = "settimeofday";
    #[cfg(not(unix))]                                    let api = "unknown";

    match set_system_time(new_time_ms) {
        Ok(_) => {
            stderr_log!("INFO System time set using {} ({})", api, remote_time_str);
            if let Some(ref mut w) = config.syslog_writer { let _ = w.info(format!("System time set using {} ({})", api, remote_time_str)); }
            process::exit(0);
        }
        Err(e) => {
            stderr_log!("ERROR Failed to adjust system time with {}: {}", api, e);
            if let Some(ref mut w) = config.syslog_writer { let _ = w.err(format!("Failed to adjust system time with {}: {}", api, e)); }
            process::exit(10);
        }
    }
}
