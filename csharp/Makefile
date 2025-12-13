.PHONY: all build clean run

all: build

build: timesync

timesync: TimeSync.cs timesync.csproj
	dotnet build -c Release timesync.csproj
	@cp bin/Release/net*/timesync.dll bin/Release/net*/timesync.runtimeconfig.json .
	@echo '#!/bin/sh' > timesync
	@echo 'DIR="$$(cd "$$(dirname "$$0")" && pwd)"' >> timesync
	@echo 'exec dotnet "$$DIR/timesync.dll" "$$@"' >> timesync
	@chmod +x timesync

clean:
	rm -f timesync timesync.dll timesync.pdb timesync.deps.json timesync.runtimeconfig.json
	rm -rf obj bin

run: build
	./timesync -nv 192.168.1.1
