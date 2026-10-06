# Bounded static semantic queries over exported high p-code (C02-R3 candidate).
# Standalone C11 host tool: no Zig, Ghidra, Java or third-party library.
# Example: make -C src/semq BUILD=$PWD/build/semq check
ROOT := $(abspath ../..)
BUILD ?= $(ROOT)/.work/semq
CC ?= cc
CPPFLAGS += -I$(CURDIR)
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra -Werror -Wswitch-enum
SOURCES := sha256 xsq_mem xsq_graph xsq_query xsq_report
OBJECTS := $(addprefix $(BUILD)/,$(addsuffix .o,$(SOURCES)))
FIXTURES := $(BUILD)/fixtures
.PHONY: all check clean
all: $(BUILD)/xsq $(BUILD)/test-xsq
$(BUILD):
	mkdir -p $@
$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@
$(BUILD)/libxsq.a: $(OBJECTS)
	$(AR) rcs $@ $^
$(BUILD)/xsq: xsq_main.c $(BUILD)/libxsq.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libxsq.a $(LDFLAGS) -o $@
$(BUILD)/test-xsq: $(ROOT)/tests/semq/test_xsq.c $(BUILD)/libxsq.a
	$(CC) $(CPPFLAGS) $(CFLAGS) -UNDEBUG $< $(BUILD)/libxsq.a $(LDFLAGS) -pthread -o $@
# Independent allocator oracle (GNU ld --wrap): charged == requested bytes.
$(BUILD)/alloc-probe: $(ROOT)/tests/semq/alloc_probe.c $(BUILD)/libxsq.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libxsq.a $(LDFLAGS) \
		-Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc -o $@
check: all $(BUILD)/alloc-probe
	mkdir -p $(FIXTURES)/synthetic
	cp $(ROOT)/tests/fixtures/semq/units.xsg $(FIXTURES)/synthetic/units.xsg
	python3 $(ROOT)/tests/semq/gen_malformed.py $(FIXTURES)/malformed
	$(BUILD)/test-xsq $(FIXTURES)
	sh $(ROOT)/tests/semq/cli.sh $(BUILD)/xsq $(FIXTURES)
	$(BUILD)/alloc-probe $(FIXTURES)/synthetic/units.xsg
clean:
	rm -f $(OBJECTS) $(OBJECTS:.o=.d) $(BUILD)/libxsq.a $(BUILD)/xsq $(BUILD)/test-xsq $(BUILD)/alloc-probe
-include $(OBJECTS:.o=.d)
