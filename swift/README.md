# TimeSync - Swift Implementation

Simple SNTP client for synchronizing system time with NTP servers, implemented in Swift.

## Features

- Pure Swift implementation using Foundation and Darwin/Glibc
- Can run as script OR compile to native binary  
- Uses BSD sockets via C interop
- Manual NTP packet construction and parsing
- Compact binary size (~79 KB optimized)
- Native macOS/Linux support

## Requirements

- Swift 5.5 or higher (included with Xcode on macOS)
- Make (for building the binary)

## Building

Build the native binary:

```sh
make
```

This creates:
- `timesync` - Native compiled binary (~79 KB with optimization)

## Usage

Run as script directly:
```sh
./timesync.swift [options] [ntp-server]
```

Or run compiled binary:
```sh
./timesync [options] [ntp-server]
```

### Options

- `-t timeout` : Timeout in milliseconds (default: 2000, max: 6000)
- `-r retries` : Number of retries (default: 3, max: 10)
- `-n` : Run in test mode (does not actually set the system time)
- `-v` : Enable verbose logging
- `-s` : Enable syslog logging (disabled in Swift - not supported)
- `-h` : Display usage information

### Examples

```sh
# Test mode with verbose output
./timesync -nv 192.168.1.1

# Using script mode
./timesync.swift -v time.google.com

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

- **Lines of Code**: ~420
- **Binary Size**: ~79 KB (optimized)
- **Script Mode**: Interpreted by Swift runtime
- **NTP Implementation**: Manual packet construction using UInt8 arrays
- **Socket Type**: BSD sockets via Darwin/Glibc interop
- **Time Setting**: `settimeofday()` system call
- **Time Resolution**: Milliseconds

## Dual-Mode Operation

The implementation supports two execution modes:

1. **Script Mode**: Fast development cycle, no compilation
   - Run with `./timesync.swift [args]` (requires shebang)
   - Interpreted by Swift runtime
   - Startup overhead: ~100-200 ms
   - Requires Swift to be installed

2. **Binary Mode**: Native compiled executable
   - Compile with `make`
   - Standalone binary (requires Swift runtime on Linux)
   - Startup overhead: <10 ms
   - Smallest compiled binary of all implementations (~79 KB)

## Notes

- Syslog support disabled due to Swift limitations with variadic C functions
- Setting system time requires root/administrator privileges (checked with getuid)
- Combined flags supported (e.g., `-nv`, `-nvs`)
- Script mode is ideal for development; binary for distribution
- The binary requires Swift runtime libraries (smaller than most other language runtimes)
- macOS includes Swift runtime; Linux needs Swift installed or static linking
