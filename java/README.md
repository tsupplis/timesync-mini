# TimeSync - Java Implementation

Simple SNTP client for synchronizing system time with NTP servers, implemented in pure Java.

## Features

- Pure JDK implementation (no external dependencies)
- Uses `java.net.DatagramSocket` for UDP communication
- `ByteBuffer` for efficient binary packet manipulation
- Cross-platform (runs on any system with JRE 8+)
- Packaged as executable JAR file
- Tiny JAR size (~6 KB)

## Requirements

- Java Development Kit (JDK) 8 or higher
- Apache Ant (for building)

## Building

Build using Apache Ant:

```sh
ant build
```

This will:
- Compile the Java source code
- Create `timesync.jar` with manifest
- Generate `timesync` wrapper script

## Usage

Run via wrapper script:
```sh
./timesync [options] [ntp-server]
```

Or run JAR directly:
```sh
java -jar timesync.jar [options] [ntp-server]
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
java -jar timesync.jar -v

# With custom timeout and retries
./timesync -t 1500 -r 2 time.google.com
```

## Other Ant Targets

```sh
# Clean build artifacts
ant clean

# Run directly (without wrapper)
ant run -Dargs="-nv 192.168.1.1"

# Clean and rebuild
ant rebuild
```

## Implementation Details

- **Lines of Code**: 322
- **JAR Size**: ~6 KB (only contains compiled classes)
- **Runtime Memory**: ~50-100 MB (typical JVM overhead)
- **NTP Implementation**: Manual packet construction using ByteBuffer
- **Socket Type**: DatagramSocket with timeout support
- **Time Resolution**: Milliseconds

## Notes

- Requires JRE to be installed on target system
- System time adjustment requires root/administrator privileges
- Combined flags supported (e.g., `-nv`, `-nvs`)
- The JAR is portable across all platforms with Java support
