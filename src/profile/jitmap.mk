# Host-side JIT code-map decoder/resolver (xodb-jit-code-lifetime/3 draft).
# Not linked into the target agent. Example, from the source root:
#   make -f src/profile/jitmap.mk BUILD=build/jitmap check
# check runs the original C07 checks, the C07-R2 contract tests (oracle,
# declared bound, limits, cancellation, allocation failures) and the C07-R3
# duplicate-evidence and allocation-accounting tests and the C07-R4
# classification-work bound tests, plain and with ASan/UBSan; check-tsan runs the cancellation tests under ThreadSanitizer.
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
BUILD ?= $(ROOT)/.work/jitmap
CC ?= cc
FUZZ_CC ?= clang
TSAN_CC ?= $(CC)
CFLAGS ?= -O2 -g
CFLAGS += -std=c11 -Wall -Wextra -Werror -Wswitch-enum
CPPFLAGS += -I$(ROOT)/src/profile -I$(ROOT)/tests
SAN := -fsanitize=address,undefined -fno-sanitize-recover=all
LIB := $(ROOT)/src/profile/jitmap.c $(ROOT)/src/profile/jitmap.h
R2 := $(ROOT)/tests/jitmap-r2
R2DEPS := $(R2)/oracle.h $(R2)/adversary.h $(ROOT)/tests/jitmap_build.h $(LIB)
R3 := $(ROOT)/tests/jitmap-r3
R4 := $(ROOT)/tests/jitmap-r4
WRAP := -Wl,--wrap=malloc,--wrap=realloc,--wrap=calloc,--wrap=free
.PHONY: all check check-tsan fuzz clean
all: $(BUILD)/xodb-jitmap $(BUILD)/test-jitmap $(BUILD)/test-jitmap-san $(BUILD)/jit-fixture \
	$(BUILD)/test-jitmap-r2 $(BUILD)/test-jitmap-r2-san $(BUILD)/jitmap-alloc-fail-san $(BUILD)/jitmap-scaling \
	$(BUILD)/test-jitmap-r3 $(BUILD)/test-jitmap-r3-san $(BUILD)/jitmap-alloc-oracle $(BUILD)/jitmap-alloc-oracle-san \
	$(BUILD)/test-jitmap-r4 $(BUILD)/test-jitmap-r4-san
$(BUILD):
	mkdir -p $@
$(BUILD)/xodb-jitmap: $(ROOT)/src/profile/jitmap_cli.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(ROOT)/src/profile/jitmap.c $< -o $@
$(BUILD)/test-jitmap: $(ROOT)/tests/profile-jitmap.c $(ROOT)/tests/jitmap_build.h $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -UNDEBUG $(ROOT)/src/profile/jitmap.c $< -o $@
$(BUILD)/test-jitmap-san: $(ROOT)/tests/profile-jitmap.c $(ROOT)/tests/jitmap_build.h $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -O1 $(SAN) $(ROOT)/src/profile/jitmap.c $< -o $@
$(BUILD)/xodb-jitmap-san: $(ROOT)/src/profile/jitmap_cli.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -O1 $(SAN) $(ROOT)/src/profile/jitmap.c $< -o $@
$(BUILD)/test-jitmap-r2: $(R2)/test-r2.c $(R2DEPS) | $(BUILD)
	$(CC) $(CPPFLAGS) -I$(R2) $(CFLAGS) -pthread $(ROOT)/src/profile/jitmap.c $< -o $@
$(BUILD)/test-jitmap-r2-san: $(R2)/test-r2.c $(R2DEPS) | $(BUILD)
	$(CC) $(CPPFLAGS) -I$(R2) $(CFLAGS) -O1 $(SAN) -pthread $(ROOT)/src/profile/jitmap.c $< -o $@
$(BUILD)/test-jitmap-r2-tsan: $(R2)/test-r2.c $(R2DEPS) | $(BUILD)
	$(TSAN_CC) $(CPPFLAGS) -I$(R2) $(CFLAGS) -O1 -fsanitize=thread -pthread $(ROOT)/src/profile/jitmap.c $< -o $@
$(BUILD)/jitmap-alloc-fail-san: $(R2)/alloc-fail.c $(R2DEPS) | $(BUILD)
	$(CC) $(CPPFLAGS) -I$(R2) $(CFLAGS) -O1 $(SAN) -DXODB_JIT_FAULT_INJECTION $(ROOT)/src/profile/jitmap.c $< -o $@
$(BUILD)/jitmap-scaling: $(R2)/scaling.c $(R2DEPS) | $(BUILD)
	$(CC) $(CPPFLAGS) -I$(R2) $(CFLAGS) -pthread $(ROOT)/src/profile/jitmap.c $< -o $@
$(BUILD)/test-jitmap-r3: $(R3)/test-r3.c $(R2DEPS) | $(BUILD)
	$(CC) $(CPPFLAGS) -I$(R2) $(CFLAGS) $(ROOT)/src/profile/jitmap.c $< -o $@
$(BUILD)/test-jitmap-r3-san: $(R3)/test-r3.c $(R2DEPS) | $(BUILD)
	$(CC) $(CPPFLAGS) -I$(R2) $(CFLAGS) -O1 $(SAN) $(ROOT)/src/profile/jitmap.c $< -o $@
# Classification-work bound: long perf-map names, expectations derived from
# the fixture description (not from the oracle).
$(BUILD)/test-jitmap-r4: $(R4)/test-r4.c $(R2DEPS) | $(BUILD)
	$(CC) $(CPPFLAGS) -I$(R2) $(CFLAGS) -UNDEBUG $(ROOT)/src/profile/jitmap.c $< -o $@
$(BUILD)/test-jitmap-r4-san: $(R4)/test-r4.c $(R2DEPS) | $(BUILD)
	$(CC) $(CPPFLAGS) -I$(R2) $(CFLAGS) -O1 $(SAN) $(ROOT)/src/profile/jitmap.c $< -o $@
# Independent allocation-accounting oracle: every malloc/realloc/calloc/free of
# the unmodified library is wrapped at link time (no library hooks).
$(BUILD)/jitmap-alloc-oracle: $(R3)/alloc-oracle.c $(R2DEPS) | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(ROOT)/src/profile/jitmap.c $< $(WRAP) -o $@
$(BUILD)/jitmap-alloc-oracle-san: $(R3)/alloc-oracle.c $(R2DEPS) | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -O1 $(SAN) $(ROOT)/src/profile/jitmap.c $< $(WRAP) -o $@
# The fixture generates x86-64 code and needs frame pointers for its walk.
$(BUILD)/jit-fixture: $(ROOT)/tests/fixtures/jit-fixture.c | $(BUILD)
	$(CC) $(CFLAGS) -O1 -fno-omit-frame-pointer $< -o $@
$(BUILD)/fuzz-jitmap: $(ROOT)/tests/fuzz/jitmap-fuzz.c $(R2)/oracle.h $(LIB) | $(BUILD)
	$(FUZZ_CC) $(CPPFLAGS) -I$(R2) -std=c11 -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all $(ROOT)/src/profile/jitmap.c $< -o $@
$(BUILD)/jitmap-seeds: $(ROOT)/tests/fuzz/jitmap-seeds.c $(ROOT)/tests/jitmap_build.h $(R2)/adversary.h | $(BUILD)
	$(CC) $(CPPFLAGS) -I$(R2) $(CFLAGS) $< -o $@
check: $(BUILD)/test-jitmap $(BUILD)/test-jitmap-san $(BUILD)/test-jitmap-r2 $(BUILD)/test-jitmap-r2-san \
	$(BUILD)/jitmap-alloc-fail-san $(BUILD)/test-jitmap-r3 $(BUILD)/test-jitmap-r3-san $(BUILD)/jitmap-alloc-oracle \
	$(BUILD)/jitmap-alloc-oracle-san $(BUILD)/test-jitmap-r4 $(BUILD)/test-jitmap-r4-san
	$(BUILD)/test-jitmap
	$(BUILD)/test-jitmap-san
	$(BUILD)/test-jitmap-r2
	$(BUILD)/test-jitmap-r2-san all 32768
	$(BUILD)/jitmap-alloc-fail-san
	$(BUILD)/test-jitmap-r3
	$(BUILD)/test-jitmap-r3-san
	$(BUILD)/jitmap-alloc-oracle
	$(BUILD)/jitmap-alloc-oracle-san
	$(BUILD)/test-jitmap-r4
	$(BUILD)/test-jitmap-r4-san
check-tsan: $(BUILD)/test-jitmap-r2-tsan
	$(BUILD)/test-jitmap-r2-tsan cancel 32768
fuzz: $(BUILD)/fuzz-jitmap $(BUILD)/jitmap-seeds
clean:
	rm -f $(BUILD)/xodb-jitmap $(BUILD)/xodb-jitmap-san $(BUILD)/test-jitmap $(BUILD)/test-jitmap-san \
		$(BUILD)/test-jitmap-r2 $(BUILD)/test-jitmap-r2-san $(BUILD)/test-jitmap-r2-tsan \
		$(BUILD)/jitmap-alloc-fail-san $(BUILD)/jitmap-scaling $(BUILD)/jit-fixture $(BUILD)/fuzz-jitmap \
		$(BUILD)/jitmap-seeds $(BUILD)/test-jitmap-r3 $(BUILD)/test-jitmap-r3-san $(BUILD)/jitmap-alloc-oracle \
		$(BUILD)/jitmap-alloc-oracle-san $(BUILD)/test-jitmap-r4 $(BUILD)/test-jitmap-r4-san
