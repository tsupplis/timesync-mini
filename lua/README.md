# Lua Implementation

A portable SNTP client written in Lua with LuaSocket for network operations.

## Features

- Pure Lua implementation with LuaSocket dependency
- Identical CLI interface to other implementations
- Root privilege checking via POSIX library or `id` command
- System time setting via `date` command
- Verbose and syslog logging support
- Combined flag support (e.g., `-nv`, `-nvs`)

## Requirements

- Lua 5.1 or higher
- LuaSocket library (`luasocket` package)
- Optional: lua-posix for better root detection

### Installing Dependencies

**macOS (Homebrew):**
```bash
brew install lua luarocks
luarocks install luasocket
luarocks install luaposix  # optional
```

**Ubuntu/Debian:**
```bash
sudo apt-get install lua5.3 lua-socket lua-posix
```

**Fedora/RHEL:**
```bash
sudo dnf install lua lua-socket lua-posix
```

**Via LuaRocks (all platforms):**
```bash
luarocks install luasocket
luarocks install luaposix  # optional
```

## Building

No compilation needed. Just make the script executable:

```bash
make
# or manually:
chmod +x timesync.lua
```

## Usage

Run as a script:

```bash
./timesync.lua                    # query pool.ntp.org
./timesync.lua -n -v              # test mode with verbose output
./timesync.lua -t 1500 time.google.com
lua timesync.lua -nv 192.168.1.1  # explicit lua interpreter
```

## Implementation Details

- **Networking**: LuaSocket UDP for cross-platform network operations
- **Root checking**: lua-posix `geteuid()` if available, falls back to `id -u` command
- **Time setting**: Uses `date` command (format: `YYYYMMDDhhmm.ss`)
- **Script size**: ~12 KB
- **Memory**: Very lightweight, ~2-3 MB resident (Lua interpreter + libraries)

## Platform Support

Works on:
- Linux
- macOS
- BSD systems
- Any Unix-like system with Lua and LuaSocket

## Notes

- Requires LuaSocket installed (not in standard Lua distribution)
- Root privileges required to actually set system time
- Test mode (`-n`) bypasses root requirement
- Falls back to shell command for root checking if lua-posix unavailable
