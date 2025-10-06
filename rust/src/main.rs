use anyhow::{Context, Result};
use clap::Parser;
use chrono::{NaiveDateTime, Utc};
use std::net::{ToSocketAddrs, UdpSocket};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// Minimal SNTP client in Rust (RFC 5905 subset).
#[derive(Parser, Debug)]
#[command(author, version, about)]
struct Opt {
    /// NTP server (default: pool.ntp.org:123)
    #[arg(long, default_value = "pool.ntp.org:123")]
    server: String,

    /// Timeout in milliseconds for each try
    #[arg(long = "timeout-ms", default_value_t = 1500)]
    timeout_ms: u64,

    /// Number of retries
    #[arg(long, default_value_t = 2)]
    retries: u32,

    /// If present, attempt to set the system time when offset magnitude > set-threshold-ms
    #[arg(long = "set", default_value_t = false)]
    set_time: bool,

    /// Threshold in milliseconds for setting system time (default 500 ms)
    #[arg(long = "set-threshold-ms", default_value_t = 500)]
    set_threshold_ms: i64,
}

/// NTP timestamp is 64-bit: 32 bits seconds since 1900-01-01, 32 bits fractional
/// We'll work with milliseconds (i64) for offsets/delays.
///
/// Size of NTP packet for SNTP: 48 bytes
const NTP_PACKET_SIZE: usize = 48;

/// Number of seconds between NTP epoch (1900-01-01) and Unix epoch (1970-01-01)
const NTP_UNIX_OFFSET_SECS: i64 = 2_208_988_800i64; // 70 years including 17 leap days

fn system_time_to_ntp_timestamp_ms(now: SystemTime) -> Result<u64> {
    // Convert SystemTime (Unix epoch) to milliseconds since NTP epoch.
    let dur = now.duration_since(UNIX_EPOCH)?;
    // seconds since unix epoch
    let secs_unix = dur.as_secs() as i64;
    let nanos = dur.subsec_nanos() as u128;

    // Convert to NTP seconds (since 1900)
    let secs_ntp = secs_unix + NTP_UNIX_OFFSET_SECS;
    // fractional part: fraction of a second scaled to 2^32 units
    // but we will produce milliseconds for convenience: compute total milliseconds since NTP epoch.
    let ms = (secs_ntp as i128) * 1000 + (nanos as i128 / 1_000_000) as i128;
    if ms < 0 {
        anyhow::bail!("system time before NTP epoch");
    }
    Ok(ms as u64)
}

fn ntp_timestamp_from_bytes(buf: &[u8]) -> u64 {
    // NTP timestamp is 64 bits: seconds (u32) then fraction (u32)
    // We'll convert to milliseconds since NTP epoch.
    let sec = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as u64;
    let frac = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]) as u64;

    // fraction represents frac / 2^32 seconds. Convert to milliseconds:
    // ms = sec * 1000 + (frac * 1000) / 2^32
    // compute (frac * 1000) / 2^32 safely with u128
    let ms = sec
        .checked_mul(1000)
        .unwrap_or(0)
        .saturating_add(((frac as u128 * 1000u128) >> 32) as u64);
    ms
}

fn write_ntp_timestamp_to_buf(ms_since_ntp_epoch: u64, buf: &mut [u8]) {
    // Convert ms_since_ntp_epoch into seconds and fraction (32-bit fraction)
    let secs = ms_since_ntp_epoch / 1000;
    let ms_rem = ms_since_ntp_epoch % 1000;

    // fraction = (ms_rem / 1000) * 2^32
    // So fraction = ms_rem * 2^32 / 1000
    let fraction =
        (((ms_rem as u128) << 32) / 1000u128) as u32; // safe: ms_rem < 1000

    let sec_bytes = (secs as u32).to_be_bytes();
    let frac_bytes = fraction.to_be_bytes();

    buf[0..4].copy_from_slice(&sec_bytes);
    buf[4..8].copy_from_slice(&frac_bytes);
}

/// Build a minimal NTP request packet (48 bytes).
fn make_request_packet(transmit_time_ms_ntp: u64) -> [u8; NTP_PACKET_SIZE] {
    let mut pkt = [0u8; NTP_PACKET_SIZE];
    // LI = 0 (no warning), VN = 4, Mode = 3 (client)
    pkt[0] = (0 << 6) | (4 << 3) | 3;
    // Stratum, poll, precision left as zero
    // Set the Transmit Timestamp (bytes 40..48)
    write_ntp_timestamp_to_buf(transmit_time_ms_ntp, &mut pkt[40..48]);
    pkt
}

/// Parse reply packet and extract relevant timestamps (all ms since NTP epoch).
///
/// Returns (originate, receive, transmit, destination)
fn parse_reply_packet(buf: &[u8], destination_time_ms: u64) -> Result<(u64, u64, u64, u64)> {
    if buf.len() < NTP_PACKET_SIZE {
        anyhow::bail!("short response");
    }
    // originate (T1) = bytes 24..32
    let originate = ntp_timestamp_from_bytes(&buf[24..32]);
    // receive (T2) = bytes 32..40
    let receive = ntp_timestamp_from_bytes(&buf[32..40]);
    // transmit (T3) = bytes 40..48
    let transmit = ntp_timestamp_from_bytes(&buf[40..48]);
    Ok((originate, receive, transmit, destination_time_ms))
}

/// Given T1 (originate), T2 (server receive), T3 (server transmit), T4 (destination recv)
/// compute round-trip delay and local clock offset (per RFC):
///
/// delay = (T4 - T1) - (T3 - T2)
/// offset = ((T2 - T1) + (T3 - T4)) / 2
///
/// All timestamps are in the same epoch and in milliseconds.
fn compute_delay_offset(t1: i128, t2: i128, t3: i128, t4: i128) -> (f64, f64) {
    // all in ms; convert to signed arithmetic
    let delay = (t4 - t1) - (t3 - t2);
    let offset = ((t2 - t1) + (t3 - t4)) / 2;
    (delay as f64, offset as f64)
}

/// Attempts to set system time to `new_time` which is a SystemTime.
/// Returns Ok(()) on success.
///
/// Uses libc::settimeofday (POSIX). This requires appropriate privileges.
#[cfg(target_family = "unix")]
fn set_system_time(new_time: SystemTime) -> Result<()> {
    use std::mem::zeroed;
    use std::os::raw::c_long;

    let dur = new_time.duration_since(UNIX_EPOCH)?;
    // seconds and microseconds
    let secs = dur.as_secs() as i64;
    let usec = (dur.subsec_micros()) as i64;

    // libc timeval
    let tv = libc::timeval {
        tv_sec: secs as libc::time_t,
        tv_usec: usec as libc::suseconds_t,
    };

    // settimeofday takes (const struct timeval *tv, const struct timezone *tz)
    let ret = unsafe { libc::settimeofday(&tv as *const libc::timeval, std::ptr::null()) };
    if ret == 0 {
        Ok(())
    } else {
        Err(anyhow::anyhow!("settimeofday failed: errno {}", nix::errno::Errno::last()))
    }
}

#[cfg(not(target_family = "unix"))]
fn set_system_time(_new_time: SystemTime) -> Result<()> {
    anyhow::bail!("setting system time is only supported on Unix in this program");
}

fn main() -> Result<()> {
    let opt = Opt::parse();

    // Resolve server address
    let addrs: Vec<_> = opt
        .server
        .to_socket_addrs()
        .with_context(|| format!("resolving server {}", opt.server))?
        .collect();
    if addrs.is_empty() {
        anyhow::bail!("no addresses found for {}", opt.server);
    }
    let server_addr = addrs[0];

    let socket = UdpSocket::bind("0.0.0.0:0").context("binding local UDP socket")?;
    socket.set_read_timeout(Some(Duration::from_millis(opt.timeout_ms)))?;

    let mut best_result: Option<(f64, f64, i64)> = None;
    // best_result = (delay_ms, offset_ms, transmit_time_ms_ntp as i64)

    for attempt in 0..=opt.retries {
        // t1: originate timestamp (local time when request leaves)
        let t1_system = SystemTime::now();
        let t1_ntp_ms = system_time_to_ntp_timestamp_ms(t1_system)?;

        let req = make_request_packet(t1_ntp_ms);
        socket
            .send_to(&req, server_addr)
            .with_context(|| format!("sending to {}", server_addr))?;

        // prepare buffer
        let mut buf = [0u8; 512];
        // receive
        let (len, _src) = match socket.recv_from(&mut buf) {
            Ok((l, s)) => (l, s),
            Err(e) => {
                eprintln!("attempt {}: recv error: {}", attempt + 1, e);
                if attempt == opt.retries {
                    anyhow::bail!("all retries exhausted");
                } else {
                    continue;
                }
            }
        };

        // t4: destination receive timestamp (immediately after recv)
        let t4_system = SystemTime::now();
        let t4_ntp_ms = system_time_to_ntp_timestamp_ms(t4_system)?;

        let (originate, receive, transmit, destination) =
            parse_reply_packet(&buf[..len], t4_ntp_ms)?;

        // Compute delay/offset as RFC
        // Convert to signed i128 for safety
        let t1 = originate as i128; // originate from packet
        let t2 = receive as i128;
        let t3 = transmit as i128;
        let t4 = destination as i128;

        let (delay_ms, offset_ms) = compute_delay_offset(t1, t2, t3, t4);

        // Print server time and statistics
        // Convert server transmit (t3) to unix time for printing
        let server_t3_unix_ms = (t3 as i128) - (NTP_UNIX_OFFSET_SECS as i128 * 1000);
        let server_t3_unix_ms = server_t3_unix_ms as i64;
        let secs = server_t3_unix_ms / 1000;
        let millis = (server_t3_unix_ms % 1000).abs();

        let naive = NaiveDateTime::from_timestamp_opt(secs as i64, (millis as u32) * 1_000_000)
            .unwrap_or_else(|| NaiveDateTime::from_timestamp(0, 0));
        let datetime = chrono::DateTime::<Utc>::from_utc(naive, Utc);

        println!("NTP server: {}", opt.server);
        println!("server transmit time (T3): {} ({} ms)", datetime, millis);
        println!("round-trip delay: {:.3} ms", delay_ms);
        println!("local clock offset: {:.3} ms", offset_ms);

        // Keep best (smallest delay)
        let delay_i64 = delay_ms.round() as i64;
        let offset_i64 = offset_ms.round() as i64;
        if best_result.is_none() || delay_ms < best_result.unwrap().0 {
            best_result = Some((delay_ms, offset_ms, transmit as i64));
        }

        // If user wants set and we are root (or permitted) and offset exceeds threshold -> set
        if opt.set_time && offset_ms.abs() > opt.set_threshold_ms as f64 {
            // compute target system time = now + offset
            let now = SystemTime::now();
            // offset_ms is (T2 - T1 + T3 - T4)/2 in ms; this is what local clock should be adjusted by (+ offset means local clock behind server)
            let offset_duration = if offset_ms >= 0.0 {
                Duration::from_millis(offset_ms.round() as u64)
            } else {
                Duration::from_millis((-offset_ms).round() as u64)
            };

            let target_time = if offset_ms >= 0.0 {
                now + offset_duration
            } else {
                now - offset_duration
            };

            println!(
                "Attempting to set system time by applying offset {:.3} ms (threshold {}).",
                offset_ms, opt.set_threshold_ms
            );

            match set_system_time(target_time) {
                Ok(()) => {
                    println!("System time adjusted successfully.");
                }
                Err(e) => {
                    eprintln!("Failed to set system time: {}", e);
                }
            }
        }

        // break after first successful reply; user can re-run for more samples if desired
        break;
    }

    if let Some((delay, offset, _tx)) = best_result {
        println!("best sample -> delay {:.3} ms, offset {:.3} ms", delay, offset);
    }

    Ok(())
}
