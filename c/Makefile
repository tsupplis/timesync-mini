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

clean:
	$(RM) timesync *.o
