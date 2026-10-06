# Standalone JVM frame importer (C06 candidate): plain C11, no Zig or GUI.
# C05-R2 compatibility: links the shared logical-frame reader from src/profile
# (contract C05-R4-1) for in-process composition (--query lframes-check) and
# the owned evidence bundle (jvm_evidence.h, --query evidence).
# Example: make -C src/import BUILD=../../.work/c06-build check
ROOT := $(abspath ../..)
BUILD ?= $(ROOT)/.work/import
CC ?= cc
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra -Werror -Wswitch-enum
CPPFLAGS += -I$(ROOT)/src/profile
SOURCES := jvm_json jvm_import jvm_query jvm_lframes sha256 jvm_budget jvm_evidence
OBJECTS := $(addprefix $(BUILD)/,$(addsuffix .o,$(SOURCES))) $(BUILD)/logical_frames.o
.PHONY: all check clean
all: $(BUILD)/xodb-jvm-import $(BUILD)/test-jvm-import $(BUILD)/test-r3-import $(BUILD)/test-evidence $(BUILD)/test-r4-import $(BUILD)/test-r5-accessor
$(BUILD):
	mkdir -p $@
$(BUILD)/%.o: %.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@
$(BUILD)/logical_frames.o: $(ROOT)/src/profile/logical_frames.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@
$(BUILD)/xodb-jvm-import: jvm_main.c $(OBJECTS)
	$(CC) $(CPPFLAGS) $(CFLAGS) $^ $(LDFLAGS) -o $@
$(BUILD)/test-jvm-import: $(ROOT)/tests/jvm/unit.c $(OBJECTS)
	$(CC) $(CPPFLAGS) -I$(CURDIR) $(CFLAGS) -UNDEBUG $^ $(LDFLAGS) -o $@
$(BUILD)/test-r3-import: $(ROOT)/tests/jvm/test_r3_import.c $(OBJECTS)
	$(CC) $(CPPFLAGS) -I$(CURDIR) $(CFLAGS) -UNDEBUG $^ $(LDFLAGS) -o $@
$(BUILD)/test-evidence: $(ROOT)/tests/jvm/test_evidence.c $(OBJECTS)
	$(CC) $(CPPFLAGS) -I$(CURDIR) $(CFLAGS) -UNDEBUG $^ $(LDFLAGS) -o $@
$(BUILD)/test-r4-import: $(ROOT)/tests/jvm/test_r4_import.c $(OBJECTS)
	$(CC) $(CPPFLAGS) -I$(CURDIR) $(CFLAGS) -UNDEBUG -pthread $^ $(LDFLAGS) -pthread -o $@
$(BUILD)/test-r5-accessor: $(ROOT)/tests/jvm/test_r5_accessor.c $(OBJECTS)
	$(CC) $(CPPFLAGS) -I$(CURDIR) $(CFLAGS) -UNDEBUG $^ $(LDFLAGS) -o $@
check: all
	$(BUILD)/test-jvm-import
	mkdir -p $(BUILD)/tmp && $(BUILD)/test-r3-import $(ROOT)/tests/jvm/regress $(BUILD)/tmp
	$(BUILD)/test-evidence $(ROOT)/tests/jvm/regress $(BUILD)/tmp
	$(BUILD)/test-r4-import $(ROOT)/tests/jvm/regress $(BUILD)/tmp
	$(BUILD)/test-r5-accessor $(ROOT)/tests/jvm/regress
	python3 $(ROOT)/tests/jvm/check.py $(BUILD)/xodb-jvm-import
clean:
	rm -f $(OBJECTS) $(OBJECTS:.o=.d) $(BUILD)/xodb-jvm-import $(BUILD)/test-jvm-import
-include $(OBJECTS:.o=.d)
