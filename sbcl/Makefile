.PHONY: all clean

SBCL = sbcl
TARGET = timesync
SOURCE = timesync.lisp

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(SBCL) --noinform --non-interactive \
		--eval "(require :sb-bsd-sockets)" \
		--load $(SOURCE) \
		--eval "(sb-ext:save-lisp-and-die \"$(TARGET)\" :toplevel #'timesync-main :executable t :compression t)"

clean:
	rm -f $(TARGET)
