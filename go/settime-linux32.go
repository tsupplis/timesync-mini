//go:build linux && 386

package main

import (
	"syscall"
	"time"
)

func setSystemDate(t time.Time, adj int64, test bool) error {
	// s := fmt.Sprintf("@%d", t.Unix())
	// args = []string{"-s", s}
	// err = exec.Command(date, args...).Run()
	var tv syscall.Timeval
	tv.Sec = int32(t.Unix())
	tv.Usec = int32((t.UnixMilli()%1000 + adj) * 1000)
	if test {
		return nil
	} else {
		return syscall.Settimeofday(&tv)
	}
}
