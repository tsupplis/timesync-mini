/*
 * TimeSync.cs - Minimal SNTP client (RFC 5905 subset)
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
 * C# port of the C implementation.
 *
 * Build:
 *   dotnet build -c Release timesync.csproj
 *
 * Usage:
 *   ./timesync                    # query pool.ntp.org
 *   ./timesync -t 1500 -r 2 -s -v time.google.com
 */

using System;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace TimeSync
{
    class Program
    {
        // ── Constants ────────────────────────────────────────────────────────

        const int    NTP_PORT         = 123;
        const int    NTP_PACKET_SIZE  = 48;
        const long   NTP_UNIX_EPOCH   = 2208988800L;
        const int    DEFAULT_TIMEOUT_MS = 2000;
        const int    DEFAULT_RETRIES    = 3;
        const string DEFAULT_SERVER     = "pool.ntp.org";

        // ── syslog constants (POSIX) ─────────────────────────────────────────

        const int LOG_PID     = 0x01;
        const int LOG_CONS    = 0x02;
        const int LOG_USER    = 1 << 3;
        const int LOG_ERR     = 3;
        const int LOG_WARNING = 4;
        const int LOG_INFO    = 6;

        // ── P/Invoke ─────────────────────────────────────────────────────────

        [DllImport("libc", SetLastError = true)]
        static extern uint geteuid();

        [DllImport("libc", SetLastError = true)]
        static extern void openlog(string ident, int option, int facility);

        [DllImport("libc", SetLastError = true)]
        static extern void syslog(int priority, string message);

        [DllImport("libc", SetLastError = true)]
        static extern void closelog();

        [DllImport("libc", SetLastError = true)]
        static extern int strerror_r(int errnum, byte[] buf, nuint buflen);

        // struct timespec is identical on macOS and Linux: { long, long } = 16 bytes.
        // Preferred over struct timeval whose tv_usec width differs (int on macOS, long on Linux).
        [StructLayout(LayoutKind.Sequential)]
        struct Timespec
        {
            public long tv_sec;
            public long tv_nsec;
        }

        [DllImport("libc", SetLastError = true)]
        static extern int clock_settime(int clockId, ref Timespec ts);

        // ── Config ───────────────────────────────────────────────────────────

        class Config
        {
            public string Server     = DEFAULT_SERVER;
            public int    TimeoutMs  = DEFAULT_TIMEOUT_MS;
            public int    Retries    = DEFAULT_RETRIES;
            public bool   Verbose    = false;
            public bool   TestOnly   = false;
            public bool   UseSyslog  = false;
        }

        // ── NtpResponse ──────────────────────────────────────────────────────

        class NtpResponse
        {
            public long   LocalBeforeMs;
            public long   LocalAfterMs;
            public long   RemoteMs;
            public string ServerAddr;

            public NtpResponse(long localBefore, long localAfter, long remoteMs, string serverAddr)
            {
                LocalBeforeMs = localBefore;
                LocalAfterMs  = localAfter;
                RemoteMs      = remoteMs;
                ServerAddr    = serverAddr;
            }
        }

        // ── Logging ──────────────────────────────────────────────────────────

        /// <summary>Log to stderr with timestamp — matches C's stderr_log format.</summary>
        static void StderrLog(string message)
        {
            string ts = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
            Console.Error.WriteLine($"{ts} {message}");
        }

        static void SyslogWrite(int priority, string message)
        {
            syslog(priority, message);
        }

        // ── Usage ────────────────────────────────────────────────────────────

        static void ShowUsage(string prog = null)
        {
            // Output to stderr, matching C's fprintf(stderr, ...) usage()
            Console.Error.WriteLine($"Usage: {prog} [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp server]");
            Console.Error.WriteLine("  server       NTP server to query (default: pool.ntp.org)");
            Console.Error.WriteLine("  -t timeout   Timeout in ms (default: 2000)");
            Console.Error.WriteLine("  -r retries   Number of retries (default: 3)");
            Console.Error.WriteLine("  -n           Test mode (no system time adjustment)");
            Console.Error.WriteLine("  -v           Verbose output");
            Console.Error.WriteLine("  -s           Enable syslog logging");
            Console.Error.WriteLine("  -h           Show this help message");
            Environment.Exit(0);
        }

        // ── Argument parsing ─────────────────────────────────────────────────

        static Config ParseArgs(string[] args)
        {
            Config config = new Config();

            for (int i = 0; i < args.Length; i++)
            {
                string arg = args[i];
                switch (arg)
                {
                    case "-h":
                        ShowUsage(AppDomain.CurrentDomain.FriendlyName);
                        break;
                    case "-t":
                        if (i + 1 < args.Length && int.TryParse(args[++i], out int t))
                        {
                            // invalid/0 resets to default, >6000 clamps — matches C
                            if      (t <= 0)   config.TimeoutMs = DEFAULT_TIMEOUT_MS;
                            else if (t > 6000) config.TimeoutMs = 6000;
                            else               config.TimeoutMs = t;
                        }
                        break;
                    case "-r":
                        if (i + 1 < args.Length && int.TryParse(args[++i], out int r))
                        {
                            // invalid/0 resets to default, >10 clamps — matches C
                            if      (r <= 0)  config.Retries = DEFAULT_RETRIES;
                            else if (r > 10)  config.Retries = 10;
                            else              config.Retries = r;
                        }
                        break;
                    case "-n": config.TestOnly  = true; break;
                    case "-v": config.Verbose   = true; break;
                    case "-s": config.UseSyslog = true; break;
                    default:
                        if (!arg.StartsWith("-")) config.Server = arg;
                        // unknown flags silently ignored — matches C
                        break;
                }
            }

            if (config.TestOnly) config.UseSyslog = false;
            return config;
        }

        // ── Time helpers ─────────────────────────────────────────────────────

        static long GetTimeMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

        /// <summary>Format ms-since-epoch as local ISO string — matches C's %Y-%m-%dT%H:%M:%S%z.</summary>
        static string FormatTime(long ms)
        {
            DateTimeOffset dt = DateTimeOffset.FromUnixTimeMilliseconds(ms).ToLocalTime();
            // %z in C produces "+0100" (no colon); "zzz" in .NET produces "+01:00".
            // Use custom format to strip the colon, matching C output exactly.
            string tz = dt.ToString("zzz").Replace(":", "");
            return $"{dt:yyyy-MM-ddTHH:mm:ss}{tz}.{ms % 1000:D3}";
        }

        // ── Errno helper ─────────────────────────────────────────────────────

        static string StrError(int errno)
        {
            byte[] buf = new byte[256];
            strerror_r(errno, buf, (nuint)buf.Length);
            int len = Array.IndexOf(buf, (byte)0);
            return Encoding.UTF8.GetString(buf, 0, len < 0 ? buf.Length : len);
        }

        // ── NTP protocol ─────────────────────────────────────────────────────

        /// <summary>Build 48-byte NTP request — LI=0, VN=4, Mode=3 → 0x23, matching C.</summary>
        static byte[] BuildNtpRequest()
        {
            byte[] packet = new byte[NTP_PACKET_SIZE];
            packet[0] = 0x23;
            return packet;
        }

        static long? NtpTsToUnixMs(byte[] buf, int offset)
        {
            if (buf.Length < offset + 8) return null;
            uint sec  = (uint)IPAddress.NetworkToHostOrder(BitConverter.ToInt32(buf, offset));
            uint frac = (uint)IPAddress.NetworkToHostOrder(BitConverter.ToInt32(buf, offset + 4));
            if (sec < NTP_UNIX_EPOCH) return null;
            long unixSec = sec - NTP_UNIX_EPOCH;
            long usec    = ((long)frac * 1_000_000L) >> 32;
            return unixSec * 1000L + usec / 1000L;
        }

        // ── NTP query (single attempt) ────────────────────────────────────────

        /// <summary>
        /// Single NTP query attempt. Returns NtpResponse on success, null on any failure.
        /// Per-address validation warnings are logged here, matching C's do_ntp_query().
        /// </summary>
        static NtpResponse DoNtpQuery(string server, int timeoutMs)
        {
            IPAddress[] addresses;
            try   { addresses = Dns.GetHostAddresses(server); }
            catch { return null; }

            foreach (IPAddress address in addresses)
            {
                using UdpClient client = new UdpClient(address.AddressFamily);
                try
                {
                    client.Client.ReceiveTimeout = timeoutMs;
                }
                catch (SocketException ex)
                {
                    StderrLog($"WARNING setsockopt SO_RCVTIMEO failed: {ex.Message}");
                    continue;
                }

                IPEndPoint endPoint = new IPEndPoint(address, NTP_PORT);
                byte[] packet = BuildNtpRequest();

                long localBefore = GetTimeMs();
                try   { client.Send(packet, packet.Length, endPoint); }
                catch { StderrLog("WARNING Failed to send NTP request"); continue; }

                byte[] response;
                IPEndPoint remote = new IPEndPoint(IPAddress.Any, 0);
                long localAfter;
                try
                {
                    response   = client.Receive(ref remote);
                    localAfter = GetTimeMs();
                }
                catch { continue; }

                if (response.Length < NTP_PACKET_SIZE) continue;

                int mode = response[0] & 0x07;
                if (mode != 4)
                {
                    StderrLog($"WARNING Invalid mode in NTP response: {mode}");
                    continue;
                }

                int stratum = response[1];
                if (stratum == 0)
                {
                    StderrLog($"WARNING Invalid stratum in NTP response: {stratum}");
                    continue;
                }

                int version = (response[0] >> 3) & 0x07;
                if (version < 1 || version > 4)
                {
                    StderrLog($"WARNING Invalid version in NTP response: {version}");
                    continue;
                }

                long? remoteMs = NtpTsToUnixMs(response, 40);
                if (remoteMs == null)
                {
                    StderrLog("WARNING Invalid transmit timestamp in NTP response");
                    continue;
                }

                return new NtpResponse(localBefore, localAfter, remoteMs.Value, address.ToString());
            }

            return null;
        }

        // ── Set system time ───────────────────────────────────────────────────

        static bool SetSystemTime(long ms, out int errnoOut)
        {
            const int CLOCK_REALTIME = 0;
            Timespec ts = new Timespec { tv_sec = ms / 1000, tv_nsec = (ms % 1000) * 1_000_000 };
            int rc = clock_settime(CLOCK_REALTIME, ref ts);
            errnoOut = rc == 0 ? 0 : Marshal.GetLastPInvokeError();
            return rc == 0;
        }

        // ── Main logic ────────────────────────────────────────────────────────

        static int Run(Config config)
        {
            // Verbose debug fires before syslog is opened — matching C
            if (config.Verbose)
            {
                StderrLog($"DEBUG Using server: {config.Server}");
                StderrLog($"DEBUG Timeout: {config.TimeoutMs} ms, Retries: {config.Retries}, Syslog: {(config.UseSyslog ? "on" : "off")}");
            }

            if (config.UseSyslog)
            {
                openlog("ntp_client", LOG_PID | LOG_CONS, LOG_USER);
                AppDomain.CurrentDomain.ProcessExit += (_, _) => closelog();
            }

            NtpResponse resp = null;
            for (int attempt = 0; attempt < config.Retries; attempt++)
            {
                if (config.Verbose)
                    StderrLog($"DEBUG Attempt ({attempt + 1}) at NTP query on {config.Server} ...");

                resp = DoNtpQuery(config.Server, config.TimeoutMs);
                if (resp != null) break;

                // Backoff fires on every failure including after last — matches C
                Thread.Sleep(200);
            }

            if (resp == null)
            {
                StderrLog($"ERROR Failed to contact NTP server {config.Server} after {config.Retries} attempts");
                if (config.UseSyslog)
                    SyslogWrite(LOG_ERR, $"NTP query failed for {config.Server} after {config.Retries} attempts");
                return 2;
            }

            // Overflow guard on avg calculation — matches C's INT64_MAX check
            if (resp.LocalBeforeMs > long.MaxValue - resp.LocalAfterMs)
            {
                StderrLog("ERROR Time averaging would overflow, invalid timestamps.");
                if (config.UseSyslog) SyslogWrite(LOG_ERR, "Time averaging would overflow");
                return 1;
            }
            long avgLocalMs  = (resp.LocalBeforeMs + resp.LocalAfterMs) / 2;
            long offsetMs    = resp.RemoteMs - avgLocalMs;
            long roundtripMs = resp.LocalAfterMs - resp.LocalBeforeMs;

            // Parse remote time unconditionally before verbose block — matches C's execution order
            string remoteTimeStr = FormatTime(resp.RemoteMs);
            int remoteYear = DateTimeOffset.FromUnixTimeMilliseconds(resp.RemoteMs).ToLocalTime().Year;

            if (config.Verbose)
            {
                StderrLog($"DEBUG Server: {config.Server} ({resp.ServerAddr})");
                // local time: date from LocalBeforeMs, ms suffix from LocalAfterMs — matches C
                string localBase  = DateTimeOffset.FromUnixTimeMilliseconds(resp.LocalBeforeMs).ToLocalTime()
                                        .ToString("yyyy-MM-ddTHH:mm:ss");
                string localTz    = DateTimeOffset.FromUnixTimeMilliseconds(resp.LocalBeforeMs).ToLocalTime()
                                        .ToString("zzz").Replace(":", "");
                string localTimeStr = $"{localBase}{localTz}.{resp.LocalAfterMs % 1000:D3}";
                StderrLog($"DEBUG Local time: {localTimeStr}");
                StderrLog($"DEBUG Remote time: {remoteTimeStr}");
                StderrLog($"DEBUG Local before(ms): {resp.LocalBeforeMs}");
                StderrLog($"DEBUG Local after(ms): {resp.LocalAfterMs}");
                StderrLog($"DEBUG Estimated roundtrip(ms): {roundtripMs}");
                StderrLog($"DEBUG Estimated offset remote - local(ms): {offsetMs}");
                if (config.UseSyslog)
                    SyslogWrite(LOG_INFO, $"NTP server={config.Server} addr={resp.ServerAddr} offset_ms={offsetMs} rtt_ms={roundtripMs}");
            }

            // Roundtrip sanity check
            if (roundtripMs < 0 || roundtripMs > 10000)
            {
                StderrLog($"ERROR Invalid roundtrip time: {roundtripMs} ms");
                if (config.UseSyslog)
                    SyslogWrite(LOG_ERR, $"Invalid suspiciously long roundtrip time: {roundtripMs} ms");
                return 1;
            }

            // Delta < 500ms: skip adjustment
            if (Math.Abs(offsetMs) > 0 && Math.Abs(offsetMs) < 500)
            {
                if (config.Verbose)
                {
                    StderrLog("INFO Delta < 500ms, not setting system time.");
                    if (config.UseSyslog) SyslogWrite(LOG_INFO, "Delta < 500ms, not setting system time");
                }
                return 0;
            }

            // Year range check
            if (remoteYear < 2025 || remoteYear > 2200)
            {
                StderrLog($"ERROR Remote year is out of valid range (2025-2200): {remoteYear}");
                if (config.UseSyslog)
                    SyslogWrite(LOG_ERR, $"Remote year is out of valid range (2025-2200): {remoteYear}");
                return 1;
            }

            if (config.TestOnly) return 0;

            // Root check — WARNING + exit 0, matching C
            if (geteuid() != 0)
            {
                StderrLog("WARNING Not root, not setting system time.");
                if (config.UseSyslog) SyslogWrite(LOG_WARNING, "Not root, not setting system time");
                return 0;
            }

            // Overflow guard on remote_ms + half_rtt — matches C's INT64_MAX check
            long halfRtt = roundtripMs / 2;
            if (resp.RemoteMs > long.MaxValue - halfRtt)
            {
                StderrLog("ERROR Time calculation would overflow, not adjusting system time.");
                if (config.UseSyslog) SyslogWrite(LOG_ERR, "Time calculation would overflow");
                return 1;
            }
            long newTimeMs = resp.RemoteMs + halfRtt;

            const string api = "clock_settime";
            if (SetSystemTime(newTimeMs, out int errno))
            {
                StderrLog($"INFO System time set using {api} ({remoteTimeStr})");
                if (config.UseSyslog) SyslogWrite(LOG_INFO, $"System time set using {api} ({remoteTimeStr})");
                return 0;
            }
            else
            {
                string errStr = StrError(errno);
                StderrLog($"ERROR Failed to adjust system time with {api}: {errStr}");
                if (config.UseSyslog) SyslogWrite(LOG_ERR, $"Failed to adjust system time with {api}: {errStr}");
                return 10;
            }
        }

        // ── Entry point ───────────────────────────────────────────────────────

        static int Main(string[] args)
        {
            Config config = ParseArgs(args);
            return Run(config);
        }
    }
}
