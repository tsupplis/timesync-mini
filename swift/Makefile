.PHONY: all clean

SWIFTC  = swiftc
TARGET  = timesync
SOURCE  = timesync.swift

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(SWIFTC) -O -lto=llvm-thin -Xlinker -dead_strip -o $(TARGET) $(SOURCE)
	strip $(TARGET)

clean:
	rm -f $(TARGET)
