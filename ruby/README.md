# Ruby Implementation

A portable SNTP client written in Ruby using only standard library components.

## Features

- Pure Ruby implementation using standard library
- Identical CLI interface to other implementations
- Root privilege checking via `Process.uid`
- System time setting via FFI (Fiddle) with fallback to `date` command
- Verbose and syslog logging support
- Combined flag support (e.g., `-nv`, `-nvs`)
- Clean object-oriented design

## Requirements

- Ruby 2.5 or higher (standard library only)
- No external gems required

### Installing Ruby

**macOS:**
```bash
# Ruby comes pre-installed
# Or use Homebrew for latest version:
brew install ruby
```

**Ubuntu/Debian:**
```bash
sudo apt-get install ruby
```

**Fedora/RHEL:**
```bash
sudo dnf install ruby
```

## Building

No compilation needed. Just make the script executable:

```bash
make
# or manually:
chmod +x timesync.rb
```

## Usage

Run as a script:

```bash
./timesync.rb                    # query pool.ntp.org
./timesync.rb -n -v              # test mode with verbose output
./timesync.rb -t 1500 time.google.com
ruby timesync.rb -nv 192.168.1.1  # explicit ruby interpreter
```

## Implementation Details

- **Networking**: Standard library `socket` for UDP communication
- **Root checking**: `Process.uid == 0` for direct privilege detection
- **Time setting**: 
  - Primary: Fiddle (FFI) to call `settimeofday()` directly
  - Fallback: `date` command if FFI unavailable
- **Script size**: ~11 KB
- **Memory**: ~10-15 MB resident (Ruby interpreter)
- **Architecture**: Clean OOP with Config, Logger, NTPClient, TimeSetter classes

## Platform Support

Works on:
- Linux
- macOS
- BSD systems
- Any Unix-like system with Ruby

## Notes

- Uses only Ruby standard library (no external gems)
- Root privileges required to actually set system time
- Test mode (`-n`) bypasses root requirement
- FFI via Fiddle for efficient `settimeofday()` call
- Automatic fallback to `date` command if FFI fails
- Includes proper timeout handling and error recovery
