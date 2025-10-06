CC=cc
CFLAGS= -O2 -Os -Wall -Wextra -DUSE_CLOCK_SETTIME
LDFLAGS=
#for solaris
#LDFLAGS= -lsocket -lnsl

all: timesync

timesync: timesync.o
	$(CC) $(LDFLAGS) timesync.o -o timesync $(LDFLAGS)
	strip timesync

clean:
	rm -rf timesync *.o
