# timesync - Perl Implementation

Minimal SNTP client implementation using Perl.

## Features

- Pure Perl script (~280 lines)
- Command-line argument parsing matching other implementations
- Combined flag support (`-nv`, `-nvs`, etc.)
- Native UDP socket operations
- Syslog integration via Sys::Syslog
- System time adjustment via settimeofday syscall
- Cross-platform: Linux, macOS, BSD

## Requirements

- Perl 5.10+
- Core modules: Socket, Time::HiRes, Sys::Syslog, POSIX
- Root/sudo for time adjustment

## Usage

```perl
# Query default server
./timesync

# Query specific server in test mode with verbose output
./timesync -nv time.google.com

# Set time from local NTP server
./timesync 192.168.1.1
```

## Implementation Notes

- Uses Perl's native Socket module for UDP operations
- Time::HiRes for microsecond precision
- Binary packet manipulation with pack/unpack
- Direct settimeofday syscall for time adjustment
- Compact error handling with Perl idioms
- Line count: ~280 lines

## Advantages

- No external dependencies (uses core modules)
- Concise syntax for network/binary operations
- Native UDP socket support
- Built-in syslog integration

## License

MIT License - See LICENSE file for details
