.PHONY: all clean run

JAVAC = javac
JAVA = java
JAR = jar
TARGET = timesync.jar
WRAPPER = timesync
MAIN_CLASS = TimeSync
SOURCE = TimeSync.java
CLASS_FILES = TimeSync.class TimeSync$$Config.class TimeSync$$NtpResult.class
MANIFEST = manifest.txt

all: $(TARGET) $(WRAPPER)

$(TARGET): $(SOURCE)
	$(JAVAC) $(SOURCE)
	@echo "Main-Class: $(MAIN_CLASS)" > $(MANIFEST)
	$(JAR) cfm $(TARGET) $(MANIFEST) *.class
	@rm -f $(MANIFEST)

$(WRAPPER): $(TARGET)
	@echo '#!/bin/sh' > $(WRAPPER)
	@echo '# Wrapper script for timesync Java JAR' >> $(WRAPPER)
	@echo 'SCRIPT_DIR="$$(cd "$$(dirname "$$0")" && pwd)"' >> $(WRAPPER)
	@echo 'exec java -jar "$$SCRIPT_DIR/timesync.jar" "$$@"' >> $(WRAPPER)
	@chmod +x $(WRAPPER)

run: $(TARGET)
	$(JAVA) -jar $(TARGET)

clean:
	rm -f *.class $(TARGET) $(MANIFEST) $(WRAPPER)
