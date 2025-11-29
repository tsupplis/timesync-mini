// timesync - Minimal SNTP client (RFC 5905 subset)
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 tsupplis
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

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
