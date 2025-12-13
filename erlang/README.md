# timesync - Erlang Implementation

Minimal SNTP client implementation using Erlang/OTP.

## Features

- Erlang escript (~280 lines)
- Pattern matching for binary NTP packet parsing
- Native UDP socket operations via gen_udp
- Command-line argument parsing
- Combined flag support (`-nv`, `-nvs`, etc.)
- Functional style with immutable data structures

## Requirements

- Erlang/OTP 23+
- No external dependencies

## Usage

```erlang
# Query default server
./timesync

# Query specific server in test mode with verbose output
./timesync -nv time.google.com

# Test with local NTP server
./timesync -nv 192.168.1.1
```

## Implementation Notes

- Uses `escript` for standalone executable
- Native `gen_udp` for UDP socket operations
- Binary pattern matching for NTP packet parsing
- Erlang's excellent binary syntax for protocol handling
- Functional error handling with pattern matching
- Line count: ~280 lines

## Limitations

- Time setting not implemented (would require C NIF)
- Test mode works perfectly for validation
- Focus is on clean functional style and networking

## Advantages

- Excellent for binary protocol parsing
- Clean pattern matching syntax
- Native UDP support
- Great error handling
- Immutable data structures

## Implementation Details

### System Time Setting

Since Erlang doesn't have direct access to C system calls without NIFs, the implementation uses ports to:
1. Check if running as root using `id -u` command
2. Set system time using the `date` command with the format `date YYYYMMDDhhmm.ss`

This approach works on macOS and BSD systems. On Linux, you may need to use `sudo date` or the `date -s` command format.

### Root Check

The `get_uid()` function spawns a port running `id -u` and parses the output to determine if the effective UID is 0 (root).

## License

MIT License - See LICENSE file for details
