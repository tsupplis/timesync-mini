.PHONY: clean push push-openbsd-amd64 push-netbsd-amd64 push-freebsd-amd64 push-linux-amd64 local

local: timesync

all: local timesync-openbsd-amd64 timesync-netbsd-amd64 timesync-freebsd-amd64 \
	timesync-linux-amd64 timesync-linux-386 timesync-linux-riscv64 timesync-solaris-amd64
	
timesync: main.go settime-darwin64.go 
	go build -ldflags="-s -w" -o $@ $*

timesync-openbsd-amd64: main.go settime-openbsd64.go
	GOOS=openbsd GOARCH=amd64 go build -ldflags="-s -w" -o $@ $*

timesync-netbsd-amd64: main.go settime-netbsd64.go 
	GOOS=netbsd GOARCH=amd64 go build -ldflags="-s -w" -o $@ $*

timesync-solaris-amd64: main.go settime-solaris64.go
	GOOS=solaris GOARCH=amd64 go build -ldflags="-s -w" -o $@ $*

timesync-linux-riscv64: main.go settime-linux64.go
	GOOS=linux GOARCH=riscv64 go build -ldflags="-s -w" -o $@ $*

timesync-freebsd-amd64: main.go settime-freebsd64.go
	GOOS=freebsd GOARCH=amd64 go build -ldflags="-s -w" -o $@ $*

timesync-linux-386: main.go settime-linux32.go
	GOOS=linux GOARCH=386 go build -ldflags="-s -w" -o $@ $*

timesync-linux-amd64: main.go settime-linux64.go
	GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o $@ $*

timesync-linux-ppc64le: main.go settime-linux64.go
	GOOS=linux GOARCH=ppc64le go build -ldflags="-s -w" -o $@ $*

clean:
	rm -f timesync timesync-openbsd-amd64 timesync-netbsd-amd64 \
	timesync-freebsd-amd64 timesync-linux-amd64 timesync-linux-ppc64le \
    timesync-linux-riscv64

push: push-openbsd-amd64 push-freebsd-amd64 push-linux-amd64 push-netbsd-amd64

push-openbsd-amd64: timesync-openbsd-amd64
	scp $< @curry-openbsd-01:
	ssh curry-openbsd-01 "strip $<;doas cp $< /usr/local/bin/timesync;rm -f timesync-openbsd-amd64"

push-netbsd-amd64: timesync-netbsd-amd64
	scp $< @curry-netbsd-01:
	ssh curry-netbsd-01 "strip $<;doas cp $< /usr/local/bin/timesync;rm -f timesync-netbsd-amd64"

push-freebsd-amd64: timesync-freebsd-amd64
	scp $< @curry-freebsd-01:
	ssh curry-freebsd-01 "strip $<;doas cp timesync-freebsd-amd64 /usr/local/bin/timesync;rm -f timesync-freebsd-amd64"

push-linux-amd64: timesync-linux-amd64
	#scp $< @curry-debian-02:
	#ssh curry-debian-02 "strip $<;sudo cp timesync-linux-amd64 /usr/local/bin/timesync;rm -f timesync-linux-amd64"
	scp $< @curry-debian-01:
	ssh curry-debian-01 "strip $<;sudo cp timesync-linux-amd64 /usr/local/bin/timesync;rm -f timesync-linux-amd64"
	#scp $< @curry-alpine-01:
	#ssh curry-alpine-01 "strip $<;sudo cp timesync-linux-amd64 /usr/local/bin/timesync;rm -f timesync-linux-amd64"

