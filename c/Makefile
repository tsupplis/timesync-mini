CC=cc
CFLAGS= -O2 -Wall -Wextra -DUSE_CLOCK_SETTIME
#for solaris
#LDFLAGS= -lsocket -lnsl
STRIP=strip
RM=rm -f

all: timesync

timesync: timesync.o
	$(CC) $(LDFLAGS) timesync.o -o timesync $(LDFLAGS)
	$(STRIP) timesync

timesync_sched: timesync_sched.o
	$(CC) $(LDFLAGS) timesync_sched.o -o timesync_sched $(LDFLAGS)
	$(STRIP) timesync_sched

clean:
	$(RM) timesync timesync_sched *.o
