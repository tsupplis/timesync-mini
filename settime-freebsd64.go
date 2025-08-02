//go:build freebsd && amd64

package main

import (
	"syscall"
	"time"
)

func setSystemDate(t time.Time, adj int64, test bool) error {
	var tv syscall.Timeval
	tv.Sec = t.Unix()
	tv.Usec = (t.UnixMilli()%1000 + adj) * 1000
	if test {
		return nil
	} else {
		return syscall.Settimeofday(&tv)
	}
}
