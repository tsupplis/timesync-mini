#!/usr/bin/env perl
#
# timesync - Minimal SNTP client (RFC 5905 subset)
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 tsupplis
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

use strict;
use warnings;
use Socket;
use Time::HiRes qw(gettimeofday);
use Sys::Syslog qw(:standard :macros);
use POSIX qw(strftime);

# Constants
use constant NTP_PACKET_SIZE => 48;
# Number of seconds between 1900 (NTP epoch) and 1970 (Unix epoch)
use constant NTP_UNIX_EPOCH  => 2208988800;
use constant {
    NTP_PORT           => 123,
    DEFAULT_SERVER     => 'pool.ntp.org',
    DEFAULT_TIMEOUT_MS => 2000,
    DEFAULT_RETRIES    => 3,
};

# Configuration
my %config = (
    server      => DEFAULT_SERVER,
    timeout_ms  => DEFAULT_TIMEOUT_MS,
    retries     => DEFAULT_RETRIES,
    verbose     => 0,
    test_only   => 0,
    use_syslog  => 0,
);

# Logging function with time prefix (always to stderr)
sub stderr_log {
    my $msg = shift;
    my $ts = strftime('%Y-%m-%d %H:%M:%S', localtime);
    warn "$ts $msg\n";
}

sub log_syslog {
    return unless $config{use_syslog};
    my ($level, $msg) = @_;
    syslog($level, '%s', $msg);
}

sub show_usage {
    print STDERR "Usage: timesync [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp server]\n";
    print STDERR "  server       NTP server to query (default: pool.ntp.org)\n";
    print STDERR "  -t timeout   Timeout in ms (default: 2000)\n";
    print STDERR "  -r retries   Number of retries (default: 3)\n";
    print STDERR "  -n           Test mode (no system time adjustment)\n";
    print STDERR "  -v           Verbose output\n";
    print STDERR "  -s           Enable syslog logging\n";
    print STDERR "  -h           Show this help message\n";
}

# Parse command line
while (@ARGV) {
    my $arg = shift @ARGV;
    if ($arg eq '-h') {
        show_usage();
        exit 0;
    } elsif ($arg eq '-t' && @ARGV) {
        $config{timeout_ms} = shift @ARGV;
        $config{timeout_ms} = 2000 if $config{timeout_ms} <= 0;
        $config{timeout_ms} = 6000 if $config{timeout_ms} > 6000;
    } elsif ($arg eq '-r' && @ARGV) {
        $config{retries} = shift @ARGV;
        $config{retries} = 3  if $config{retries} <= 0;
        $config{retries} = 10 if $config{retries} > 10;
    } elsif ($arg =~ /^-([nvsh]+)$/) {
        # Handle combined flags like -nv
        my $flags = $1;
        if ($flags =~ /h/) { show_usage(); exit 0; }
        $config{test_only}  = 1 if $flags =~ /n/;
        $config{verbose}    = 1 if $flags =~ /v/;
        $config{use_syslog} = 1 if $flags =~ /s/;
    } elsif ($arg !~ /^-/) {
        $config{server} = $arg;
    }
}

# Disable syslog in test mode
$config{use_syslog} = 0 if $config{test_only};

if ($config{verbose}) {
    stderr_log("DEBUG Using server: $config{server}");
    stderr_log(sprintf("DEBUG Timeout: %d ms, Retries: %d, Syslog: %s",
        $config{timeout_ms}, $config{retries},
        $config{use_syslog} ? 'on' : 'off'));
}

# Open syslog if needed
openlog('ntp_client', 'pid,cons', LOG_USER) if $config{use_syslog};

# Get time in milliseconds
sub get_time_ms {
    my ($sec, $usec) = gettimeofday();
    return $sec * 1000 + int($usec / 1000);
}

# Build NTP request packet (48 bytes)
# LI=0, VN=4, Mode=3 (client) -> 0b00100011 = 0x23
# rest are zero (we don't set transmit timestamp; some servers prefer it zero)
sub build_ntp_request {
    return pack('C', 0x23) . ("\0" x (NTP_PACKET_SIZE - 1));
}

# Read 64-bit NTP timestamp from buffer (bytes are big-endian).
# NTP timestamp: seconds (32 bits) + fractional (32 bits).
# We convert to milliseconds since Unix epoch.
sub ntp_to_unix_ms {
    my ($buf, $offset) = @_;

    my $sec  = unpack('N', substr($buf, $offset,     4));
    my $frac = unpack('N', substr($buf, $offset + 4, 4));

    return -1 if $sec < NTP_UNIX_EPOCH;

    my $unix_sec = $sec - NTP_UNIX_EPOCH;
    my $usec     = ($frac * 1_000_000) >> 32;  # fraction to microseconds

    return $unix_sec * 1000 + int($usec / 1000);
}

# Format time in ISO 8601 local time with timezone offset
sub format_time_local {
    my $ms  = shift;
    my $sec = int($ms / 1000);
    return strftime('%Y-%m-%dT%H:%M:%S%z', localtime($sec));
}

# Perform a single NTP query attempt; returns (0, results...) on success or (-1) on failure
sub do_ntp_query {
    my ($server, $timeout_ms) = @_;

    # Resolve hostname
    my @addrs = gethostbyname($server);
    return -1 unless @addrs;

    my $ip = inet_ntoa($addrs[4]);

    # Create UDP socket
    socket(my $sock, AF_INET, SOCK_DGRAM, getprotobyname('udp'))
        or return -1;

    # Set receive timeout
    my $timeout_tv = pack('L!L!', int($timeout_ms / 1000),
                          ($timeout_ms % 1000) * 1000);
    unless (setsockopt($sock, SOL_SOCKET, SO_RCVTIMEO, $timeout_tv)) {
        stderr_log("WARNING setsockopt SO_RCVTIMEO failed: $!");
        close($sock);
        return -1;
    }

    # Build and send NTP request
    my $packet = build_ntp_request();
    my $addr   = sockaddr_in(NTP_PORT, inet_aton($ip));

    my $local_before = get_time_ms();
    my $sent = send($sock, $packet, 0, $addr);
    if (!defined $sent || $sent != NTP_PACKET_SIZE) {
        stderr_log("WARNING Failed to send NTP request");
        close($sock);
        return -1;
    }

    # Receive response
    my $response;
    my $recv_addr = recv($sock, $response, NTP_PACKET_SIZE, 0);
    my $local_after = get_time_ms();

    close($sock);

    # Must have a full packet
    return -1 unless defined $recv_addr && length($response) >= NTP_PACKET_SIZE;

    # Validate mode = 4 (server)
    my $first_byte = unpack('C', substr($response, 0, 1));
    my $mode       = $first_byte & 0x07;
    if ($mode != 4) {
        stderr_log("WARNING Invalid mode in NTP response: $mode");
        return -1;
    }

    # Validate stratum != 0
    my $stratum = unpack('C', substr($response, 1, 1));
    if ($stratum == 0) {
        stderr_log("WARNING Invalid stratum in NTP response: $stratum");
        return -1;
    }

    # Validate version (1-4 valid)
    my $version = ($first_byte >> 3) & 0x07;
    if ($version < 1 || $version > 4) {
        stderr_log("WARNING Invalid version in NTP response: $version");
        return -1;
    }

    # Parse transmit timestamp (bytes 40-47)
    my $remote_ms = ntp_to_unix_ms($response, 40);
    if ($remote_ms < 0) {
        stderr_log("WARNING Invalid transmit timestamp in NTP response");
        return -1;
    }

    return (0, $local_before, $remote_ms, $local_after, $ip);
}

# Main execution
my $local_before_ms = 0;
my $remote_ms       = 0;
my $local_after_ms  = 0;
my $server_addr     = '';
my $success         = 0;

for my $attempt (1 .. $config{retries}) {
    $server_addr = '';
    if ($config{verbose}) {
        stderr_log("DEBUG Attempt ($attempt) at NTP query on $config{server} ...");
    }

    my ($rc, $before, $remote, $after, $ip) =
        do_ntp_query($config{server}, $config{timeout_ms});

    if (defined $rc && $rc == 0) {
        $local_before_ms = $before;
        $remote_ms       = $remote;
        $local_after_ms  = $after;
        $server_addr     = $ip;
        $success         = 1;
        last;
    }

    # small backoff before retry
    select(undef, undef, undef, 0.2);
}

unless ($success) {
    stderr_log("ERROR Failed to contact NTP server $config{server} after $config{retries} attempts");
    log_syslog(LOG_ERR, "NTP query failed for $config{server} after $config{retries} attempts");
    closelog() if $config{use_syslog};
    exit 2;
}

# Estimate network delay and clock offset like simple SNTP:
# t1 = client send time (local_before), t2 = server receive (not available),
# t3 = server transmit (remote_ms), t4 = client receive (local_after).
# offset = ((t3 + t2) - (t1 + t4)) / 2, but since t2 is unknown:
# offset ≈ t3 - ((t1 + t4) / 2)
# Check for potential overflow in avg calculation
if ($local_before_ms > 9223372036854775807 - $local_after_ms) {
    stderr_log("ERROR Time averaging would overflow, invalid timestamps.");
    log_syslog(LOG_ERR, "Time averaging would overflow");
    closelog() if $config{use_syslog};
    exit 1;
}
my $avg_local_ms  = int(($local_before_ms + $local_after_ms) / 2);
my $offset_ms     = $remote_ms - $avg_local_ms;
my $roundtrip_ms  = $local_after_ms - $local_before_ms;

# Parse remote time unconditionally — needed for year check and success log
my $remote_time_str = format_time_local($remote_ms);
my $remote_year     = (localtime(int($remote_ms / 1000)))[5] + 1900;

if ($config{verbose}) {
    my $local_time_str  = format_time_local($local_before_ms);
    my $local_after_str = sprintf("%03d", $local_after_ms % 1000);
    my $remote_ms_str   = sprintf("%03d", $remote_ms % 1000);

    stderr_log("DEBUG Server: $config{server} ($server_addr)");
    stderr_log("DEBUG Local time: $local_time_str.$local_after_str");
    stderr_log("DEBUG Remote time: $remote_time_str.$remote_ms_str");
    stderr_log("DEBUG Local before(ms): $local_before_ms");
    stderr_log("DEBUG Local after(ms): $local_after_ms");
    stderr_log("DEBUG Estimated roundtrip(ms): $roundtrip_ms");
    stderr_log("DEBUG Estimated offset remote - local(ms): $offset_ms");
    log_syslog(LOG_INFO,
        "NTP server=$config{server} addr=$server_addr offset_ms=$offset_ms rtt_ms=$roundtrip_ms");
}

# Basic sanity check on roundtrip
if ($roundtrip_ms < 0 || $roundtrip_ms > 10000) {
    stderr_log("ERROR Invalid roundtrip time: $roundtrip_ms ms");
    log_syslog(LOG_ERR, "Invalid suspiciously long roundtrip time: $roundtrip_ms ms");
    closelog() if $config{use_syslog};
    exit 1;
}

# Check if offset is within acceptable range (no adjustment needed)
my $abs_offset = abs($offset_ms);
if ($abs_offset > 0 && $abs_offset < 500) {
    if ($config{verbose}) {
        stderr_log("INFO Delta < 500ms, not setting system time.");
        log_syslog(LOG_INFO, "Delta < 500ms, not setting system time");
    }
    closelog() if $config{use_syslog};
    exit 0;
}

# Validate remote year
if ($remote_year < 2025 || $remote_year > 2200) {
    stderr_log("ERROR Remote year is out of valid range (2025-2200): $remote_year");
    log_syslog(LOG_ERR, "Remote year is out of valid range (2025-2200): $remote_year");
    closelog() if $config{use_syslog};
    exit 1;
}

# Test mode — return without adjusting
if ($config{test_only}) {
    closelog() if $config{use_syslog};
    exit 0;
}

# Check if running as root
if ($< != 0) {
    stderr_log("WARNING Not root, not setting system time.");
    log_syslog(LOG_WARNING, "Not root, not setting system time");
    closelog() if $config{use_syslog};
    exit 0;
}

# Set system time using settimeofday
my $half_rtt    = int($roundtrip_ms / 2);
# Check for potential overflow before time calculation
if ($remote_ms > 9223372036854775807 - $half_rtt) {
    stderr_log("ERROR Time calculation would overflow, not adjusting system time.");
    log_syslog(LOG_ERR, "Time calculation would overflow");
    closelog() if $config{use_syslog};
    exit 1;
}
my $new_time_ms   = $remote_ms + $half_rtt;
my $new_time_sec  = int($new_time_ms / 1000);
my $new_time_usec = ($new_time_ms % 1000) * 1000;

eval {
    require Time::HiRes;
    Time::HiRes->import('settimeofday');
};

if ($@) {
    stderr_log("ERROR Time::HiRes::settimeofday not available");
    log_syslog(LOG_ERR, "Time::HiRes::settimeofday not available");
    closelog() if $config{use_syslog};
    exit 10;
}

if (eval { Time::HiRes::settimeofday($new_time_sec, $new_time_usec); 1 }) {
    stderr_log(sprintf("INFO System time set using settimeofday (%s.%03d)",
        $remote_time_str, $remote_ms % 1000));
    log_syslog(LOG_INFO, sprintf("System time set using settimeofday (%s.%03d)",
        $remote_time_str, $remote_ms % 1000));
    closelog() if $config{use_syslog};
    exit 0;
} else {
    stderr_log("ERROR Failed to adjust system time with settimeofday: $!");
    log_syslog(LOG_ERR, "Failed to adjust system time with settimeofday: $!");
    closelog() if $config{use_syslog};
    exit 10;
}
