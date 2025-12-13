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
![Java](https://img.shields.io/badge/Java-ED8B00?style=flat&logo=openjdk&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-FA7343?style=flat&logo=swift&logoColor=white)
![Lua](https://img.shields.io/badge/Lua-2C2D72?style=flat&logo=lua&logoColor=white)
![Ruby](https://img.shields.io/badge/Ruby-CC342D?style=flat&logo=ruby&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

`timesync-mini` is a simple command-line tool for synchronizing system time with NTP servers. It is available in thirteen implementations across different programming languages, this is a fun little exercice to exercise code conversion with claude sonnet on a tiny program ...

- **C implementation** (`c/`): Minimal dependencies, uses only standard C library and BSD sockets, includes Haiku OS support with root privilege checking
- **Go implementation** (`go/`): Uses the beevik/ntp package for NTP queries
- **Rust implementation** (`rust/`): Direct port of C version with Rust's safety guarantees and root privilege checking
- **OCaml implementation** (`ocaml/`): Functional programming approach with C FFI for system calls and root checking
- **Python implementation** (`python/`): Pure Python with ctypes for system calls, includes root privilege checking
- **Bash implementation** (`bash/`): Shell script using socat for UDP communication
- **Perl implementation** (`perl/`): Native socket programming with Time::HiRes and settimeofday, includes root checking
- **Erlang implementation** (`erlang/`): OTP-style implementation with gen_udp, uses ports for root checking and time setting via date command
- **SBCL implementation** (`sbcl/`): Common Lisp with sb-bsd-sockets and FFI for settimeofday, available as script or compiled binary with root checking
- **Java implementation** (`java/`): JDK implementation with JNA for native system calls, packaged as JAR
- **Ruby implementation** (`ruby/`): Object-oriented implementation with standard library, FFI via Fiddle for settimeofday, includes root checking
- **Swift implementation** (`swift/`): Native Apple platform support with Foundation and BSD sockets, smallest compiled binary with root checking
- **Lua implementation** (`lua/`): Lightweight scripting with LuaSocket, FFI support via LuaJIT or lua-posix for settimeofday, includes root checking

All implementations support the same command-line interface for consistency.

## Key Features

- **Consistent CLI**: All 13 implementations support identical command-line flags and behavior
- **Root Privilege Checking**: All implementations check if running as root before attempting to set system time (except Bash and Java which rely on OS checks)
- **System Time Setting**: Each implementation can set system time when offset exceeds 500ms threshold:
  - **C, Rust, OCaml**: Direct `settimeofday()` system call
  - **Python**: Uses `ctypes` to call `clock_settime()` or `settimeofday()`
  - **Perl**: Uses `Time::HiRes::settimeofday()`
  - **SBCL**: FFI to `settimeofday()` via `sb-alien`
  - **Erlang**: Port-based approach using `date` command
  - **Swift**: Direct `settimeofday()` via Darwin/Glibc
  - **Lua**: FFI via LuaJIT or lua-posix for `settimeofday()`
  - **Ruby**: FFI via Fiddle for `settimeofday()`, fallback to `date` command
  - **Go, Java, Bash**: Platform-dependent approaches
- **Dual-Mode Support**: SBCL and Swift can run as scripts or compiled binaries
- **Memory Safety**: All implementations except C use automatic memory management (GC or compile-time)
- **Binary Sizes**: Range from 79 KB (Swift) to 13 MB (SBCL with embedded runtime)

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

| Implementation | Lines of Code | Dependencies | Binary Size | Memory Safety | NTP Implementation | Time Setting Method |
|---------------|---------------|--------------|-------------|---------------|-------------------|---------------------|
| **Go** | 274 | beevik/ntp | ~2-3 MB | Automatic (GC) | Library-based | syscall.Settimeofday() |
| **SBCL** | 275 | sb-bsd-sockets | ~13 MB (compressed) | Automatic (GC) | Manual | FFI settimeofday() |
| **Bash** | 283 | socat, xxd | 8.9 KB (script) | N/A | Manual (socat/UDP) | date command |
| **Perl** | 302 | Core modules | 10 KB (script) | Manual | Manual (native sockets) | Time::HiRes::settimeofday() |
| **Erlang** | 304 | kernel, stdlib | 16 KB (BEAM) | Automatic (BEAM VM) | Manual (gen_udp) | Port: date command |
| **Java** | 360 | JDK + JNA | ~1.8 MB (7 KB + 1.8 MB JNA) | Automatic (GC) | Manual (DatagramSocket) | JNA settimeofday() |
| **OCaml** | 368 | unix.cmxa | ~500 KB | Automatic (compile-time) | Manual | Unix.settimeofday() |
| **Ruby** | 386 | Standard library | 10 KB (script) | Automatic (GC) | Manual (native sockets) | Fiddle FFI / date fallback |
| **Swift** | 400 | Foundation | ~79 KB | Automatic (ARC) | Manual (BSD sockets) | settimeofday() syscall |
| **Lua** | 415 | luasocket | 12 KB (script) | Automatic (GC) | Manual (LuaSocket UDP) | LuaJIT FFI / posix fallback |
| **Python** | 416 | Standard library | 14 KB (script) | Automatic (GC) | Manual | ctypes clock_settime() |
| **Rust** | 521 | libc, chrono | ~500 KB - 1 MB | Automatic (compile-time) | Manual | libc::settimeofday() |
| **C** | 539 | Standard C library | ~20-30 KB (stripped) | Manual | Manual | settimeofday() syscall |

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
- **Java**: Cross-platform (any system with JRE 8+)
- **Ruby**: Unix-like systems with Ruby 2.5+
- **Swift**: macOS, Linux (with Swift runtime)
- **Lua**: Unix-like systems with Lua 5.1+ or LuaJIT
### Build Systems

- **C, Go, Rust, OCaml, Perl, Erlang, SBCL, Java, Swift**: Makefile provided
- **Python, Bash, Lua, Ruby**: No build required (scripts)

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
### Perl Implementation
- Perl 5
- Core modules: Socket, Time::HiRes, Sys::Syslog, POSIX
- Uses `Time::HiRes::settimeofday()` for setting system time (replaces non-portable `syscall()`)
- Root privilege check via `$<` (effective UID)
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
### Erlang Implementation
- Erlang/OTP runtime
- kernel and stdlib applications (gen_udp, inet)
- Uses port-based approach for root checking (`id -u` command)

### Java Implementation
- Java Development Kit (JDK) 8 or higher
- JNA (Java Native Access) library for native system calls
- Root privilege checking via JNA `getuid()` FFI
- System time setting via JNA `settimeofday()` FFI
- Graceful degradation if JNA is not available
- Packaged as executable JAR (~7 KB + JNA dependency)

### SBCL Implementation
- Steel Bank Common Lisp (SBCL)
- sb-bsd-sockets (included with SBCL)
- Can run as script or compiled to native binary (~13 MB with compression)
- Uses FFI (`sb-alien`) for `getuid()` and `settimeofday()` system calls
- Root privilege checking and direct time setting support
### SBCL Implementation
- Steel Bank Common Lisp (SBCL)
- sb-bsd-sockets (included with SBCL)
- Can run as script or compiled to native binary
### Swift Implementation
- Swift 5.5 or higher (included with Xcode on macOS)
- Foundation framework (standard)
- Darwin/Glibc for system calls
- Direct BSD socket and `settimeofday()` system call support
- Root privilege checking via `getuid()`
- Produces smallest optimized binary (~79 KB)
- Syslog support disabled (Swift limitation with variadic C functions)

### Lua Implementation
- Lua 5.1 or higher, or LuaJIT (recommended)
- LuaSocket library for UDP networking
- Optional: LuaJIT (for FFI-based `settimeofday()`) or lua-posix
- Root privilege checking via FFI or fallback to `id` command
- Time setting via LuaJIT FFI or lua-posix (no `date` command fallback)

### Ruby Implementation
- Ruby 2.5 or higher (standard library only)
- No external gems required
- Root privilege checking via `Process.uid`
- Time setting via Fiddle FFI (primary) with `date` command fallback
- Clean object-oriented design with Config, Logger, NTPClient, TimeSetter classes

## Security Considerations

All implementations that support setting system time include root privilege verification:
- Exit with code **10** if not running as root when attempting to set time
- Display warning message: "WARNING Not root, not setting system time."
- Test mode (`-n` flag) bypasses root check and simulates time adjustment

## Exit Codes

- **0**: Success (time synchronized or within 500ms threshold)
- **1**: Invalid NTP response or out-of-range time value
- **2**: Network error, timeout, or cannot resolve hostname
- **10**: Permission denied (not running as root) or failed to set system time- Packaged as executable JAR file

### Swift Implementation
- Swift 5.5 or higher (included with Xcode on macOS)
- Foundation framework (standard)
- Darwin/Glibc for system calls

