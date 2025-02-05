// write sample main function
package main

import (
	"errors"
	"flag"
	"fmt"
	"log"
	"log/syslog"
	"net"
	"os"
	"time"

	"github.com/beevik/ntp"
)

// Config holds the settings for the application.
type Config struct {
	Servers []string
	Verbose bool
	Test    bool
}

// parseConfig parses command line flags and returns a Config structure.
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
	syslog, err := syslog.New(syslog.LOG_INFO|syslog.LOG_DAEMON, "timesync")
	log.SetPrefix("timesync: ")
	cfg, err := parseConfig()

	if err != nil {
		os.Exit(-1)
	}
	if cfg == nil {
		os.Exit(0)
	}
	if cfg.Verbose {
		log.Printf("Server config: %v", cfg.Servers)
	}
	if err != nil && syslog != nil {
		log.Printf("Failed to create syslog, ignored: %v", err)
	} else {
		if cfg.Verbose {
			log.Printf("Syslog created")
		}
	}
	for _, server := range cfg.Servers {
		err = timeSync(server, cfg.Test, syslog, cfg.Verbose)
		if err == nil {
			os.Exit(0)
		}
	}
	os.Exit(-1)
}

func timeSync(server string, test bool, syslog *syslog.Writer, verbose bool) error {
	var yearLaps int64 = 365 * 24 * 60 * 60 * 1000
	ips, err := net.LookupIP(server)
	if err != nil {
		log.Printf("Could not get IPs: %v\n", err)
		if syslog != nil {
			syslog.Err(fmt.Sprintf("Could not get IPs: %v\n", err))
		}
		return err
	}
	server = ips[0].String()
	if verbose {
		log.Printf("Network time server: %v", server)
	}
	prepoch := time.Now().UnixMilli()
	ntime, err := ntp.Time(server)
	if err != nil {
		log.Printf("Failed to get time: %v", err)
		if syslog != nil {
			syslog.Err(fmt.Sprintf("Failed to get time: %v", err))
		}
		return err
	}
	nyear := ntime.Year()
	if nyear < 2025 {
		log.Printf("Year is less than 2025: %v", nyear)
		if syslog != nil {
			syslog.Err(fmt.Sprintf("Year is less than 2025: %v", nyear))
		}
		return errors.New("Year is less than 2025")
	}
	nowpoch := time.Now().UnixMilli()
	ntimepoch := ntime.UnixMilli()
	delta := nowpoch - ntimepoch
	if delta < 0 {
		delta = -delta
	}
	if nowpoch-prepoch > 500 {
		log.Printf("Time sync took too long (%v)", nowpoch-prepoch)
		if syslog != nil {
			syslog.Err(fmt.Sprintf("Time sync took too long (%v)", nowpoch-prepoch))
		}
		return nil
	}
	ntime = ntime.Add(time.Millisecond * (time.Duration)((nowpoch-prepoch)/4))
	ntimepoch = ntime.UnixMilli()
	if delta > yearLaps {
		if verbose {
			log.Printf("Time is off by more than a year: %d, not adjusting", delta)
		}
	} else {
		if delta > 500 {
			err = setSystemDate(ntime, 0, test)
			if err != nil {
				log.Printf("Failed to set system date: %v", err)
				if syslog != nil {
					syslog.Err(fmt.Sprintf("Failed to set system date: %v", err))
				}
				return err
			} else {
				log.Printf("System time set to network time")
				if syslog != nil {
					syslog.Info(fmt.Sprintf("System time set to network time"))
				}
			}
		} else {
			if verbose {
				log.Print("Time is already in sync")
			}
			if syslog != nil {
				syslog.Info(fmt.Sprintf("Time is already in sync"))
			}
		}
	}
	if verbose {
		log.Printf("Current time: %v ms epoch", nowpoch)
		log.Printf("Network time(%v): %v ms epoch", server, ntime.UnixMilli())
		log.Printf("Time difference: %v ms", ntimepoch-nowpoch)
	}
	if syslog != nil {
		syslog.Info(fmt.Sprintf("Time difference: %vms", ntimepoch-nowpoch))
	}
	if verbose {
		log.Printf("Call time: %vms < 500 ms", nowpoch-prepoch)
	}
	return nil
}
