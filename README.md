# timesync-mini

![C](https://img.shields.io/badge/C-00599C?style=flat&logo=c&logoColor=white)
![Go](https://img.shields.io/badge/Go-00ADD8?style=flat&logo=go&logoColor=white)
![Rust](https://img.shields.io/badge/Rust-000000?style=flat&logo=rust&logoColor=white)
![OCaml](https://img.shields.io/badge/OCaml-EC6813?style=flat&logo=ocaml&logoColor=white)
![Python](https://img.shields.io/badge/Python-3776AB?style=flat&logo=python&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-4EAA25?style=flat&logo=gnu-bash&logoColor=white)
![Perl](https://img.shields.io/badge/Perl-39457E?style=flat&logo=perl&logoColor=white)
![Erlang](https://img.shields.io/badge/Erlang-A90533?style=flat&logo=erlang&logoColor=white)
![Common Lisp](https://img.shields.io/badge/Common_Lisp-3498DB?style=flat&logo=lisp&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

`timesync-mini` is a simple command-line tool for synchronizing system time with NTP servers. It is available in nine implementations across different programming languages:

- **C implementation** (`c/`): Minimal dependencies, uses only standard C library and BSD sockets, includes Haiku OS support
- **Go implementation** (`go/`): Uses the beevik/ntp package for NTP queries
- **Rust implementation** (`rust/`): Direct port of C version with Rust's safety guarantees
- **OCaml implementation** (`ocaml/`): Functional programming approach with C FFI for system calls
- **Python implementation** (`python/`): Pure Python with ctypes for system calls
- **Bash implementation** (`bash/`): Shell script using socat for UDP communication
- **Perl implementation** (`perl/`): Native socket programming with Time::HiRes
- **Erlang implementation** (`erlang/`): OTP-style implementation with gen_udp
- **SBCL implementation** (`sbcl/`): Common Lisp with sb-bsd-sockets, available as script or compiled binary

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

| Implementation | Lines of Code | Dependencies | Binary Size | Memory Safety | NTP Implementation |
|---------------|---------------|--------------|-------------|---------------|-------------------|
| **Go** | 274 | `beevik/ntp` | ~2-3 MB | Automatic (GC) | Library-based |
| **SBCL** | 275 | `sb-bsd-sockets` | ~13 MB (compressed) | Automatic (GC) | Manual |
| **Bash** | 283 | socat, xxd | N/A (script) | N/A | Manual (socat/UDP) |
| **Perl** | 302 | Core modules | N/A (script) | Manual | Manual (native sockets) |
| **Erlang** | 304 | kernel, stdlib | N/A (script) | Automatic (BEAM VM) | Manual (gen_udp) |
| **OCaml** | 368 | unix.cmxa | ~500 KB | Automatic (compile-time) | Manual |
| **Python** | 416 | Standard library | N/A (script) | Automatic (GC) | Manual |
| **Rust** | 521 | libc, chrono | ~500 KB - 1 MB | Automatic (compile-time) | Manual |
| **C** | 539 | Standard C library | ~20-30 KB (stripped) | Manual | Manual |

### Platform Support

- **C**: Unix-like systems + Haiku OS (with scheduler support)
- **Go**: Excellent cross-platform support (Unix-like, Windows)
- **Rust**: Excellent cross-platform support (Unix-like)
- **OCaml**: Unix-like systems (requires OCaml compiler)
- **Python**: Cross-platform (Unix-like, Windows with modifications)
- **Bash**: Unix-like systems with bash, socat, and xxd
- **Perl**: Unix-like systems with Perl 5
- **Erlang**: Systems with Erlang/OTP runtime
- **SBCL**: Systems with Steel Bank Common Lisp compiler/runtime

### Build Systems

- **C, Go, Rust, OCaml, Perl, Erlang, SBCL**: Makefile provided
- **Python, Bash**: No build required (scripts)

All implementations support the same command-line interface and behavior.

Each implementation directory contains its own README with specific build and usage instructions.

## Dependencies

### C Implementation
- Standard C library only (BSD sockets)
- On Solaris/Illumos: additional `-lsocket -lnsl` linker flags required
- On Haiku: scheduler support via `set_thread_priority()`

### Go Implementation
- [github.com/beevik/ntp](https://github.com/beevik/ntp) : A Go package for querying NTP servers

### Rust Implementation
- `libc` 0.2 - For Unix system calls
- `chrono` 0.4 - For datetime handling and formatting

### OCaml Implementation
- OCaml compiler (ocamlopt)
- unix library (standard)
- C stubs for `settimeofday()` system call

### Python Implementation
- Python 3.x
- Standard library only (socket, struct, ctypes)

### Bash Implementation
- bash shell
- socat (for UDP communication)
- xxd (for hex/binary conversion)
- Standard Unix utilities (date, sudo)

### Perl Implementation
- Perl 5
- Core modules: Socket, Time::HiRes, Sys::Syslog, POSIX

### Erlang Implementation
- Erlang/OTP runtime
- kernel and stdlib applications (gen_udp, inet)

### SBCL Implementation
- Steel Bank Common Lisp (SBCL)
- sb-bsd-sockets (included with SBCL)
- Can run as script or compiled to native binary

