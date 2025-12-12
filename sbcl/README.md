# TimeSync - SBCL Implementation

Simple SNTP client for synchronizing system time with NTP servers, implemented in Common Lisp (SBCL).

## Features

- Pure SBCL implementation using `sb-bsd-sockets`
- Can run as script OR compile to native binary
- Manual timeout handling using `sb-ext:with-timeout`
- Functional programming style with S-expression syntax
- Binary includes full SBCL runtime (~13 MB compressed)

## Requirements

- Steel Bank Common Lisp (SBCL)
- Make (for building the binary)

## Building

Build the native binary:

```sh
make
```

This creates two executables:
- `timesync` - Native compiled binary (~13 MB with compression)
- `timesync.sh` - Script wrapper that loads the .lisp file

## Usage

Run compiled binary:
```sh
./timesync [options] [ntp-server]
```

Run as script directly:
```sh
sbcl --script timesync.lisp [options] [ntp-server]
```

Or using generated wrapper:
```sh
./timesync.sh [options] [ntp-server]
```

### Options

- `-t timeout` : Timeout in milliseconds (default: 2000, max: 6000)
- `-r retries` : Number of retries (default: 3, max: 10)
- `-n` : Run in test mode (does not actually set the system time)
- `-v` : Enable verbose logging
- `-s` : Enable syslog logging
- `-h` : Display usage information

### Examples

```sh
# Test mode with verbose output
./timesync -nv 192.168.1.1

# Using script mode
sbcl --script timesync.lisp -v time.google.com

# Using compiled binary
./timesync -t 1500 -r 2 pool.ntp.org
```

## Make Targets

```sh
# Build compiled binary
make

# Remove all build artifacts
make clean
```

## Implementation Details

- **Lines of Code**: 275
- **Binary Size**: ~13 MB (includes SBCL runtime with compression)
- **Script Mode**: No compilation needed, instant startup
- **NTP Implementation**: Manual packet construction using byte vectors
- **Socket Type**: `sb-bsd-sockets:inet-socket` with datagram protocol
- **Timeout**: `sb-ext:with-timeout` wrapper (socket-level timeout unavailable)
- **Time Resolution**: Microseconds

## Dual-Mode Operation

The implementation supports two execution modes:

1. **Script Mode**: Fast development cycle, no compilation
   - Run with `sbcl --script timesync.lisp`
   - Uses runtime-interpreted bytecode
   - Startup overhead: ~50-100 ms

2. **Binary Mode**: Standalone executable
   - Compile with `make`
   - Single file distribution
   - Includes full SBCL runtime (~13 MB compressed)
   - Startup overhead: ~20-50 ms

## Notes

- Binary size is large due to embedded SBCL runtime
- Setting system time requires root/administrator privileges
- Combined flags supported (e.g., `-nv`, `-nvs`)
- Script mode is ideal for development; binary for distribution
- The binary is platform-specific (recompile for each architecture)
