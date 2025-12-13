/*
 * TimeSync.cs - Simple SNTP client in C#
 *
 * Copyright (c) 2025 Thierry Supplis
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
 */

using System;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace TimeSync
{
    class Program
    {
        const int NTP_PORT = 123;
        const int NTP_PACKET_SIZE = 48;
        const long NTP_UNIX_EPOCH = 2208988800L;
        const int DEFAULT_TIMEOUT_MS = 2000;
        const int DEFAULT_RETRIES = 3;
        const string DEFAULT_SERVER = "pool.ntp.org";

        // P/Invoke for Unix system calls
        [DllImport("libc", SetLastError = true)]
        private static extern uint geteuid();

        [StructLayout(LayoutKind.Sequential)]
        private struct Timeval
        {
            public long tv_sec;
            public long tv_usec;
        }

        [DllImport("libc", SetLastError = true)]
        private static extern int settimeofday(ref Timeval tv, IntPtr tz);

        class Config
        {
            public string Server = DEFAULT_SERVER;
            public int TimeoutMs = DEFAULT_TIMEOUT_MS;
            public int Retries = DEFAULT_RETRIES;
            public bool Verbose = false;
            public bool TestOnly = false;
            public bool UseSyslog = false;
        }

        class NtpResult
        {
            public long LocalBefore;
            public long LocalAfter;
            public long RemoteMs;

            public NtpResult(long localBefore, long localAfter, long remoteMs)
            {
                LocalBefore = localBefore;
                LocalAfter = localAfter;
                RemoteMs = remoteMs;
            }
        }

        static void ShowUsage()
        {
            Console.WriteLine("Usage: timesync [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp server]");
            Console.WriteLine("  server       NTP server to query (default: pool.ntp.org)");
            Console.WriteLine("  -t timeout   Timeout in ms (default: 2000)");
            Console.WriteLine("  -r retries   Number of retries (default: 3)");
            Console.WriteLine("  -n           Test mode (no system time adjustment)");
            Console.WriteLine("  -v           Verbose output");
            Console.WriteLine("  -s           Enable syslog logging");
            Console.WriteLine("  -h           Show this help message");
        }

        static void LogStderr(string format, params object[] args)
        {
            string timestamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
            Console.Error.WriteLine($"{timestamp} {string.Format(format, args)}");
        }

        static int Clamp(int val, int min, int max)
        {
            return Math.Max(min, Math.Min(max, val));
        }

        static bool IsRoot()
        {
            try
            {
                // On Unix/Linux/macOS
                if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux) ||
                    RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
                {
                    return geteuid() == 0;
                }
                // On Windows, always return false (not implemented)
                return false;
            }
            catch
            {
                return false;
            }
        }

        static bool SetSystemTime(long remoteMs)
        {
            try
            {
                if (!RuntimeInformation.IsOSPlatform(OSPlatform.Linux) &&
                    !RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
                {
                    LogStderr("ERROR Time setting not supported on this platform");
                    return false;
                }

                long sec = remoteMs / 1000;
                long usec = (remoteMs % 1000) * 1000;

                Timeval tv = new Timeval { tv_sec = sec, tv_usec = usec };
                int result = settimeofday(ref tv, IntPtr.Zero);

                return result == 0;
            }
            catch (Exception ex)
            {
                LogStderr($"ERROR Failed to set system time: {ex.Message}");
                return false;
            }
        }

        static Config ParseArgs(string[] args)
        {
            Config config = new Config();

            for (int i = 0; i < args.Length; i++)
            {
                string arg = args[i];

                if (arg == "-h")
                {
                    ShowUsage();
                    Environment.Exit(0);
                }
                else if (arg == "-t" && i + 1 < args.Length)
                {
                    if (int.TryParse(args[++i], out int timeout))
                    {
                        config.TimeoutMs = Clamp(timeout, 1, 6000);
                    }
                }
                else if (arg == "-r" && i + 1 < args.Length)
                {
                    if (int.TryParse(args[++i], out int retries))
                    {
                        config.Retries = Clamp(retries, 1, 10);
                    }
                }
                else if (arg.StartsWith("-") && arg != "-h" && arg != "-t" && arg != "-r")
                {
                    // Handle combined flags like -nv
                    foreach (char flag in arg.Substring(1))
                    {
                        switch (flag)
                        {
                            case 'h':
                                ShowUsage();
                                Environment.Exit(0);
                                break;
                            case 'n':
                                config.TestOnly = true;
                                break;
                            case 'v':
                                config.Verbose = true;
                                break;
                            case 's':
                                config.UseSyslog = true;
                                break;
                        }
                    }
                }
                else if (!arg.StartsWith("-"))
                {
                    config.Server = arg;
                }
            }

            return config;
        }

        static long GetTimeMs()
        {
            return DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        }

        static byte[] BuildNtpRequest()
        {
            byte[] packet = new byte[NTP_PACKET_SIZE];
            packet[0] = 0x1b; // LI = 0, Version = 3, Mode = 3 (client)
            return packet;
        }

        static NtpResult HandleResponse(byte[] response, long localBefore, long localAfter)
        {
            if (response.Length < NTP_PACKET_SIZE)
            {
                throw new ArgumentException("Short packet");
            }

            int mode = response[0] & 0x07;
            if (mode != 4)
            {
                throw new ArgumentException("Invalid mode");
            }

            // Extract transmit timestamp (bytes 40-47)
            uint ntpSec = (uint)IPAddress.NetworkToHostOrder(BitConverter.ToInt32(response, 40));
            uint ntpFrac = (uint)IPAddress.NetworkToHostOrder(BitConverter.ToInt32(response, 44));

            if (ntpSec < NTP_UNIX_EPOCH)
            {
                throw new ArgumentException("Invalid NTP timestamp");
            }

            long unixSec = ntpSec - NTP_UNIX_EPOCH;
            long unixMs = (ntpFrac * 1000L) / 0x100000000L;
            long remoteMs = unixSec * 1000L + unixMs;

            return new NtpResult(localBefore, localAfter, remoteMs);
        }

        static NtpResult QueryNtpServer(string hostname, Config config)
        {
            IPAddress[] addresses = Dns.GetHostAddresses(hostname);
            if (addresses.Length == 0)
            {
                throw new Exception($"Cannot resolve hostname: {hostname}");
            }

            IPAddress address = addresses[0];
            IPEndPoint endPoint = new IPEndPoint(address, NTP_PORT);

            using (UdpClient client = new UdpClient())
            {
                client.Client.ReceiveTimeout = config.TimeoutMs;

                byte[] requestPacket = BuildNtpRequest();

                long localBefore = GetTimeMs();
                client.Send(requestPacket, requestPacket.Length, endPoint);

                byte[] responseBuffer;
                try
                {
                    responseBuffer = client.Receive(ref endPoint);
                }
                catch (SocketException)
                {
                    throw new Exception("Timeout");
                }

                long localAfter = GetTimeMs();

                return HandleResponse(responseBuffer, localBefore, localAfter);
            }
        }

        static int HandleNtpResult(NtpResult result, Config config, string ipStr)
        {
            long avgLocal = (result.LocalBefore + result.LocalAfter) / 2;
            long offset = result.RemoteMs - avgLocal;
            long rtt = result.LocalAfter - result.LocalBefore;

            if (config.Verbose)
            {
                LogStderr($"DEBUG Server: {config.Server} ({ipStr})");
                LogStderr($"DEBUG Local before(ms): {result.LocalBefore}");
                LogStderr($"DEBUG Local after(ms): {result.LocalAfter}");
                LogStderr($"DEBUG Remote time(ms): {result.RemoteMs}");
                LogStderr($"DEBUG Estimated roundtrip(ms): {rtt}");
                LogStderr($"DEBUG Estimated offset remote - local(ms): {offset}");
            }

            if (rtt < 0 || rtt > 10000)
            {
                LogStderr($"ERROR Invalid roundtrip time: {rtt} ms");
                return 1;
            }

            long absOffset = Math.Abs(offset);
            if (absOffset > 0 && absOffset < 500)
            {
                if (config.Verbose)
                {
                    LogStderr("INFO Delta < 500ms, not setting system time.");
                }
                return 0;
            }

            return ValidateAndSetTime(result.RemoteMs, offset, config);
        }

        static int ValidateAndSetTime(long remoteMs, long offset, Config config)
        {
            long remoteSec = remoteMs / 1000;
            DateTime remoteTime = DateTimeOffset.FromUnixTimeSeconds(remoteSec).DateTime;
            int remoteYear = remoteTime.Year;

            if (remoteYear < 2025 || remoteYear > 2200)
            {
                LogStderr($"ERROR Remote year is out of valid range (2025-2200): {remoteYear}");
                return 1;
            }

            if (config.TestOnly)
            {
                if (config.Verbose)
                {
                    LogStderr($"INFO Test mode: would adjust system time by {offset} ms");
                }
                return 0;
            }

            // Check root privileges
            if (!IsRoot())
            {
                LogStderr("ERROR Must run as root to set system time");
                return 3;
            }

            // Set system time
            if (SetSystemTime(remoteMs))
            {
                if (config.Verbose)
                {
                    LogStderr($"INFO System time adjusted by {offset} ms");
                }
                return 0;
            }
            else
            {
                LogStderr("ERROR Failed to set system time");
                return 10;
            }
        }

        static int DoNtpAttempt(Config config, int attempt)
        {
            if (config.Verbose)
            {
                LogStderr($"DEBUG Attempt ({attempt}) at NTP query on {config.Server} ...");
            }

            try
            {
                NtpResult result = QueryNtpServer(config.Server, config);

                // Get IP address for display
                string ipStr;
                try
                {
                    IPAddress[] addresses = Dns.GetHostAddresses(config.Server);
                    ipStr = addresses[0].ToString();
                }
                catch
                {
                    ipStr = config.Server;
                }

                return HandleNtpResult(result, config, ipStr);
            }
            catch (Exception ex)
            {
                string message = ex.Message;

                if (message == "Timeout")
                {
                    if (attempt < config.Retries)
                    {
                        System.Threading.Thread.Sleep(200);
                        return DoNtpAttempt(config, attempt + 1);
                    }
                    else
                    {
                        LogStderr("ERROR Timeout waiting for NTP response");
                        return 2;
                    }
                }
                else
                {
                    LogStderr($"ERROR {message}");
                    return 2;
                }
            }
        }

        static int DoNtpQuery(Config config)
        {
            return DoNtpAttempt(config, 1);
        }

        static int Main(string[] args)
        {
            Config config = ParseArgs(args);

            // Disable syslog in test mode
            if (config.TestOnly)
            {
                config.UseSyslog = false;
            }

            if (config.Verbose)
            {
                LogStderr($"DEBUG Using server: {config.Server}");
                LogStderr($"DEBUG Timeout: {config.TimeoutMs} ms, Retries: {config.Retries}, Syslog: {(config.UseSyslog ? "on" : "off")}");
            }

            int exitCode = DoNtpQuery(config);
            return exitCode;
        }
    }
}
