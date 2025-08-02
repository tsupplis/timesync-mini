// write sample main function
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
type Config struct {
	Servers []string
	Verbose bool
	Test    bool
}

func parseConfig() (*Config, error) {
	cfg := &Config{}
	showHelp := false

	fs := flag.NewFlagSet("timesync", flag.ExitOnError)
	fs.BoolVar(&cfg.Test, "t", false, "Run in test mode")
	fs.BoolVar(&cfg.Verbose, "v", false, "Verbose output")
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

	// Check if the NTP server is provided as a positional argument.
	args := fs.Args()
	if len(args) == 0 {
		cfg.Servers = []string{"time.google.com"}
	} else {
		cfg.Servers = args
	}
	return cfg, nil
}

func main() {
	syslog, _ := syslog.New(syslog.LOG_INFO|syslog.LOG_DAEMON, "timesync")
	cfg, err := parseConfig()

	if err != nil {
		os.Exit(-1)
	}
	if cfg == nil {
		os.Exit(0)
	}

	if cfg.Verbose {
		slog.SetLogLoggerLevel(slog.LevelDebug)
	} else {
		slog.SetLogLoggerLevel(slog.LevelInfo)
	}
	slog.Debug("Server config", "config", cfg.Servers)
	if err != nil && syslog != nil {
		slog.Error("Failed to create syslog, ignored", "error", err)
	} else {
		slog.Debug("Syslog created")
	}
	for _, server := range cfg.Servers {
		err = timeSync(server, cfg.Test, syslog)
		if err == nil {
			os.Exit(0)
		}
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
// - syslog: A syslog.Writer to log messages to the system log.
//
// Returns an error if any step fails.
func timeSync(server string, test bool, syslog *syslog.Writer) error {
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
	ntime, err := ntp.Time(server)
	if err != nil {
		slog.Error("Failed to get time", "error", err)
		if syslog != nil {
			syslog.Err(fmt.Sprintf("Failed to get time: %v", err))
		}
		return err
	}
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
