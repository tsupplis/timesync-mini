//go:build freebsd && amd64

package main

import (
	"syscall"
	"time"
)

func setSystemDate(t time.Time) error {
	// s := fmt.Sprintf("%d%02d%02d%02d%02d.%02d", t.Year(), t.Month(), t.Day(), t.Hour(), t.Minute(), t.Second())
	// args = []string{"-u", s}
	// err = exec.Command(date, args...).Run()
	var tv syscall.Timeval
	tv.Sec = t.Unix()
	tv.Usec = (t.UnixMilli()%1000)*1000 + 5
	return syscall.Settimeofday(&tv)
}
