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
use Time::HiRes qw(gettimeofday tv_interval);
use Sys::Syslog qw(:standard :macros);
use POSIX qw(strftime);

# Constants
use constant {
    NTP_PORT           => 123,
    NTP_PACKET_SIZE    => 48,
    NTP_UNIX_EPOCH     => 2208988800,
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

# Logging functions
sub log_stderr {
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
    print STDERR <<'EOF';
Usage: timesync [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp server]
  server       NTP server to query (default: pool.ntp.org)
  -t timeout   Timeout in ms (default: 2000)
  -r retries   Number of retries (default: 3)
  -n           Test mode (no system time adjustment)
  -v           Verbose output
  -s           Enable syslog logging
  -h           Show this help message
EOF
    exit 0;
}

# Parse command line
while (@ARGV) {
    my $arg = shift @ARGV;
    if ($arg eq '-h') {
        show_usage();
    } elsif ($arg eq '-t' && @ARGV) {
        $config{timeout_ms} = shift @ARGV;
        $config{timeout_ms} = 1 if $config{timeout_ms} < 1;
        $config{timeout_ms} = 6000 if $config{timeout_ms} > 6000;
    } elsif ($arg eq '-r' && @ARGV) {
        $config{retries} = shift @ARGV;
        $config{retries} = 1 if $config{retries} < 1;
        $config{retries} = 10 if $config{retries} > 10;
    } elsif ($arg =~ /^-([nvsh]+)$/) {
        # Handle combined flags like -nv
        my $flags = $1;
        show_usage() if $flags =~ /h/;
        $config{test_only} = 1 if $flags =~ /n/;
        $config{verbose} = 1 if $flags =~ /v/;
        $config{use_syslog} = 1 if $flags =~ /s/;
    } elsif ($arg !~ /^-/) {
        $config{server} = $arg;
    }
}

# Disable syslog in test mode
$config{use_syslog} = 0 if $config{test_only};

# Open syslog if needed
openlog('ntp_client', 'pid', LOG_USER) if $config{use_syslog};

if ($config{verbose}) {
    log_stderr("DEBUG Using server: $config{server}");
    log_stderr(sprintf("DEBUG Timeout: %d ms, Retries: %d, Syslog: %s",
        $config{timeout_ms}, $config{retries},
        $config{use_syslog} ? 'on' : 'off'));
}

# Get time in milliseconds
sub get_time_ms {
    my ($sec, $usec) = gettimeofday();
    return $sec * 1000 + int($usec / 1000);
}

# Build NTP request packet
sub build_ntp_request {
    return pack('C', 0x1b) . ("\0" x (NTP_PACKET_SIZE - 1));
}

# Parse NTP timestamp to Unix milliseconds
sub ntp_to_unix_ms {
    my ($buf, $offset) = @_;
    
    my $sec = unpack('N', substr($buf, $offset, 4));
    my $frac = unpack('N', substr($buf, $offset + 4, 4));
    
    return 0 if $sec < NTP_UNIX_EPOCH;
    
    my $unix_sec = $sec - NTP_UNIX_EPOCH;
    my $unix_ms = int($frac * 1000 / 2**32);
    
    return $unix_sec * 1000 + $unix_ms;
}

# Format time in ISO format
sub format_time {
    my $ms = shift;
    my $sec = int($ms / 1000);
    my $msec = $ms % 1000;
    my $ts = strftime('%Y-%m-%dT%H:%M:%S', gmtime($sec));
    return sprintf("%s+0000.%03d", $ts, $msec);
}

# Perform NTP query
sub do_ntp_query {
    my $attempt = 1;
    
    while ($attempt <= $config{retries}) {
        log_stderr("DEBUG Attempt ($attempt) at NTP query on $config{server} ...")
            if $config{verbose};
        
        # Resolve hostname
        my @addrs = gethostbyname($config{server});
        unless (@addrs) {
            log_stderr("ERROR Cannot resolve hostname: $config{server}");
            return 2;
        }
        
        my $ip = inet_ntoa($addrs[4]);
        
        # Create UDP socket
        socket(my $sock, AF_INET, SOCK_DGRAM, getprotobyname('udp'))
            or die "Cannot create socket: $!";
        
        # Set timeout
        my $timeout_sec = $config{timeout_ms} / 1000;
        my $timeout_tv = pack('L!L!', int($timeout_sec), int(($timeout_sec - int($timeout_sec)) * 1_000_000));
        setsockopt($sock, SOL_SOCKET, SO_RCVTIMEO, $timeout_tv);
        
        # Build and send NTP request
        my $packet = build_ntp_request();
        my $addr = sockaddr_in(NTP_PORT, inet_aton($ip));
        
        my $local_before = get_time_ms();
        send($sock, $packet, 0, $addr);
        
        # Receive response
        my $response;
        my $recv_addr = recv($sock, $response, NTP_PACKET_SIZE, 0);
        my $local_after = get_time_ms();
        
        close($sock);
        
        unless (defined $recv_addr && length($response) == NTP_PACKET_SIZE) {
            if ($attempt < $config{retries}) {
                select(undef, undef, undef, 0.2);
                $attempt++;
                next;
            }
            log_stderr("ERROR Timeout waiting for NTP response");
            log_syslog(LOG_ERR, "Timeout waiting for NTP response");
            return 2;
        }
        
        # Validate response
        my $first_byte = unpack('C', substr($response, 0, 1));
        my $mode = $first_byte & 0x07;
        my $stratum = unpack('C', substr($response, 1, 1));
        
        if ($mode != 4) {
            log_stderr("ERROR Invalid mode in NTP response: $mode");
            return 2;
        }
        
        if ($stratum == 0) {
            log_stderr("ERROR Invalid stratum in NTP response");
            return 2;
        }
        
        # Parse transmit timestamp (bytes 40-47)
        my $remote_ms = ntp_to_unix_ms($response, 40);
        return 2 unless $remote_ms;
        
        # Calculate offset and RTT
        my $avg_local = int(($local_before + $local_after) / 2);
        my $offset = $remote_ms - $avg_local;
        my $rtt = $local_after - $local_before;
        
        if ($config{verbose}) {
            log_stderr("DEBUG Server: $config{server} ($ip)");
            log_stderr("DEBUG Local before(ms): $local_before");
            log_stderr("DEBUG Local after(ms): $local_after");
            log_stderr("DEBUG Remote time(ms): $remote_ms");
            log_stderr("DEBUG Estimated roundtrip(ms): $rtt");
            log_stderr("DEBUG Estimated offset remote - local(ms): $offset");
            
            log_syslog(LOG_INFO,
                "NTP server=$config{server} addr=$ip offset_ms=$offset rtt_ms=$rtt");
        }
        
        # Validate RTT
        if ($rtt < 0 || $rtt > 10000) {
            log_stderr("ERROR Invalid roundtrip time: $rtt ms");
            log_syslog(LOG_ERR, "Invalid roundtrip time: $rtt ms");
            return 1;
        }
        
        # Check if offset is small
        my $abs_offset = abs($offset);
        if ($abs_offset > 0 && $abs_offset < 500) {
            if ($config{verbose}) {
                log_stderr("INFO Delta < 500ms, not setting system time.");
                log_syslog(LOG_INFO, "Delta < 500ms, not setting system time");
            }
            return 0;
        }
        
        # Validate remote time year
        my $remote_sec = int($remote_ms / 1000);
        my $remote_year = (gmtime($remote_sec))[5] + 1900;
        
        if ($remote_year < 2025 || $remote_year > 2200) {
            log_stderr("ERROR Remote year is out of valid range (2025-2200): $remote_year");
            log_syslog(LOG_ERR, "Remote year out of range: $remote_year");
            return 1;
        }
        
        # Test mode
        if ($config{test_only}) {
            if ($config{verbose}) {
                log_stderr("INFO Test mode: would adjust system time by $offset ms");
                log_syslog(LOG_INFO, "Test mode: would adjust system time by $offset ms");
            }
            return 0;
        }
        
        # Check if running as root
        if ($< != 0) {  # $< is effective UID
            log_stderr("WARNING Not root, not setting system time.");
            log_syslog(LOG_WARNING, "Not root, not setting system time")
                if $config{use_syslog};
            return 10;
        }
        
        # Set system time
        my $new_time_sec = int($remote_ms / 1000);
        my $new_time_usec = ($remote_ms % 1000) * 1000;
        
        # Load Time::HiRes for settimeofday
        eval {
            require Time::HiRes;
            Time::HiRes->import('settimeofday');
        };
        
        if ($@) {
            log_stderr("ERROR Time::HiRes::settimeofday not available");
            log_syslog(LOG_ERR, "Time::HiRes::settimeofday not available")
                if $config{use_syslog};
            return 10;
        }
        
        # Try settimeofday (requires root)
        if (eval { Time::HiRes::settimeofday($new_time_sec, $new_time_usec); 1 }) {
            if ($config{verbose}) {
                log_stderr(sprintf("INFO System time set (%s)", format_time($remote_ms)));
                log_syslog(LOG_INFO, sprintf("System time set (%s)", format_time($remote_ms)));
            }
            return 0;
        } else {
            log_stderr("ERROR Failed to adjust system time: $@");
            log_syslog(LOG_ERR, "Failed to adjust system time")
                if $config{use_syslog};
            return 10;
        }
    }
}

# Main execution
my $rc = do_ntp_query();
closelog() if $config{use_syslog};
exit $rc;
