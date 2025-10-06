/*
 * ntp_client.c
 *
 * Minimal SNTP client (RFC 5905 subset) -> query server, print offset/delay in
 * ms.
 *
 * Build:
 *   gcc -std=c11 -O2 -Wall -o ntp_client ntp_client.c
 *
 * Usage:
 *   ./ntp_client                    # query pool.ntp.org
 *   ./ntp_client -server time.google.com -timeout-ms 1500 -retries 2 -syslog
 *
 * Notes:
 * - No external libraries required (uses BSD sockets).
 * - Works on Linux/macOS. Requires linking to standard C library only.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
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

#define NTP_PORT "123"
#define NTP_PACKET_SIZE 48
/* Number of seconds between 1900 (NTP epoch) and 1970 (Unix epoch) */
#define NTP_UNIX_EPOCH_DIFF 2208988800UL

/* CLI defaults */
static const char *default_server = "pool.ntp.org";
static int timeout_ms = 2000;
static int retries = 3;
static int use_syslog = 0;

/* Convert timeval to milliseconds since epoch */
static int64_t tv_to_ms(const struct timeval *tv) {
    return (int64_t)tv->tv_sec * 1000LL + (tv->tv_usec / 1000);
}

/* Read 64-bit NTP timestamp from buffer (bytes are big-endian).
   NTP timestamp: seconds (32 bits) + fractional (32 bits).
   We convert to milliseconds since Unix epoch. */
static int64_t ntp_ts_to_unix_ms(const uint8_t *buf) {
    uint32_t sec = (buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3];
    uint32_t frac = (buf[4] << 24) | (buf[5] << 16) | (buf[6] << 8) | buf[7];
    uint64_t usec =
        ((uint64_t)frac * 1000000ULL) >> 32; /* fraction to microseconds */
    uint64_t unix_sec = (uint64_t)sec - NTP_UNIX_EPOCH_DIFF;
    return (int64_t)(unix_sec * 1000LL + (usec / 1000ULL));
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

    if (getaddrinfo(server, NTP_PORT, &hints, &res) != 0) {
        return -1;
    }

    for (rp = res; rp != NULL; rp = rp->ai_next) {
        sock = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (sock < 0)
            continue;

        /* set receive timeout */
        tv.tv_sec = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        /* capture local time before send */
        struct timeval before;
        gettimeofday(&before, NULL);
        ssize_t sent = sendto(sock, packet, NTP_PACKET_SIZE, 0, rp->ai_addr,
                              rp->ai_addrlen);
        if (sent != NTP_PACKET_SIZE) {
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

        /* remote transmit timestamp is at bytes 40..47 */
        int64_t remote_ms = ntp_ts_to_unix_ms(&buf[40]);

        /* fill outputs */
        *out_local_before_ms = tv_to_ms(&before);
        *out_local_after_ms = tv_to_ms(&after);
        *out_remote_ms = remote_ms;

        /* compose server address string */
        if (server_addr_str && server_addr_len > 0) {
            if (src.ss_family == AF_INET) {
                struct sockaddr_in *s4 = (struct sockaddr_in *)&src;
                inet_ntop(AF_INET, &s4->sin_addr, server_addr_str,
                          server_addr_len);
            } else if (src.ss_family == AF_INET6) {
                struct sockaddr_in6 *s6 = (struct sockaddr_in6 *)&src;
                inet_ntop(AF_INET6, &s6->sin6_addr, server_addr_str,
                          server_addr_len);
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
    printf("Usage: %s [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp "
           "server]\n",
           prog);
    printf("  server       NTP server to query (default: pool.ntp.org)\n");
    printf("  -t timeout   Timeout in ms (default: 2000)\n");
    printf("  -r retries   Number of retries (default: 3)\n");
    printf("  -n           No effect\n");
    printf("  -v           Verbose output\n");
    printf("  -s           Enable syslog logging\n");
    printf("  -h           Show this help message\n");
}

/*
 * Main function algorithm (synopsis):
 * 1. Parse command-line arguments for server, timeout, retries, and syslog
 * option.
 * 2. Optionally enable syslog logging.
 * 3. Attempt to query the NTP server up to 'retries' times:
 *    - On success, record local send/receive times and remote server time.
 *    - On failure, retry after a short delay.
 * 4. If all attempts fail, print error and exit.
 * 5. On success:
 *    - Calculate average local time, offset (remote - local), and roundtrip
 * delay.
 *    - Format and print results (server, remote time, timings, offset,
 * roundtrip).
 *    - Optionally log results to syslog.
 */
int main(int argc, char **argv) {
    int opt;
    const char *server = default_server;
    int verbose = 0;
    int test_only = 0;

    while ((opt = getopt(argc, argv, "t:r:vnsh")) != -1) {
        if (opt == 's') {
            use_syslog = 1;
        } else if (opt == 't') {
            timeout_ms = atoi(optarg);
            if (timeout_ms <= 0)
                timeout_ms = 2000;
        } else if (opt == 'r') {
            retries = atoi(optarg);
            if (retries <= 0)
                retries = 1;
        } else if (opt == 'v') {
            verbose = 1;
        } else if (opt == 'n') {
            test_only = 1;
        } else if (opt == 'h') {
            usage(argv[0]);
            exit(0);
        } else {
            /* ignore unknowns; simple CLI */
        }
    }
    /* If there is a positional argument left, treat it as the server */
    if (optind < argc) {
        server = argv[optind];
    }

    if (verbose) {
        fprintf(stderr, "INF: Using server: %s\n", server);
        fprintf(stderr, "INF: Timeout: %d ms, Retries: %d, Syslog: %s\n",
                timeout_ms, retries, use_syslog ? "on" : "off");
    }
    while ((opt = getopt(argc, argv, "t:r:--")) != -1) {
        if (opt == 's') {
            server = optarg;
        } else if (opt == 't') {
            timeout_ms = atoi(optarg);
            if (timeout_ms <= 0)
                timeout_ms = 2000;
        } else if (opt == 'r') {
            retries = atoi(optarg);
            if (retries <= 0)
                retries = 1;
        } else {
            /* ignore unknowns; simple CLI */
        }
    }

    if (use_syslog) {
        openlog("ntp_client", LOG_PID | LOG_CONS, LOG_USER);
    }

    int attempt;
    int64_t local_before_ms = 0, remote_ms = 0, local_after_ms = 0;
    char server_addr[INET6_ADDRSTRLEN] = {0};
    int success = 0;

    for (attempt = 0; attempt < retries; ++attempt) {
        if (do_ntp_query(server, timeout_ms, &local_before_ms, &remote_ms,
                         &local_after_ms, server_addr,
                         sizeof(server_addr)) == 0) {
            success = 1;
            break;
        }
        /* small backoff before retry */
        usleep(200000);
    }

    if (!success) {
        fprintf(stderr,
                "ERR: Failed to contact NTP server %s after %d attempts\n",
                server, retries);
        if (use_syslog) {
            syslog(LOG_ERR, "NTP query failed for %s after %d attempts", server,
                   retries);
            closelog();
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
    int64_t avg_local_ms = (local_before_ms + local_after_ms) / 2;
    int64_t epoch_diff_ms = remote_ms - avg_local_ms;
    int64_t roundtrip_ms = local_after_ms - local_before_ms;

    /* Print output */
    time_t remote_sec = (time_t)(remote_ms / 1000);
    struct tm rtm;
    localtime_r(&remote_sec, &rtm);
    char timestr[64];
    strftime(timestr, sizeof(timestr), "%Y-%m-%dT%H:%M:%S%z", &rtm);

    if (verbose) {
        fprintf(stderr, "INF: Server: %s (%s)\n", server, server_addr);
        fprintf(stderr, "INF: Remote time: %s.%03lld\n", timestr,
                (long long)(remote_ms % 1000));
        fprintf(stderr, "INF: Local before(ms): %lld\n",
                (long long)local_before_ms);
        fprintf(stderr, "INF: Local after(ms): %lld\n",
                (long long)local_after_ms);
        fprintf(stderr, "INF: Estimated roundtrip(ms): %lld\n",
                (long long)roundtrip_ms);
        fprintf(stderr, "INF: Estimated offset remote - local(ms): %lld\n",
                (long long)epoch_diff_ms);
    }
    if (use_syslog) {
        syslog(LOG_INFO, "NTP server=%s addr=%s offset_ms=%lld rtt_ms=%lld",
               server, server_addr, (long long)epoch_diff_ms,
               (long long)roundtrip_ms);
    }

    /* Set system time if conditions are met */
    if (llabs(epoch_diff_ms) > 0 && llabs(epoch_diff_ms) < 500) {
        /* Only adjust if remote year is >= 2025 to avoid issues with
         * misconfigured servers */
        fprintf(stderr, "INF: Delta < 500ms, not setting system time.\n");
        if (use_syslog) {
            syslog(LOG_INFO, "Delta not < 500ms, not setting system time");
            closelog();
        }
        return 0;
    }
    if (rtm.tm_year + 1900 < 2025) {
        fprintf(stderr, "WRN: Remote year is less than 2025, not "
                        "adjusting system time.\n");
        if (use_syslog) {
            syslog(LOG_WARNING,
                   "Remote year < 2025, not adjusting system time");
            closelog();
        }
        return 1;
    }
    if (test_only) {
        if (use_syslog) {
            closelog();
        }
        return 0;
    }
    if (getuid() != 0) {
        fprintf(stderr, "WRN: Not root, not setting system time.\n");
        if (use_syslog) {
            openlog("ntp_client", LOG_PID | LOG_CONS, LOG_USER);
            syslog(LOG_WARNING, "Not root, not setting system time");
            closelog();
        }
        return 0;
    }

#if defined(USE_CLOCK_SETTIME)
    char * api= "clock_settime";
    struct timespec ts;
    ts.tv_sec = (remote_ms + roundtrip_ms) / 1000;
    ts.tv_nsec = ((remote_ms + roundtrip_ms) % 1000) * 1000000;
    int rc = clock_settime(CLOCK_REALTIME, &ts);
#else
    struct timeval new_time;
    char * api= "settimeofday";
    new_time.tv_sec = (remote_ms + roundtrip_ms) / 1000;
    new_time.tv_usec = ((remote_ms + roundtrip_ms) % 1000) * 1000;
    int rc = settimeofday(&new_time, NULL);
#endif
    if (rc == 0) {
        fprintf(stderr, "INF: System time set using %s (%s.%03lld)\n",
                api,timestr, (long long)(remote_ms % 1000));
        if (use_syslog) {
            syslog(LOG_INFO, "System time set using %s (%s.%03lld)",
                   api,timestr, (long long)(remote_ms % 1000));
        }
    } else {
        fprintf(stderr,
                "ERR: Failed to adjust system time with %s: %s\n",
                api, strerror(errno));
        if (use_syslog) {
            syslog(LOG_ERR,
                   "Failed to adjust system time with %s: %s",
                   api, strerror(errno));
        }
    }
    if(use_syslog) {
        closelog();
    }
    return 0;
}
