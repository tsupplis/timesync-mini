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

//go:build freebsd && amd64

package main

import (
	"syscall"
	"time"
)

func setSystemDate(t time.Time, adj int64, test bool) error {
	// s := fmt.Sprintf("%d%02d%02d%02d%02d.%02d", t.Year(), t.Month(), t.Day(), t.Hour(), t.Minute(), t.Second())
	// args = []string{"-u", s}
	// err = exec.Command(date, args...).Run()
	var tv syscall.Timeval
	tv.Sec = t.Unix()
	tv.Usec = (t.UnixMilli()%1000 + adj) * 1000
	if test {
		return nil
	} else {
		return syscall.Settimeofday(&tv)
	}
}
