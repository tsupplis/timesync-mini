/*
 * timesync.c
 *
 * Minimal SNTP client (RFC 5905 subset) -> query server, print offset/delay in
 * ms. set system time if run as root and offset is > 500ms.
 *
 * Build:
 *   gcc -std=c11 -O2 -Wall -o timesync timesync.c (-socket -lnsl for Solaris)
 *
 *
 * Usage:
 *   ./timesync                    # query pool.ntp.org
 *   ./timesync -server time.google.com -timeout-ms 1500 -retries 2 -syslog
 *
 * Notes:
 * - No external libraries required (uses BSD sockets).
 * - Works on Linux/macOS/Solaris/BSD. Requires linking to standard C library
 * only (with exception of solaris where -lsocket -lnsl may be needed).
 */

#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

static const char *const default_ntp_port = "123";
#define NTP_PACKET_SIZE 48
/* Number of seconds between 1900 (NTP epoch) and 1970 (Unix epoch) */
#define NTP_UNIX_EPOCH_DIFF 2208988800UL

/* CLI defaults */
static const char *const default_server = "pool.ntp.org";
static const int default_timeout_ms = 2000;
static const int default_retries = 3;

/* Convert timeval to milliseconds since epoch */
static int64_t tv_to_ms(const struct timeval *tv) {
    return (int64_t)tv->tv_sec * 1000LL + (tv->tv_usec / 1000);
}

/* Read 64-bit NTP timestamp from buffer (bytes are big-endian).
   NTP timestamp: seconds (32 bits) + fractional (32 bits).
   We convert to milliseconds since Unix epoch. */
static int64_t ntp_ts_to_unix_ms(const uint8_t *buf) {
    if (buf == NULL) {
        return -1; // NULL buffer
    }
    uint32_t sec = (buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3];
    uint32_t frac = (buf[4] << 24) | (buf[5] << 16) | (buf[6] << 8) | buf[7];

    if (sec < NTP_UNIX_EPOCH_DIFF) {
        return -1; // Invalid timestamp
    }
    uint64_t usec =
        ((uint64_t)frac * 1000000ULL) >> 32; /* fraction to microseconds */
    uint64_t unix_sec = (uint64_t)sec - NTP_UNIX_EPOCH_DIFF;
    return (int64_t)(unix_sec * 1000LL + (usec / 1000ULL));
}

/* Log function with time prefix (always to stderr) */
static void stderr_log(const char *fmt, ...) {
    time_t now = time(NULL);
    struct tm local_tm;
    char local_time_str[32] = "";
    if (now != (time_t)-1 && localtime_r(&now, &local_tm) != NULL) {
        if (strftime(local_time_str, sizeof(local_time_str), "%Y-%m-%d %H:%M:%S", &local_tm) == 0) {
            snprintf(local_time_str, sizeof(local_time_str), "TIME_FORMAT_ERROR");
        }
    } else {
        snprintf(local_time_str, sizeof(local_time_str), "TIME_UNAVAILABLE");
    }

    fprintf(stderr, "%s ", local_time_str);
    
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    
    fprintf(stderr, "\n");
}

/* Build an NTP request packet (48 bytes) */
static void build_ntp_request(uint8_t *buf) {
    memset(buf, 0, NTP_PACKET_SIZE);
    /* LI = 0 (no warning), VN = 4 (version), Mode = 3 (client) -> 0b00 100 011
     * = 0x23 */
    buf[0] = 0x23; /* 0010 0011 */
    /* rest are zero (we don't set transmit timestamp; some servers prefer it
     * zero) */
}

/* Send single query and return 0 on success (outputs values via pointers) */
static int do_ntp_query(const char *server, int timeout_ms,
                        int64_t *out_local_before_ms, int64_t *out_remote_ms,
                        int64_t *out_local_after_ms, char *server_addr_str,
                        size_t server_addr_len) {
    struct addrinfo hints = {0}, *res = NULL, *rp;
    int sock = -1, rc = -1;
    uint8_t packet[NTP_PACKET_SIZE];
    struct timeval tv;
    build_ntp_request(packet);

    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;

    if (getaddrinfo(server, default_ntp_port, &hints, &res) != 0) {
        return -1;
    }

    for (rp = res; rp != NULL; rp = rp->ai_next) {
        sock = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (sock < 0) {
            continue;
        }

        /* set receive timeout */
        tv.tv_sec = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;
        if (setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) {
            stderr_log("WARNING setsockopt SO_RCVTIMEO failed: %s", strerror(errno));
            close(sock);
            sock = -1;
            continue;
        }

        /* capture local time before send */
        struct timeval before;
        gettimeofday(&before, NULL);
        ssize_t sent = sendto(sock, packet, NTP_PACKET_SIZE, 0, rp->ai_addr,
                              rp->ai_addrlen);
        if (sent != NTP_PACKET_SIZE) {
            stderr_log("WARNING Failed to send NTP request");
            close(sock);
            sock = -1;
            continue;
        }

        /* wait for response */
        uint8_t buf[NTP_PACKET_SIZE];
        struct sockaddr_storage src;
        socklen_t srclen = sizeof(src);
        ssize_t rec = recvfrom(sock, buf, sizeof(buf), 0,
                               (struct sockaddr *)&src, &srclen);
        struct timeval after;
        gettimeofday(&after, NULL);

        if (rec < 0) {
            close(sock);
            sock = -1;
            continue;
        }
        if ((size_t)rec < NTP_PACKET_SIZE) {
            /* ignore short replies */
            close(sock);
            sock = -1;
            continue;
        }

        /* Validate NTP response */
        /* Check mode field = 4 (server) */
        if ((buf[0] & 0x07) != 4) {
            stderr_log("WARNING Invalid mode in NTP response: %d",
                       buf[0] & 0x07);
            close(sock);
            sock = -1;
            continue;
        }

        /* Check stratum (0 = invalid) */
        if (buf[1] == 0) {
            stderr_log("WARNING Invalid stratum in NTP response: %d", buf[1]);
            close(sock);
            sock = -1;
            continue;
        }

        /* Check version (1-4 valid) */
        int protocol_version = (buf[0] >> 3) & 0x07;
        if (protocol_version < 1 || protocol_version > 4) {
            stderr_log("WARNING Invalid version in NTP response: %d",
                       protocol_version);
            close(sock);
            sock = -1;
            continue;
        }

        /* remote transmit timestamp is at bytes 40..47 */
        int64_t remote_ms = ntp_ts_to_unix_ms(&buf[40]);
        if (remote_ms < 0) {
            stderr_log("WARNING Invalid transmit timestamp in NTP response");
            close(sock);
            sock = -1;
            continue;
        }

        /* fill outputs */
        *out_local_before_ms = tv_to_ms(&before);
        *out_local_after_ms = tv_to_ms(&after);
        *out_remote_ms = remote_ms;

        /* compose server address string */
        if (server_addr_str && server_addr_len > 8) {
            if (src.ss_family == AF_INET) {
                if (server_addr_len < INET_ADDRSTRLEN) {
                    snprintf(server_addr_str, server_addr_len, "invalid");
                } else {
                    struct sockaddr_in *s4 = (struct sockaddr_in *)&src;
                    inet_ntop(AF_INET, &s4->sin_addr, server_addr_str,
                              server_addr_len);
                }
            } else if (src.ss_family == AF_INET6) {
                if (server_addr_len < INET6_ADDRSTRLEN) {
                    snprintf(server_addr_str, server_addr_len, "invalid");
                } else {
                    struct sockaddr_in6 *s6 = (struct sockaddr_in6 *)&src;
                    inet_ntop(AF_INET6, &s6->sin6_addr, server_addr_str,
                              server_addr_len);
                }
            } else {
                snprintf(server_addr_str, server_addr_len, "unknown");
            }
        }

        rc = 0;
        close(sock);
        break;
    }

    freeaddrinfo(res);
    return rc;
}

void usage(const char *prog) {
    fprintf(stderr,
            "Usage: %s [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp "
            "server]\n",
            prog);
    fprintf(stderr,
            "  server       NTP server to query (default: pool.ntp.org)\n");
    fprintf(stderr, "  -t timeout   Timeout in ms (default: 2000)\n");
    fprintf(stderr, "  -r retries   Number of retries (default: 3)\n");
    fprintf(stderr, "  -n           Test mode (no system time adjustment)\n");
    fprintf(stderr, "  -v           Verbose output\n");
    fprintf(stderr, "  -s           Enable syslog logging\n");
    fprintf(stderr, "  -h           Show this help message\n");
}

typedef struct _config_t {
    const char *server;
    int timeout_ms;
    int retries;
    int verbose;
    int test_only;
    int use_syslog;
} config_t;

/**
 * Main function:
 * 1. Parse command-line options and initialize configuration.
 * 2. Query NTP server with retry logic and timeout handling.
 * 3. Calculate clock offset and network delay from timestamps.
 * 4. Validate response (sanity checks on time values and roundtrip).
 * 5. Adjust system clock if running as root and offset exceeds threshold.
 * 6. Log results to stderr and optionally to syslog.
 */
int main(int argc, char **argv) {
    config_t config = {0};
    int opt;
    config.server = default_server;
    config.timeout_ms = default_timeout_ms;
    config.retries = default_retries;
    config.verbose = 0;
    config.test_only = 0;

    while ((opt = getopt(argc, argv, "t:r:vnsh")) != -1) {
        if (opt == 's') {
            config.use_syslog = 1;
        } else if (opt == 't') {
            config.timeout_ms = atoi(optarg);
            if (config.timeout_ms > 6000) {
                config.timeout_ms = 6000;
            }
            if (config.timeout_ms <= 0) {
                config.timeout_ms = 2000;
            }
        } else if (opt == 'r') {
            config.retries = atoi(optarg);
            if (config.retries <= 0) {
                config.retries = 3;
            }
            if (config.retries > 10) {
                config.retries = 10;
            }
        } else if (opt == 'v') {
            config.verbose = 1;
        } else if (opt == 'n') {
            config.test_only = 1;
        } else if (opt == 'h') {
            usage("timesync");
            exit(0);
        } else {
            /* ignore unknowns; simple CLI */
        }
    }
    /* If there is a positional argument left, treat it as the server */
    if (optind < argc) {
        config.server = argv[optind];
    }

    /* Disable syslog in test mode */
    if (config.test_only) {
        config.use_syslog = 0;
    }
    if (config.verbose) {
        stderr_log("DEBUG Using server: %s", config.server);
        stderr_log("DEBUG Timeout: %d ms, Retries: %d, Syslog: %s",
                   config.timeout_ms, config.retries,
                   config.use_syslog ? "on" : "off");
    }

    if (config.use_syslog) {
        openlog("ntp_client", LOG_PID | LOG_CONS, LOG_USER);
        atexit(closelog);
    }

    int attempt;
    int64_t local_before_ms = 0, remote_ms = 0, local_after_ms = 0;
    char server_addr[INET6_ADDRSTRLEN] = {0};
    int success = 0;

    for (attempt = 0; attempt < config.retries; ++attempt) {
        server_addr[0] = '\0';
        if (config.verbose) {
            stderr_log("DEBUG Attempt (%d) at NTP query on %s ...", attempt + 1,
                       config.server);
        }
        if (do_ntp_query(config.server, config.timeout_ms, &local_before_ms,
                         &remote_ms, &local_after_ms, server_addr,
                         sizeof(server_addr)) == 0) {
            success = 1;
            break;
        }
        /* small backoff before retry */
        usleep(200000);
    }

    if (!success) {
        stderr_log("ERROR Failed to contact NTP server %s after %d attempts",
                   config.server, config.retries);
        if (config.use_syslog) {
            syslog(LOG_ERR, "NTP query failed for %s after %d attempts",
                   config.server, config.retries);
        }
        return 2;
    }

    /* estimate network delay and clock offset like simple SNTP:
       t1 = client send time (local_before), t2 = server receive (not
       available), t3 = server transmit (remote_ms), t4 = client receive
       (local_after). For a simple client we use offset = ((t3 + t2) - (t1 +
       t4)) / 2, but since we don't know server receive time, we use offset ≈ t3
       - ((t1 + t4) / 2)
    */
    /* Check for potential overflow in avg calculation */
    if (local_before_ms > INT64_MAX - local_after_ms) {
        stderr_log("ERROR Time averaging would overflow, invalid timestamps.");
        if (config.use_syslog) {
            syslog(LOG_ERR, "Time averaging would overflow");
        }
        return 1;
    }
    int64_t avg_local_ms = (local_before_ms + local_after_ms) / 2;
    int64_t offset_ms = remote_ms - avg_local_ms;
    int64_t roundtrip_ms = local_after_ms - local_before_ms;
    time_t now = local_before_ms / 1000;
    struct tm local_tm;
    char local_time_str[64] = "";
    if (localtime_r(&now, &local_tm) != NULL) {
        if (strftime(local_time_str, sizeof(local_time_str), "%Y-%m-%dT%H:%M:%S%z",
                     &local_tm) == 0) {
            snprintf(local_time_str, sizeof(local_time_str), "TIME_FORMAT_ERROR");
        }
    }

    /* Print output */
    time_t remote_sec = (time_t)(remote_ms / 1000);
    struct tm remote_tm;
    char remote_time_str[64] = "";
    if (localtime_r(&remote_sec, &remote_tm) != NULL) {
        if (strftime(remote_time_str, sizeof(remote_time_str), "%Y-%m-%dT%H:%M:%S%z",
                     &remote_tm) == 0) {
            snprintf(remote_time_str, sizeof(remote_time_str), "TIME_FORMAT_ERROR");
        }
    } else {
        stderr_log("ERROR Could not parse remote time, not adjusting system time.");
        if (config.use_syslog) {
            syslog(LOG_ERR, "Could not parse remote time, not adjusting system time");
        }
        return 1;
    }

    if (config.verbose) {
        stderr_log("DEBUG Server: %s (%s)", config.server, server_addr);
        stderr_log("DEBUG Local time: %s.%03lld", local_time_str,
                   (long long)(local_after_ms % 1000));
        stderr_log("DEBUG Remote time: %s.%03lld", remote_time_str,
                   (long long)(remote_ms % 1000));
        stderr_log("DEBUG Local before(ms): %lld", (long long)local_before_ms);
        stderr_log("DEBUG Local after(ms): %lld", (long long)local_after_ms);
        stderr_log("DEBUG Estimated roundtrip(ms): %lld",
                   (long long)roundtrip_ms);
        stderr_log("DEBUG Estimated offset remote - local(ms): %lld",
                   (long long)offset_ms);
        if (config.use_syslog) {
            syslog(LOG_INFO, "NTP server=%s addr=%s offset_ms=%lld rtt_ms=%lld",
                   config.server, server_addr, (long long)offset_ms,
                   (long long)roundtrip_ms);
        }
    }

    /* Basic sanity checks for roundtrip time */
    if (roundtrip_ms < 0 || roundtrip_ms > 10000) {
        stderr_log("ERROR Invalid roundtrip time: %lld ms",
                   (long long)roundtrip_ms);
        if (config.use_syslog) {
            syslog(LOG_ERR, "Invalid suspiciously long roundtrip time: %lld ms",
                   (long long)roundtrip_ms);
        }
        return 1;
    }

    /* Set system time if conditions are met */
    if (llabs(offset_ms) > 0 && llabs(offset_ms) < 500) {
        if (config.verbose) {
            stderr_log("INFO Delta < 500ms, not setting system time.");
            if (config.use_syslog) {
                syslog(LOG_INFO, "Delta < 500ms, not setting system time");
            }
        }
        return 0;
    }
    /* Check remote year */
    if (remote_tm.tm_year + 1900 < 2025 || remote_tm.tm_year + 1900 > 2200) {
        stderr_log("ERROR Remote year is %d, not adjusting system time.",
                   remote_tm.tm_year + 1900);
        if (config.use_syslog) {
            syslog(LOG_ERR, "Remote year < 2025, not adjusting system time");
        }
        return 1;
    }
    if (config.test_only) {
        return 0;
    }
    if (getuid() != 0) {
        stderr_log("WARNING Not root, not setting system time.");
        if (config.use_syslog) {
            syslog(LOG_WARNING, "Not root, not setting system time");
        }
        return 0;
    }

    /* Check for potential overflow before time calculation */
    int64_t half_rtt = roundtrip_ms / 2;
    if (remote_ms > INT64_MAX - half_rtt) {
        stderr_log("ERROR Time calculation would overflow, not adjusting system time.");
        if (config.use_syslog) {
            syslog(LOG_ERR, "Time calculation would overflow");
        }
        return 1;
    }

    int64_t new_time_ms = remote_ms + half_rtt;

#if defined(USE_CLOCK_SETTIME)
    const char *api = "clock_settime";
    struct timespec ts;
    ts.tv_sec = new_time_ms / 1000;
    ts.tv_nsec = (new_time_ms % 1000) * 1000000;
    int rc = clock_settime(CLOCK_REALTIME, &ts);
#else
    struct timeval new_time;
    const char *api = "settimeofday";
    new_time.tv_sec = new_time_ms / 1000;
    new_time.tv_usec = (new_time_ms % 1000) * 1000;
    int rc = settimeofday(&new_time, NULL);
#endif
    if (!rc) {
        stderr_log("INFO System time set using %s (%s.%03lld)", api,
                   remote_time_str, (long long)(remote_ms % 1000));
        if (config.use_syslog) {
            syslog(LOG_INFO, "System time set using %s (%s.%03lld)", api,
                   remote_time_str, (long long)(remote_ms % 1000));
        }
        return 0;
    } else {
        stderr_log("ERROR Failed to adjust system time with %s: %s", api,
                   strerror(errno));
        if (config.use_syslog) {
            syslog(LOG_ERR, "Failed to adjust system time with %s: %s", api,
                   strerror(errno));
        }
        return 10;
    }
}
