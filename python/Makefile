# Simple Makefile for Python timesync
# No compilation needed, just utility targets

TARGET=timesync
OBJS=__pycache__

.PHONY: all clean test install

all:
	@echo "Python script ready to run: ./$(TARGET)"
	@echo "Run 'make test' to test the script"

test:
	@echo "Testing $(TARGET)..."
	./$(TARGET) -n -v

install:
	@echo "Installing to /usr/local/bin/$(TARGET)..."
	@sudo cp $(TARGET) /usr/local/bin/$(TARGET)
	@sudo chmod 755 /usr/local/bin/$(TARGET)
	@echo "Installed successfully"

clean:
	@find . -name "*.pyc" -delete
	@find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "Cleaned Python cache files"
