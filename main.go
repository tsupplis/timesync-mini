// write sample main function
package main

import (
	"fmt"
	"log"
	"log/syslog"
	"net"
	"os"
	"time"

	"github.com/beevik/ntp"
)

func main() {
	syslog, err := syslog.New(syslog.LOG_INFO|syslog.LOG_DAEMON, "timesync")
	log.SetPrefix("timesync: ")
	if err != nil && syslog != nil {
		log.Printf("Failed to create syslog, ignored: %v", err)
	} else {
		log.Printf("Syslog created")
	}
	var yearLaps int64 = 365 * 24 * 60 * 60 * 1000
	server := "time.google.com"
	if len(os.Args) > 1 {
		server = os.Args[1]
	}
	ips, err := net.LookupIP(server)
	if err != nil {
		log.Printf("Could not get IPs: %v\n", err)
		if syslog != nil {
			syslog.Err(fmt.Sprintf("Could not get IPs: %v\n", err))
		}
		os.Exit(-1)
		return
	}
	server = ips[0].String()
	log.Printf("Network time server: %v", server)
	prepoch := time.Now().UnixMilli()
	ntime, err := ntp.Time(server)
	if err != nil {
		log.Printf("Failed to get time: %v", err)
		if syslog != nil {
			syslog.Err(fmt.Sprintf("Failed to get time: %v", err))
		}
		os.Exit(-1)
		return
	}
	nyear := ntime.Year()
	if nyear < 2025 {
		log.Printf("Year is less than 2025: %v", nyear)
		if syslog != nil {
			syslog.Err(fmt.Sprintf("Year is less than 2025: %v", nyear))
		}
		os.Exit(-1)
		return
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
		return
	}
	ntime = ntime.Add(time.Millisecond * (time.Duration)((nowpoch-prepoch)/4))
	ntimepoch = ntime.UnixMilli()
	if delta > yearLaps {
		log.Printf("Time is off by more than a year: %d, not adjusting", delta)
	} else {
		if delta > 500 {
			err = setSystemDate(ntime, 0)
			if err != nil {
				log.Printf("Failed to set system date: %v", err)
				if syslog != nil {
					syslog.Err(fmt.Sprintf("Failed to set system date: %v", err))
				}
				os.Exit(-1)
				return
			} else {
				log.Printf("System time set to network time")
				if syslog != nil {
					syslog.Info(fmt.Sprintf("System time set to network time"))
				}
			}
		} else {
			log.Print("Time is already in sync")
			if syslog != nil {
				syslog.Info(fmt.Sprintf("Time is already in sync"))
			}
		}
	}
	log.Printf("Current time: %v ms epoch", nowpoch)
	log.Printf("Network time(%v): %v ms epoch", server, ntime.UnixMilli())
	log.Printf("Time difference: %v ms", ntimepoch-nowpoch)
	if syslog != nil {
		syslog.Info(fmt.Sprintf("Time difference: %vms", ntimepoch-nowpoch))
	}
	log.Printf("Call time: %vms < 500 ms", nowpoch-prepoch)
	os.Exit(0)
}
