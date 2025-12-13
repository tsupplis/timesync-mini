/*
 * TimeSync.java - Simple SNTP client in Java
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

import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.SocketTimeoutException;
import java.net.UnknownHostException;
import java.nio.ByteBuffer;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;

import com.sun.jna.Library;
import com.sun.jna.Native;
import com.sun.jna.Structure;
import com.sun.jna.Pointer;

public class TimeSync {
    // JNA interface to C library functions
    public interface CLibrary extends Library {
        CLibrary INSTANCE = Native.load("c", CLibrary.class);
        
        int getuid();
        int settimeofday(Timeval tv, Pointer tz);
    }
    
    @Structure.FieldOrder({"tv_sec", "tv_usec"})
    public static class Timeval extends Structure {
        public long tv_sec;
        public long tv_usec;
        
        public Timeval() {}
        
        public Timeval(long tv_sec, long tv_usec) {
            this.tv_sec = tv_sec;
            this.tv_usec = tv_usec;
        }
    }
    
    private static final int NTP_PORT = 123;
    private static final int NTP_PACKET_SIZE = 48;
    private static final long NTP_UNIX_EPOCH = 2208988800L;
    private static final int DEFAULT_TIMEOUT_MS = 2000;
    private static final int DEFAULT_RETRIES = 3;
    private static final String DEFAULT_SERVER = "pool.ntp.org";
    
    private static final DateTimeFormatter LOG_FORMAT = 
        DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");

    private static class Config {
        String server = DEFAULT_SERVER;
        int timeoutMs = DEFAULT_TIMEOUT_MS;
        int retries = DEFAULT_RETRIES;
        boolean verbose = false;
        boolean testOnly = false;
        boolean useSyslog = false;
    }

    private static class NtpResult {
        long localBefore;
        long localAfter;
        long remoteMs;

        NtpResult(long localBefore, long localAfter, long remoteMs) {
            this.localBefore = localBefore;
            this.localAfter = localAfter;
            this.remoteMs = remoteMs;
        }
    }

    private static void showUsage() {
        System.out.println("Usage: timesync [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp server]");
        System.out.println("  server       NTP server to query (default: pool.ntp.org)");
        System.out.println("  -t timeout   Timeout in ms (default: 2000)");
        System.out.println("  -r retries   Number of retries (default: 3)");
        System.out.println("  -n           Test mode (no system time adjustment)");
        System.out.println("  -v           Verbose output");
        System.out.println("  -s           Enable syslog logging");
        System.out.println("  -h           Show this help message");
    }

    private static void logStderr(String format, Object... args) {
        String timestamp = LocalDateTime.now().format(LOG_FORMAT);
        System.err.printf("%s %s%n", timestamp, String.format(format, args));
    }

    private static int clamp(int val, int min, int max) {
        return Math.max(min, Math.min(max, val));
    }
    
    private static boolean isRoot() {
        try {
            return CLibrary.INSTANCE.getuid() == 0;
        } catch (UnsatisfiedLinkError e) {
            // JNA not available, assume not root
            return false;
        }
    }
    
    private static boolean setSystemTime(long remoteMs) {
        try {
            long sec = remoteMs / 1000;
            long usec = (remoteMs % 1000) * 1000;
            
            Timeval tv = new Timeval(sec, usec);
            int result = CLibrary.INSTANCE.settimeofday(tv, null);
            
            return result == 0;
        } catch (UnsatisfiedLinkError e) {
            // JNA not available
            logStderr("ERROR JNA library not available for time setting");
            return false;
        }
    }

    private static Config parseArgs(String[] args) {
        Config config = new Config();
        
        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            
            if (arg.equals("-h")) {
                showUsage();
                System.exit(0);
            } else if (arg.equals("-t") && i + 1 < args.length) {
                try {
                    config.timeoutMs = clamp(Integer.parseInt(args[++i]), 1, 6000);
                } catch (NumberFormatException e) {
                    // Skip invalid values
                }
            } else if (arg.equals("-r") && i + 1 < args.length) {
                try {
                    config.retries = clamp(Integer.parseInt(args[++i]), 1, 10);
                } catch (NumberFormatException e) {
                    // Skip invalid values
                }
            } else if (arg.startsWith("-") && !arg.equals("-h") && !arg.equals("-t") && !arg.equals("-r")) {
                // Handle combined flags like -nv
                for (int j = 1; j < arg.length(); j++) {
                    char flag = arg.charAt(j);
                    switch (flag) {
                        case 'h':
                            showUsage();
                            System.exit(0);
                            break;
                        case 'n':
                            config.testOnly = true;
                            break;
                        case 'v':
                            config.verbose = true;
                            break;
                        case 's':
                            config.useSyslog = true;
                            break;
                    }
                }
            } else if (!arg.startsWith("-")) {
                config.server = arg;
            }
        }
        
        return config;
    }

    private static long getTimeMs() {
        return System.currentTimeMillis();
    }

    private static byte[] buildNtpRequest() {
        byte[] packet = new byte[NTP_PACKET_SIZE];
        packet[0] = 0x1b; // LI = 0, Version = 3, Mode = 3 (client)
        return packet;
    }

    private static NtpResult handleResponse(byte[] response, long localBefore, long localAfter) {
        if (response.length < NTP_PACKET_SIZE) {
            throw new IllegalArgumentException("Short packet");
        }

        int mode = response[0] & 0x07;
        if (mode != 4) {
            throw new IllegalArgumentException("Invalid mode");
        }

        // Extract transmit timestamp (bytes 40-47)
        ByteBuffer bb = ByteBuffer.wrap(response, 40, 8);
        long ntpSec = bb.getInt() & 0xFFFFFFFFL;
        long ntpFrac = bb.getInt() & 0xFFFFFFFFL;

        if (ntpSec < NTP_UNIX_EPOCH) {
            throw new IllegalArgumentException("Invalid NTP timestamp");
        }

        long unixSec = ntpSec - NTP_UNIX_EPOCH;
        long unixMs = (ntpFrac * 1000L) / 0x100000000L;
        long remoteMs = unixSec * 1000L + unixMs;

        return new NtpResult(localBefore, localAfter, remoteMs);
    }

    private static NtpResult queryNtpServer(String hostname, Config config) throws IOException {
        InetAddress address;
        try {
            address = InetAddress.getByName(hostname);
        } catch (UnknownHostException e) {
            throw new IOException("Cannot resolve hostname: " + hostname);
        }

        try (DatagramSocket socket = new DatagramSocket()) {
            socket.setSoTimeout(config.timeoutMs);

            byte[] requestPacket = buildNtpRequest();
            DatagramPacket request = new DatagramPacket(
                requestPacket, requestPacket.length, address, NTP_PORT);

            long localBefore = getTimeMs();
            socket.send(request);

            byte[] responseBuffer = new byte[NTP_PACKET_SIZE];
            DatagramPacket response = new DatagramPacket(responseBuffer, responseBuffer.length);
            
            try {
                socket.receive(response);
            } catch (SocketTimeoutException e) {
                throw new IOException("Timeout");
            }

            long localAfter = getTimeMs();

            return handleResponse(responseBuffer, localBefore, localAfter);
        }
    }

    private static int handleNtpResult(NtpResult result, Config config, String ipStr) {
        long avgLocal = (result.localBefore + result.localAfter) / 2;
        long offset = result.remoteMs - avgLocal;
        long rtt = result.localAfter - result.localBefore;

        if (config.verbose) {
            logStderr("DEBUG Server: %s (%s)", config.server, ipStr);
            logStderr("DEBUG Local before(ms): %d", result.localBefore);
            logStderr("DEBUG Local after(ms): %d", result.localAfter);
            logStderr("DEBUG Remote time(ms): %d", result.remoteMs);
            logStderr("DEBUG Estimated roundtrip(ms): %d", rtt);
            logStderr("DEBUG Estimated offset remote - local(ms): %d", offset);
        }

        if (rtt < 0 || rtt > 10000) {
            logStderr("ERROR Invalid roundtrip time: %d ms", rtt);
            return 1;
        }

        long absOffset = Math.abs(offset);
        if (absOffset > 0 && absOffset < 500) {
            if (config.verbose) {
                logStderr("INFO Delta < 500ms, not setting system time.");
            }
            return 0;
        }

        return validateAndSetTime(result.remoteMs, offset, config);
    }

    private static int validateAndSetTime(long remoteMs, long offset, Config config) {
        long remoteSec = remoteMs / 1000;
        Instant instant = Instant.ofEpochSecond(remoteSec);
        int remoteYear = LocalDateTime.ofInstant(instant, ZoneId.systemDefault()).getYear();

        if (remoteYear < 2025 || remoteYear > 2200) {
            logStderr("ERROR Remote year is out of valid range (2025-2200): %d", remoteYear);
            return 1;
        }

        if (config.testOnly) {
            if (config.verbose) {
                logStderr("INFO Test mode: would adjust system time by %d ms", offset);
            }
            return 0;
        }

        // Check root privileges
        if (!isRoot()) {
            logStderr("ERROR Must run as root to set system time");
            return 3;
        }

        // Set system time
        if (setSystemTime(remoteMs)) {
            if (config.verbose) {
                logStderr("INFO System time adjusted by %d ms", offset);
            }
            return 0;
        } else {
            logStderr("ERROR Failed to set system time");
            return 10;
        }
    }

    private static int doNtpAttempt(Config config, int attempt) {
        if (config.verbose) {
            logStderr("DEBUG Attempt (%d) at NTP query on %s ...", attempt, config.server);
        }

        try {
            NtpResult result = queryNtpServer(config.server, config);
            
            // Get IP address for display
            String ipStr;
            try {
                InetAddress addr = InetAddress.getByName(config.server);
                ipStr = addr.getHostAddress();
            } catch (UnknownHostException e) {
                ipStr = config.server;
            }

            return handleNtpResult(result, config, ipStr);
        } catch (IOException e) {
            String message = e.getMessage();
            
            if ("Timeout".equals(message)) {
                if (attempt < config.retries) {
                    try {
                        Thread.sleep(200);
                    } catch (InterruptedException ie) {
                        Thread.currentThread().interrupt();
                    }
                    return doNtpAttempt(config, attempt + 1);
                } else {
                    logStderr("ERROR Timeout waiting for NTP response");
                    return 2;
                }
            } else {
                logStderr("ERROR %s", message);
                return 2;
            }
        } catch (IllegalArgumentException e) {
            logStderr("ERROR %s", e.getMessage());
            return 2;
        }
    }

    private static int doNtpQuery(Config config) {
        return doNtpAttempt(config, 1);
    }

    public static void main(String[] args) {
        Config config = parseArgs(args);

        // Disable syslog in test mode
        if (config.testOnly) {
            config.useSyslog = false;
        }

        if (config.verbose) {
            logStderr("DEBUG Using server: %s", config.server);
            logStderr("DEBUG Timeout: %d ms, Retries: %d, Syslog: %s",
                config.timeoutMs, config.retries, config.useSyslog ? "on" : "off");
        }

        int exitCode = doNtpQuery(config);
        System.exit(exitCode);
    }
}
