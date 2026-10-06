# Standalone logical-frame reader (C05-R2), tests and owned Ruby extension.
# Example: make -C tests/logical-frames BUILD=../../.work/lf check
# Candidate build only; not part of build.zig or an installed xodb.
ROOT := $(abspath ../..)
BUILD ?= $(ROOT)/.work/logical-frames
CC ?= cc
RUBY ?= ruby
PYTHON ?= python3
CFLAGS ?= -O2 -g
WARN := -std=c11 -Wall -Wextra -Werror -Wswitch-enum
SAN := -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize-recover=all -fno-builtin
TSAN := -O1 -g -fsanitize=thread
CPPFLAGS += -I$(ROOT)/src/profile
READER := $(ROOT)/src/profile/logical_frames.c
LIB := $(READER) $(ROOT)/src/profile/logical_frames.h
FIXTURE := $(CURDIR)/regress/c05-weight-overflow.jsonl
BINS := xodb-lframes xodb-lframes-asan example-caller test-decoder test-decoder-asan test-r2 test-r2-asan test-threads test-threads-tsan test-r3 test-r3-asan test-fifo test-fifo-asan test-stable test-stable-asan
.PHONY: all check check-exact ruby-ext clean
all: $(addprefix $(BUILD)/,$(BINS))
$(BUILD):
	mkdir -p $@
$(BUILD)/xodb-lframes: $(ROOT)/src/profile/logical_frames_main.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(WARN) $(CFLAGS) $(ROOT)/src/profile/logical_frames_main.c $(READER) -o $@
$(BUILD)/xodb-lframes-asan: $(ROOT)/src/profile/logical_frames_main.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(WARN) $(SAN) $(ROOT)/src/profile/logical_frames_main.c $(READER) -o $@
$(BUILD)/test-decoder: test_decoder.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(WARN) $(CFLAGS) -UNDEBUG test_decoder.c $(READER) -o $@
$(BUILD)/test-decoder-asan: test_decoder.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(WARN) $(SAN) test_decoder.c $(READER) -o $@
$(BUILD)/example-caller: example_caller.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(WARN) $(CFLAGS) example_caller.c $(READER) -o $@
# -DXLF_TESTING enables allocation-failure and cancellation hooks (test builds only).
$(BUILD)/test-r2: test_r2.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(WARN) $(CFLAGS) -DXLF_TESTING test_r2.c $(READER) -o $@
$(BUILD)/test-r2-asan: test_r2.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(WARN) $(SAN) -DXLF_TESTING test_r2.c $(READER) -o $@
$(BUILD)/test-r3: test_r3.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(WARN) $(CFLAGS) -DXLF_TESTING test_r3.c $(READER) -o $@
$(BUILD)/test-r3-asan: test_r3.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(WARN) $(SAN) -DXLF_TESTING test_r3.c $(READER) -o $@
$(BUILD)/test-fifo: test_fifo.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(WARN) $(CFLAGS) -pthread test_fifo.c $(READER) -o $@
$(BUILD)/test-fifo-asan: test_fifo.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(WARN) $(SAN) -pthread test_fifo.c $(READER) -o $@
# C05-R4: stable reads; runs in TMPDIR (default /tmp), reports the filesystem type.
$(BUILD)/test-stable: test_stable.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(WARN) $(CFLAGS) -DXLF_TESTING -pthread test_stable.c $(READER) -o $@
$(BUILD)/test-stable-asan: test_stable.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(WARN) $(SAN) -DXLF_TESTING -pthread test_stable.c $(READER) -o $@
$(BUILD)/test-threads: test_threads.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(WARN) $(CFLAGS) -pthread test_threads.c $(READER) -o $@
$(BUILD)/test-threads-tsan: test_threads.c $(LIB) | $(BUILD)
	$(CC) $(CPPFLAGS) $(WARN) $(TSAN) -pthread test_threads.c $(READER) -o $@
# The extension links against the selected interpreter's headers; a static
# interpreter (ENABLE_SHARED=no) resolves symbols from the executable.
ruby-ext: | $(BUILD)
	@set -e; hdr=$$($(RUBY) -e 'print RbConfig::CONFIG["rubyhdrdir"]'); \
	arch=$$($(RUBY) -e 'print RbConfig::CONFIG["rubyarchhdrdir"]'); \
	shared=$$($(RUBY) -e 'print RbConfig::CONFIG["ENABLE_SHARED"]'); \
	libs=; if [ "$$shared" = yes ]; then libs="-L$$($(RUBY) -e 'print RbConfig::CONFIG["libdir"]') -lruby"; fi; \
	ver=$$($(RUBY) -e 'print RUBY_VERSION'); mkdir -p $(BUILD)/ruby-$$ver; \
	set -x; $(CC) -std=gnu11 $(CFLAGS) -Wall -Wextra -Werror -fPIC -shared -isystem $$hdr -isystem $$arch \
	    ext/xodb_lframes_rb.c $$libs -o $(BUILD)/ruby-$$ver/xodb_lframes_rb.so
check: all
	$(BUILD)/test-decoder
	$(BUILD)/test-decoder-asan
	$(BUILD)/test-r2 $(FIXTURE)
	$(BUILD)/test-r2-asan $(FIXTURE)
	$(BUILD)/test-r3
	$(BUILD)/test-r3-asan
	$(BUILD)/test-fifo
	$(BUILD)/test-fifo-asan
	$(BUILD)/test-stable $${XLF_TEST_TMPDIR:-$${TMPDIR:-/tmp}}
	$(BUILD)/test-stable-asan $${XLF_TEST_TMPDIR:-$${TMPDIR:-/tmp}} 60
	$(BUILD)/test-threads
	$(BUILD)/example-caller $(FIXTURE)
	TSAN_OPTIONS=halt_on_error=1 $(BUILD)/test-threads-tsan
	$(MAKE) check-exact
# Independent exact-integer oracle (Python ints) against the CLI.
check-exact: $(BUILD)/xodb-lframes $(BUILD)/xodb-lframes-asan
	$(PYTHON) -B exact_oracle.py $(BUILD)/xodb-lframes --fixture $(FIXTURE)
	$(PYTHON) -B exact_oracle.py $(BUILD)/xodb-lframes-asan --fixture $(FIXTURE) --cases 60
clean:
	rm -rf $(addprefix $(BUILD)/,$(BINS)) $(BUILD)/ruby-*
