.PHONY: all clean test release

all: release

release:
	cargo build --release
	strip target/release/timesync

debug:
	cargo build

test:
	cargo test

clean:
	cargo clean

install: release
	install -m 755 target/release/timesync /usr/local/bin/timesync

uninstall:
	rm -f /usr/local/bin/timesync
