# Standalone C runtime: no Zig, GUI, ELF or DWARF library is required.
# Example: make -C src/runtime BUILD=/data2/icp/Work/xodb-c-build check
ROOT := $(abspath ../..)
BUILD ?= $(ROOT)/.work/c-runtime
CC ?= cc
AR ?= ar
CPPFLAGS += -I$(CURDIR)
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra -Werror -Wswitch-enum
LDLIBS += -latomic -pthread
SOURCES := memory arch registers process target probes watchpoints events family xstate perf perf_cpu perf_syscalls perf_allocations wire wire_target agent remote files mapped_file perf_wire agent_perf remote_perf allocation_broker
OBJECTS := $(addprefix $(BUILD)/,$(addsuffix .o,$(SOURCES)))
TESTS := memory registers process target perf wire snapshot
TEST_BINS := $(addprefix $(BUILD)/test-,$(TESTS))
.PHONY: all check clean
all: $(BUILD)/libxrt.a $(BUILD)/xodb-agent
$(BUILD):
	mkdir -p $@
$(BUILD)/allocation_broker.o: $(ROOT)/src/profile/allocation_broker.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@
$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@
$(BUILD)/libxrt.a: $(OBJECTS)
	$(AR) rcs $@ $^
$(BUILD)/xodb-agent: agent_main.c $(BUILD)/libxrt.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libxrt.a $(LDFLAGS) $(LDLIBS) -o $@
$(BUILD)/test-%: $(ROOT)/tests/runtime-%.c $(BUILD)/libxrt.a
	$(CC) $(CPPFLAGS) $(CFLAGS) -UNDEBUG $< $(BUILD)/libxrt.a $(LDFLAGS) $(LDLIBS) -o $@
$(BUILD)/test-remote: $(ROOT)/tests/runtime-remote.c $(BUILD)/libxrt.a
	$(CC) $(CPPFLAGS) $(CFLAGS) -UNDEBUG -fno-pie -no-pie $< $(BUILD)/libxrt.a $(LDFLAGS) $(LDLIBS) -o $@
check: $(TEST_BINS) $(BUILD)/test-remote $(BUILD)/xodb-agent
	@set -e; for test in $(TEST_BINS); do "$$test"; done
	$(BUILD)/test-remote $(BUILD)/xodb-agent
clean:
	rm -f $(OBJECTS) $(OBJECTS:.o=.d) $(TEST_BINS) $(BUILD)/libxrt.a $(BUILD)/xodb-agent
-include $(OBJECTS:.o=.d)
