# timesync-mini

`timesync-mini` is a simple command-line tool written in Go that synchronizes the system time with a specified NTP server. It supports verbose logging and a test mode.

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

- [github.com/beevik/ntp](https://github.com/beevik/ntp) : A Go package for querying NTP servers.

## License

This project is licensed under the MIT License.
