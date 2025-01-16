//go:build openbsd && amd64

package main

import (
	"syscall"
	"time"
)

func setSystemDate(t time.Time, adj int64) error {
	// s := fmt.Sprintf("%d%02d%02d%02d%02d.%02d", t.Year(), t.Month(), t.Day(), t.Hour(), t.Minute(), t.Second())
	// args = []string{"-u", s}
	// err = exec.Command(date, args...).Run()
	var tv syscall.Timeval
	tv.Sec = t.Unix()
	tv.Usec = (t.UnixMilli()%1000 + adj) * 1000
	return syscall.Settimeofday(&tv)
}
