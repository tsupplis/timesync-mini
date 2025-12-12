# timesync - Bash Implementation

Minimal SNTP client implementation using pure Bash scripting.

## Features

- Pure Bash script (~280 lines)
- Command-line argument parsing matching other implementations
- Combined flag support (`-nv`, `-nvs`, etc.)
- NTP query with configurable timeout and retries
- System time adjustment (requires sudo/root)
- Verbose debug output
- Cross-platform: Linux, macOS, BSD

## Requirements

- Bash 4.0+
- `socat` for UDP operations (install: `brew install socat` or `apt install socat`)
- `xxd` for hex conversion
- `sudo` for time adjustment
- Optional: `gdate` on macOS for millisecond precision

## Usage

```bash
# Query default server
./timesync

# Query specific server in test mode with verbose output
./timesync -nv time.google.com

# Set time from local NTP server
./timesync 192.168.1.1
```

## Implementation Notes

- Uses `socat` for UDP socket operations (more reliable than `nc`)
- Parses binary NTP packets using hex encoding via `xxd`
- Supports macOS, Linux, and BSD date commands
- Millisecond precision where available
- Requires sudo for system time changes
- Line count: ~285 lines

## Limitations

- Requires external tools (`socat`, `xxd`)
- Less precise than native implementations due to script overhead
- RTT measurements include shell execution time

## License

MIT License - See LICENSE file for details
