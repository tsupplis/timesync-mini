/*
 * timesync - Minimal SNTP client (RFC 5905 subset)
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
use chrono::{Datelike, Local, TimeZone};
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

fn stderr_log(message: &str) {
    let now = chrono::Local::now();
    eprintln!("{} {}", now.format("%Y-%m-%d %H:%M:%S"), message);
}

fn build_ntp_request() -> [u8; NTP_PACKET_SIZE] {
    let mut packet = [0u8; NTP_PACKET_SIZE];
    // LI = 0 (no warning), VN = 4 (version), Mode = 3 (client) -> 0b00100011 = 0x23
    packet[0] = 0x23;
    packet
}

fn ntp_ts_to_unix_ms(buf: &[u8]) -> Option<i64> {
    if buf.len() < 8 {
        return None;
    }
    
    let sec = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as u64;
    let frac = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]) as u64;
    
    if sec < NTP_UNIX_EPOCH_DIFF {
        return None;
    }
    
    let usec = (frac * 1_000_000) >> 32;
    let unix_sec = sec - NTP_UNIX_EPOCH_DIFF;
    Some((unix_sec * 1000 + usec / 1000) as i64)
}

fn system_time_to_ms(time: SystemTime) -> Option<i64> {
    match time.duration_since(UNIX_EPOCH) {
        Ok(duration) => Some(duration.as_millis() as i64),
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
        let socket = match UdpSocket::bind("0.0.0.0:0") {
            Ok(s) => s,
            Err(_) => continue,
        };
        
        if socket.set_read_timeout(Some(Duration::from_millis(timeout_ms))).is_err() {
            continue;
        }
        
        let packet = build_ntp_request();
        let before = SystemTime::now();
        
        if socket.send_to(&packet, addr).is_err() {
            continue;
        }
        
        let mut buf = [0u8; NTP_PACKET_SIZE];
        let (size, peer) = match socket.recv_from(&mut buf) {
            Ok(result) => result,
            Err(_) => continue,
        };
        
        let after = SystemTime::now();
        
        if size < NTP_PACKET_SIZE {
            continue;
        }
        
        // Validate NTP response
        // Check mode field = 4 (server)
        if (buf[0] & 0x07) != 4 {
            stderr_log(&format!("WARNING Invalid mode in NTP response: {}", buf[0] & 0x07));
            continue;
        }
        
        // Check stratum (0 = invalid)
        if buf[1] == 0 {
            stderr_log(&format!("WARNING Invalid stratum in NTP response: {}", buf[1]));
            continue;
        }
        
        // Check version (1-4 valid)
        let protocol_version = (buf[0] >> 3) & 0x07;
        if !(1..=4).contains(&protocol_version) {
            stderr_log(&format!("WARNING Invalid version in NTP response: {}", protocol_version));
            continue;
        }
        
        // Remote transmit timestamp is at bytes 40..47
        let remote_ms = match ntp_ts_to_unix_ms(&buf[40..48]) {
            Some(ms) => ms,
            None => {
                stderr_log("WARNING Invalid transmit timestamp in NTP response");
                continue;
            }
        };
        
        let local_before_ms = match system_time_to_ms(before) {
            Some(ms) => ms,
            None => continue,
        };
        let local_after_ms = match system_time_to_ms(after) {
            Some(ms) => ms,
            None => continue,
        };
        
        return Ok(NtpResponse {
            local_before_ms,
            remote_ms,
            local_after_ms,
            server_addr: peer.ip().to_string(),
        });
    }
    
    Err(format!("Failed to query {}", server))
}

fn set_system_time(time_ms: i64) -> Result<(), String> {
    #[cfg(unix)]
    {
        let secs = time_ms / 1000;
        let usecs = (time_ms % 1000) * 1000;
        
        #[repr(C)]
        struct Timeval {
            tv_sec: libc::time_t,
            tv_usec: libc::suseconds_t,
        }
        
        let tv = Timeval {
            tv_sec: secs as libc::time_t,
            tv_usec: usecs as libc::suseconds_t,
        };
        
        unsafe {
            if libc::settimeofday(&tv as *const Timeval as *const libc::timeval, std::ptr::null()) == 0 {
                Ok(())
            } else {
                Err(format!("settimeofday failed: {}", std::io::Error::last_os_error()))
            }
        }
    }
    
    #[cfg(not(unix))]
    {
        Err("Setting system time is only supported on Unix-like systems".to_string())
    }
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
                    config.timeout_ms = args[i].parse().unwrap_or(DEFAULT_TIMEOUT_MS).min(6000).max(1);
                }
            }
            "-r" => {
                i += 1;
                if i < args.len() {
                    config.retries = args[i].parse().unwrap_or(DEFAULT_RETRIES).min(10).max(1);
                }
            }
            "-n" => config.test_only = true,
            "-v" => config.verbose = true,
            "-s" => config.use_syslog = true,
            "-h" => {
                usage(&prog_name);
                process::exit(0);
            }
            arg if !arg.starts_with('-') => {
                config.server = arg.to_string();
            }
            _ => {}
        }
        i += 1;
    }
    
    if config.test_only {
        config.use_syslog = false;
    }
    
    if config.use_syslog {
        let formatter = Formatter3164 {
            facility: Facility::LOG_USER,
            hostname: None,
            process: "ntp_client".into(),
            pid: std::process::id(),
        };
        
        match syslog::unix(formatter) {
            Ok(writer) => {
                config.syslog_writer = Some(Box::new(writer));
            }
            Err(e) => {
                stderr_log(&format!("WARNING Failed to initialize syslog: {}", e));
                config.use_syslog = false;
            }
        }
    }
    
    if config.verbose {
        stderr_log(&format!("DEBUG Using server: {}", config.server));
        stderr_log(&format!(
            "DEBUG Timeout: {} ms, Retries: {}, Syslog: {}",
            config.timeout_ms,
            config.retries,
            if config.use_syslog { "on" } else { "off" }
        ));
    }
    
    let mut success = false;
    let mut response: Option<NtpResponse> = None;
    
    for attempt in 0..config.retries {
        if config.verbose {
            stderr_log(&format!(
                "DEBUG Attempt ({}) at NTP query on {} ...",
                attempt + 1,
                config.server
            ));
        }
        
        match do_ntp_query(&config.server, config.timeout_ms) {
            Ok(resp) => {
                response = Some(resp);
                success = true;
                break;
            }
            Err(_) => {
                std::thread::sleep(Duration::from_millis(200));
            }
        }
    }
    
    if !success {
        stderr_log(&format!(
            "ERROR Failed to contact NTP server {} after {} attempts",
            config.server, config.retries
        ));
        if let Some(ref mut writer) = config.syslog_writer {
            let _ = writer.err(format!(
                "NTP query failed for {} after {} attempts",
                config.server, config.retries
            ));
        }
        process::exit(2);
    }
    
    let resp = response.unwrap();
    
    // Check for overflow in avg calculation
    let avg_local_ms = match resp.local_before_ms.checked_add(resp.local_after_ms) {
        Some(sum) => sum / 2,
        None => {
            stderr_log("ERROR Time averaging would overflow, invalid timestamps.");
            if let Some(ref mut writer) = config.syslog_writer {
                let _ = writer.err("Time averaging would overflow".to_string());
            }
            process::exit(1);
        }
    };
    
    let offset_ms = resp.remote_ms - avg_local_ms;
    let roundtrip_ms = resp.local_after_ms - resp.local_before_ms;
    
    if config.verbose {
        stderr_log(&format!("DEBUG Server: {} ({})", config.server, resp.server_addr));
        
        // Format local time (non-fatal if fails, like C version)
        let local_time_str = match Local.timestamp_millis_opt(resp.local_after_ms) {
            chrono::LocalResult::Single(dt) => format!("{}.{:03}", dt.format("%Y-%m-%dT%H:%M:%S%z"), resp.local_after_ms % 1000),
            _ => "TIME_FORMAT_ERROR".to_string(),
        };
        stderr_log(&format!("DEBUG Local time: {}", local_time_str));
        
        // Format remote time (non-fatal if fails)
        let remote_time_str = match Local.timestamp_millis_opt(resp.remote_ms) {
            chrono::LocalResult::Single(dt) => format!("{}.{:03}", dt.format("%Y-%m-%dT%H:%M:%S%z"), resp.remote_ms % 1000),
            _ => "TIME_FORMAT_ERROR".to_string(),
        };
        stderr_log(&format!("DEBUG Remote time: {}", remote_time_str));
        stderr_log(&format!("DEBUG Local before(ms): {}", resp.local_before_ms));
        stderr_log(&format!("DEBUG Local after(ms): {}", resp.local_after_ms));
        stderr_log(&format!("DEBUG Estimated roundtrip(ms): {}", roundtrip_ms));
        stderr_log(&format!("DEBUG Estimated offset remote - local(ms): {}", offset_ms));
        
        if let Some(ref mut writer) = config.syslog_writer {
            let _ = writer.info(format!(
                "NTP server={} addr={} offset_ms={} rtt_ms={}",
                config.server, resp.server_addr, offset_ms, roundtrip_ms
            ));
        }
    }
    
    // Sanity check for roundtrip time
    if roundtrip_ms < 0 || roundtrip_ms > 10000 {
        stderr_log(&format!("ERROR Invalid roundtrip time: {} ms", roundtrip_ms));
        if let Some(ref mut writer) = config.syslog_writer {
            let _ = writer.err(format!("Invalid suspiciously long roundtrip time: {} ms", roundtrip_ms));
        }
        process::exit(1);
    }
    
    // Check if adjustment is needed
    if offset_ms.abs() > 0 && offset_ms.abs() < 500 {
        if config.verbose {
            stderr_log("INFO Delta < 500ms, not setting system time.");
            if let Some(ref mut writer) = config.syslog_writer {
                let _ = writer.info("Delta < 500ms, not setting system time".to_string());
            }
        }
        process::exit(0);
    }
    
    // Check remote year
    let remote_year = match Local.timestamp_millis_opt(resp.remote_ms) {
        chrono::LocalResult::Single(dt) => dt.year(),
        _ => {
            stderr_log("ERROR Could not parse remote time, not adjusting system time.");
            if let Some(ref mut writer) = config.syslog_writer {
                let _ = writer.err("Could not parse remote time, not adjusting system time".to_string());
            }
            process::exit(1);
        }
    };
    
    if remote_year < 2025 || remote_year > 2200 {
        stderr_log(&format!(
            "ERROR Remote year is {}, not adjusting system time.",
            remote_year
        ));
        if let Some(ref mut writer) = config.syslog_writer {
            let _ = writer.err("Remote year < 2025, not adjusting system time".to_string());
        }
        process::exit(1);
    }
    
    if config.test_only {
        process::exit(0);
    }
    
    // Check if running as root
    #[cfg(unix)]
    {
        unsafe {
            if libc::getuid() != 0 {
                stderr_log("WARNING Not root, not setting system time.");
                if let Some(ref mut writer) = config.syslog_writer {
                    let _ = writer.warning("Not root, not setting system time".to_string());
                }
                process::exit(0);
            }
        }
    }
    
    // Check for overflow before time calculation
    let half_rtt = roundtrip_ms / 2;
    let new_time_ms = match resp.remote_ms.checked_add(half_rtt) {
        Some(time) => time,
        None => {
            stderr_log("ERROR Time calculation would overflow, not adjusting system time.");
            if let Some(ref mut writer) = config.syslog_writer {
                let _ = writer.err("Time calculation would overflow".to_string());
            }
            process::exit(1);
        }
    };
    
    match set_system_time(new_time_ms) {
        Ok(_) => {
            let remote_dt = match Local.timestamp_millis_opt(resp.remote_ms) {
                chrono::LocalResult::Single(dt) => dt,
                _ => {
                    stderr_log("ERROR Could not format time for logging");
                    process::exit(1);
                }
            };
            let time_str = format!(
                "{}.{:03}",
                remote_dt.format("%Y-%m-%dT%H:%M:%S%z"),
                resp.remote_ms % 1000
            );
            stderr_log(&format!("INFO System time set using settimeofday ({})", time_str));
            if let Some(ref mut writer) = config.syslog_writer {
                let _ = writer.info(format!("System time set using settimeofday ({})", time_str));
            }
            process::exit(0);
        }
        Err(e) => {
            stderr_log(&format!("ERROR Failed to adjust system time: {}", e));
            if let Some(ref mut writer) = config.syslog_writer {
                let _ = writer.err(format!("Failed to adjust system time: {}", e));
            }
            process::exit(10);
        }
    }
}
