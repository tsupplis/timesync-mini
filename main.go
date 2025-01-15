// write sample main function
package main

import (
	"fmt"
	"log"
	"log/syslog"
	"net"
	"os"
	"os/exec"
	"runtime"
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
	ntimepoch := ntime.UnixMilli()
	nowpoch := time.Now().UnixMilli()
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
	if delta > yearLaps {
		log.Printf("Time is off by more than a year: %d, not adjusting", delta)
	} else {
		if delta > 1000 {
			err = setSystemDate(ntime)
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
	log.Printf("Current time: %vms epoch", nowpoch)
	log.Printf("Network time(%v): %vms epoch", server, ntime.UnixMilli())
	log.Printf("Time difference: %vms", ntimepoch-nowpoch)
	if syslog != nil {
		syslog.Info(fmt.Sprintf("Time difference: %vms", ntimepoch-nowpoch))
	}
	log.Printf("Call time: %vms < 500ms", nowpoch-prepoch)
	os.Exit(0)
}

func setSystemDate(t time.Time) error {
	date := "/bin/date"
	var args []string
	var err error = nil

	switch runtime.GOOS {
	case "linux":
		s := fmt.Sprintf("@%d", t.Unix())
		args = []string{"-s", s}
	case "netbsd":
		s := fmt.Sprintf("%d%02d%02d%02d%02d.%02d", t.Year(), t.Month(), t.Day(), t.Hour(), t.Minute(), t.Second())
		args = []string{"-u", s}
	case "openbsd":
		s := fmt.Sprintf("%d%02d%02d%02d%02d.%02d", t.Year(), t.Month(), t.Day(), t.Hour(), t.Minute(), t.Second())
		args = []string{"-u", s}
	case "freebsd":
		s := fmt.Sprintf("%d%02d%02d%02d%02d.%02d", t.Year(), t.Month(), t.Day(), t.Hour(), t.Minute(), t.Second())
		args = []string{"-u", s}
	default:
		err = fmt.Errorf("Unsupported OS: %v", runtime.GOOS)
		return err
	}
	err = exec.Command(date, args...).Run()
	return err
}

// date +"%s"
// openbsd set: date [-aju] [-f pformat] [-r seconds] [-z output_zone] [+format] [[[[[[cc]yy]mm]dd]HH]MM[.SS]]
//
// freebsd: date  [-nRu]  [-z  output_zone]	[-I[FMT]]  [-r	filename] [-r seconds]
//                [-v[+|-]val[y|m|w|d|H|M|S]]	[+output_fmt]
//   		date  [-jnRu]  [-z  output_zone]	[-I[FMT]]  [-v[+|-]val[y|m|w|d|H|M|S]]
//			      [[[[[cc]yy]mm]dd]HH]MM[.SS]	[+output_fmt]
// 			date  [-jnRu] [-z output_zone] [-I[FMT]]	[-v[+|-]val[y|m|w|d|H|M|S]] -f
//				  input_fmt new_date [+output_fmt]
// netbsd: date [-ajnRUu] [-d date] [-r seconds] [-z zone] [+format]
//	            [[[[[[CC]yy]mm]dd]HH]MM[.SS]]
//  	   date [-ajnRu] -f input_format new_date [+format]
