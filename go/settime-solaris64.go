//go:build solaris && amd64

package main

import (
	"fmt"
	"os"
	"os/exec"
	"time"
)

func setSystemDate(t time.Time, adj int64, test bool) error {
	if test {
		return nil
	} else {
		_ = adj
		s := fmt.Sprintf("%02d%02d%02d%02d%04d.%02d", t.Month(), t.Day(), t.Hour(), t.Minute(), t.Year(), t.Second())
		args := []string{s}
		fmt.Fprintf(os.Stderr, "setSystemDate: %d\n", adj)
		fmt.Fprintf(os.Stderr, "setSystemDate: %s\n", args)
		out, err := exec.Command("/usr/bin/date", args...).Output()
		fmt.Fprintf(os.Stderr, "setSystemDate: %s\n", out)
		return err
	}
}
