CC=ocamlopt
CFLAGS=-w +A-48-70 -I +unix
LIBS=unix.cmxa
TARGET=timesync
SRC=timesync.ml
STUBS=timesync_stubs.c
OBJS=timesync_stubs.o timesync.cmx

all: $(TARGET)

$(TARGET): $(SRC) $(STUBS)
	$(CC) $(CFLAGS) -o $(TARGET) $(STUBS) $(LIBS) $(SRC)
	strip $(TARGET)

clean:
	rm -f $(TARGET) $(OBJS) *.cmi *.cmo *.cma

.PHONY: all clean
