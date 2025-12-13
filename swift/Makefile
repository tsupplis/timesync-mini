.PHONY: all clean

SWIFTC = swiftc
TARGET = timesync
SOURCE = timesync.swift

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(SWIFTC) -O -o $(TARGET) $(SOURCE)

clean:
	rm -f $(TARGET)
