# timesync-mini

![C](https://img.shields.io/badge/C-00599C?style=flat&logo=c&logoColor=white)
![Go](https://img.shields.io/badge/Go-00ADD8?style=flat&logo=go&logoColor=white)
![Rust](https://img.shields.io/badge/Rust-000000?style=flat&logo=rust&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

`timesync-mini` is a simple command-line tool for synchronizing system time with NTP servers. It is available in three implementations:

- **C implementation** (`c/`): Minimal dependencies, uses only standard C library and BSD sockets
- **Go implementation** (`go/`): Uses the beevik/ntp package for NTP queries
- **Rust implementation** (`rust/`): Direct port of C version with Rust's safety guarantees

All implementations support the same command-line interface for consistency.

## Usage

```sh
timesync [options] [ntp-server]
```

### Options

All three implementations support the same options:

- `-t timeout` : Timeout in milliseconds (default: 2000, max: 6000)
- `-r retries` : Number of retries (default: 3, max: 10)
- `-n` : Run in test mode (does not actually set the system time)
- `-v` : Enable verbose logging
- `-s` : Enable syslog logging
- `-h` : Display usage information

### Positional Arguments

- `ntp-server` : The NTP server to synchronize with. If not provided, defaults to `pool.ntp.org`.

## Examples

### Synchronize with default server

```sh
timesync
```

### Synchronize with a specific NTP server

```sh
timesync time.google.com
```

### With custom timeout and retries

```sh
timesync -t 1500 -r 2 time.google.com
```

### Run in test mode with verbose output

```sh
timesync -n -v
```

### Enable syslog logging

```sh
timesync -s -v
```

### Display usage information

```sh
timesync -h
```

## Implementation Comparison

| Feature | C | Go | Rust |
|---------|---|----|----|
| **Dependencies** | Standard C library only | `beevik/ntp` package | `libc`, `chrono` crates |
| **Binary Size** | ~20-30 KB (stripped) | ~2-3 MB | ~500 KB - 1 MB |
| **Build System** | Make / cc | Go toolchain / Make | Cargo / Make |
| **Memory Safety** | Manual | Automatic (GC) | Automatic (compile-time) |
| **Cross-compile** | Platform-specific | Excellent | Excellent |
| **Platforms** | Unix-like + Haiku | Unix-like | Unix-like |
| **Command-line** | Consistent across all | Consistent across all | Consistent across all |

Each implementation directory contains its own README with specific build and usage instructions.

## Dependencies

### Go Implementation
- [github.com/beevik/ntp](https://github.com/beevik/ntp) : A Go package for querying NTP servers.

### C Implementation
- Standard C library only (BSD sockets)
- On Solaris/Illumos: additional `-lsocket -lnsl` linker flags required

### Rust Implementation
- `libc` 0.2 - For Unix system calls
- `chrono` 0.4 - For datetime handling and formatting

