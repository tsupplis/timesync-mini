.PHONY: all clean test

all:
	@echo "Lua implementation is script-only (requires lua and luasocket)"
	@echo "Run with: ./timesync.lua or lua timesync.lua"
	@chmod +x timesync.lua

test:
	@echo "Testing Lua implementation..."
	lua timesync.lua -n -v pool.ntp.org

clean:
	@echo "Nothing to clean (script-only)"
