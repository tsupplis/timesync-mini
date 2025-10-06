/*
 * timesync.c
 *
 * Loop for regular time synchronization on Haiku OS
 *
 * Build:
 *   gcc -std=c11 -O2 -Wall -o timesync timesync.c
 *
 *
 * Usage:
 *   ./timesync                    # query pool.ntp.org in a loop for Haiku
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Log function with time prefix (always to stderr) */
static void stderr_log(const char *fmt, ...) {
    time_t now = time(NULL);
    struct tm tm_now;
    char time_str[32];
    localtime_r(&now, &tm_now);
    strftime(time_str, sizeof(time_str), "%Y-%m-%d %H:%M:%S", &tm_now);

    char full_fmt[1024];
    snprintf(full_fmt, sizeof(full_fmt), "%s %s\n", time_str, fmt);

    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, full_fmt, args);
    va_end(args);
}

void usage(const char *prog) {
    fprintf(stderr, "Usage: %s\n", prog);
    fprintf(stderr, "  This program does not take any argument.\n");
    fprintf(stderr,
            "  It runs an infinite loop executing the Haiku Time preference\n");
    fprintf(stderr, "  panel with --update option every 60 seconds.\n");
}

int main(int argc, char **argv) {
    char *cmd;
    char **arg;
    char *path;

    if (argc > 1) {
        if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
            usage("timesync");
            return 0;
        }
        stderr_log("ERROR This program does not take any argument");
        return 1;
    }

    cmd = "/boot/system/preferences/Time";
    arg = (char **)malloc(3 * sizeof(char *));
    arg[0] = cmd;
    arg[1] = "--update";
    arg[2] = 0;
    path = getenv("PATH");
    path = path ? path : ":/boot/system/preferences;/bin:/usr/bin";
    while (1) {
        stderr_log("INFO Execute Time --update");
        switch (fork()) {
        case 0:
            setsid();
            close(0);
            close(1);
            close(2);
            stderr_log("INFO Exec %s %s ...", cmd, arg[0]);
            execvp(cmd, arg);
            stderr_log("ERROR Failed exec: %s", strerror(errno));
            break;
        case -1:
            stderr_log("ERROR Failed fork: %s", strerror(errno));
            break;
        default:
            break;
        }
        stderr_log("INFO Sleeping 60 seconds ...");
        sleep(60);
    }
}
