# TimeSync - C# Implementation

Simple SNTP client for synchronizing system time with NTP servers, implemented in C# / .NET.

## Features

- Native .NET implementation using UdpClient
- P/Invoke for Unix system calls (geteuid, settimeofday)
- Cross-platform support (Linux, macOS via Mono or .NET Core)
- Root privilege checking on Unix-like systems
- System time setting via native settimeofday() call
- Compiled to native executable via Mono or .NET

## Requirements

- **Mono** (5.0 or higher) or **.NET SDK** (5.0 or higher)
- On Linux/macOS: root privileges for setting system time

## Building

### Using Mono (cross-platform):
```sh
make
```

This will:
- Compile `TimeSync.cs` to `timesync.exe` using Mono's C# compiler (`csc`)
- Create a wrapper script `timesync` that runs via Mono

### Using .NET SDK (alternative):
```sh
dotnet new console -o timesync-csharp
# Copy TimeSync.cs to Program.cs
dotnet build -c Release
```

## Usage

Run via wrapper script:
```sh
./timesync [options] [ntp-server]
```

Or run directly with Mono:
```sh
mono timesync.exe [options] [ntp-server]
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

# Using default NTP server
./timesync -v

# With custom timeout and retries
./timesync -t 1500 -r 2 time.google.com

# Run as root to actually set system time
sudo ./timesync -v 192.168.1.1
```

## Implementation Details

- **Lines of Code**: ~430
- **Executable Size**: ~6-8 KB (exe) + Mono runtime or self-contained .NET
- **Platform Interop**: P/Invoke to libc for geteuid() and settimeofday()
- **NTP Implementation**: Manual packet construction with UdpClient
- **Socket Type**: UdpClient with timeout support
- **Time Resolution**: Milliseconds
- **Root Checking**: Via geteuid() == 0 on Unix platforms
- **Time Setting**: Via settimeofday() P/Invoke on Unix platforms

## Platform Support

- **Linux**: Full support with Mono or .NET Core/5+
- **macOS**: Full support with Mono or .NET Core/5+
- **Windows**: NTP query works, but time setting not implemented
- **FreeBSD/Other Unix**: Should work with Mono (untested)

## Notes

- Requires Mono runtime or .NET runtime installed on target system
- System time adjustment requires root/administrator privileges on Unix
- Combined flags supported (e.g., `-nv`, `-nvs`)
- The executable is portable across platforms with Mono/.NET support
- P/Invoke calls are Unix-specific and won't work on Windows

## Clean Build

```sh
make clean
make
```
