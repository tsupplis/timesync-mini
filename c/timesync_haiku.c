/*
 * timesync_haiku.c - Loop for regular time synchronization on Haiku OS
 *
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2025 tsupplis
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 * Execute the Haiku Time preference panel with --update option every 60 seconds.
 *
 * Build:
 *   gcc -std=c11 -O2 -Wall -o timesync timesync_haiku.c
 *
 * Usage:
 *   ./timesync              # Execute Haiku Time preference in a loop
 */

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

/* Log function with time prefix (to both stderr and syslog) */
static void stderr_log(const char *fmt, ...) {
    time_t now = time(NULL);
    struct tm tm_now;
    char time_str[32];
    localtime_r(&now, &tm_now);
    strftime(time_str, sizeof(time_str), "%Y-%m-%d %H:%M:%S", &tm_now);

    char full_fmt[1024];
    snprintf(full_fmt, sizeof(full_fmt), "%s %s\n", time_str, fmt);

    va_list args, args_copy;
    va_start(args, fmt);
    va_copy(args_copy, args);
    vfprintf(stderr, full_fmt, args);
    va_end(args);

    /* Determine syslog priority from message prefix */
    int priority = LOG_INFO;
    if (strncmp(fmt, "ERROR", 5) == 0) {
        priority = LOG_ERR;
    } else if (strncmp(fmt, "WARNING", 7) == 0) {
        priority = LOG_WARNING;
    }

    vsyslog(priority, fmt, args_copy);
    va_end(args_copy);
}

void usage(const char *prog) {
    fprintf(stderr, "Usage: %s [-h|--help]\n", prog);
    fprintf(stderr, "  -h, --help    Show this help message\n");
    fprintf(stderr, "\n");
    fprintf(stderr,
            "  Runs an infinite loop executing the Haiku Time preference\n");
    fprintf(stderr, "  panel with --update option every 60 seconds.\n");
}

int main(int argc, char **argv) {
    const char *cmd = "/boot/system/preferences/Time";
    char *arg[3];
    pid_t child_pid;
    int status;

    /* Initialize syslog */
    openlog("ntp_client", LOG_PID, LOG_DAEMON);

    if (argc > 1) {
        if (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
            usage("timesync");
            closelog();
            return 0;
        }
        stderr_log("ERROR This program does not take any argument");
        closelog();
        return 1;
    }

    arg[0] = (char *)cmd;
    arg[1] = "--update";
    arg[2] = NULL;

    while (1) {
        stderr_log("INFO Execute Time --update");
        child_pid = fork();
        switch (child_pid) {
        case 0:
            /* Child process */
            setsid();
            close(0);
            /* Keep stderr open for error logging until exec */
            execvp(cmd, arg);
            /* Only reached if exec fails */
            fprintf(stderr, "ERROR Failed exec: %s\n", strerror(errno));
            _exit(1);
        case -1:
            stderr_log("ERROR Failed fork: %s", strerror(errno));
            break;
        default:
            /* Parent process - wait for child to avoid zombies */
            if (waitpid(child_pid, &status, 0) == -1) {
                stderr_log("ERROR Failed waitpid: %s", strerror(errno));
            } else if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
                stderr_log("WARNING Time preference exited with status %d",
                           WEXITSTATUS(status));
            } else if (WIFSIGNALED(status)) {
                stderr_log("WARNING Time preference killed by signal %d",
                           WTERMSIG(status));
            }
            break;
        }
        stderr_log("INFO Sleeping 60 seconds ...");
        sleep(60);
    }
}
