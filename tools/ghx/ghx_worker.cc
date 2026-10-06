/* ghx_worker: native (no Java) Ghidra decompiler worker for one ELF function.
 *
 * C01 candidate for xodb (GPLv3).  This file is the only xodb-owned code
 * that touches Ghidra's C++ decompiler API (Apache-2.0, built from source into
 * libdecomp.a).  It is a host-side analysis process only; nothing here is a
 * dependency of the xodb C target agent.
 *
 * Immutable inputs: the ELF image and the optional
 * function-start map are each read once into worker-owned memory, hashed from
 * that memory and served from it; their paths are never reopened.  The SLEIGH
 * specification set is copied once per worker process into a private snapshot
 * directory (hashing the bytes written) and Ghidra is initialised on that
 * snapshot only; every request re-verifies the snapshot.
 *
 * Protocol (provisional, worker side, one line per request on stdin):
 *   DECOMPILE \t id=.. \t elf=.. \t entry=0x.. [\t size=0x..] [\t name=..]
 *             [\t lang=..] [\t cspec=..] [\t symbols=0|1] [\t imports=0|1]
 *             [\t bounds=strict|advisory] [\t function_map=/abs] [\t max_out=N]
 *             test hooks (only with --test-hooks): test_sleep_ms, test_crash,
 *             test_alloc_mb, test_barrier=/abs, test_read_barrier=/abs
 *   PING | QUIT
 * Response: "RESULT\tid=..\tstatus=ok|error\tbytes=N\n" followed by N bytes of
 * JSON (schema xodb.ghidra.function_graph 0.4.1), or "PONG\n".
 */
#include "libdecomp.hh"
#include "funcdata.hh"
#include "flow.hh"
#include "comment.hh"
#include "prettyprint.hh"
#include "jumptable.hh"

extern "C" {
#include "sha256.h"
#include "elfid.h"
}

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
#include <algorithm>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <cstring>

using namespace ghidra;
using std::string;

static const char *WORKER_VERSION = "0.4.1";
static const char *SCHEMA = "xodb.ghidra.function_graph";
static const char *SCHEMA_VERSION = "0.4.1";
#ifndef GHIDRA_COMMIT
#define GHIDRA_COMMIT "unknown"
#endif
#ifndef GHIDRA_VERSION
#define GHIDRA_VERSION "unknown"
#endif

#define MAX_ELF_BYTES (512ull << 20)
#define MAX_MAP_BYTES (1ull << 20)
#define MAX_SPEC_FILE (64ull << 20)
#define MAX_SPEC_TOTAL (512ull << 20)
#define MAX_SPEC_FILES 4096

/* Imports whose callee never returns.  Declared knowledge, versioned and
 * hashed into every artifact identity (noreturn_table_sha256). */
static const char NORETURN_TABLE[] =
	"ghx-noreturn-v1\n"
	"abort\nexit\n_exit\n_Exit\nquick_exit\n__stack_chk_fail\n__stack_chk_fail_local\n"
	"__assert_fail\n__assert_perror_fail\n__fortify_fail\n__chk_fail\n__libc_fatal\n"
	"longjmp\n_longjmp\nsiglongjmp\n__longjmp_chk\npthread_exit\nthrd_exit\n"
	"err\nerrx\nverr\nverrx\n__cxa_throw\n__cxa_rethrow\n__cxa_pure_virtual\n"
	"_Unwind_Resume\n_ZSt9terminatev\n";

/* Import prototypes (SysV x86-64 C ABI), declared knowledge hashed into every
 * artifact identity (prototype_table_sha256).  name|return|args[|...]
 * types: v void, i int32, u uint32, l int64, z size_t, p pointer. */
static const char PROTOTYPE_TABLE[] =
	"ghx-prototypes-v1\n"
	"malloc|p|z\ncalloc|p|z,z\nrealloc|p|p,z\nfree|v|p\n"
	"memcpy|p|p,p,z\nmemmove|p|p,p,z\nmemset|p|p,i,z\nmemcmp|i|p,p,z\n"
	"strlen|z|p\nstrcmp|i|p,p\nstrncmp|i|p,p,z\nstrcpy|p|p,p\nstrncpy|p|p,p,z\n"
	"strtol|l|p,p,i\n__isoc23_strtol|l|p,p,i\natoi|i|p\n"
	"printf|i|p|...\nputs|i|p\n"
	"abort|v|\nexit|v|i\n_exit|v|i\n__stack_chk_fail|v|\n";

/* ------------------------------------------------------------------ JSON */

static void jstr(string &o, const string &s)
{
	static const char hx[] = "0123456789abcdef";
	o += '"';
	size_t i = 0, n = s.size();
	while (i < n) {
		unsigned char c = s[i];
		if (c == '"' || c == '\\') { o += '\\'; o += c; i++; continue; }
		if (c < 0x20) { o += "\\u00"; o += hx[c >> 4]; o += hx[c & 15]; i++; continue; }
		if (c < 0x80) { o += c; i++; continue; }
		/* validate one UTF-8 sequence; replace invalid bytes with U+FFFD */
		int len = (c & 0xe0) == 0xc0 ? 2 : (c & 0xf0) == 0xe0 ? 3 : (c & 0xf8) == 0xf0 ? 4 : 0;
		bool ok = len > 0 && i + len <= n;
		for (int k = 1; ok && k < len; k++)
			ok = (((unsigned char)s[i + k]) & 0xc0) == 0x80;
		if (ok) { o.append(s, i, len); i += len; }
		else { o += "\\ufffd"; i++; }
	}
	o += '"';
}

static string hexu(uintb v)
{
	char b[24];
	snprintf(b, sizeof b, "0x%llx", (unsigned long long)v);
	return b;
}

static string jhex(uintb v) { return "\"" + hexu(v) + "\""; }

/* Comma-managing object/array writer. */
struct J {
	string o;
	std::vector<bool> first;	/* per open container: no element written yet */
	bool keyed = false;		/* a key was just written; next value takes no comma */
	void vsep() {
		if (keyed) { keyed = false; return; }
		if (!first.empty()) { if (!first.back()) o += ','; first.back() = false; }
	}
	J &obj() { vsep(); o += '{'; first.push_back(true); return *this; }
	J &arr() { vsep(); o += '['; first.push_back(true); return *this; }
	J &end_obj() { o += '}'; first.pop_back(); return *this; }
	J &end_arr() { o += ']'; first.pop_back(); return *this; }
	J &key(const char *k) { vsep(); jstr(o, k); o += ':'; keyed = true; return *this; }
	J &raw(const string &v) { vsep(); o += v; return *this; }
	J &s(const string &v) { vsep(); jstr(o, v); return *this; }
	J &i(long long v) { vsep(); o += std::to_string(v); return *this; }
	J &b(bool v) { vsep(); o += v ? "true" : "false"; return *this; }
	J &null() { vsep(); o += "null"; return *this; }
	J &hx(uintb v) { vsep(); o += jhex(v); return *this; }
	J &kobj(const char *k) { key(k); return obj(); }
	J &karr(const char *k) { key(k); return arr(); }
	J &ks(const char *k, const string &v) { key(k); return s(v); }
	J &ki(const char *k, long long v) { key(k); return i(v); }
	J &kb(const char *k, bool v) { key(k); return b(v); }
	J &khx(const char *k, uintb v) { key(k); return hx(v); }
	J &knull(const char *k) { key(k); return null(); }
	J &kraw(const char *k, const string &v) { key(k); return raw(v); }
};
static J &openobj(J &j) { return j.obj(); }

/* ------------------------------------------------------------ utilities */

static double now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static long peak_rss_kb(void)
{
	struct rusage ru;
	getrusage(RUSAGE_SELF, &ru);
	return ru.ru_maxrss;
}

static string sha_hex(const string &s)
{
	char h[65];
	ghx_sha256_hex(s.data(), s.size(), h);
	return h;
}

static string self_sha;		/* sha256 of /proc/self/exe at start */
static bool test_hooks = false;

/* Test barrier: announce PATH.ready (with an optional payload) and wait up to
 * 20 s for PATH.go to exist.  Only reachable with --test-hooks. */
static void barrier(const string &path, const string &payload)
{
	string ready = path + ".ready", go = path + ".go";
	int fd = open(ready.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (fd >= 0) {
		if (write(fd, payload.data(), payload.size()) < 0) { /* best effort */ }
		close(fd);
	}
	for (int i = 0; i < 20000; i++) {
		if (access(go.c_str(), F_OK) == 0) return;
		usleep(1000);
	}
}

/* ------------------------------------------------- specification snapshot */

struct SpecFile { string rel; string sha; uint64_t size; };
static std::vector<SpecFile> specs;	/* sorted by rel */
static string snapdir, spec_set_sha, ldefs_sha, spec_error;
static bool snapdir_owned = false;

static bool has_suffix(const string &s, const char *suf)
{
	size_t n = strlen(suf);
	return s.size() >= n && s.compare(s.size() - n, n, suf) == 0;
}

static std::vector<string> list_dir(const string &dir, bool want_dirs)
{
	std::vector<string> out;
	DIR *d = opendir(dir.c_str());
	if (!d) return out;
	while (struct dirent *e = readdir(d)) {
		string n = e->d_name;
		if (n == "." || n == "..") continue;
		struct stat st;
		if (lstat((dir + "/" + n).c_str(), &st) != 0) continue;
		if (want_dirs ? S_ISDIR(st.st_mode) : S_ISREG(st.st_mode)) out.push_back(n);
	}
	closedir(d);
	std::sort(out.begin(), out.end());
	return out;
}

static bool mkdirs(const string &path)
{
	for (size_t p = 1; p <= path.size(); p++) {
		if (p < path.size() && path[p] != '/') continue;
		string d = path.substr(0, p);
		if (mkdir(d.c_str(), 0755) != 0 && errno != EEXIST) return false;
	}
	return true;
}

/* Copy every *.ldefs/.sla/.pspec/.cspec of SRC/Ghidra/Processors/<p>/data/languages
 * into DST, hashing the snapshot bytes.  Returns "" or an error. */
static string snapshot_specs(const string &src, const string &dst)
{
	uint64_t total = 0;
	string procs = src + "/Ghidra/Processors";
	for (const string &p : list_dir(procs, true)) {
		string rel_dir = "Ghidra/Processors/" + p + "/data/languages";
		for (const string &f : list_dir(src + "/" + rel_dir, false)) {
			if (!has_suffix(f, ".ldefs") && !has_suffix(f, ".sla") && !has_suffix(f, ".pspec") && !has_suffix(f, ".cspec"))
				continue;
			if (specs.size() >= MAX_SPEC_FILES) return "too many specification files";
			struct ghx_snapshot s;
			char err[256];
			string rel = rel_dir + "/" + f;
			int rc = ghx_snapshot_read((src + "/" + rel).c_str(), MAX_SPEC_FILE, &s, err, sizeof err, NULL, NULL);
			if (rc) return rel + ": " + err;
			total += s.size;
			if (total > MAX_SPEC_TOTAL) { ghx_snapshot_free(&s); return "specification set exceeds size limit"; }
			if (!mkdirs(dst + "/" + rel_dir)) { ghx_snapshot_free(&s); return "cannot create snapshot directory"; }
			int fd = open((dst + "/" + rel).c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0444);
			uint64_t off = 0;
			while (fd >= 0 && off < s.size) {
				ssize_t k = write(fd, s.bytes + off, s.size - off);
				if (k < 0 && errno == EINTR) continue;
				if (k <= 0) break;
				off += (uint64_t)k;
			}
			if (fd < 0 || off != s.size || close(fd) != 0) { ghx_snapshot_free(&s); return rel + ": cannot write snapshot copy"; }
			specs.push_back(SpecFile{ rel, s.sha256, s.size });
			ghx_snapshot_free(&s);
		}
	}
	if (specs.empty()) return "no specification files under " + procs;
	std::sort(specs.begin(), specs.end(), [](const SpecFile &a, const SpecFile &b) { return a.rel < b.rel; });
	string all, ld;
	for (const SpecFile &f : specs) {
		string line = f.rel + "\t" + f.sha + "\t" + std::to_string(f.size) + "\n";
		all += line;
		if (has_suffix(f.rel, ".ldefs")) ld += line;
	}
	spec_set_sha = sha_hex(all);
	ldefs_sha = sha_hex(ld);
	return "";
}

/* re-hash the private snapshot; returns "" or the first difference */
static string verify_specs(void)
{
	for (const SpecFile &f : specs) {
		char h[65];
		if (ghx_sha256_file((snapdir + "/" + f.rel).c_str(), h) != 0) return f.rel + ": unreadable";
		if (f.sha != h) return f.rel + ": content changed";
	}
	return "";
}

static const SpecFile *spec_for_path(const string &full)
{
	string norm;
	for (char c : full) if (!(c == '/' && !norm.empty() && norm.back() == '/')) norm += c;
	string pre = snapdir + "/";
	if (norm.compare(0, pre.size(), pre) != 0) return 0;
	string rel = norm.substr(pre.size());
	for (const SpecFile &f : specs) if (f.rel == rel) return &f;
	return 0;
}

static void remove_tree(const string &dir)
{
	for (const string &d : list_dir(dir, true)) remove_tree(dir + "/" + d);
	for (const string &f : list_dir(dir, false)) unlink((dir + "/" + f).c_str());
	rmdir(dir.c_str());
}

/* ---------------------------------------------- snapshot load image */

/// LoadImage over the immutable snapshot: PT_LOAD file bytes, zero memsz
/// tail, nothing outside the segments.  Symbols come from the snapshot too.
///
/// Data reads (jump tables, read-only constants) see any PT_LOAD and fail with
/// DataUnavailError if any requested byte is outside every segment; no byte is
/// invented.  The one exception is the SLEIGH decoder's fixed 16-byte
/// prefetch (prefetch > 0, set only by AdmitSleigh): its unmapped suffix is
/// padded with zeros so that a short instruction at a segment end can be
/// decoded.  That padding is never evidence: AdmitSleigh admits an
/// instruction only if its whole consumed span is file-backed executable.
class SnapImage : public LoadImage {
	const unsigned char *bytes;
	const ghx_elfid *id;
	AddrSpace *spc = 0;
	std::vector<LoadImageFunc> syms;
	mutable size_t cur = 0;
public:
	int prefetch = 0;
	SnapImage(const string &name, const unsigned char *b, const ghx_elfid *e) : LoadImage(name), bytes(b), id(e) {}
	void attachToSpace(AddrSpace *s) { spc = s; }
	AddrSpace *space(void) const { return spc; }
	void addSymbol(const string &n, uintb a) { LoadImageFunc f; f.name = n; f.address = Address(spc, a); syms.push_back(f); }
	virtual void loadFill(uint1 *ptr, int4 size, const Address &addr) {
		if (addr.getSpace() != spc)
			throw DataUnavailError("Trying to get loadimage bytes from space: " + addr.getSpace()->getName());
		uintb a = addr.getOffset();
		for (int4 i = 0; i < size; i++) {
			unsigned char v;
			if (a + (uintb)i < a || ghx_elf_byte(id, bytes, a + (uintb)i, &v) < 0) {
				if (i == 0 || prefetch <= 0)
					throw DataUnavailError("Unable to load bytes at " + hexu(a + (uintb)i) + ": outside every PT_LOAD");
				memset(ptr + i, 0, size - i);	/* decoder prefetch only */
				return;
			}
			ptr[i] = v;
		}
	}
	virtual void openSymbols(void) const { cur = 0; }
	virtual void closeSymbols(void) const { cur = 0; }
	virtual bool getNextSymbol(LoadImageFunc &r) const {
		if (cur >= syms.size()) return false;
		r = syms[cur++];
		return true;
	}
	virtual void getReadonly(RangeList &list) const {
		for (unsigned i = 0; i < id->nload; i++)
			if (!(id->load[i].flags & 2) && id->load[i].memsz)
				list.insertRange(spc, id->load[i].vaddr, id->load[i].vaddr + id->load[i].memsz - 1);
	}
	virtual string getArchType(void) const { return "elf64-x86-64-snapshot"; }
	virtual void adjustVma(long) { throw LowlevelError("adjustVma unsupported on a snapshot image"); }
};

/* ------------------------------------------ instruction admission */

/// SLEIGH translator that admits an instruction only if its complete
/// consumed span [addr, addr+length) is file-backed bytes of one PF_X PT_LOAD
/// and, for strict bounds, lies inside [lo, lo+size).  Anything else raises
/// BadDataError before p-code, assembly or length is published, which Ghidra's
/// flow turns into a truncated path (artificial halt).  Refusals seen while
/// recording are kept for the export's qualification.  A decode failure whose
/// 16-byte prefetch window is not entirely file-backed executable bytes may be
/// caused by the padding (a truncated instruction), so it is refused
/// (undecodable_at_segment_end), not left as an ordinary bad instruction.
struct Refusal { int4 length; string reason; };

static string refusal_why(const string &reason)
{
	if (reason == "outside_strict_bounds") return "it does not fit inside the strict declared range";
	if (reason == "undecodable_at_segment_end")
		return "it does not decode and the decoder's 16-byte window runs past the file-backed executable bytes, so it may be a truncated instruction";
	return "its consumed bytes are not all file-backed bytes of an executable PT_LOAD";
}

class AdmitSleigh : public Sleigh {
public:
	const ghx_elfid *id = 0;
	SnapImage *img = 0;
	bool strict = false;
	uintb lo = 0, size = 0;
	bool record = false;
	mutable std::map<uintb, Refusal> refused;
	AdmitSleigh(LoadImage *ld, ContextDatabase *c) : Sleigh(ld, c) {}
	struct Prefetch {
		SnapImage *i;
		Prefetch(SnapImage *x) : i(x) { i->prefetch++; }
		~Prefetch() { i->prefetch--; }
	};
	int4 admit(const Address &a) const {
		uintb off = a.getOffset();
		int4 n = 0;
		const char *why = 0;
		if (a.getSpace() != img->space() || !ghx_elfid_exec_range(id, off, 1))
			why = "not_file_backed_executable";
		else {
			bool undecodable = false;
			try { Prefetch p(img); n = Sleigh::instructionLength(a); }
			catch (LowlevelError &) {
				if (ghx_elfid_exec_range(id, off, 16)) throw;	/* window is real bytes */
				undecodable = true;
			}
			if (undecodable)
				why = "undecodable_at_segment_end";
			else if (n <= 0 || !ghx_elfid_exec_range(id, off, (uint64_t)n))
				why = "not_file_backed_executable";
			else if (strict && !(off >= lo && off - lo < size && (uintb)n <= size - (off - lo)))
				why = "outside_strict_bounds";
		}
		if (why) {
			if (record) refused[off] = Refusal{ n, why };
			throw BadDataError("instruction at " + hexu(off) + (n > 0 ? " (length " + std::to_string(n) + ")" : string()) +
					   " refused: " + why);
		}
		return n;
	}
	virtual int4 instructionLength(const Address &a) const { return admit(a); }
	virtual int4 oneInstruction(PcodeEmit &emit, const Address &a) const {
		admit(a);
		Prefetch p(img);
		return Sleigh::oneInstruction(emit, a);
	}
	virtual int4 printAssembly(AssemblyEmit &emit, const Address &a) const {
		admit(a);
		Prefetch p(img);
		return Sleigh::printAssembly(emit, a);
	}
};

/* One admitting translator per language for the worker process, reset for
 * every request like SleighArchitecture's own cache (the .sla is decoded
 * once).  Deliberately never freed. */
static std::map<string, AdmitSleigh *> admit_translators;

/* ---------------------------------------------- architecture subclass */

/// SleighArchitecture with the snapshot loader and an explicit language id.
class ElfArch : public SleighArchitecture {
public:
	string langid, cspecid;
	const unsigned char *bytes;
	const ghx_elfid *id;
	bool strict;
	uintb lo, size;
	ElfArch(const string &name, const string &lang, const string &cspec, const unsigned char *b, const ghx_elfid *e,
		bool strict_bounds, uintb entry, uintb sz, ostream *err)
		: SleighArchitecture(name, lang + ":" + cspec, err), langid(lang), cspecid(cspec), bytes(b), id(e),
		  strict(strict_bounds), lo(entry), size(sz) {}
	virtual void buildLoader(DocumentStorage &store) {
		collectSpecFiles(*errorstream);
		loader = new SnapImage(getFilename(), bytes, id);	/* owned by Architecture */
	}
	virtual Translate *buildTranslator(DocumentStorage &store) {
		AdmitSleigh *&t = admit_translators[langid];
		if (t) t->reset(loader, context);
		else t = new AdmitSleigh(loader, context);
		t->id = id;
		t->img = (SnapImage *)loader;
		t->strict = strict;
		t->lo = lo;
		t->size = size;
		t->record = false;
		t->refused.clear();
		return t;
	}
	AdmitSleigh *admitter(void) { return (AdmitSleigh *)translate; }
	virtual void resolveArchitecture(void) {
		archid = getTarget();	/* explicit: lang:cspec, no guessing */
		SleighArchitecture::resolveArchitecture();
	}
	virtual void postSpecFile(void) {
		Architecture::postSpecFile();
		((SnapImage *)loader)->attachToSpace(getDefaultCodeSpace());
	}
	SnapImage *image(void) { return (SnapImage *)loader; }
	const LanguageDescription &lang(void) const {
		const std::vector<LanguageDescription> &d(getDescriptions());
		for (size_t i = 0; i < d.size(); i++)
			if (d[i].getId() == langid) return d[i];
		throw LowlevelError("language description vanished: " + langid);
	}
};

/* ------------------------------------------------- raw p-code capture */

struct RawOp {
	OpCode opc;
	bool hasout;
	VarnodeData out;
	std::vector<VarnodeData> in;
};

class RawEmit : public PcodeEmit {
public:
	std::vector<RawOp> ops;
	virtual void dump(const Address &addr, OpCode opc, VarnodeData *outvar, VarnodeData *vars, int4 isize) {
		RawOp r;
		r.opc = opc;
		r.hasout = outvar != 0;
		if (outvar) r.out = *outvar;
		for (int4 i = 0; i < isize; i++) r.in.push_back(vars[i]);
		ops.push_back(r);
	}
};

class AsmEmit : public AssemblyEmit {
public:
	string mnem, body;
	virtual void dump(const Address &addr, const string &m, const string &b) { mnem = m; body = b; }
};

/* -------------------------------------------------------- request */

struct Req {
	string id, elf, name, funcmap, lang = "x86:LE:64:default", cspec = "gcc";
	uintb entry = 0, size = 0;
	bool have_entry = false, symbols = true, imports = true, strict_bounds = false;
	long long max_out = 64ll << 20;
	long test_sleep_ms = 0, test_alloc_mb = 0;
	bool test_crash = false;
	string test_barrier, test_read_barrier;
};

static bool parse_hex(const string &s, uintb &v)
{
	if (s.size() < 3 || s.size() > 18 || s[0] != '0' || (s[1] != 'x' && s[1] != 'X')) return false;
	v = 0;
	for (size_t i = 2; i < s.size(); i++) {
		char c = s[i];
		int d = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
		if (d < 0) return false;
		v = v << 4 | d;
	}
	return true;
}

static bool safe_token(const string &s, size_t max)
{
	if (s.empty() || s.size() > max) return false;
	for (unsigned char c : s)
		if (!(isalnum(c) || c == '_' || c == '.' || c == '-' || c == ':' || c == '@' || c == '$'))
			return false;
	return true;
}

static bool parse_num(const string &v, long lo, long hi, long &out)
{
	if (v.empty() || v.size() > 12) return false;
	for (char c : v) if (c < '0' || c > '9') return false;
	long n = atol(v.c_str());
	if (n < lo || n > hi) return false;
	out = n;
	return true;
}

/* returns "" or an error string */
static string parse_req(const string &line, Req &r)
{
	std::vector<string> f;
	size_t p = 0;
	std::set<string> seen;
	for (;;) {
		size_t t = line.find('\t', p);
		f.push_back(line.substr(p, t == string::npos ? string::npos : t - p));
		if (t == string::npos) break;
		p = t + 1;
	}
	for (size_t i = 1; i < f.size(); i++) {
		size_t eq = f[i].find('=');
		if (eq == string::npos) return "field without '='";
		string k = f[i].substr(0, eq), v = f[i].substr(eq + 1);
		if (!seen.insert(k).second) return "duplicate field " + k;
		long n;
		if (k == "id") { if (!safe_token(v, 64)) return "bad id"; r.id = v; }
		else if (k == "elf") { if (v.empty() || v[0] != '/' || v.size() > 4095) return "bad elf path"; r.elf = v; }
		else if (k == "function_map") { if (v.empty() || v[0] != '/' || v.size() > 4095) return "bad function_map"; r.funcmap = v; }
		else if (k == "entry") { if (!parse_hex(v, r.entry)) return "bad entry"; r.have_entry = true; }
		else if (k == "size") { if (!parse_hex(v, r.size) || r.size > (1u << 24)) return "bad size"; }
		else if (k == "name") { if (!safe_token(v, 256)) return "bad name"; r.name = v; }
		else if (k == "lang") { if (!safe_token(v, 128)) return "bad lang"; r.lang = v; }
		else if (k == "cspec") { if (!safe_token(v, 64)) return "bad cspec"; r.cspec = v; }
		else if (k == "bounds") { if (v != "strict" && v != "advisory") return "bad bounds"; r.strict_bounds = v == "strict"; }
		else if (k == "symbols") { if (v != "0" && v != "1") return "bad symbols"; r.symbols = v == "1"; }
		else if (k == "imports") { if (v != "0" && v != "1") return "bad imports"; r.imports = v == "1"; }
		else if (k == "max_out") { if (!parse_num(v, 1024, 1l << 31, n)) return "bad max_out"; r.max_out = n; }
		else if (k == "test_sleep_ms" && test_hooks) { if (!parse_num(v, 0, 600000, n)) return "bad test_sleep_ms"; r.test_sleep_ms = n; }
		else if (k == "test_alloc_mb" && test_hooks) { if (!parse_num(v, 0, 1 << 20, n)) return "bad test_alloc_mb"; r.test_alloc_mb = n; }
		else if (k == "test_crash" && test_hooks) r.test_crash = v == "1";
		else if (k == "test_barrier" && test_hooks) { if (v.empty() || v[0] != '/') return "bad test_barrier"; r.test_barrier = v; }
		else if (k == "test_read_barrier" && test_hooks) { if (v.empty() || v[0] != '/') return "bad test_read_barrier"; r.test_read_barrier = v; }
		else return "unknown field " + k;
	}
	if (r.id.empty()) return "missing id";
	if (r.elf.empty()) return "missing elf";
	if (!r.have_entry) return "missing entry";
	if (r.size && r.entry + r.size < r.entry) return "entry+size overflows the address space";
	return "";
}

/* ------------------------------------------------------ export helpers */

static string opid(const PcodeOp *op) { return "op:" + std::to_string(op->getTime()); }
static string vnid(const Varnode *vn) { return "vn:" + std::to_string(vn->getCreateIndex()); }

static const char *spacetype_name(spacetype t)
{
	switch (t) {
	case IPTR_CONSTANT: return "constant";
	case IPTR_PROCESSOR: return "processor";
	case IPTR_SPACEBASE: return "spacebase";
	case IPTR_INTERNAL: return "internal";
	case IPTR_FSPEC: return "fspec";
	case IPTR_IOP: return "iop";
	case IPTR_JOIN: return "join";
	}
	return "unknown";
}

/* storage of a raw VarnodeData (no identity) */
static void emit_vdata(J &j, Architecture *glb, const VarnodeData &v, bool spaceid = false)
{
	openobj(j);
	j.ks("space", v.space->getName());
	if (spaceid) {	/* LOAD/STORE input0: constant encodes an AddrSpace pointer */
		AddrSpace *sp = v.getSpaceFromConst();
		j.khx("offset", sp ? (uintb)sp->getIndex() : 0);
		j.ks("space_ref", sp ? sp->getName() : "");
		j.ki("size", v.size);
		j.end_obj();
		return;
	}
	j.khx("offset", v.offset);
	j.ki("size", v.size);
	if (v.space->getType() == IPTR_PROCESSOR) {
		string rn = glb->translate->getRegisterName(v.space, v.offset, v.size);
		if (!rn.empty()) j.ks("register", rn);
	}
	j.end_obj();
}

static string type_name(Datatype *t) { return t ? t->getDisplayName() : string(); }

/* ---------------------------------------------- pseudocode token walk */

struct Tok {
	string text, kind;
	int line, col;
	long long opref = -1, varref = -1, blockref = -1;
	string symref;
	int color = -1;
};

static void walk_markup(const Element *el, std::vector<Tok> &toks)
{
	const List &ch = el->getChildren();
	if (el->getName() == "break") return;
	if (ch.empty()) {
		const string &c = el->getContent();
		if (c.empty()) return;
		Tok t;
		t.text = c; t.kind = el->getName(); t.line = 0; t.col = 0;
		for (int4 i = 0; i < el->getNumAttributes(); i++) {
			const string &an = el->getAttributeName(i), &av = el->getAttributeValue(i);
			if (an == "opref") t.opref = strtoll(av.c_str(), 0, 0);
			else if (an == "varref") t.varref = strtoll(av.c_str(), 0, 0);
			else if (an == "blockref") t.blockref = strtoll(av.c_str(), 0, 0);
			else if (an == "symref") t.symref = av;
			else if (an == "color") t.color = (int)strtol(av.c_str(), 0, 0);
		}
		toks.push_back(t);
		return;
	}
	for (const Element *c : ch) walk_markup(c, toks);
}

/* Place tokens on the canonical plain text: only whitespace may separate
 * consecutive tokens (Ghidra's XML reader drops whitespace-only content).
 * Returns the number of tokens that could not be aligned. */
static size_t align_tokens(std::vector<Tok> &toks, const string &text)
{
	size_t pos = 0, bad = 0;
	int line = 1;
	size_t linestart = 0;
	for (Tok &t : toks) {
		size_t q = pos;
		while (q < text.size() && (text[q] == ' ' || text[q] == '\n' || text[q] == '\t')) q++;
		if (text.compare(q, t.text.size(), t.text) != 0) { t.line = -1; t.col = -1; bad++; continue; }
		for (size_t k = pos; k < q; k++) if (text[k] == '\n') { line++; linestart = k + 1; }
		t.line = line;
		t.col = (int)(q - linestart);
		pos = q + t.text.size();
	}
	return bad;
}

static bool gs_query(Architecture *glb, const Address &a)
{
	return glb->symboltab->getGlobalScope()->queryFunction(a) != 0;
}

/* ------------------------------------------------------------- core */

struct Fail {
	string code, msg;
};

struct Import { string name, section; uintb stub, got; bool noreturn, added, prototype; };

/* Apply the table entry for name (if any) as a locked prototype. */
static bool apply_prototype(Architecture *glb, Funcdata *f, const string &name)
{
	string key = "\n" + name + "|";
	const char *at = strstr(PROTOTYPE_TABLE, key.c_str());
	if (!at) return false;
	at += key.size();
	const char *end = strchr(at, '\n');
	string spec(at, end - at), ret = spec.substr(0, spec.find('|')), rest = spec.substr(spec.find('|') + 1);
	bool varargs = false;
	size_t bar = rest.find('|');
	if (bar != string::npos) { varargs = rest.substr(bar + 1) == "..."; rest = rest.substr(0, bar); }
	TypeFactory *t = glb->types;
	auto type = [&](char c) -> Datatype * {
		switch (c) {
		case 'v': return t->getTypeVoid();
		case 'i': return t->getBase(4, TYPE_INT);
		case 'u': return t->getBase(4, TYPE_UINT);
		case 'l': return t->getBase(8, TYPE_INT);
		case 'z': return t->getBase(8, TYPE_UINT);
		default: return t->getTypePointer(8, t->getBase(1, TYPE_UNKNOWN), 1);
		}
	};
	PrototypePieces pp;
	pp.model = glb->defaultfp;
	pp.name = name;
	pp.outtype = type(ret.empty() ? 'v' : ret[0]);
	for (size_t i = 0; i < rest.size(); i++) {
		if (rest[i] == ',') continue;
		pp.intypes.push_back(type(rest[i]));
		pp.innames.push_back("arg" + std::to_string(pp.intypes.size()));
	}
	pp.firstVarArgSlot = varargs ? (int4)pp.intypes.size() : -1;
	f->getFuncProto().setPieces(pp);
	return true;
}

static void import_cb(void *arg, const char *name, uint64_t stub, uint64_t got, const char *section)
{
	std::vector<Import> *v = (std::vector<Import> *)arg;
	for (const Import &i : *v) if (i.name == name || i.stub == stub) return;	/* first wins */
	v->push_back(Import{ name, section, stub, got, false, false, false });
}

static void sym_cb(void *arg, const char *name, uint64_t addr, uint64_t)
{
	((SnapImage *)arg)->addSymbol(name, addr);
}

static bool noreturn_name(const string &n)
{
	string t = "\n" + n + "\n";
	return strstr(NORETURN_TABLE, t.c_str()) != NULL;
}

struct Inputs {
	const ghx_snapshot *elf;
	const ghx_elfid *id;
	const ghx_snapshot *fmap;	/* NULL if none */
};

static void decompile_export(const Req &r, J &j, const Inputs &in, double t0, std::ostringstream &errs)
{
	const ghx_elfid &id = *in.id;
	string fm_sha = in.fmap ? in.fmap->sha256 : "none";
	ElfArch *arch = 0;
	try {
		arch = new ElfArch("snapshot:" + string(id.sha256), r.lang, r.cspec, in.elf->bytes, in.id,
				   r.strict_bounds && r.size != 0, r.entry, r.size, &errs);
		DocumentStorage store;
		arch->init(store);
	} catch (LowlevelError &e) {
		delete arch;
		throw Fail{ "arch_init", e.explain };
	} catch (DecoderError &e) {
		delete arch;
		throw Fail{ "spec_decode", e.explain };
	}
	std::unique_ptr<ElfArch> own(arch);
	Architecture *glb = arch;
	double t_init = now_ms();

	string symbols_status = !r.symbols ? "disabled" : id.has_symtab ? "symtab" : "absent";
	if (r.symbols) {
		char serr[256] = "";
		if (ghx_elf_symbols(in.elf->bytes, in.elf->size, sym_cb, arch->image(), serr, sizeof serr) != 0)
			throw Fail{ "symbols", serr };
		try { glb->readLoaderSymbols(); }
		catch (LowlevelError &e) { throw Fail{ "symbols", e.explain }; }
	}
	AddrSpace *code = glb->getDefaultCodeSpace();
	Address entry(code, r.entry);
	Scope *gs = glb->symboltab->getGlobalScope();
	/* declared function starts (e.g. retained oracle for stripped images):
	 * one record "name 0xentry 0xsize" per line, parsed from the map
	 * snapshot.  Declared input, not discovery.  Every non-empty line must be
	 * a complete, valid record whose range is file-backed executable bytes,
	 * with no entry repeated; any malformed, truncated, duplicate or
	 * out-of-range record refuses the request (error function_map).  Only
	 * accepted records count as evidence (function_map.used). */
	long fm_records = 0, fm_added = 0, fm_present = 0;
	long fm_malformed = 0, fm_noncanonical = 0, fm_truncated = 0, fm_duplicate = 0, fm_range = 0;
	uintb fm_entry_size = 0;	/* size of the accepted record starting at the requested entry, 0 if none */
	std::map<uintb, string> fm_starts;	/* every accepted record: start -> name */
	string fm_first_bad;
	std::set<uintb> fm_set;		/* entries added to the scope from the function_map */
	if (in.fmap) {
		std::set<uintb> fm_seen;
		std::vector<std::pair<string, uintb>> fm_ok;
		auto canonical = [](const string &t) {	/* 0x0 or 0x[1-9a-f][0-9a-f]* */
			if (t.size() < 3 || t.size() > 18 || t[0] != '0' || t[1] != 'x' || (t[2] == '0' && t.size() > 3)) return false;
			for (size_t i = 2; i < t.size(); i++)
				if (!((t[i] >= '0' && t[i] <= '9') || (t[i] >= 'a' && t[i] <= 'f'))) return false;
			return true;
		};
		const char *b = (const char *)in.fmap->bytes, *end = b + in.fmap->size;
		long lineno = 0;
		while (b < end) {
			const char *nl = (const char *)memchr(b, '\n', end - b);
			string line(b, nl ? nl - b : end - b);
			b = nl ? nl + 1 : end;
			lineno++;
			std::vector<string> tok;
			std::istringstream ls(line);
			for (string t; ls >> t;) tok.push_back(t);
			if (tok.empty() || tok[0][0] == '#') continue;
			const char *bad = 0;
			uintb e = 0, z = 0;
			if (++fm_records > 100000) bad = "more than 100000 records";
			else if (tok.size() < 3) { bad = "truncated record"; fm_truncated++; }
			else if (tok.size() > 3 || line.find('\0') != string::npos || !safe_token(tok[0], 256) ||
				 !parse_hex(tok[1], e) || !parse_hex(tok[2], z)) { bad = "malformed record"; fm_malformed++; }
			else if (!canonical(tok[1]) || !canonical(tok[2])) { bad = "non-canonical hex"; fm_noncanonical++; }
			else if (!fm_seen.insert(e).second) { bad = "duplicate entry"; fm_duplicate++; }
			else if (z == 0 || !ghx_elfid_exec_range(&id, e, z)) { bad = "range is not file-backed executable bytes"; fm_range++; }
			if (bad) {
				if (fm_first_bad.empty()) fm_first_bad = "line " + std::to_string(lineno) + ": " + bad;
				if (fm_records > 100000) break;
				continue;
			}
			fm_ok.push_back(std::make_pair(tok[0], e));
			fm_starts[e] = tok[0];
			if (e == r.entry) fm_entry_size = z;
		}
		long rejected = fm_malformed + fm_noncanonical + fm_truncated + fm_duplicate + fm_range;
		if (rejected || fm_records > 100000)
			throw Fail{ "function_map", "function_map rejected (" + std::to_string(rejected) + " of " + std::to_string(fm_records) +
				    " records: malformed " + std::to_string(fm_malformed) + ", noncanonical " + std::to_string(fm_noncanonical) + ", truncated " + std::to_string(fm_truncated) +
				    ", duplicate " + std::to_string(fm_duplicate) + ", range " + std::to_string(fm_range) + "); first: " + fm_first_bad };
		for (auto &f : fm_ok) {
			Address fa(code, f.second);
			if (gs_query(glb, fa)) { fm_present++; continue; }
			gs->addFunction(fa, f.first);
			fm_set.insert(f.second);
			fm_added++;
		}
	}
	long fm_accepted = fm_added + fm_present;
	/* imports: PLT stubs named from relocations of the same snapshot */
	std::vector<Import> imports;
	string imports_status = "disabled";
	std::set<uintb> import_set;
	if (r.imports) {
		char ierr[256] = "";
		int n = ghx_elf_plt_imports(in.elf->bytes, in.elf->size, import_cb, &imports, ierr, sizeof ierr);
		if (n < 0) throw Fail{ "imports", ierr };
		imports_status = imports.empty() ? "none" : "plt_relocations";
		for (Import &im : imports) {
			Address sa(code, im.stub);
			Funcdata *f = gs->queryFunction(sa);
			if (!f) {
				f = gs->addFunction(sa, im.name)->getFunction();
				im.added = true;
			}
			im.prototype = apply_prototype(glb, f, im.name);
			im.noreturn = noreturn_name(im.name);
			if (im.noreturn) f->getFuncProto().setNoReturn(true);
			import_set.insert(im.stub);
		}
	}
	/* entry (and declared range) must be file-backed bytes of an executable
	 * PT_LOAD segment of the snapshot. */
	if (!ghx_elfid_exec_range(&id, r.entry, 1))
		throw Fail{ "entry_unmapped", "entry " + hexu(r.entry) + " is not in a file-backed executable PT_LOAD segment" };
	if (r.size && !ghx_elfid_exec_range(&id, r.entry, r.size))
		throw Fail{ "range_unmapped", "declared range [" + hexu(r.entry) + "," + hexu(r.entry + r.size) + ") leaves executable file-backed segment" };
	Funcdata *fd = gs->queryFunction(entry);
	string name_prov;
	if (fd != 0) name_prov = fm_set.count(r.entry) ? "request_function_map" : import_set.count(r.entry) ? "plt_relocation" : "loader_symbol(symtab)";
	else {
		string nm = r.name;
		if (nm.empty()) { glb->nameFunction(entry, nm); name_prov = "decompiler_default"; }
		else name_prov = "request";
		fd = gs->addFunction(entry, nm)->getFunction();
	}
	bool name_matches_request = r.name.empty() || r.name == fd->getName();
	/* gcc's hot/cold split: "<owner>.cold" or "<owner>.cold.<n>" is a
	 * fragment of the requested function, not another function.  owner is
	 * the entry's function_map record name, else the function's own name.
	 * Exact suffix only: "B.cold" or "foo.coldstart" is another function. */
	const string owner = fm_entry_size ? fm_starts.at(r.entry) : fd->getName();
	auto cold_fragment = [&owner](const string &n) {
		if (n.size() < owner.size() + 5 || n.compare(0, owner.size(), owner) != 0) return false;
		string s = n.substr(owner.size());
		if (s == ".cold") return true;
		if (s.size() < 7 || s.compare(0, 6, ".cold.") != 0) return false;
		for (size_t i = 6; i < s.size(); i++)
			if (s[i] < '0' || s[i] > '9') return false;
		return true;
	};

	/* flow bounds: strict => [entry, entry+size); advisory (default) => the
	 * stock decompiler's unbounded flow, with the declared size only used to
	 * report instructions that fall outside it. */
	Address lo, hi;
	if (r.size != 0 && r.strict_bounds) { lo = entry; hi = entry + r.size; }
	else { lo = Address(code, 0); hi = Address(code, code->getHighest()); }
	AdmitSleigh *adm = arch->admitter();
	adm->record = true;
	adm->refused.clear();
	/* A flow failure after the flow left the strict range (Ghidra warns
	 * "Function flow out of bounds", then cannot find the fall-through op) is
	 * reported as bounds_exceeded, not as a generic flow error. */
	auto follow = [&]() {
		try { fd->followFlow(lo, hi); }
		catch (LowlevelError &e) {
			string oob;
			if (r.size && r.strict_bounds)
				for (auto it = glb->commentdb->beginComment(entry); it != glb->commentdb->endComment(entry); ++it)
					if (oob.empty() && (*it)->getText().find("Function flow out of bounds") != string::npos) oob = (*it)->getText();
			if (!oob.empty())
				throw Fail{ "bounds_exceeded", "flow leaves the strict declared range [" + hexu(r.entry) + "," + hexu(r.entry + r.size) +
					    "): " + oob + " (" + e.explain + ")" };
			throw Fail{ "flow", e.explain };
		}
	};
	follow();
	/* Tail calls: an unconditional jump to the start of another known
	 * function (symbol, function_map entry or PLT import) is re-flowed as
	 * CALL+RETURN (Ghidra's "callreturn" flow override), as the Java analyzer
	 * does through its function bodies.  Recorded in tail_calls[]. */
	std::vector<std::pair<uintb, uintb>> tailcalls;
	std::vector<PcodeOp *> flowed;
	for (auto it = fd->beginOpDead(); it != fd->endOpDead(); ++it) flowed.push_back(*it);
	for (auto it = fd->beginOpAlive(); it != fd->endOpAlive(); ++it) flowed.push_back(*it);
	std::vector<std::pair<uintb, uintb>> condtail;	/* jcc to a known function: not overridable */
	for (PcodeOp *op : flowed) {
		if (op->code() != CPUI_BRANCH && op->code() != CPUI_CBRANCH) continue;
		Varnode *t = op->getIn(0);
		if (!t || t->getSpace() != code) continue;
		uintb target = t->getOffset();
		Funcdata *tf = gs->queryFunction(Address(code, target));
		if (target == r.entry || !tf) continue;
		if (r.size && target >= r.entry && target - r.entry < r.size) continue;
		if (cold_fragment(tf->getName())) continue;
		uintb pc = op->getAddr().getOffset();
		if (op->code() == CPUI_CBRANCH) {
			condtail.push_back(std::make_pair(pc, target));
			continue;
		}
		bool dup = false;
		for (auto &tc : tailcalls) dup |= tc.first == pc;
		if (!dup) tailcalls.push_back(std::make_pair(pc, target));
	}
	if (!tailcalls.empty()) {
		/* drop the first pass's flow warnings (e.g. jump-table attempts inside
		 * a PLT stub); the re-flow regenerates any that still apply */
		glb->commentdb->clearType(entry, Comment::warning | Comment::warningheader);
		fd->clear();
		adm->refused.clear();
		for (auto &tc : tailcalls) fd->getOverride().insertFlowOverride(Address(code, tc.first), "callreturn");
		follow();
	}

	Action *act = glb->allacts.getCurrent();
	act->reset(*fd);
	int4 res = act->perform(*fd);
	if (res < 0) throw Fail{ "decompile_break", "action break" };
	adm->record = false;
	if (adm->refused.count(r.entry)) {
		const Refusal &x = adm->refused[r.entry];
		throw Fail{ "instruction_refused", "entry instruction at " + hexu(r.entry) + (x.length > 0 ? " (length " + std::to_string(x.length) + ")" : string()) +
			    " refused: " + x.reason + (x.reason == "outside_strict_bounds" ? " [" + hexu(r.entry) + "," + hexu(r.entry + r.size) + ")" :
			    ": " + refusal_why(x.reason)) };
	}
	double t_dec = now_ms();

	/* -------- collect ops (alive) and instructions */
	std::vector<PcodeOp *> ops;
	for (auto it = fd->beginOpAlive(); it != fd->endOpAlive(); ++it) ops.push_back(*it);
	std::sort(ops.begin(), ops.end(), [](PcodeOp *a, PcodeOp *b) { return a->getTime() < b->getTime(); });
	size_t ndead = 0;
	std::set<uintb> insn_addrs;
	for (auto it = fd->beginOpAlive(); it != fd->endOpAlive(); ++it)
		if ((*it)->getAddr().getSpace() == code) insn_addrs.insert((*it)->getAddr().getOffset());
	for (auto it = fd->beginOpDead(); it != fd->endOpDead(); ++it) {
		ndead++;
		if ((*it)->getAddr().getSpace() == code) insn_addrs.insert((*it)->getAddr().getOffset());
	}
	std::map<uintb, std::vector<string>> high_by_insn;
	for (PcodeOp *op : ops)
		if (op->getAddr().getSpace() == code) high_by_insn[op->getAddr().getOffset()].push_back(opid(op));

	struct Insn { uintb addr; int len; string mnem, body, bytes, disc; std::vector<RawOp> raw; bool err; string errmsg, refused; };
	std::map<uintb, Insn> insns;
	auto lift = [&](uintb a, const string &disc) -> Insn & {
		Insn &in = insns[a];
		in.addr = a; in.disc = disc; in.err = false; in.len = 0;
		Address ad(code, a);
		if (adm->refused.count(a)) {	/* never decoded into evidence */
			in.err = true;
			in.refused = adm->refused[a].reason;
			in.errmsg = "instruction refused: " + in.refused;
			return in;
		}
		try {
			AsmEmit ae;
			in.len = glb->translate->printAssembly(ae, ad);
			in.mnem = ae.mnem; in.body = ae.body;
			RawEmit re;
			glb->translate->oneInstruction(re, ad);
			in.raw = re.ops;
			uint1 buf[32];
			int n = in.len > 32 ? 32 : in.len;
			glb->loader->loadFill(buf, n, ad);
			static const char hx[] = "0123456789abcdef";
			for (int k = 0; k < n; k++) { in.bytes += hx[buf[k] >> 4]; in.bytes += hx[buf[k] & 15]; }
		} catch (LowlevelError &e) { in.err = true; in.errmsg = e.explain; }
		return in;
	};
	/* Instructions: sweep each basic block's original address cover (it keeps
	 * instructions whose p-code was later removed, and zero-p-code ones). */
	{
		const BlockGraph &bgc = fd->getBasicBlocks();
		for (int4 bi = 0; bi < bgc.getSize(); bi++) {
			const BlockBasic *bb = (const BlockBasic *)bgc.getBlock(bi);
			Address st = bb->getStart(), sp = bb->getStop();
			if (st.isInvalid() || sp.isInvalid() || st.getSpace() != code) continue;
			uintb a = st.getOffset(), e = sp.getOffset();
			size_t guard = 0;
			while (a <= e && guard++ < (1u << 20)) {
				if (!bb->contains(Address(code, a))) { a++; continue; }
				Insn &in = insns.count(a) ? insns[a] : lift(a, "block_cover");
				if (in.err || in.len <= 0) break;
				a += in.len;
			}
		}
		for (uintb a : insn_addrs)
			if (!insns.count(a)) lift(a, "pcode_op_address_only");
	}

	/* -------- varnodes */
	std::vector<Varnode *> vns;
	for (auto it = fd->beginLoc(); it != fd->endLoc(); ++it) vns.push_back(*it);
	std::sort(vns.begin(), vns.end(), [](Varnode *a, Varnode *b) { return a->getCreateIndex() < b->getCreateIndex(); });

	/* -------- high variables */
	std::map<HighVariable *, string> hvid;
	std::vector<HighVariable *> hvs;
	for (Varnode *vn : vns) {
		if (vn->isAnnotation()) continue;
		HighVariable *h = 0;
		try { h = vn->getHigh(); } catch (LowlevelError &) { h = 0; }
		if (!h || hvid.count(h)) continue;
		Varnode *rep = h->getNameRepresentative();
		hvid[h] = "hv:" + std::to_string(rep->getCreateIndex());
		hvs.push_back(h);
	}

	/* -------- pseudocode */
	std::ostringstream xs, ps;
	glb->print->setOutputStream(&xs);
	glb->print->setMarkup(true);
	glb->print->setPackedOutput(false);
	glb->print->docFunction(fd);
	glb->print->setMarkup(false);
	glb->print->setOutputStream(&ps);
	glb->print->docFunction(fd);
	std::vector<Tok> toks;
	string tok_status = "ok";
	size_t tok_unaligned = 0;
	{
		std::istringstream is(xs.str());
		Document *doc = 0;
		try {
			doc = xml_tree(is);
			walk_markup(doc->getRoot(), toks);
			tok_unaligned = align_tokens(toks, ps.str());
			if (tok_unaligned) tok_status = "partial_alignment";
		} catch (DecoderError &e) { tok_status = "markup_parse_failed: " + e.explain; }
		delete doc;
	}
	std::map<long long, PcodeOp *> op_by_time;
	for (PcodeOp *op : ops) op_by_time[op->getTime()] = op;
	std::map<long long, Varnode *> vn_by_idx;
	for (Varnode *vn : vns) vn_by_idx[vn->getCreateIndex()] = vn;

	/* -------- warnings (decompiler comments of warning type) */
	struct W { uintb addr; string text; bool header; };
	std::vector<W> warns;
	for (auto it = glb->commentdb->beginComment(entry); it != glb->commentdb->endComment(entry); ++it) {
		Comment *c = *it;
		if (c->getType() & (Comment::warning | Comment::warningheader))
			warns.push_back(W{ c->getAddr().getOffset(), c->getText(), (c->getType() & Comment::warningheader) != 0 });
	}


	/* ================= identity ================= */
	const LanguageDescription &ld = arch->lang();
	string slapath, pspath, cspath;
	SleighArchitecture::specpaths.findFile(slapath, ld.getSlaFile());
	SleighArchitecture::specpaths.findFile(pspath, ld.getProcessorSpec());
	SleighArchitecture::specpaths.findFile(cspath, ld.getCompiler(r.cspec).getSpec());
	const SpecFile *sla = spec_for_path(slapath), *psp = spec_for_path(pspath), *csp = spec_for_path(cspath);
	if (!sla || !psp || !csp)
		throw Fail{ "spec_outside_snapshot", "selected specification file is not part of the worker snapshot: " + slapath + " " + pspath + " " + cspath };
	string basis;
	auto kv = [&](const char *k, const string &v) { basis += k; basis += '='; basis += v; basis += '\n'; };
	kv("schema", string(SCHEMA) + "/" + SCHEMA_VERSION);
	kv("worker_sha256", self_sha);
	kv("ghidra_commit", GHIDRA_COMMIT);
	kv("image_sha256", id.sha256);
	kv("function_map_sha256", fm_sha);
	kv("spec_set_sha256", spec_set_sha);
	kv("ldefs_sha256", ldefs_sha);
	kv("sla_sha256", sla->sha);
	kv("pspec_sha256", psp->sha);
	kv("cspec_sha256", csp->sha);
	kv("lang", r.lang);
	kv("cspec", r.cspec);
	kv("entry", hexu(r.entry));
	kv("size", r.size ? hexu(r.size) : "none");
	kv("bounds", r.strict_bounds ? "strict" : "advisory");
	kv("symbols", r.symbols ? "1" : "0");
	kv("imports", r.imports ? "1" : "0");
	kv("noreturn_table_sha256", sha_hex(NORETURN_TABLE));
	kv("prototype_table_sha256", sha_hex(PROTOTYPE_TABLE));
	kv("name", r.name.empty() ? "none" : r.name);
	string artifact = "fg2-" + sha_hex(basis);

	/* ================= qualification ================= */
	struct Reason { string code, level, detail; bool has_addr; uintb addr; };
	std::vector<Reason> reasons;
	auto qual = [&](const string &code, const string &level, const string &detail, bool has_addr, uintb addr) {
		reasons.push_back(Reason{ code, level, detail, has_addr, addr });
	};
	if ((!r.symbols || !id.has_symtab) && fm_entry_size == 0)
		qual("stripped_without_function_starts", "qualified", in.fmap ? "no symbol table and the function_map has no record for the requested entry: function starts and extent are unknown" :
		     "no symbol table and no function_map: callee function starts are unknown", false, 0);
	/* refused instructions on the flowed paths: flow is truncated there */
	std::map<uintb, Refusal> refused_in_flow;
	for (auto &x : adm->refused)
		if (insn_addrs.count(x.first)) refused_in_flow[x.first] = x.second;
	for (auto &x : refused_in_flow)
		qual("instruction_refused_" + x.second.reason, "unreliable", "flow reaches " + hexu(x.first) + ": " + refusal_why(x.second.reason) +
		     "; that path is truncated (artificial halt), its semantics are not represented", true, x.first);
	/* undecodable file-backed executable bytes (window entirely real bytes):
	 * the path ends where the CPU would fault; explicit, never silent */
	for (auto &kv2 : insns)
		if (kv2.second.err && kv2.second.refused.empty())
			qual("instruction_undecoded", "qualified", "flow reaches " + hexu(kv2.first) +
			     ", file-backed executable bytes that do not decode (" + kv2.second.errmsg + "); that path ends there (artificial halt)", true, kv2.first);
	for (W &w : warns) {
		if (w.text.find("PIC construction") != string::npos)
			qual("pic_call_to_branch_heuristic", "unreliable", w.text, true, w.addr);
		else if (w.text.find("Could not recover jumptable") != string::npos || w.text.find("Treating indirect jump as call") != string::npos)
			qual("unresolved_indirect_branch", "qualified", w.text, true, w.addr);
		else
			qual("decompiler_warning", "qualified", w.text, true, w.addr);
	}
	if (r.size) {
		size_t outside = 0;
		uintb first = 0;
		size_t crossing = 0;
		uintb firstx = 0;
		for (auto &kv2 : insns) {
			if (kv2.first < r.entry || kv2.first - r.entry >= r.size) { if (!outside) first = kv2.first; outside++; }
			else if (kv2.second.len > 0 && (uintb)kv2.second.len > r.size - (kv2.first - r.entry)) { if (!crossing) firstx = kv2.first; crossing++; }
		}
		if (outside)
			qual("flow_outside_declared_bounds", "qualified", std::to_string(outside) + " instruction(s) outside the declared range", true, first);
		if (crossing)
			qual("instruction_crosses_declared_bounds", "qualified", std::to_string(crossing) + " instruction(s) start inside the declared range and end past it", true, firstx);
	}
	if (!r.size && fm_entry_size) {	/* the entry's map record is the extent */
		size_t outside = 0;
		uintb first = 0;
		for (auto &kv2 : insns)
			if (kv2.first < r.entry || kv2.first - r.entry >= fm_entry_size ||
			    (kv2.second.len > 0 && (uintb)kv2.second.len > fm_entry_size - (kv2.first - r.entry))) { if (!outside) first = kv2.first; outside++; }
		if (outside)
			qual("flow_outside_function_map_bounds", "qualified", std::to_string(outside) + " instruction(s) leave the function_map record [" +
			     hexu(r.entry) + "," + hexu(r.entry + fm_entry_size) + ")", true, first);
	}
	/* declared extents are trusted input; report the cheap signs that one is
	 * wrong: the requested size and the entry record disagree, or no exported
	 * instruction reaches the extent's last byte (dead code, or an overbroad
	 * extent that may hide absorbed code).  An overbroad extent that ends
	 * exactly at reached code is not detectable here. */
	if (r.size && fm_entry_size && r.size != fm_entry_size)
		qual("declared_extent_conflict", "qualified", "requested size " + hexu(r.size) + " differs from the function_map entry record size " +
		     hexu(fm_entry_size), false, 0);
	if (r.size || fm_entry_size) {
		uintb last = r.entry + (r.size ? r.size : fm_entry_size) - 1;
		bool reached = false;
		for (auto &kv2 : insns)
			reached |= kv2.first <= last && last - kv2.first < (uintb)(kv2.second.len > 0 ? kv2.second.len : 1);
		if (!reached)
			qual("declared_extent_unreached", "qualified", "no exported instruction reaches " + hexu(last) +
			     ", the last byte of the declared extent: dead code, or an extent wider than the function", true, last);
	}
	/* absorbed code is still reached by real control flow (an inlined tail
	 * call or fall-through); what is wrong is which function owns it.  The
	 * owner's own "<owner>.cold" fragments are not other functions. */
	for (auto &kv2 : insns) {
		auto f = fm_starts.find(kv2.first);
		if (kv2.first != r.entry && f != fm_starts.end() && !cold_fragment(f->second))
			qual("flow_reaches_other_function_start", "qualified", "flow reaches " + hexu(kv2.first) + ", the start of function_map record " +
			     f->second + "; that function's body is absorbed into this one", true, kv2.first);
	}
	for (int4 i = 0; i < fd->numCalls(); i++) {
		FuncCallSpecs *fc = fd->getCallSpecs(i);
		PcodeOp *op = fc->getOp();
		if (!op || fc->isNoReturn() || !r.size) continue;
		uintb pc = op->getAddr().getOffset();
		auto it = insns.find(pc);
		if (it == insns.end() || it->second.len <= 0) continue;
		uintb fall = pc + (uintb)it->second.len;
		if ((fall < r.entry || fall - r.entry >= r.size) && insns.count(fall))
			qual("flow_past_unknown_noreturn_candidate", "unreliable",
			     "flow continues past the call at " + hexu(pc) + " out of the declared range; the callee's return behaviour is unknown", true, pc);
	}
	for (PcodeOp *op : ops)
		if (op->code() == CPUI_BRANCHIND && fd->findJumpTable(op) == 0)
			qual("unresolved_indirect_branch", "qualified", "indirect branch without recovered targets", true, op->getAddr().getOffset());
	if (fd->numJumpTables() > 0)
		qual("jump_table_hypothesis", "qualified", std::to_string(fd->numJumpTables()) + " switch table(s) recovered from static image contents", false, 0);
	for (auto &tc : condtail)
		qual("conditional_tail_call_unmodelled", "unreliable", "conditional jump at " + hexu(tc.first) + " to known function start " + hexu(tc.second) +
		     " cannot be overridden as a call; the callee body is flowed as part of this function", true, tc.first);
	for (auto &tc : tailcalls)
		qual("tail_call_inferred", "qualified", "jump at " + hexu(tc.first) + " to known function start " + hexu(tc.second) + " treated as call+return", true, tc.first);
	{
		string inferred, local;
		uintb first_inf = 0, first_loc = 0;
		for (int4 i = 0; i < fd->numCalls(); i++) {
			FuncCallSpecs *fc = fd->getCallSpecs(i);
			PcodeOp *op = fc->getOp();
			if (!op) continue;
			uintb pc = op->getAddr().getOffset();
			if (!fc->isInputLocked()) { if (inferred.empty()) first_inf = pc; inferred += (inferred.empty() ? "" : " ") + hexu(pc); }
			Address ea = fc->getEntryAddress();
			bool import = !ea.isInvalid() && import_set.count(ea.getOffset());
			if (!import && !fc->isInputLocked()) { if (local.empty()) first_loc = pc; local += (local.empty() ? "" : " ") + hexu(pc); }
		}
		if (!inferred.empty())
			qual("call_arguments_inferred", "qualified", "argument lists inferred (no prototype); register arguments passed through unchanged may be missing: " + inferred, true, first_inf);
		if (!local.empty())
			qual("callee_abi_assumed", "qualified", "register effects of callees without a prototype follow the default ABI; interprocedural register allocation can differ: " + local, true, first_loc);
	}
	if (fd->numCalls() > 0)
		qual("unknown_call_semantics", "qualified", std::to_string(fd->numCalls()) + " call(s); callee effects are not modelled (only noreturn of listed imports)", false, 0);
	string level = "complete";
	for (Reason &q : reasons) {
		if (q.level == "unreliable") level = "unreliable";
		else if (level == "complete") level = "qualified";
	}

	/* ================= emit ================= */
	j.ks("status", "ok");
	j.ks("artifact_id", artifact);
	j.kobj("identity");
	j.ks("basis", basis);
	j.ks("rule", "artifact_id = fg2- + sha256(identity.basis); every hash is of the in-memory bytes actually analysed");
	j.end_obj();
	j.ks("source_kind", "static_analysis");

	j.kobj("qualification");
	j.ks("level", level);
	j.karr("reasons");
	for (Reason &q : reasons) {
		j.obj(); j.ks("code", q.code); j.ks("level", q.level); j.ks("detail", q.detail);
		if (q.has_addr) j.khx("addr", q.addr);
		j.end_obj();
	}
	j.end_arr();
	j.kobj("function_starts");
	j.ks("entry", "request");
	j.ks("size", r.size ? "request" : "none");
	j.ks("symbols", symbols_status);
	j.ks("function_map", !in.fmap ? "none" : fm_entry_size ? "used" : "supplied_unused");
	j.ks("imports", imports_status);
	j.end_obj();
	j.ks("call_effects", "unknown_callee_semantics");
	j.ks("note", "status=ok means an export was produced; it is not semantic verification");
	j.end_obj();

	j.kobj("image");
	j.ks("path", r.elf);
	j.ks("sha256", id.sha256);
	j.ki("size", id.file_size);
	if (id.build_id[0]) j.ks("gnu_build_id", id.build_id); else j.knull("gnu_build_id");
	j.ks("format", "elf64-little");
	j.ks("machine", "x86-64");
	j.ki("e_type", id.type);
	j.kb("has_symtab", id.has_symtab);
	j.kb("has_dynsym", id.has_dynsym);
	j.kb("has_debug_info", id.has_debug_info);
	j.ks("snapshot", "single read through one descriptor, fstat-stable before and after; path not reopened");
	j.ks("loader", "ghx SnapImage: PT_LOAD file bytes of the snapshot, zero memsz tail, nothing else; data reads never padded");
	j.karr("load_segments");
	for (unsigned k = 0; k < id.nload; k++) {
		j.obj();
		j.khx("vaddr", id.load[k].vaddr); j.khx("memsz", id.load[k].memsz);
		j.khx("offset", id.load[k].offset); j.khx("filesz", id.load[k].filesz);
		j.ks("flags", string(id.load[k].flags & 4 ? "r" : "-") + (id.load[k].flags & 2 ? "w" : "-") + (id.load[k].flags & 1 ? "x" : "-"));
		j.end_obj();
	}
	j.end_arr();
	j.ks("address_basis", "link-time virtual addresses from ELF program headers; no runtime load bias applied");
	j.end_obj();

	j.kobj("language");
	j.ks("id", r.lang);
	j.ks("compiler_spec", r.cspec);
	j.ks("processor", ld.getProcessor());
	j.ks("sla_file", ld.getSlaFile());
	j.ks("sla_sha256", sla->sha);
	j.ks("pspec_file", ld.getProcessorSpec());
	j.ks("pspec_sha256", psp->sha);
	j.ks("cspec_file", ld.getCompiler(r.cspec).getSpec());
	j.ks("cspec_sha256", csp->sha);
	j.ks("ldefs_sha256", ldefs_sha);
	j.ks("spec_set_sha256", spec_set_sha);
	j.ki("spec_files", (long long)specs.size());
	j.ks("spec_source", "worker-private snapshot taken at worker start; hashes are of the snapshot bytes");
	j.ks("prototype_model_default", glb->defaultfp ? glb->defaultfp->getName() : "");
	j.end_obj();

	j.karr("address_spaces");
	for (int4 i = 0; i < glb->numSpaces(); i++) {
		AddrSpace *s = glb->getSpace(i);
		if (!s) continue;
		j.obj();
		j.ki("index", s->getIndex());
		j.ks("name", s->getName());
		j.ks("type", spacetype_name(s->getType()));
		j.ki("addr_size", s->getAddrSize());
		j.ki("word_size", s->getWordSize());
		j.kb("big_endian", s->isBigEndian());
		j.kb("default_code", s == code);
		j.end_obj();
	}
	j.end_arr();

	/* function */
	const FuncProto &fp = fd->getFuncProto();
	j.kobj("function");
	j.khx("entry", r.entry);
	j.ks("name", fd->getName());
	j.ks("name_provenance", name_prov);
	j.kb("name_matches_request", name_matches_request);
	if (r.size) j.khx("declared_size", r.size); else j.knull("declared_size");
	j.ks("entry_provenance", "request");
	j.kobj("function_map");
	j.kb("supplied", in.fmap != NULL);
	j.kb("used", fm_entry_size > 0);	/* a record starts at the requested entry */
	if (fm_entry_size) j.khx("entry_size", fm_entry_size); else j.knull("entry_size");
	if (in.fmap) {
		j.ks("path", r.funcmap); j.ks("sha256", fm_sha);
		j.ki("records", fm_records); j.ki("entries_accepted", fm_accepted);
		j.ki("entries_added", fm_added); j.ki("entries_already_known", fm_present); j.ki("entries_rejected", 0);
	}
	j.end_obj();
	j.ks("bounds_provenance", r.size ? "request" : "none");
	j.ks("bounds_policy", r.size == 0 ? "unbounded_flow" : r.strict_bounds ? "strict" : "advisory");
	j.karr("instructions_outside_declared_bounds");
	if (r.size)
		for (auto &kv : insns)
			if (kv.first < r.entry || kv.first - r.entry >= r.size) j.s("insn:" + hexu(kv.first));
	j.end_arr();
	j.karr("instructions_crossing_declared_bounds");
	if (r.size)
		for (auto &kv : insns)
			if (kv.first >= r.entry && kv.first - r.entry < r.size && kv.second.len > 0 &&
			    (uintb)kv.second.len > r.size - (kv.first - r.entry))
				j.s("insn:" + hexu(kv.first));
	j.end_arr();
	j.ki("flow_size", fd->getSize());
	j.kb("has_unreachable_blocks", fd->hasUnreachableBlocks());
	j.kobj("prototype");
	j.ks("model", fp.getModelName());
	j.kb("input_locked", fp.isInputLocked());
	j.kb("output_locked", fp.isOutputLocked());
	j.kb("varargs", fp.isDotdotdot());
	j.ks("provenance", (fp.isInputLocked() || fp.isOutputLocked()) ? "locked" : "decompiler_inferred");
	j.karr("params");
	for (int4 i = 0; i < fp.numParams(); i++) {
		ProtoParameter *pp = fp.getParam(i);
		j.obj();
		j.ki("index", i);
		j.ks("name", pp->getName());
		j.ks("type", type_name(pp->getType()));
		j.ki("size", pp->getSize());
		Address a = pp->getAddress();
		j.ks("storage_space", a.getSpace() ? a.getSpace()->getName() : "");
		j.khx("storage_offset", a.getOffset());
		if (a.getSpace() && a.getSpace()->getType() == IPTR_PROCESSOR) {
			string rn = glb->translate->getRegisterName(a.getSpace(), a.getOffset(), pp->getSize());
			if (!rn.empty()) j.ks("register", rn);
		}
		j.kb("type_locked", pp->isTypeLocked());
		j.end_obj();
	}
	j.end_arr();
	{
		ProtoParameter *out = fp.getOutput();
		j.kobj("return");
		j.ks("type", type_name(out->getType()));
		j.ki("size", out->getSize());
		Address a = out->getAddress();
		if (a.getSpace() && !a.isInvalid()) {
			j.ks("storage_space", a.getSpace()->getName());
			j.khx("storage_offset", a.getOffset());
		}
		j.kb("type_locked", out->isTypeLocked());
		j.end_obj();
	}
	j.end_obj();
	j.karr("warnings");
	for (W &w : warns) { j.obj(); j.khx("addr", w.addr); j.kb("header", w.header); j.ks("text", w.text); j.end_obj(); }
	j.end_arr();
	j.end_obj();

	/* instructions + raw p-code */
	j.karr("instructions");
	for (auto &kv : insns) {
		Insn &in = kv.second;
		j.obj();
		j.ks("id", "insn:" + hexu(in.addr));
		j.khx("addr", in.addr);
		j.ki("length", in.len);
		j.ks("discovery", in.disc);
		j.ks("admission", in.refused.empty() ? (in.err ? "undecoded" : "admitted") : "refused");
		if (!in.refused.empty()) j.ks("refusal_reason", in.refused);
		if (in.err) { j.ks("error", in.errmsg); j.end_obj(); continue; }
		j.ks("bytes", in.bytes);
		j.ks("mnemonic", in.mnem);
		j.ks("operands", in.body);
		j.karr("raw_pcode");
		for (size_t k = 0; k < in.raw.size(); k++) {
			RawOp &ro = in.raw[k];
			j.obj();
			j.ks("id", "raw:" + hexu(in.addr) + ":" + std::to_string(k));
			j.ks("opcode", get_opname(ro.opc));
			j.key("out");
			if (ro.hasout) emit_vdata(j, glb, ro.out); else j.null();
			j.karr("in");
			for (size_t q = 0; q < ro.in.size(); q++)
				emit_vdata(j, glb, ro.in[q], q == 0 && (ro.opc == CPUI_LOAD || ro.opc == CPUI_STORE));
			j.end_arr();
			j.end_obj();
		}
		j.end_arr();
		j.karr("high_ops");
		for (const string &s : high_by_insn[in.addr]) j.s(s);
		j.end_arr();
		j.end_obj();
	}
	j.end_arr();

	j.kobj("instruction_admission");
	j.ks("rule", "an instruction is admitted only if every byte of [addr, addr+length) is a file byte of one PF_X PT_LOAD (and, with strict bounds, inside [entry, entry+size)); decoder prefetch padding is never evidence");
	j.karr("refused");
	for (auto &x : adm->refused) {
		j.obj(); j.khx("addr", x.first);
		if (x.second.length > 0) j.ki("length", x.second.length); else j.knull("length");
		j.ks("reason", x.second.reason); j.kb("on_flow_path", refused_in_flow.count(x.first) != 0);
		j.end_obj();
	}
	j.end_arr();
	j.end_obj();

	/* high p-code */
	j.kobj("high_pcode");
	j.ks("kind", "decompiler_final_ssa");
	j.ks("note", "alive ops after the full decompile action; op ids are PcodeOp creation times, varnode ids are Varnode creation indices; both are stable only within this artifact_id");
	j.ki("dead_ops_omitted", ndead);
	j.karr("ops");
	for (PcodeOp *op : ops) {
		j.obj();
		j.ks("id", opid(op));
		j.ks("space", op->getAddr().getSpace()->getName());
		j.khx("pc", op->getAddr().getOffset());
		j.ki("seq_order", op->getSeqNum().getOrder());
		j.ks("insn", op->getAddr().getSpace() == code ? "insn:" + hexu(op->getAddr().getOffset()) : "");
		j.ks("raw_link", "instruction_only");
		j.ks("block", op->getParent() ? "bb:" + std::to_string(op->getParent()->getIndex()) : "");
		j.ks("opcode", get_opname(op->code()));
		j.key("out");
		if (op->getOut()) j.s(vnid(op->getOut())); else j.null();
		j.karr("in");
		for (int4 i = 0; i < op->numInput(); i++) {
			Varnode *v = op->getIn(i);
			if (v) j.s(vnid(v)); else j.null();
		}
		j.end_arr();
		if (op->code() == CPUI_CBRANCH) j.kb("boolean_flip", op->isBooleanFlip());
		j.end_obj();
	}
	j.end_arr();
	j.karr("varnodes");
	for (Varnode *vn : vns) {
		j.obj();
		j.ks("id", vnid(vn));
		AddrSpace *sp = vn->getSpace();
		j.ks("space", sp->getName());
		/* never export host pointers: space-id constants, iop and fspec
		 * varnodes encode C++ object addresses in their offset */
		bool spaceid = false;
		if (vn->isConstant())
			for (auto it = vn->beginDescend(); it != vn->endDescend(); ++it) {
				PcodeOp *u = *it;
				if ((u->code() == CPUI_LOAD || u->code() == CPUI_STORE) && u->getIn(0) == vn) spaceid = true;
			}
		if (spaceid) {
			AddrSpace *rs = vn->getSpaceFromConst();
			j.khx("offset", rs ? (uintb)rs->getIndex() : 0);
			j.ks("space_ref", rs ? rs->getName() : "");
			j.ks("offset_encoding", "space_index");
		} else if (sp->getType() == IPTR_IOP || sp->getType() == IPTR_FSPEC) {
			j.khx("offset", 0);
			j.ks("offset_encoding", "reference_elided");
		} else
			j.khx("offset", vn->getOffset());
		j.ki("size", vn->getSize());
		if (sp->getType() == IPTR_PROCESSOR) {
			string rn = glb->translate->getRegisterName(sp, vn->getOffset(), vn->getSize());
			if (!rn.empty()) j.ks("register", rn);
		}
		if (sp->getType() == IPTR_SPACEBASE)
			j.ks("signed_offset", std::to_string((long long)sign_extend(vn->getOffset(), sp->getAddrSize() * 8 - 1)));
		if (sp->getType() == IPTR_IOP) {
			PcodeOp *rop = PcodeOp::getOpFromConst(vn->getAddr());
			j.ks("ref_op", rop ? opid(rop) : "");
		}
		if (sp->getType() == IPTR_FSPEC) {
			FuncCallSpecs *fc = FuncCallSpecs::getFspecFromConst(vn->getAddr());
			j.ks("ref_call", fc && fc->getOp() ? opid(fc->getOp()) : "");
		}
		j.karr("flags");
		if (vn->isConstant()) j.s("constant");
		if (vn->isInput()) j.s("input");
		if (vn->isWritten()) j.s("written");
		if (vn->isFree()) j.s("free");
		if (vn->isAddrTied()) j.s("addrtied");
		if (vn->isPersist()) j.s("persist");
		if (vn->isAnnotation()) j.s("annotation");
		if (vn->isImplied()) j.s("implied");
		if (vn->isExplicit()) j.s("explicit");
		if (vn->isSpacebase()) j.s("spacebase");
		j.end_arr();
		j.key("def");
		if (vn->getDef()) j.s(opid(vn->getDef())); else j.null();
		j.karr("uses");
		std::vector<long long> u;
		for (auto it = vn->beginDescend(); it != vn->endDescend(); ++it) u.push_back((*it)->getTime());
		std::sort(u.begin(), u.end());
		for (long long t : u) j.s("op:" + std::to_string(t));
		j.end_arr();
		HighVariable *h = 0;
		if (!vn->isAnnotation()) { try { h = vn->getHigh(); } catch (LowlevelError &) { h = 0; } }
		j.key("high");
		if (h) j.s(hvid[h]); else j.null();
		j.ks("type", type_name(vn->getType()));
		j.end_obj();
	}
	j.end_arr();
	j.end_obj();

	/* blocks */
	const BlockGraph &bg = fd->getBasicBlocks();
	j.karr("blocks");
	for (int4 i = 0; i < bg.getSize(); i++) {
		const BlockBasic *bb = (const BlockBasic *)bg.getBlock(i);
		j.obj();
		j.ks("id", "bb:" + std::to_string(bb->getIndex()));
		j.khx("start", bb->getStart().getOffset());
		j.khx("stop", bb->getStop().getOffset());
		j.karr("ops");
		const PcodeOp *lastop = 0;
		for (auto it = bb->beginOp(); it != bb->endOp(); ++it) { j.s(opid(*it)); lastop = *it; }
		j.end_arr();
		j.karr("succ");
		for (int4 k = 0; k < bb->sizeOut(); k++) {
			j.obj();
			j.ks("to", "bb:" + std::to_string(bb->getOut(k)->getIndex()));
			j.ki("slot", k);
			string kind = "flow";
			if (lastop && lastop->code() == CPUI_CBRANCH && bb->sizeOut() == 2) kind = k == 0 ? "false_out" : "true_out";
			else if (lastop && lastop->code() == CPUI_BRANCHIND) kind = "switch";
			else if (bb->sizeOut() == 1) kind = "unconditional";
			j.ks("kind", kind);
			j.karr("flags");
			if (bb->isBackEdgeOut(k)) j.s("back_edge");
			if (bb->isGotoOut(k)) j.s("goto");
			if (bb->isIrreducibleOut(k)) j.s("irreducible");
			j.end_arr();
			j.end_obj();
		}
		j.end_arr();
		j.karr("pred");
		for (int4 k = 0; k < bb->sizeIn(); k++) j.s("bb:" + std::to_string(bb->getIn(k)->getIndex()));
		j.end_arr();
		j.end_obj();
	}
	j.end_arr();

	/* calls */
	j.karr("calls");
	for (int4 i = 0; i < fd->numCalls(); i++) {
		FuncCallSpecs *fc = fd->getCallSpecs(i);
		PcodeOp *op = fc->getOp();
		j.obj();
		j.ks("op", op ? opid(op) : "");
		j.khx("pc", op ? op->getAddr().getOffset() : 0);
		bool indirect = op && op->code() == CPUI_CALLIND;
		j.ks("kind", indirect ? "indirect" : "direct");
		Address ea = fc->getEntryAddress();
		if (ea.isInvalid()) { j.knull("target"); j.ks("target_status", "unresolved"); }
		else {
			j.khx("target", ea.getOffset());
			j.ks("target_status", indirect ? "resolved_by_decompiler" : "direct");
		}
		j.ks("prototype", fc->isInputLocked() ? "locked(ghx-prototypes-v1)" : "inferred");
		j.ki("argument_count", fc->numParams());
		if (fc->getName().empty()) j.knull("target_name");
		else {
			j.ks("target_name", fc->getName());
			Funcdata *tf = ea.isInvalid() ? 0 : gs->queryFunction(ea);
			j.ks("target_name_provenance", !tf ? "decompiler" : fm_set.count(ea.getOffset()) ? "request_function_map" :
			     import_set.count(ea.getOffset()) ? "plt_relocation" : r.symbols ? "loader_symbol(symtab)" : "decompiler");
		}
		j.end_obj();
	}
	j.end_arr();

	/* jump tables */
	j.karr("jump_tables");
	for (int4 i = 0; i < fd->numJumpTables(); i++) {
		JumpTable *jt = fd->getJumpTable(i);
		j.obj();
		j.khx("pc", jt->getOpAddress().getOffset());
		j.ks("op", jt->getIndirectOp() ? opid(jt->getIndirectOp()) : "");
		j.karr("targets");
		for (int4 k = 0; k < jt->numEntries(); k++) j.hx(jt->getAddressByIndex(k).getOffset());
		j.end_arr();
		j.end_obj();
	}
	j.end_arr();

	/* high variables */
	j.karr("high_variables");
	std::sort(hvs.begin(), hvs.end(), [&](HighVariable *a, HighVariable *b) { return hvid[a] < hvid[b]; });
	for (HighVariable *h : hvs) {
		j.obj();
		j.ks("id", hvid[h]);
		Symbol *sym = 0;
		try { sym = h->getSymbol(); } catch (LowlevelError &) { sym = 0; }
		j.ks("type", type_name(h->getType()));
		string cls = "local";
		if (h->isConstant()) cls = "constant";
		else if (sym && sym->getCategory() == Symbol::function_parameter) cls = "parameter";
		else if (h->isPersist()) cls = "global";
		else if (!sym) cls = "unnamed_temporary";
		j.ks("class", cls);
		if (sym) {
			j.kobj("symbol");
			j.ks("id", hexu(sym->getId()));
			j.ks("name", sym->getName());
			j.ks("scope", sym->getScope() ? sym->getScope()->getName() : "");
			j.ki("category", sym->getCategory());
			j.ks("provenance", sym->isNameLocked() ? "locked" : "decompiler_generated");
			j.end_obj();
		} else j.knull("symbol");
		j.karr("instances");
		std::vector<long long> ix;
		for (int4 k = 0; k < h->numInstances(); k++) ix.push_back(h->getInstance(k)->getCreateIndex());
		std::sort(ix.begin(), ix.end());
		for (long long x : ix) j.s("vn:" + std::to_string(x));
		j.end_arr();
		j.end_obj();
	}
	j.end_arr();

	/* pseudocode */
	j.kobj("pseudocode");
	j.ks("language", "c");
	j.ks("printer", "ghidra PrintC (EmitMarkup)");
	j.ks("text", ps.str());
	j.ki("tokens_unaligned", tok_unaligned);
	j.ks("position_basis", "line is 1-based, col is 0-based byte offset, both in pseudocode.text");
	j.ks("token_status", tok_status);
	j.ks("address_map_status", "partial: tokens carry an op only when the printer attached one; syntax tokens have none");
	j.karr("tokens");
	for (size_t k = 0; k < toks.size(); k++) {
		Tok &t = toks[k];
		j.obj();
		j.ki("i", k);
		j.ki("line", t.line);
		j.ki("col", t.col);
		j.ks("kind", t.kind);
		j.ks("text", t.text);
		if (t.opref >= 0) {
			auto it = op_by_time.find(t.opref);
			if (it != op_by_time.end()) { j.ks("op", "op:" + std::to_string(t.opref)); j.khx("pc", it->second->getAddr().getOffset()); }
			else j.ks("op_unresolved", "op:" + std::to_string(t.opref));
		}
		if (t.varref >= 0) {
			if (vn_by_idx.count(t.varref)) j.ks("var", "vn:" + std::to_string(t.varref));
			else j.ks("var_unresolved", "vn:" + std::to_string(t.varref));
		}
		if (t.blockref >= 0) j.ki("struct_block", t.blockref);
		if (t.color >= 0) j.ki("color", t.color);
		if (!t.symref.empty()) j.ks("symbol", t.symref);
		j.end_obj();
	}
	j.end_arr();
	j.end_obj();

	j.kobj("source_lines");
	j.ks("status", "unavailable");
	j.ks("reason", "native worker has no DWARF line reader; image has_debug_info is reported but not consumed");
	j.end_obj();

	j.karr("unresolved_relationships");
	j.s("high_op_to_raw_op: only instruction-level (pc) link; decompiler transforms do not preserve raw op index");
	j.s("pseudocode_struct_block: printer block refs index structured blocks, not basic blocks");
	j.s("types: no DWARF/type database; all non-primitive types are decompiler inferred");
	j.end_arr();

	j.kobj("timing");
	j.ki("arch_init_us", (long long)((t_init - t0) * 1000));
	j.ki("decompile_us", (long long)((t_dec - t_init) * 1000));
	j.ki("export_us", (long long)((now_ms() - t_dec) * 1000));
	j.ki("worker_peak_rss_kb", peak_rss_kb());
	j.end_obj();
	string e = errs.str();
	if (e.size() > 4096) e = e.substr(0, 4096) + "...[truncated]";
	j.ks("decompiler_messages", e);

	j.karr("tail_calls");
	for (auto &tc : tailcalls) {
		j.obj(); j.khx("pc", tc.first); j.khx("target", tc.second);
		j.ks("provenance", "jmp_to_known_function_start(callreturn_override)");
		j.end_obj();
	}
	j.end_arr();
	j.karr("imports");
	for (Import &im : imports) {
		j.obj();
		j.ks("name", im.name);
		j.khx("stub", im.stub);
		j.khx("got", im.got);
		j.ks("section", im.section);
		j.ks("provenance", "plt_relocation");
		j.kb("function_added", im.added);
		j.kb("noreturn", im.noreturn);
		j.kb("prototype", im.prototype);
		if (im.noreturn) j.ks("noreturn_provenance", "ghx-noreturn-v1");
		j.end_obj();
	}
	j.end_arr();
	j.kobj("import_policy");
	j.ks("status", imports_status);
	j.ks("noreturn_table", "ghx-noreturn-v1");
	j.ks("noreturn_table_sha256", sha_hex(NORETURN_TABLE));
	j.ks("prototype_table", "ghx-prototypes-v1");
	j.ks("prototype_table_sha256", sha_hex(PROTOTYPE_TABLE));
	j.ks("prototypes", "listed imports get locked C prototypes; other callees are inferred by the decompiler");
	j.end_obj();
}

static bool poisoned = false;
static void read_hook(void *a) { barrier(*(const string *)a, "elf-mid-read"); }

static string handle(const string &line, string &reqid, bool &ok)
{
	Req r;
	J j;
	ok = false;
	double t0 = now_ms();
	j.obj();
	j.ks("schema", SCHEMA);
	j.ks("schema_version", SCHEMA_VERSION);
	j.ks("contract", "C01-R5 CONTRACT.v5");
	j.kobj("producer");
	j.ks("kind", "ghidra_native_decompiler");
	j.ks("worker", "ghx_worker");
	j.ks("worker_version", WORKER_VERSION);
	j.ks("worker_sha256", self_sha);
	j.ks("ghidra_commit", GHIDRA_COMMIT);
	j.ks("ghidra_version", GHIDRA_VERSION);
	j.kb("java", false);
	j.ks("spec_snapshot_dir", snapdir);
	j.end_obj();
	string perr = parse_req(line, r);
	reqid = r.id.empty() ? "-" : r.id;
	if (!perr.empty()) {
		j.ks("status", "error");
		j.kobj("error"); j.ks("code", "bad_request"); j.ks("message", perr); j.end_obj();
		j.end_obj();
		return j.o;
	}
	j.kobj("request");
	j.ks("id", r.id); j.ks("elf", r.elf); j.khx("entry", r.entry);
	if (r.size) j.khx("size", r.size); else j.knull("size");
	j.ks("name", r.name); j.ks("lang", r.lang); j.ks("cspec", r.cspec); j.kb("symbols", r.symbols);
	j.kb("imports", r.imports); j.ks("bounds", r.strict_bounds ? "strict" : "advisory");
	if (r.funcmap.empty()) j.knull("function_map"); else j.ks("function_map", r.funcmap);
	j.end_obj();
	size_t mark = j.o.size();
	std::vector<bool> fmark = j.first;
	auto fail = [&](const string &code, const string &msg, const char *sha) {
		j.o.resize(mark); j.first = fmark; j.keyed = false;
		j.ks("status", "error");
		j.kobj("error"); j.ks("code", code); j.ks("message", msg);
		if (sha) j.ks("image_sha256", sha);
		j.end_obj();
		j.end_obj();
		return j.o;
	};
	if (!spec_error.empty()) return fail("spec_snapshot", spec_error, NULL);
	if (r.test_sleep_ms > 0) usleep(r.test_sleep_ms * 1000);
	if (r.test_crash) abort();
	if (r.test_alloc_mb > 0) {
		size_t n = (size_t)r.test_alloc_mb << 20;
		/* volatile: the compiler must not elide the allocation */
		char *volatile p = (char *)malloc(n);
		if (!p) return fail("out_of_memory", "test allocation of " + std::to_string(r.test_alloc_mb) + " MiB failed", NULL);
		for (size_t k = 0; k < n; k += 4096) ((volatile char *)p)[k] = 1;
		free(p);
	}

	static const char *codes[] = { "", "io_error", "malformed_elf", "unsupported_image", "input_too_large", "input_unstable" };
	ghx_snapshot elf, fm;
	char ebuf[256] = "";
	int erc = ghx_snapshot_read(r.elf.c_str(), MAX_ELF_BYTES, &elf, ebuf, sizeof ebuf,
				    r.test_read_barrier.empty() ? NULL : read_hook, &r.test_read_barrier);
	if (erc != 0) return fail(codes[erc], ebuf, NULL);
	ghx_elfid id;
	erc = ghx_elfid_parse(elf.bytes, elf.size, elf.sha256, &id, ebuf, sizeof ebuf);
	if (erc != 0) { string o = fail(codes[erc], ebuf, elf.sha256); ghx_snapshot_free(&elf); return o; }
	bool have_fm = false;
	if (!r.funcmap.empty()) {
		erc = ghx_snapshot_read(r.funcmap.c_str(), MAX_MAP_BYTES, &fm, ebuf, sizeof ebuf, NULL, NULL);
		if (erc != 0) {
			string o = fail(erc == 5 ? "input_unstable" : erc == 4 ? "input_too_large" : "function_map",
					string("function_map: ") + ebuf, elf.sha256);
			ghx_snapshot_free(&elf);
			return o;
		}
		have_fm = true;
	}
	if (!r.test_barrier.empty()) barrier(r.test_barrier, elf.sha256);
	Inputs in{ &elf, &id, have_fm ? &fm : NULL };
	std::ostringstream errs;
	try {
		decompile_export(r, j, in, t0, errs);
		ok = true;
		j.end_obj();
	} catch (Fail &f) {
		fail(f.code, f.msg, elf.sha256);
	} catch (LowlevelError &e) {
		fail("decompiler_error", e.explain, elf.sha256);
	} catch (DecoderError &e) {
		fail("decoder_error", e.explain, elf.sha256);
	} catch (std::bad_alloc &) {
		fail("out_of_memory", "allocation failed", elf.sha256);
	}
	string image_sha = elf.sha256;
	ghx_snapshot_free(&elf);
	if (have_fm) ghx_snapshot_free(&fm);
	string verr = verify_specs();
	if (!verr.empty()) {
		poisoned = true;
		ok = false;
		return fail("spec_snapshot_modified", "private specification snapshot changed during the request (" + verr + "); worker exits", image_sha.c_str());
	}
	if ((long long)j.o.size() > r.max_out) {
		J e;
		e.obj(); e.ks("schema", SCHEMA); e.ks("schema_version", SCHEMA_VERSION); e.ks("status", "error");
		e.kobj("request"); e.ks("id", r.id); e.end_obj();
		e.kobj("error"); e.ks("code", "output_limit");
		e.ks("message", "export of " + std::to_string(j.o.size()) + " bytes exceeds max_out " + std::to_string(r.max_out));
		e.end_obj(); e.end_obj();
		ok = false;
		return e.o;
	}
	return j.o;
}

int main(int argc, char **argv)
{
	string src, spec_barrier;
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--sleighhome") && i + 1 < argc) src = argv[++i];
		else if (!strcmp(argv[i], "--spec-snapshot") && i + 1 < argc) snapdir = argv[++i];
		else if (!strcmp(argv[i], "--test-hooks")) test_hooks = true;
		else if (!strcmp(argv[i], "--test-spec-barrier") && i + 1 < argc) spec_barrier = argv[++i];
		else {
			fprintf(stderr, "usage: ghx_worker --sleighhome DIR [--spec-snapshot EMPTYDIR] [--test-hooks [--test-spec-barrier PATH]]\n");
			return 2;
		}
	}
	if (src.empty()) { fprintf(stderr, "ghx_worker: --sleighhome required\n"); return 2; }
	if (!spec_barrier.empty() && !test_hooks) { fprintf(stderr, "ghx_worker: --test-spec-barrier needs --test-hooks\n"); return 2; }
	{
		char h[65];
		self_sha = ghx_sha256_file("/proc/self/exe", h) == 0 ? h : "";
	}
	if (snapdir.empty()) {
		const char *t = getenv("TMPDIR");
		string tmpl = string(t && *t ? t : "/tmp") + "/ghx-spec-XXXXXX";
		std::vector<char> buf(tmpl.begin(), tmpl.end());
		buf.push_back(0);
		if (!mkdtemp(buf.data())) spec_error = "cannot create private snapshot directory";
		else { snapdir = buf.data(); snapdir_owned = true; chmod(snapdir.c_str(), 0700); }
	} else {
		struct stat st;
		while (snapdir.size() > 1 && snapdir.back() == '/') snapdir.pop_back();
		if (lstat(snapdir.c_str(), &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != geteuid() ||
		    !list_dir(snapdir, true).empty() || !list_dir(snapdir, false).empty())
			spec_error = "--spec-snapshot must be an existing empty directory owned by this user";
	}
	if (spec_error.empty()) spec_error = snapshot_specs(src, snapdir);
	if (!spec_barrier.empty()) barrier(spec_barrier, snapdir);
	signal(SIGPIPE, SIG_DFL);
	if (spec_error.empty()) startDecompilerLibrary(snapdir.c_str());
	string line;
	while (std::getline(std::cin, line)) {
		if (line.size() > 8192) { std::cout << "RESULT\tid=-\tstatus=error\tbytes=0\n" << std::flush; continue; }
		if (line == "QUIT") break;
		if (line == "PING") { std::cout << "PONG\n" << std::flush; continue; }
		if (line.compare(0, 10, "DECOMPILE\t") != 0) { std::cout << "RESULT\tid=-\tstatus=error\tbytes=0\n" << std::flush; continue; }
		string rid;
		bool ok;
		string out = handle(line, rid, ok);
		std::cout << "RESULT\tid=" << rid << "\tstatus=" << (ok ? "ok" : "error") << "\tbytes=" << out.size() << "\n";
		std::cout.write(out.data(), out.size());
		std::cout << std::flush;
		if (poisoned) break;
	}
	if (spec_error.empty()) shutdownDecompilerLibrary();
	if (snapdir_owned) remove_tree(snapdir);
	return poisoned ? 3 : 0;
}
