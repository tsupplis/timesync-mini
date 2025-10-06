.PHONY: clean 

STRIP=strip

all: timesync
	
timesync: timesync.o
	$(CC) -o $@ $<
	$(STRIP) $@

tymesync.o: timesync.c

clean:
	rm -rf timesync timesync.o

