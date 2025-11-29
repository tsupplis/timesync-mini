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
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"log/syslog"
	"net"
	"os"
	"time"

	"github.com/beevik/ntp"
)

// Config holds the settings for the application.
// Fields:
// - Servers: A list of NTP servers to synchronize with.
// - Verbose: If true, enables verbose output.
// - Test: If true, runs the application in test mode without setting the system time.
// - TimeoutMS: Timeout in milliseconds for NTP queries.
// - Retries: Number of retry attempts.
// - UseSyslog: If true, enables syslog logging.
type Config struct {
	Servers   []string
	Verbose   bool
	Test      bool
	TimeoutMS int
	Retries   int
	UseSyslog bool
}

func parseConfig() (*Config, error) {
	cfg := &Config{
		TimeoutMS: 2000, // default
		Retries:   3,    // default
	}
	showHelp := false

	fs := flag.NewFlagSet("timesync", flag.ExitOnError)
	fs.IntVar(&cfg.TimeoutMS, "t", 2000, "Timeout in milliseconds (max: 6000)")
	fs.IntVar(&cfg.Retries, "r", 3, "Number of retries (max: 10)")
	fs.BoolVar(&cfg.Test, "n", false, "Run in test mode (no action)")
	fs.BoolVar(&cfg.Verbose, "v", false, "Verbose output")
	fs.BoolVar(&cfg.UseSyslog, "s", false, "Enable syslog logging")
	fs.BoolVar(&showHelp, "h", false, "Display usage")
	// Override the default usage message to include the ntp server argument.
	fs.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: %s [options] <ntp-server>\nOptions:\n", os.Args[0])
		fs.PrintDefaults()
	}
	fs.SetOutput(os.Stderr)
	fs.Parse(os.Args[1:])
	if showHelp {
		fmt.Fprintf(os.Stderr, "Usage: %s [options] <ntp-server>\nOptions:\n", os.Args[0])
		fs.PrintDefaults()
		return nil, nil
	}

	// Validate and clamp timeout
	if cfg.TimeoutMS > 6000 {
		cfg.TimeoutMS = 6000
	}
	if cfg.TimeoutMS <= 0 {
		cfg.TimeoutMS = 2000
	}

	// Validate and clamp retries
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

	// Check if the NTP server is provided as a positional argument.
	args := fs.Args()
	if len(args) == 0 {
		cfg.Servers = []string{"pool.ntp.org"}
	} else {
		cfg.Servers = args
	}
	return cfg, nil
}

func main() {
	cfg, err := parseConfig()

	if err != nil {
		os.Exit(-1)
	}
	if cfg == nil {
		os.Exit(0)
	}

	var syslogWriter *syslog.Writer
	if cfg.UseSyslog {
		syslogWriter, err = syslog.New(syslog.LOG_INFO|syslog.LOG_DAEMON, "timesync")
		if err != nil {
			slog.Error("Failed to create syslog, ignored", "error", err)
		} else {
			slog.Debug("Syslog created")
		}
	}

	if cfg.Verbose {
		slog.SetLogLoggerLevel(slog.LevelDebug)
		slog.Debug("Using server", "server", cfg.Servers)
		slog.Debug("Config", "timeout", cfg.TimeoutMS, "retries", cfg.Retries, "syslog", cfg.UseSyslog)
	} else {
		slog.SetLogLoggerLevel(slog.LevelInfo)
	}

	for attempt := 0; attempt < cfg.Retries; attempt++ {
		for _, server := range cfg.Servers {
			if cfg.Verbose && attempt > 0 {
				slog.Debug("Retry attempt", "attempt", attempt+1, "server", server)
			}
			err = timeSync(server, cfg.Test, time.Duration(cfg.TimeoutMS)*time.Millisecond, syslogWriter)
			if err == nil {
				os.Exit(0)
			}
			if attempt < cfg.Retries-1 {
				time.Sleep(200 * time.Millisecond)
			}
		}
	}
	slog.Error("Failed to contact NTP server after retries", "attempts", cfg.Retries)
	if syslogWriter != nil {
		syslogWriter.Err(fmt.Sprintf("NTP query failed after %d attempts", cfg.Retries))
	}
	os.Exit(-1)
}

// timeSync synchronizes the system time with the given NTP server.
// It performs the following steps:
// 1. Resolves the IP address of the NTP server.
// 2. Retrieves the current time from the NTP server.
// 3. Checks if the retrieved time is valid (year >= 2025).
// 4. Calculates the time difference between the system time and the NTP time.
// 5. If the time difference is significant, it adjusts the system time.
// 6. Logs the results and any errors encountered.
//
// Parameters:
// - server: The NTP server to synchronize with.
// - test: If true, the function runs in test mode and does not actually set the system time.
// - timeout: The timeout duration for the NTP query.
// - syslog: A syslog.Writer to log messages to the system log.
//
// Returns an error if any step fails.
func timeSync(server string, test bool, timeout time.Duration, syslog *syslog.Writer) error {
	var yearLaps int64 = 365 * 24 * 60 * 60 * 1000
	ips, err := net.LookupIP(server)
	if err != nil {
		slog.Error("Could not get IPs:", "error", err)
		if syslog != nil {
			syslog.Err(fmt.Sprintf("Could not get IPs: %v\n", err))
		}
		return err
	}
	server = ips[0].String()
	slog.Debug("Network time server", "server", server)
	prepoch := time.Now().UnixMilli()

	// Query NTP with timeout
	options := ntp.QueryOptions{Timeout: timeout}
	response, err := ntp.QueryWithOptions(server, options)
	if err != nil {
		slog.Error("Failed to query NTP server", "error", err)
		if syslog != nil {
			syslog.Err(fmt.Sprintf("Failed to query NTP server: %v", err))
		}
		return err
	}
	ntime := time.Now().Add(response.ClockOffset)
	nyear := ntime.Year()
	if nyear < 2025 {
		slog.Error("Year is less than 2025", "year", nyear)
		if syslog != nil {
			syslog.Err(fmt.Sprintf("Year is less than 2025: %v", nyear))
		}
		return errors.New("year is less than 2025")
	}
	nowpoch := time.Now().UnixMilli()
	ntimepoch := ntime.UnixMilli()
	delta := nowpoch - ntimepoch
	if delta < 0 {
		delta = -delta
	}
	if nowpoch-prepoch > 500 {
		slog.Error("Time sync took too long", "duration", nowpoch-prepoch)
		if syslog != nil {
			syslog.Err(fmt.Sprintf("Time sync took too long (%v)", nowpoch-prepoch))
		}
		return nil
	}
	ntime = ntime.Add(time.Millisecond * (time.Duration)((nowpoch-prepoch)/4))
	ntimepoch = ntime.UnixMilli()
	if delta > yearLaps {
		slog.Info("Time is off by more than a year, not adjusting", "delta", delta)
	} else {
		if delta > 500 {
			err = setSystemDate(ntime, 0, test)
			if err != nil {
				slog.Error("Failed to set system date", "error", err)
				if syslog != nil {
					syslog.Err(fmt.Sprintf("Failed to set system date: %v", err))
				}
				return err
			} else {
				slog.Info("System time set to network time", "server", server, "delta", delta)
				if syslog != nil {
					syslog.Info("System time set to network time")
				}
			}
		} else {
			slog.Debug("Time is already in sync")
			if syslog != nil {
				syslog.Info("Time is already in sync")
			}
		}
	}
	slog.Debug("Before time", "sys-epoch", nowpoch)
	slog.Debug("Network time", "server", server, "network-epoch", ntime.UnixMilli())
	slog.Debug("Time difference", "epoch-diff", ntimepoch-nowpoch)
	slog.Debug("Current time", "time", time.Now().Format(time.RFC3339))
	if syslog != nil {
		syslog.Info(fmt.Sprintf("Time difference: %vms", ntimepoch-nowpoch))
	}
	slog.Debug("Call time < 500 ms", "time", nowpoch-prepoch)

	return nil
}
