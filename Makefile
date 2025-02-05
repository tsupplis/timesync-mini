.PHONY: clean push push-openbsd-amd64 push-netbsd-amd64 push-freebsd-amd64 push-linux-amd64 local

local: timesync

all: local timesync-openbsd-amd64 timesync-netbsd-amd64 timesync-freebsd-amd64 \
	timesync-linux-amd64 
	
timesync: main.go settime-darwin.go 
	go build -ldflags="-s -w" -o $@ $*

timesync-openbsd-amd64: main.go settime-openbsd.go
	GOOS=openbsd GOARCH=amd64 go build -ldflags="-s -w" -o $@ $*

timesync-netbsd-amd64: main.go settime-netbsd.go 
	GOOS=netbsd GOARCH=amd64 go build -ldflags="-s -w" -o $@ $*

timesync-freebsd-amd64: main.go settime-freebsd.go
	GOOS=freebsd GOARCH=amd64 go build -ldflags="-s -w" -o $@ $*

timesync-linux-amd64: main.go settime-linux.go
	GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o $@ $*

timesync-linux-ppc64le: main.go settime-linux.go
	GOOS=linux GOARCH=ppc64le go build -ldflags="-s -w" -o $@ $*

clean:
	rm -f timesync timesync-openbsd-amd64 timesync-netbsd-amd64 \
	timesync-freebsd-amd64 timesync-linux-amd64 timesync-linux-ppc64le

push: push-openbsd-amd64 push-netbsd-amd64 push-freebsd-amd64 push-linux-amd64 

push-openbsd-amd64: timesync-openbsd-amd64
	scp $< @garlic-openbsd-01:
	ssh garlic-openbsd-01 "strip $<;doas cp $< /usr/local/bin/timesync;rm -f timesync-openbsd-amd64"

push-netbsd-amd64: timesync-netbsd-amd64
	scp $< @garlic-netbsd-01:
	ssh garlic-netbsd-01 "strip $<;doas cp $< /usr/local/bin/timesync;rm -f timesync-netbsd-amd64"

push-freebsd-amd64: timesync-freebsd-amd64
	scp $< @garlic-freebsd-01:
	ssh garlic-freebsd-01 "strip $<;doas cp timesync-freebsd-amd64 /usr/local/bin/timesync;rm -f timesync-freebsd-amd64"

push-linux-amd64: timesync-linux-amd64
	scp $< @garlic-debian-01:
	ssh garlic-debian-01 "strip $<;sudo cp timesync-linux-amd64 /usr/local/bin/timesync;rm -f timesync-linux-amd64"
	scp $< @garlic-alpine-01:
	ssh garlic-alpine-01 "strip $<;sudo cp timesync-linux-amd64 /usr/local/bin/timesync;rm -f timesync-linux-amd64"
