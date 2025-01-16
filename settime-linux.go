//go:build linux

package main

import (
	"syscall"
	"time"
)

func setSystemDate(t time.Time) error {
	// s := fmt.Sprintf("@%d", t.Unix())
	// args = []string{"-s", s}
	// err = exec.Command(date, args...).Run()
	var tv syscall.Timeval
	tv.Sec = t.Unix()
	tv.Usec = (t.UnixMilli() % 1000) * 1000
	return syscall.Settimeofday(&tv)
}
