# Standalone C runtime: no Zig, GUI, ELF or DWARF library is required.
# Example: make -C src/runtime BUILD=../../.work/c-build check
ROOT := $(abspath ../..)
BUILD ?= $(ROOT)/.work/c-runtime
CC ?= cc
AR ?= ar
CPPFLAGS += -I$(CURDIR)
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra -Werror -Wswitch-enum
LDLIBS += -latomic -pthread -ldl
SOURCES := memory arch registers process target probes loongarch_step watchpoints events family xstate perf perf_cpu perf_syscalls perf_allocations wire wire_target agent remote files loader elf_symbols mapped_file perf_wire agent_perf remote_perf fdscan allocation_broker sysstat sysstat_nvml source binary_object dwarf_cursor source_paths
OBJECTS := $(addprefix $(BUILD)/,$(addsuffix .o,$(SOURCES)))
TESTS := memory registers process target perf wire snapshot symbols fdscan sysstat services
TEST_BINS := $(addprefix $(BUILD)/test-,$(TESTS))
.PHONY: all check check-leaks clean
all: $(BUILD)/libxrt.a $(BUILD)/xodb-agent $(BUILD)/xodb-lsof-top
check-leaks:
	python3 $(ROOT)/tests/runtime-leaks.py --work $(BUILD)/leak-probe
$(BUILD):
	mkdir -p $@
$(BUILD)/allocation_broker.o: $(ROOT)/src/profile/allocation_broker.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@
$(BUILD)/binary_object.o: $(ROOT)/src/binary/object.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@
$(BUILD)/dwarf_cursor.o: $(ROOT)/src/debug/dwarf_cursor.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@
$(BUILD)/source_paths.o: $(ROOT)/src/debug/source_paths.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@
$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@
$(BUILD)/libxrt.a: $(OBJECTS)
	$(AR) rcs $@ $^
$(BUILD)/xodb-agent: agent_main.c $(BUILD)/libxrt.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $< $(BUILD)/libxrt.a $(LDFLAGS) $(LDLIBS) -o $@
# lsof-top for machines that run only the agent; xodb --lsof-top is the same program.
$(BUILD)/xodb-lsof-top: $(ROOT)/src/lsoftop/main.c $(ROOT)/src/lsoftop/lsoftop.c $(BUILD)/libxrt.a
	$(CC) $(CPPFLAGS) $(CFLAGS) $(ROOT)/src/lsoftop/main.c $(ROOT)/src/lsoftop/lsoftop.c $(BUILD)/libxrt.a $(LDFLAGS) $(LDLIBS) -o $@
$(BUILD)/test-%: $(ROOT)/tests/runtime-%.c $(BUILD)/libxrt.a
	$(CC) $(CPPFLAGS) $(CFLAGS) -UNDEBUG $< $(BUILD)/libxrt.a $(LDFLAGS) $(LDLIBS) -o $@
$(BUILD)/test-remote: $(ROOT)/tests/runtime-remote.c $(BUILD)/libxrt.a
	$(CC) $(CPPFLAGS) $(CFLAGS) -UNDEBUG -fno-pie -no-pie $< $(BUILD)/libxrt.a $(LDFLAGS) $(LDLIBS) -o $@
$(BUILD)/test-loader: $(ROOT)/tests/runtime-loader.c $(BUILD)/libxrt.a
	$(CC) $(CPPFLAGS) $(CFLAGS) -UNDEBUG -fno-pie -no-pie $< $(BUILD)/libxrt.a $(LDFLAGS) $(LDLIBS) -o $@
$(BUILD)/test-sysstat-sensors: $(ROOT)/tests/runtime-sysstat-sensors.c $(BUILD)/libxrt.a
	$(CC) $(CPPFLAGS) $(CFLAGS) -UNDEBUG $< $(BUILD)/libxrt.a $(LDFLAGS) -Wl,--wrap=clock_gettime -Wl,--wrap=read $(LDLIBS) -o $@
check: $(BUILD)/test-sysstat-sensors $(BUILD)/test-loader $(TEST_BINS) $(BUILD)/test-remote $(BUILD)/test-replies $(BUILD)/xodb-agent
	$(BUILD)/test-sysstat-sensors
	@set -e; for test in $(TEST_BINS); do "$$test"; done
	$(BUILD)/test-loader
	$(BUILD)/test-loader $(BUILD)/xodb-agent
	$(BUILD)/test-remote $(BUILD)/xodb-agent
	$(BUILD)/test-replies $(BUILD)/xodb-agent
# Function probes are currently x86-64 only; live checks explicitly supply a
# helper path (and optionally an agent) to this standalone test executable.
$(BUILD)/test-uprobes: $(ROOT)/tests/runtime-uprobes.c $(BUILD)/libxrt.a
	$(CC) $(CPPFLAGS) $(CFLAGS) -UNDEBUG -fno-pie -no-pie $< $(BUILD)/libxrt.a $(LDFLAGS) $(LDLIBS) -o $@
clean:
	rm -f $(OBJECTS) $(OBJECTS:.o=.d) $(TEST_BINS) $(BUILD)/libxrt.a $(BUILD)/xodb-agent $(BUILD)/xodb-lsof-top
-include $(OBJECTS:.o=.d)
