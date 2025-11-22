# timesync-mini

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

![C](https://img.shields.io/badge/c-00599C?style=flat&logo=c&logoColor=white)
![Go](https://img.shields.io/badge/go-00ADD8?style=flat&logo=go&logoColor=white)
`timesync-mini` is a simple command-line tool for synchronizing system time with NTP servers. It is available in two implementations:

- **C implementation** (`c/`): Minimal dependencies, uses only standard C library and BSD sockets
- **Go implementation** (`go/`): Uses the beevik/ntp package for NTP queries

Both implementations support verbose logging and test mode.

## Usage

```sh
timesync-mini [options] <ntp-server>
```

### Options

- `-t` : Run in test mode (does not actually set the system time).
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
timesync-mini -t time.nist.gov
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

## License

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

This project is licensed under the MIT License. See [LICENSE.md](LICENSE.md) for details.

Both the C and Go implementations are released under the MIT License.
