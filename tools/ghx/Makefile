# C01-R2 ghx native worker and supervisor (host analysis tools, not part of
# the xodb target agent or the default build).
#   make -C tools/ghx GHIDRA_CPP=<copy>/Ghidra/Features/Decompiler/src/decompile/cpp OUT=<dir>
# GHIDRA_CPP must point at a *copy* of Ghidra's decompiler sources in which
# libdecomp.a was built (see build_ghidra.sh).  The worker reads ELF bytes
# through its own snapshot loader; it does not link GNU libbfd.
GHIDRA_CPP ?=
GHIDRA_COMMIT ?= a462673d2f1543d153c61d10bcd6c68f85555194
GHIDRA_VERSION ?= 12.3-DEV
OUT ?= $(CURDIR)/build
CC ?= gcc
CXX ?= g++
PREFIXMAP = -ffile-prefix-map=$(CURDIR)=src $(if $(GHIDRA_CPP),-ffile-prefix-map=$(abspath $(GHIDRA_CPP))=ghidra-cpp)
CFLAGS = -std=c11 -O2 -g -Wall -Wextra $(PREFIXMAP)
CXXFLAGS = -std=c++14 -O2 -g -Wall -Wno-sign-compare -D__TERMINAL__ $(PREFIXMAP) \
	-DGHIDRA_COMMIT='"$(GHIDRA_COMMIT)"' -DGHIDRA_VERSION='"$(GHIDRA_VERSION)"' -I$(abspath $(GHIDRA_CPP))

all: $(OUT)/ghx_worker $(OUT)/ghx_supervise $(OUT)/ghx_measure $(OUT)/ghx_elfcheck
tools: $(OUT)/ghx_supervise $(OUT)/ghx_measure $(OUT)/ghx_elfcheck

$(OUT)/ghx_measure: ghx_measure.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -D_GNU_SOURCE -o $@ ghx_measure.c
$(OUT)/sha256.o: sha256.c sha256.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -c -o $@ sha256.c
$(OUT)/elfid.o: elfid.c elfid.h sha256.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -c -o $@ elfid.c
$(OUT)/ghx_elfcheck: tests/ghx_elfcheck.c $(OUT)/elfid.o $(OUT)/sha256.o
	$(CC) $(CFLAGS) -I. -o $@ tests/ghx_elfcheck.c $(OUT)/elfid.o $(OUT)/sha256.o
$(OUT)/ghx_worker.o: ghx_worker.cc sha256.h elfid.h
	@test -n "$(GHIDRA_CPP)" || { echo "set GHIDRA_CPP to a built copy of Ghidra's decompiler cpp directory (build_ghidra.sh)" >&2; exit 1; }
	@mkdir -p $(OUT)
	$(CXX) $(CXXFLAGS) -c -o $@ ghx_worker.cc
$(OUT)/ghx_worker: $(OUT)/ghx_worker.o $(OUT)/sha256.o $(OUT)/elfid.o $(GHIDRA_CPP)/libdecomp.a
	$(CXX) -o $@ $(OUT)/ghx_worker.o $(OUT)/sha256.o $(OUT)/elfid.o $(GHIDRA_CPP)/libdecomp.a -lz
$(OUT)/ghx_supervise: ghx_supervise.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -D_GNU_SOURCE -o $@ ghx_supervise.c

clean:
	rm -f $(OUT)/*.o $(OUT)/ghx_worker $(OUT)/ghx_supervise $(OUT)/ghx_measure $(OUT)/ghx_elfcheck
.PHONY: all tools clean
