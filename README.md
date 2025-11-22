# timesync-mini

`timesync-mini` is a simple command-line tool for synchronizing system time with NTP servers. It is available in two implementations:

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![C](https://img.shields.io/badge/language-c-blue.svg)
![C](https://img.shields.io/badge/language-go-blue.svg)

- **C implementation** (`c/`): Minimal dependencies, uses only standard C library and BSD sockets
- **Go implementation** (`go/`): Uses the beevik/ntp package for NTP queries

Both implementations support verbose logging and test mode.

## Usage

```sh
timesync-mini [options] <ntp-server>
```

### Options

- `-n` : Run in test mode (does not actually set the system time).
- `-v` : Enable verbose logging.
- `-h` : Display usage information.

### Positional Arguments

- `<ntp-server>` : The NTP server to synchronize with. If not provided, defaults to `time.google.com`.

## Examples

### Synchronize with a specific NTP server

```sh
timesync-mini time.nist.gov
```

### Run in test mode

```sh
timesync-mini -n time.nist.gov
```

### Enable verbose logging

```sh
timesync-mini -v time.nist.gov
```

### Display usage information

```sh
timesync-mini -h
```

## Configuration

The configuration is parsed from the command line flags and positional arguments. The configuration structure is as follows:

```go
type Config struct {
    Server  string
    Test    bool
    Verbose bool
}
```

## Error Handling

The program differentiates between the `-h` flag for displaying usage information and unknown flags. If an unknown flag is provided, the program will display an error message and the usage information.

## Logging

The program uses the standard `log` package for logging. If verbose logging is enabled, additional information will be logged.

## Dependencies

### Go Implementation
- [github.com/beevik/ntp](https://github.com/beevik/ntp) : A Go package for querying NTP servers.

### C Implementation
- Standard C library only (BSD sockets)
- On Solaris/Illumos: additional `-lsocket -lnsl` linker flags required

