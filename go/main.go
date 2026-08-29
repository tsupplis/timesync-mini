// timesync - Minimal SNTP client (RFC 5905 subset)
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

package main

import (
	"flag"
	"fmt"
	"log/syslog"
	"math"
	"net"
	"os"
	"time"

	"github.com/beevik/ntp"
)

// Config holds runtime settings parsed from CLI flags.
type Config struct {
	Server    string
	Verbose   bool
	Test      bool
	TimeoutMS int
	Retries   int
	UseSyslog bool
}

// stderrLog prints a timestamped line to stderr, matching C's stderr_log format:
//
//	YYYY-MM-DD HH:MM:SS <message>
func stderrLog(msg string) {
	fmt.Fprintf(os.Stderr, "%s %s\n", time.Now().Format("2006-01-02 15:04:05"), msg)
}

func parseConfig() *Config {
	cfg := &Config{
		TimeoutMS: 2000,
		Retries:   3,
		Server:    "pool.ntp.org",
	}
	showHelp := false

	fs := flag.NewFlagSet("timesync", flag.ExitOnError)
	fs.IntVar(&cfg.TimeoutMS, "t", 2000, "Timeout in ms (default: 2000)")
	fs.IntVar(&cfg.Retries, "r", 3, "Number of retries (default: 3)")
	fs.BoolVar(&cfg.Test, "n", false, "Test mode (no system time adjustment)")
	fs.BoolVar(&cfg.Verbose, "v", false, "Verbose output")
	fs.BoolVar(&cfg.UseSyslog, "s", false, "Enable syslog logging")
	fs.BoolVar(&showHelp, "h", false, "Show this help message")
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: %s [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp server]\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "  server       NTP server to query (default: pool.ntp.org)\n")
		fmt.Fprintf(os.Stderr, "  -t timeout   Timeout in ms (default: 2000)\n")
		fmt.Fprintf(os.Stderr, "  -r retries   Number of retries (default: 3)\n")
		fmt.Fprintf(os.Stderr, "  -n           Test mode (no system time adjustment)\n")
		fmt.Fprintf(os.Stderr, "  -v           Verbose output\n")
		fmt.Fprintf(os.Stderr, "  -s           Enable syslog logging\n")
		fmt.Fprintf(os.Stderr, "  -h           Show this help message\n")
	}
	fs.SetOutput(os.Stderr)
	fs.Parse(os.Args[1:])

	if showHelp {
		fs.Usage()
		os.Exit(0)
	}

	// Validate and clamp timeout — invalid/0 resets to default, matching C
	if cfg.TimeoutMS > 6000 {
		cfg.TimeoutMS = 6000
	}
	if cfg.TimeoutMS <= 0 {
		cfg.TimeoutMS = 2000
	}

	// Validate and clamp retries — invalid/0 resets to default, matching C
	if cfg.Retries > 10 {
		cfg.Retries = 10
	}
	if cfg.Retries <= 0 {
		cfg.Retries = 3
	}

	// Disable syslog in test mode
	if cfg.Test {
		cfg.UseSyslog = false
	}

	// Single positional server argument, matching C
	if args := fs.Args(); len(args) > 0 {
		cfg.Server = args[0]
	}

	return cfg
}

func main() {
	cfg := parseConfig()

	// Verbose debug fires before syslog is opened, matching C
	if cfg.Verbose {
		stderrLog(fmt.Sprintf("DEBUG Using server: %s", cfg.Server))
		syslogStr := "off"
		if cfg.UseSyslog {
			syslogStr = "on"
		}
		stderrLog(fmt.Sprintf("DEBUG Timeout: %d ms, Retries: %d, Syslog: %s",
			cfg.TimeoutMS, cfg.Retries, syslogStr))
	}

	var syslogWriter *syslog.Writer
	if cfg.UseSyslog {
		var err error
		syslogWriter, err = syslog.New(syslog.LOG_INFO|syslog.LOG_USER, "ntp_client")
		if err != nil {
			stderrLog(fmt.Sprintf("WARNING Failed to initialize syslog: %v", err))
			cfg.UseSyslog = false
		}
	}

	for attempt := 0; attempt < cfg.Retries; attempt++ {
		if cfg.Verbose {
			stderrLog(fmt.Sprintf("DEBUG Attempt (%d) at NTP query on %s ...", attempt+1, cfg.Server))
		}
		err := timeSync(cfg.Server, cfg, time.Duration(cfg.TimeoutMS)*time.Millisecond, syslogWriter)
		if err == nil {
			os.Exit(0)
		}
		// Small backoff before retry — always sleep after failure, including after last attempt
		// matching C's usleep(200000) which also fires after the final failed attempt
		time.Sleep(200 * time.Millisecond)
	}

	stderrLog(fmt.Sprintf("ERROR Failed to contact NTP server %s after %d attempts",
		cfg.Server, cfg.Retries))
	if syslogWriter != nil {
		syslogWriter.Err(fmt.Sprintf("NTP query failed for %s after %d attempts",
			cfg.Server, cfg.Retries))
	}
	os.Exit(2)
}

// timeSync queries the NTP server and optionally sets the system clock.
// Returns nil on success (including when no adjustment is needed),
// or an error that causes the retry loop to retry.
func timeSync(server string, cfg *Config, timeout time.Duration, syslogWriter *syslog.Writer) error {
	// Resolve server address — C's getaddrinfo is silent on failure, but we
	// have an explicit DNS step so log a meaningful message (fix A)
	ips, err := net.LookupIP(server)
	if err != nil {
		stderrLog(fmt.Sprintf("WARNING Failed to resolve %s: %v", server, err))
		return err
	}
	serverAddr := ips[0].String()

	// Capture local time before query, matching C's gettimeofday(&before)
	localBeforeMs := time.Now().UnixMilli()

	// Query NTP server
	options := ntp.QueryOptions{Timeout: timeout}
	response, err := ntp.QueryWithOptions(server, options)
	if err != nil {
		return err
	}

	// Capture local time after query, matching C's gettimeofday(&after)
	localAfterMs := time.Now().UnixMilli()

	// Remote transmit time with clock offset applied, converted to ms
	remoteMs := time.Now().Add(response.ClockOffset).UnixMilli()

	// Overflow guard on avg calculation, matching C's INT64_MAX check (fix C)
	if localBeforeMs > 0 && localAfterMs > math.MaxInt64-localBeforeMs {
		stderrLog("ERROR Time averaging would overflow, invalid timestamps.")
		if syslogWriter != nil {
			syslogWriter.Err("Time averaging would overflow")
		}
		os.Exit(1)
	}

	// SNTP offset and roundtrip, matching C's formula:
	//   offset = remote - (before + after) / 2
	//   roundtrip = after - before
	avgLocalMs := (localBeforeMs + localAfterMs) / 2
	offsetMs := remoteMs - avgLocalMs
	roundtripMs := localAfterMs - localBeforeMs

	// Parse remote time — fatal if it fails, matching C
	remoteTime := time.UnixMilli(remoteMs).Local()
	remoteTimeStr := fmt.Sprintf("%s.%03d", remoteTime.Format("2006-01-02T15:04:05-0700"), remoteMs%1000)

	if cfg.Verbose {
		stderrLog(fmt.Sprintf("DEBUG Server: %s (%s)", server, serverAddr))

		// Local time: date/time from localBeforeMs, ms suffix from localAfterMs — matching C
		localTime := time.UnixMilli(localBeforeMs).Local()
		localTimeStr := fmt.Sprintf("%s.%03d", localTime.Format("2006-01-02T15:04:05-0700"), localAfterMs%1000)
		stderrLog(fmt.Sprintf("DEBUG Local time: %s", localTimeStr))
		stderrLog(fmt.Sprintf("DEBUG Remote time: %s", remoteTimeStr))
		stderrLog(fmt.Sprintf("DEBUG Local before(ms): %d", localBeforeMs))
		stderrLog(fmt.Sprintf("DEBUG Local after(ms): %d", localAfterMs))
		stderrLog(fmt.Sprintf("DEBUG Estimated roundtrip(ms): %d", roundtripMs))
		stderrLog(fmt.Sprintf("DEBUG Estimated offset remote - local(ms): %d", offsetMs))
		if syslogWriter != nil {
			syslogWriter.Info(fmt.Sprintf("NTP server=%s addr=%s offset_ms=%d rtt_ms=%d",
				server, serverAddr, offsetMs, roundtripMs))
		}
	}

	// Roundtrip sanity check — exit 1 immediately like C, do not retry (fix B)
	if roundtripMs < 0 || roundtripMs > 10000 {
		stderrLog(fmt.Sprintf("ERROR Invalid roundtrip time: %d ms", roundtripMs))
		if syslogWriter != nil {
			syslogWriter.Err(fmt.Sprintf("Invalid suspiciously long roundtrip time: %d ms", roundtripMs))
		}
		os.Exit(1)
	}

	// Delta < 500ms: skip adjustment, matching C's llabs(offset_ms) < 500 condition
	absOffset := offsetMs
	if absOffset < 0 {
		absOffset = -absOffset
	}
	if absOffset > 0 && absOffset < 500 {
		if cfg.Verbose {
			stderrLog("INFO Delta < 500ms, not setting system time.")
			if syslogWriter != nil {
				syslogWriter.Info("Delta < 500ms, not setting system time")
			}
		}
		return nil
	}

	// Year range check — exit 1 immediately like C, do not retry (fix B)
	remoteYear := remoteTime.Year()
	if remoteYear < 2025 || remoteYear > 2200 {
		stderrLog(fmt.Sprintf("ERROR Remote year is out of valid range (2025-2200): %d", remoteYear))
		if syslogWriter != nil {
			syslogWriter.Err(fmt.Sprintf("Remote year is out of valid range (2025-2200): %d", remoteYear))
		}
		os.Exit(1)
	}

	if cfg.Test {
		return nil
	}

	// Root check, matching C's getuid() != 0 guard
	if os.Getuid() != 0 {
		stderrLog("WARNING Not root, not setting system time.")
		if syslogWriter != nil {
			syslogWriter.Warning("Not root, not setting system time")
		}
		return nil
	}

	// Half-RTT correction before setting time, matching C's remote_ms + half_rtt
	halfRtt := roundtripMs / 2
	if remoteMs > math.MaxInt64-halfRtt {
		stderrLog("ERROR Time calculation would overflow, not adjusting system time.")
		if syslogWriter != nil {
			syslogWriter.Err("Time calculation would overflow")
		}
		os.Exit(1)
	}
	newTime := time.UnixMilli(remoteMs + halfRtt).Local()

	const api = "settimeofday"
	// Set-time failure — exit 10 immediately like C, do not retry (fix B)
	err = setSystemDate(newTime, 0, false)
	if err != nil {
		stderrLog(fmt.Sprintf("ERROR Failed to adjust system time with %s: %v", api, err))
		if syslogWriter != nil {
			syslogWriter.Err(fmt.Sprintf("Failed to adjust system time with %s: %v", api, err))
		}
		os.Exit(10)
	}

	stderrLog(fmt.Sprintf("INFO System time set using %s (%s)", api, remoteTimeStr))
	if syslogWriter != nil {
		syslogWriter.Info(fmt.Sprintf("System time set using %s (%s)", api, remoteTimeStr))
	}
	return nil
}
