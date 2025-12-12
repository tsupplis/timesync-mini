.PHONY: all clean

SBCL = sbcl
TARGET = timesync
SOURCE = timesync.lisp
SCRIPT = timesync.sh

all: $(TARGET) $(SCRIPT)

$(TARGET): $(SOURCE)
	$(SBCL) --noinform --non-interactive \
		--eval "(require :sb-bsd-sockets)" \
		--load $(SOURCE) \
		--eval "(sb-ext:save-lisp-and-die \"$(TARGET)\" :toplevel #'timesync-main :executable t :compression t)"

$(SCRIPT): $(SOURCE)
	@echo '#!/usr/bin/env sbcl --script' > $(SCRIPT)
	@cat $(SOURCE) >> $(SCRIPT)
	@chmod +x $(SCRIPT)

clean:
	rm -f $(TARGET) $(SCRIPT)
