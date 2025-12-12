# Erlang timesync Makefile

ERLC=erlc
ERLC_FLAGS=+debug_info

TARGET=timesync
SRC=$(TARGET).erl
BEAM=$(TARGET).beam
ESCRIPT=$(TARGET)
OBJS=$(BEAM)

all: $(BEAM) $(ESCRIPT)

$(BEAM): $(SRC)
	$(ERLC) $(ERLC_FLAGS) $(SRC)

$(ESCRIPT): $(BEAM)
	@echo '#!/usr/bin/env escript' > $(ESCRIPT)
	@echo '%% -*- erlang -*-' >> $(ESCRIPT)
	@echo '%%! -pa .' >> $(ESCRIPT)
	@echo 'main(Args) -> timesync:main(Args).' >> $(ESCRIPT)
	@chmod +x $(ESCRIPT)

clean:
	rm -f $(OBJS) $(ESCRIPT) erl_crash.dump

test: $(ESCRIPT)
	./$(ESCRIPT) -nv 192.168.1.1

.PHONY: all clean test
