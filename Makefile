# space-sim build. Targets:
#   make          debug binary  -> bin/space-sim
#   make run      build debug and run it
#   make release  optimised binary -> bin/space-sim-release
#   make test     run `odin test` over the packages
#   make check    type-check without linking
#   make clean

ODIN      ?= odin
SRC       := src
COLLECT   := -collection:sim=$(SRC)
BIN_DIR   := bin
DEBUG_BIN := $(BIN_DIR)/space-sim
REL_BIN   := $(BIN_DIR)/space-sim-release
SOURCES   := $(shell find $(SRC) -name '*.odin')

.PHONY: all run release test check clean

all: $(DEBUG_BIN)

$(DEBUG_BIN): $(SOURCES) | $(BIN_DIR)
	$(ODIN) build $(SRC) $(COLLECT) -out:$@ -debug

$(REL_BIN): $(SOURCES) | $(BIN_DIR)
	$(ODIN) build $(SRC) $(COLLECT) -out:$@ -o:speed

run: $(DEBUG_BIN)
	./$(DEBUG_BIN)

release: $(REL_BIN)

test:
	$(ODIN) test $(SRC) $(COLLECT) -all-packages -out:$(BIN_DIR)/tests

check:
	$(ODIN) check $(SRC) $(COLLECT)

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

clean:
	rm -rf $(BIN_DIR)
