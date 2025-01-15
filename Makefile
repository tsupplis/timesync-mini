all: timesync-openbsd-amd64 timesync-netbsd-amd64 timesync-freebsd-amd64 timesync-linux-amd64 \
	timesync-linux-ppc64le timesync

timesync: main.go
	go build -ldflags="-s -w" -o $@ $<

timesync-openbsd-amd64: main.go
	GOOS=openbsd GOARCH=amd64 go build -ldflags="-s -w" -o $@ $<

timesync-netbsd-amd64: main.go
	GOOS=netbsd GOARCH=amd64 go build -ldflags="-s -w" -o $@ $<

timesync-freebsd-amd64: main.go
	GOOS=freebsd GOARCH=amd64 go build -ldflags="-s -w" -o $@ $<

timesync-linux-amd64: main.go
	GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o $@ $<

timesync-linux-ppc64le: main.go
	GOOS=linux GOARCH=ppc64le go build -ldflags="-s -w" -o $@ $<

clean:
	rm -f timesync timesync-openbsd-amd64 timesync-netbsd-amd64 \
	timesync-freebsd-amd64 timesync-linux-amd64 timesync-linux-ppc64le

push: push-openbsd-amd64 push-netbsd-amd64 push-freebsd-amd64 push-linux-amd64 push-linux-ppc64le

push-openbsd-amd64: timesync-openbsd-amd64
	scp $< @garlic-openbsd:
	ssh garlic-openbsd "strip $<;doas cp $< /usr/local/bin/timesync;rm -f timesync-openbsd-amd64"

push-netbsd-amd64: timesync-netbsd-amd64
	scp $< @garlic-netbsd:
	ssh garlic-netbsd "strip $<;doas cp $< /usr/local/bin/timesync;rm -f timesync-netbsd-amd64"

push-freebsd-amd64: timesync-freebsd-amd64
	scp $< @garlic-freebsd:
	ssh garlic-freebsd "strip $<;doas cp timesync-freebsd-amd64 /usr/local/bin/timesync;rm -f timesync-freebsd-amd64"

push-linux-amd64: timesync-linux-amd64
	scp $< @garlic-amd64:
	ssh garlic-amd64 "strip $<;sudo cp timesync-linux-amd64 /usr/local/bin/timesync;rm -f timesync-linux-amd64"
	scp $< @garlic-alpine:
	ssh garlic-alpine "strip $<;sudo cp timesync-linux-amd64 /usr/local/bin/timesync;rm -f timesync-linux-amd64"

push-linux-ppc64le: timesync-linux-ppc64le
	scp $< @garlic-ppc64:
	ssh garlic-ppc64 "strip $<;sudo cp timesync-linux-ppc64le /usr/local/bin/timesync;rm -f timesync-linux-ppc64le"
