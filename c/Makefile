CC=cc
CFLAGS= -O2

all: timesync

timesync: timesync.o
	$(CC) $(LDFLAGS) timesync.o -o timesync
	strip timesync

clean:
	rm -rf timesync *.o
