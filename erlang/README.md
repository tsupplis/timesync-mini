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

## License

MIT License - See LICENSE file for details
