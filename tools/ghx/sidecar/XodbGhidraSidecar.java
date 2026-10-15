// Persistent Ghidra producer for xodb (GPLv3). Ghidra is an optional Apache-2.0 dependency.
import java.io.*;
import java.lang.management.ManagementFactory;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.*;
import java.nio.channels.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.BasicFileAttributes;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

import com.google.gson.*;
import com.sun.security.auth.module.UnixSystem;
import ghidra.GhidraApplicationLayout;
import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.decompiler.*;
import ghidra.app.plugin.core.analysis.AutoAnalysisManager;
import ghidra.app.plugin.core.analysis.PdbUniversalAnalyzer;
import ghidra.app.decompiler.component.DecompilerUtils;
import ghidra.app.util.bin.ByteProvider;
import ghidra.app.util.bin.FileByteProvider;
import ghidra.app.util.bin.format.elf.ElfException;
import ghidra.app.util.bin.format.elf.ElfHeader;
import ghidra.app.util.importer.ProgramLoader;
import ghidra.app.util.opinion.ElfLoader;
import ghidra.app.util.opinion.LoadResults;
import ghidra.base.project.GhidraProject;
import ghidra.framework.Application;
import ghidra.framework.HeadlessGhidraApplicationConfiguration;
import ghidra.framework.model.DomainFile;
import ghidra.framework.options.Options;
import ghidra.program.database.ProgramDB;
import ghidra.program.model.address.*;
import ghidra.program.model.data.*;
import ghidra.program.model.lang.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.MemoryAccessException;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.pcode.*;
import ghidra.program.model.symbol.*;
import ghidra.program.util.DefaultLanguageService;
import ghidra.util.task.TaskMonitor;
import ghidra.util.task.TaskMonitorAdapter;

public final class XodbGhidraSidecar {
    static final int PROTOCOL = 1;
    static final int SCHEMA = 1;
    static final String PRODUCER = "ghidra-jvm-sidecar-0.1.6";
    static final Gson JSON = new GsonBuilder().disableHtmlEscaping().serializeNulls().create();
    static final int MAX_LINE = 1 << 20;
    static final int MAX_PAYLOAD = 64 << 20;

    final Path socketPath;
    final Path cacheDir;
    final Path logPath;
    final long uid = new UnixSystem().getUid();
    final AtomicBoolean stopping = new AtomicBoolean(false);
    final AtomicInteger connectedClients = new AtomicInteger();
    final AtomicLong lastRequestNanos = new AtomicLong(System.nanoTime());
    final ExecutorService clients = Executors.newCachedThreadPool();
    // Priming uses an isolated in-memory ProgramDB.  Keep it off the single
    // project worker: loading a language is not TaskMonitor-aware and can hold
    // that worker for hundreds of milliseconds after cancellation.
    final ExecutorService primes = Executors.newSingleThreadExecutor();
    final ThreadPoolExecutor ghidra = new ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS, new PriorityBlockingQueue<>());
    final ScheduledExecutorService lifetime = Executors.newSingleThreadScheduledExecutor();
    final ConcurrentMap<String, Work> jobs = new ConcurrentHashMap<>();
    final ConcurrentMap<String, Image> images = new ConcurrentHashMap<>();
    final ConcurrentMap<String, byte[]> documents = new ConcurrentHashMap<>();
    // Only the single Ghidra worker touches this access-ordered pool.
    final LinkedHashMap<String, OpenProgram> openPrograms = new LinkedHashMap<>(16, .75f, true);
    final AtomicLong taskSequence = new AtomicLong();
    final AtomicLong workSequence = new AtomicLong();
    final AtomicReference<Work> runningBackground = new AtomicReference<>();
    final AtomicInteger openProgramCount = new AtomicInteger();
    final AtomicLong projectCacheBytes = new AtomicLong();
    final HashMap<String, Long> imageLastUsed = new HashMap<>();
    final int maxImages = envInt("XODB_GHIDRA_MAX_IMAGES", 64, 1, 4096);
    final int maxDocuments = envInt("XODB_GHIDRA_MAX_DOCUMENTS", 1024, 1, 65536);
    final int maxOpenPrograms = envInt("XODB_GHIDRA_MAX_OPEN_PROGRAMS", 8, 1, 64);
    final long maxCacheBytes = envLong("XODB_GHIDRA_CACHE_BYTES", 2L << 30, 64L << 20, 1L << 40);
    final double idleMinutes = envDouble("XODB_GHIDRA_IDLE", 30.0, 0.0, 10080.0);
    final long idleNanos = idleMinutes == 0 ? 0 : Math.max(1, (long)(idleMinutes * 60.0 * 1_000_000_000.0));
    final GhidraProject project;
    ServerSocketChannel listener;
    Object boundSocketKey;
    volatile String stopReason = "running";

    static final class Image {
        final String key;
        final String sha;
        final String path;
        final String debugPath;
        final String debugSha;
        volatile String state = "pending";
        volatile String progress = "queued";
        volatile String code;
        volatile String detail;
        // Imported ahead of any request; may not take the slots kept for requests.
        volatile boolean background;
        Image(String key, String sha, String path, String debugPath, String debugSha) {
            this.key = key; this.sha = sha; this.path = path;
            this.debugPath = debugPath; this.debugSha = debugSha;
        }
    }
    static final class Work {
        final String id;
        final TaskMonitorAdapter monitor = new TaskMonitorAdapter(true);
        volatile String state = "pending";
        volatile String progress = "queued";
        volatile String code;
        volatile String detail;
        volatile byte[] payload;
        volatile Future<?> future;
        volatile boolean background;
        Work(String id) { this.id = id; }
    }
    static final class PrioritizedTask extends FutureTask<Void> implements Comparable<PrioritizedTask> {
        final int priority;
        final long sequence;
        PrioritizedTask(Runnable run, int priority, long sequence) { super(run, null); this.priority = priority; this.sequence = sequence; }
        public int compareTo(PrioritizedTask other) {
            int order = Integer.compare(priority, other.priority);
            return order != 0 ? order : Long.compare(sequence, other.sequence);
        }
    }
    static final class OpenProgram {
        final String sha;
        final Program program;
        final DecompInterface decompiler;
        long lastUsedNanos = System.nanoTime();
        OpenProgram(String sha, Program program, DecompInterface decompiler) { this.sha = sha; this.program = program; this.decompiler = decompiler; }
    }

    Work makeWork(String key) {
        return new Work(key + ":" + workSequence.getAndIncrement());
    }

    Work findWork(String id) {
        for (Work work : jobs.values()) if (work.id.equals(id)) return work;
        return null;
    }

    Future<?> submitGhidra(Work work, boolean background, Runnable action) {
        work.background = background;
        PrioritizedTask task = new PrioritizedTask(() -> {
            if (background) runningBackground.set(work);
            try { action.run(); }
            finally { if (background) runningBackground.compareAndSet(work, null); }
        }, background ? 10 : 0, taskSequence.getAndIncrement());
        ghidra.execute(task);
        return task;
    }

    void preemptBackground() {
        Work work = runningBackground.get();
        if (work == null || !work.state.equals("pending")) return;
        work.monitor.cancel();
        Future<?> future = work.future;
        if (future != null) future.cancel(true);
    }

    XodbGhidraSidecar(Path socketPath, Path cacheDir, Path logPath) throws Exception {
        this.socketPath = socketPath;
        this.cacheDir = cacheDir;
        this.logPath = logPath;
        Files.createDirectories(cacheDir);
        Application.initializeApplication(new GhidraApplicationLayout(), new HeadlessGhidraApplicationConfiguration());
        Path parent = cacheDir.resolve("project");
        Files.createDirectories(parent);
        String name = "xodb";
        this.project = Files.exists(parent.resolve(name + ".gpr"))
            ? GhidraProject.openProject(parent.toString(), name, true)
            : GhidraProject.createProject(parent.toString(), name, false);
        projectCacheBytes.set(cacheUsage());
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 3) {
            System.err.println("usage: XodbGhidraSidecar SOCKET CACHE_DIR LOG_PATH");
            System.exit(2);
        }
        XodbGhidraSidecar server = new XodbGhidraSidecar(Paths.get(args[0]), Paths.get(args[1]), Paths.get(args[2]));
        server.run();
    }

    void run() throws Exception {
        Files.createDirectories(socketPath.getParent());
        listener = ServerSocketChannel.open(StandardProtocolFamily.UNIX);
        listener.bind(UnixDomainSocketAddress.of(socketPath));
        Files.setPosixFilePermissions(socketPath, PosixFilePermissions.fromString("rw-------"));
        boundSocketKey = socketKey();
        lastRequestNanos.set(System.nanoTime());
        long pollSeconds = Math.max(1, Math.min(60, idleNanos == 0 ? 60 : TimeUnit.NANOSECONDS.toSeconds(idleNanos)));
        lifetime.scheduleWithFixedDelay(this::checkLifetime, pollSeconds, pollSeconds, TimeUnit.SECONDS);
        try {
            while (!stopping.get()) {
                SocketChannel channel;
                try { channel = listener.accept(); }
                catch (AsynchronousCloseException e) { break; }
                connectedClients.incrementAndGet();
                try { clients.submit(() -> serve(channel)); }
                catch (RejectedExecutionException e) {
                    connectedClients.decrementAndGet();
                    try { channel.close(); } catch (Exception ignored) {}
                    if (!stopping.get()) throw e;
                }
            }
        } finally {
            stopping.set(true);
            try { listener.close(); } catch (Exception ignored) {}
            lifetime.shutdownNow();
            clients.shutdownNow();
            primes.shutdownNow();
            ghidra.shutdownNow();
            for (Work work : jobs.values()) work.monitor.cancel();
            try { primes.awaitTermination(5, TimeUnit.SECONDS); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            try { ghidra.awaitTermination(5, TimeUnit.SECONDS); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            closeOpenPrograms();
            project.close();
            // Ghidra's helper children (the demangler) must not outlive the sidecar.
            for (ProcessHandle child : ProcessHandle.current().children().toList()) {
                child.destroyForcibly();
                try { child.onExit().get(2, TimeUnit.SECONDS); } catch (Exception ignored) {}
            }
            try { if (ownsEndpoint()) Files.deleteIfExists(socketPath); } catch (Exception ignored) {}
        }
    }

    Object socketKey() throws IOException {
        return Files.readAttributes(socketPath, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS).fileKey();
    }

    boolean ownsEndpoint() {
        try {
            if (!Files.exists(socketPath, LinkOption.NOFOLLOW_LINKS)) return false;
            Object current = socketKey();
            return boundSocketKey == null ? current == null : boundSocketKey.equals(current);
        } catch (Exception ignored) { return false; }
    }

    void requestStop(String reason) {
        if (!stopping.compareAndSet(false, true)) return;
        stopReason = reason;
        System.err.println("lifetime: stopping: " + reason);
        try { listener.close(); } catch (Exception ignored) {}
    }

    void checkLifetime() {
        try {
            if (stopping.get()) return;
            if (!ownsEndpoint()) { requestStop("endpoint_replaced"); return; }
            if (idleNanos != 0 && connectedClients.get() == 0 && System.nanoTime() - lastRequestNanos.get() >= idleNanos)
                requestStop("idle");
        } catch (Throwable error) {
            System.err.println("lifetime: " + error);
        }
    }

    void serve(SocketChannel channel) {
        try (channel) {
            InputStream in = Channels.newInputStream(channel);
            OutputStream out = Channels.newOutputStream(channel);
            while (!stopping.get()) {
                String line = readLine(in);
                if (line == null) break;
                JsonObject request;
                try { request = JsonParser.parseString(line).getAsJsonObject(); }
                catch (Exception e) { sendFailure(out, "?", "bad_json", e.getMessage()); continue; }
                try { handle(request, out); }
                catch (Failure e) { sendFailure(out, text(request, "id", "?"), e.code, e.getMessage()); }
                catch (Exception e) { sendFailure(out, text(request, "id", "?"), "request_failed", e.getMessage()); }
                // A hello is a probe, not use: `scripts/ghidra-sidecar status` sends one
                // first, and counting it would make every status print an idle time of zero.
                finally { if (!text(request, "verb", "").equals("hello")) lastRequestNanos.set(System.nanoTime()); }
            }
        } catch (Exception e) {
            if (!stopping.get()) System.err.println("client: " + e);
        } finally { connectedClients.decrementAndGet(); }
    }

    void handle(JsonObject request, OutputStream out) throws Exception {
        String id = text(request, "id", "?");
        String verb = text(request, "verb", "");
        switch (verb) {
            case "hello" -> hello(out, id);
            case "status" -> status(out, id, text(request, "job", null));
            case "prime" -> prime(request, out, id);
            case "open_image" -> openImage(request, out, id);
            case "decompile" -> decompile(request, out, id);
            case "cancel" -> cancel(out, id, text(request, "job", ""));
            case "shutdown" -> shutdown(out, id);
            case "hints" -> sendFailure(out, id, "reserved", "runtime hints are reserved for a later schema");
            default -> sendFailure(out, id, "unknown_verb", verb);
        }
    }

    void hello(OutputStream out, String id) throws Exception {
        JsonObject r = base(id, "ready");
        r.addProperty("protocol", PROTOCOL);
        r.addProperty("schema", SCHEMA);
        r.addProperty("producer", PRODUCER);
        r.addProperty("ghidra", Application.getApplicationVersion());
        r.addProperty("uid", uid);
        r.addProperty("healthy", !stopping.get());
        r.addProperty("log", logPath.toString());
        JsonArray caps = new JsonArray();
        for (String c : new String[]{"prime", "open_image", "decompile", "cancel", "status", "shutdown", "hints_reserved", "xsg", "pseudocode", "variables", "types", "function_index"}) caps.add(c);
        r.add("capabilities", caps);
        send(out, r, null);
    }

    void prime(JsonObject q, OutputStream out, String id) throws Exception {
        String architecture = required(q, "architecture");
        String jobId = "prime:" + architecture;
        Work work = jobs.computeIfAbsent(jobId, key -> {
            Work made = makeWork(key);
            made.background = true;
            made.future = primes.submit(() -> primeArchitecture(architecture, made));
            return made;
        });
        sendWork(out, id, work);
    }

    void primeArchitecture(String architecture, Work work) {
        ProgramDB program = null;
        Object consumer = new Object();
        try {
            work.progress = "loading language";
            work.monitor.checkCanceled();
            PrimeSpec spec = PrimeSpec.forArchitecture(architecture);
            Language language = DefaultLanguageService.getLanguageService().getLanguage(new LanguageID(spec.language));
            work.monitor.checkCanceled();
            CompilerSpec compiler = language.getCompilerSpecByID(new CompilerSpecID(spec.compiler));
            program = new ProgramDB("xodb-prime-" + architecture, language, compiler, consumer);
            work.monitor.checkCanceled();
            int transaction = program.startTransaction("prime decompiler");
            Function function;
            try {
                Address start = program.getAddressFactory().getDefaultAddressSpace().getAddress(0x1000);
                MemoryBlock block = program.getMemory().createInitializedBlock("text", start, spec.code.length, (byte)0, work.monitor, false);
                block.setRead(true); block.setExecute(true);
                program.getMemory().setBytes(start, spec.code);
                DisassembleCommand disassemble = new DisassembleCommand(start, new AddressSet(start, start.add(spec.code.length - 1)), true);
                disassemble.enableCodeAnalysis(false);
                if (!disassemble.applyTo(program, work.monitor)) throw new Failure("prime_disassembly_failed", architecture + ": " + disassemble.getStatusMsg());
                work.monitor.checkCanceled();
                function = program.getFunctionManager().createFunction("xodb_prime", start, new AddressSet(start, start.add(spec.code.length - 1)), SourceType.ANALYSIS);
                program.endTransaction(transaction, true);
            } catch (Throwable error) {
                program.endTransaction(transaction, false);
                throw error;
            }
            work.progress = "decompiling";
            DecompInterface decompiler = new DecompInterface();
            try {
                decompiler.toggleSyntaxTree(true);
                decompiler.toggleCCode(true);
                decompiler.setSimplificationStyle("decompile");
                work.monitor.checkCanceled();
                if (!decompiler.openProgram(program)) throw new Failure("prime_decompiler_open_failed", decompiler.getLastMessage());
                work.monitor.checkCanceled();
                DecompileResults result = decompiler.decompileFunction(function, 10, work.monitor);
                if (!result.decompileCompleted()) throw new Failure("prime_decompile_failed", result.getErrorMessage());
            } finally { decompiler.dispose(); }
            work.progress = "ready";
            work.state = "ready";
        } catch (Throwable error) { failed(work, error); }
        finally { if (program != null) program.release(consumer); }
    }

    static final class PrimeSpec {
        final String language;
        final String compiler;
        final byte[] code;
        PrimeSpec(String language, String compiler, int... code) {
            this.language = language; this.compiler = compiler; this.code = new byte[code.length];
            for (int i = 0; i < code.length; i++) this.code[i] = (byte)code[i];
        }
        static PrimeSpec forArchitecture(String architecture) throws Failure {
            return switch (architecture) {
                case "x86_64" -> new PrimeSpec("x86:LE:64:default", "gcc", 0x31, 0xc0, 0xc3);
                case "aarch64" -> new PrimeSpec("AARCH64:LE:64:v8A", "default", 0x00, 0x00, 0x80, 0xd2, 0xc0, 0x03, 0x5f, 0xd6);
                case "m68k" -> new PrimeSpec("68000:BE:32:default", "default", 0x70, 0x00, 0x4e, 0x75);
                case "ppc64le" -> new PrimeSpec("PowerPC:LE:64:default", "default", 0x00, 0x00, 0x60, 0x38, 0x20, 0x00, 0x80, 0x4e);
                case "loongarch64" -> new PrimeSpec("Loongarch:LE:64:lp64d", "default", 0x04, 0x00, 0x80, 0x02, 0x20, 0x00, 0x00, 0x4c);
                default -> throw new Failure("prime_unsupported_architecture", architecture);
            };
        }
    }

    void status(OutputStream out, String id, String jobId) throws Exception {
        if (jobId != null) {
            Work work = findWork(jobId);
            if (work == null) { sendFailure(out, id, "unknown_job", jobId); return; }
            sendWork(out, id, work);
            return;
        }
        Runtime rt = Runtime.getRuntime();
        JsonObject r = base(id, "ready");
        r.addProperty("healthy", !stopping.get());
        r.addProperty("heap_used", rt.totalMemory() - rt.freeMemory());
        r.addProperty("heap_committed", rt.totalMemory());
        r.addProperty("heap_max", rt.maxMemory());
        r.addProperty("images_open", images.values().stream().filter(x -> x.state.equals("ready")).count());
        r.addProperty("queue", jobs.values().stream().filter(x -> x.state.equals("pending")).count());
        r.addProperty("max_images", maxImages);
        r.addProperty("max_documents", maxDocuments);
        r.addProperty("documents_cached", documents.size());
        r.addProperty("open_programs", openProgramCount.get());
        r.addProperty("max_open_programs", maxOpenPrograms);
        r.addProperty("cache_bytes", projectCacheBytes.get());
        r.addProperty("cache_limit_bytes", maxCacheBytes);
        r.addProperty("idle_seconds", (System.nanoTime() - lastRequestNanos.get()) / 1_000_000_000.0);
        r.addProperty("idle_limit_seconds", idleNanos == 0 ? 0 : idleNanos / 1_000_000_000.0);
        r.addProperty("clients_connected", connectedClients.get());
        r.addProperty("pid", ProcessHandle.current().pid());
        send(out, r, null);
    }

    void openImage(JsonObject q, OutputStream out, String id) throws Exception {
        String sha = required(q, "sha256");
        String path = required(q, "path");
        if (!sha.matches("[0-9a-f]{64}")) { sendFailure(out, id, "bad_sha256", sha); return; }
        String key = analysisKey(q);
        String debugPath = text(q, "debug_path", null);
        String debugSha = text(q, "debug_sha256", null);
        String jobId = "open:" + key;
        if (!jobs.containsKey(jobId) && jobs.size() >= maxImages + maxDocuments + 128) {
            sendFailure(out, id, "queue_full", "retained job limit reached; restart the sidecar");
            return;
        }
        boolean background = q.has("background") && q.get("background").isJsonPrimitive() && q.get("background").getAsBoolean();
        if (!background) {
            preemptBackground();
            Work oldWork = jobs.get(jobId);
            Image oldImage = images.get(key);
            // An explicit request restarts an import that it just pre-empted;
            // the old task owns a different Image object and cannot clobber it.
            if (oldWork != null && oldWork.background && oldWork.state.equals("pending")) {
                oldWork.monitor.cancel();
                if (oldWork.future != null) oldWork.future.cancel(true);
                jobs.remove(jobId, oldWork);
                if (oldImage != null) images.remove(key, oldImage);
            }
        }
        // Eager imports stop at half the limit: the rest is for images a user asks about.
        if (background && !images.containsKey(key) && images.size() >= maxImages / 2) {
            sendFailure(out, id, "cache_reserved", "background imports stop at half of the image limit " + maxImages);
            return;
        }
        Image image = images.compute(key, (ignored, old) -> {
            if (old != null && !old.state.equals("failed")) { if (!background) old.background = false; return old; }
            Image made = new Image(key, sha, path, debugPath, debugSha); made.background = background; return made;
        });
        Work work = jobs.compute(jobId, (ignored, old) -> old == null || old.state.equals("failed") ? startImport(image, jobId, background) : old);
        sendWork(out, id, work);
    }

    Work startImport(Image image, String key, boolean background) {
            Work made = makeWork(key);
            made.future = submitGhidra(made, background, () -> importImage(image, made));
            return made;
    }

    void importImage(Image image, Work work) {
        try {
            work.progress = image.progress = "hashing";
            String actual = sha256(Paths.get(image.path));
            if (!actual.equals(image.sha)) throw new Failure("image_identity_mismatch", "expected " + image.sha + ", got " + actual);
            if (image.debugPath != null) {
                String actualDebug = sha256(Paths.get(image.debugPath));
                if (!actualDebug.equals(image.debugSha))
                    throw new Failure("debug_identity_mismatch", "expected " + image.debugSha + ", got " + actualDebug);
            }
            work.monitor.checkCanceled();
            boolean cached = project.getProjectData().getFile("/" + image.key) != null;
            if (!cached || !cachedAtLinkedBase(image.key)) {
                closeOpenProgram(image.key);
                if (!cached && image.background && project.getRootFolder().getFiles().length >= maxImages / 2)
                    throw new Failure("cache_reserved", "background imports stop at half of the image limit " + maxImages);
                if (!cached) makeProjectSlot(image.key);
                work.progress = image.progress = "importing";
                Program program = load(new File(image.path));
                if (!atLinkedBase(program)) {
                    program.release(project);
                    throw new Failure("import_failed", "Ghidra did not load the image at its linked base");
                }
                int tx = program.startTransaction("xodb import");
                boolean saved = false;
                try {
                    work.progress = image.progress = "analyzing";
                    if (image.debugPath != null)
                        PdbUniversalAnalyzer.setPdbFileOption(program, new File(image.debugPath));
                    trimAnalysis(program);
                    AutoAnalysisManager manager = AutoAnalysisManager.getAnalysisManager(program);
                    manager.initializeOptions();
                    manager.reAnalyzeAll(null);
                    manager.startAnalysis(work.monitor);
                    work.monitor.checkCanceled();
                    program.endTransaction(tx, true); tx = -1;
                    project.saveAs(program, "/", image.key, true);
                    saved = true;
                } finally {
                    if (tx >= 0) program.endTransaction(tx, false);
                    if (saved) project.close(program); else program.release(project);
                }
            }
            imageLastUsed.put(image.key, System.nanoTime());
            trimProjectCache(image.key);
            image.state = work.state = "ready";
            image.progress = work.progress = "ready";
        } catch (Throwable e) {
            failed(work, e);
            image.state = "failed";
            image.code = work.code;
            image.detail = work.detail;
        }
    }

    // xodb asks about link addresses (runtime address minus load bias). Ghidra
    // moves a position-independent ELF, executable or library, to a default
    // base of its own unless told the base to use; loading at the linked base
    // keeps every address in the program, relocated data included, a link
    // address. Other formats have no such loader option and load as before.
    Program load(File file) throws Exception {
        ProgramLoader.Builder builder = ProgramLoader.builder().source(file).project(project.getProject());
        try (ByteProvider bytes = new FileByteProvider(file, null, AccessMode.READ)) {
            ElfHeader elf = new ElfHeader(bytes, null);
            elf.parse();
            builder.addLoaderArg("-loader-imagebase", Long.toHexString(elf.getImageBase()));
        } catch (ElfException notElf) {}
        try (LoadResults<Program> loaded = builder.load()) { return loaded.getPrimaryDomainObject(project); }
    }

    static boolean atLinkedBase(Program program) {
        Long linked = ElfLoader.getElfOriginalImageBase(program);
        return linked == null || linked == program.getImageBase().getOffset();
    }

    // A project written by a sidecar older than 0.1.1 holds position-independent
    // images at Ghidra's base; such an import is replaced, never answered from.
    boolean cachedAtLinkedBase(String sha) throws Exception {
        Program program = project.openProgram("/", sha, true);
        try { return atLinkedBase(program); }
        finally { project.close(program); }
    }

    OpenProgram openProgram(String sha) throws Exception {
        OpenProgram slot = openPrograms.get(sha);
        if (slot != null) { slot.lastUsedNanos = System.nanoTime(); imageLastUsed.put(sha, slot.lastUsedNanos); return slot; }
        while (openPrograms.size() >= maxOpenPrograms) {
            String oldest = openPrograms.entrySet().iterator().next().getKey();
            closeOpenProgram(oldest);
        }
        Program program = project.openProgram("/", sha, true);
        if (program == null) throw new Failure("image_not_open", sha);
        DecompInterface decompiler = new DecompInterface();
        boolean ready = false;
        try {
            DecompileOptions options = new DecompileOptions();
            options.grabFromProgram(program);
            options.setMaxWidth(80);
            decompiler.setOptions(options);
            decompiler.toggleSyntaxTree(true);
            decompiler.toggleCCode(true);
            decompiler.setSimplificationStyle("decompile");
            if (!decompiler.openProgram(program)) throw new Failure("decompiler_open_failed", decompiler.getLastMessage());
            slot = new OpenProgram(sha, program, decompiler);
            openPrograms.put(sha, slot);
            openProgramCount.incrementAndGet();
            imageLastUsed.put(sha, System.nanoTime());
            ready = true;
            return slot;
        } finally {
            if (!ready) { decompiler.dispose(); project.close(program); }
        }
    }

    void closeOpenProgram(String sha) {
        OpenProgram slot = openPrograms.remove(sha);
        if (slot == null) return;
        openProgramCount.decrementAndGet();
        slot.decompiler.dispose();
        project.close(slot.program);
    }

    void closeOpenPrograms() {
        for (String sha : new ArrayList<>(openPrograms.keySet())) closeOpenProgram(sha);
    }

    long cacheUsage() {
        long total = 0;
        for (DomainFile file : project.getRootFolder().getFiles()) {
            try { total = Math.addExact(total, file.length()); }
            catch (Exception error) { return Long.MAX_VALUE; }
        }
        return total;
    }

    ArrayList<DomainFile> projectFilesByAge(String keep) {
        ArrayList<DomainFile> files = new ArrayList<>(Arrays.asList(project.getRootFolder().getFiles()));
        files.removeIf(file -> file.getName().equals(keep));
        files.sort(Comparator.comparingLong(file -> imageLastUsed.getOrDefault(file.getName(), file.getLastModifiedTime())));
        return files;
    }

    long evictProjectFile(DomainFile file) throws Exception {
        String sha = file.getName();
        long bytes = file.length();
        closeOpenProgram(sha);
        file.delete();
        images.remove(sha);
        jobs.remove("open:" + sha);
        documents.keySet().removeIf(key -> key.startsWith(sha + ":"));
        jobs.keySet().removeIf(key -> key.startsWith("decompile:" + sha + ":"));
        imageLastUsed.remove(sha);
        return bytes;
    }

    void makeProjectSlot(String keep) throws Exception {
        while (project.getRootFolder().getFiles().length >= maxImages) {
            ArrayList<DomainFile> files = projectFilesByAge(keep);
            if (files.isEmpty()) throw new Failure("cache_full", "project image limit " + maxImages + " has no evictable entry");
            evictProjectFile(files.get(0));
        }
    }

    void trimProjectCache(String keep) throws Exception {
        long used = cacheUsage();
        projectCacheBytes.set(used);
        if (used <= maxCacheBytes) return;
        for (DomainFile file : projectFilesByAge(keep)) {
            long bytes = evictProjectFile(file);
            used = Math.max(0, used - bytes);
            if (used <= maxCacheBytes) break;
        }
        // A single imported image can itself exceed the configured bound.
        if (used > maxCacheBytes) {
            DomainFile file = project.getProjectData().getFile("/" + keep);
            if (file != null) {
                closeOpenProgram(keep);
                file.delete();
                images.remove(keep);
                imageLastUsed.remove(keep);
            }
            projectCacheBytes.set(cacheUsage());
            throw new Failure("cache_too_large", "the imported project image exceeds XODB_GHIDRA_CACHE_BYTES=" + maxCacheBytes);
        }
        projectCacheBytes.set(cacheUsage());
    }

    void decompile(JsonObject q, OutputStream out, String id) throws Exception {
        String sha = required(q, "sha256");
        String analysisKey = analysisKey(q);
        String selector = q.has("symbol") ? "symbol=" + required(q, "symbol") : "entry=" + required(q, "entry");
        String options = text(q, "options", "default");
        String key = analysisKey + ":" + selector + ":" + options;
        byte[] cached = documents.get(key);
        if (cached != null) { send(out, base(id, "ready"), cached); return; }
        boolean background = q.has("background") && q.get("background").isJsonPrimitive() && q.get("background").getAsBoolean();
        String jobId = "decompile:" + key;
        if (!background) {
            preemptBackground();
            Work oldWork = jobs.get(jobId);
            // An explicit request for the function that is currently warming
            // owns the replacement job; never return that cancelled warm job.
            if (oldWork != null && oldWork.background && oldWork.state.equals("pending")) {
                oldWork.monitor.cancel();
                if (oldWork.future != null) oldWork.future.cancel(true);
                jobs.remove(jobId, oldWork);
            }
        }
        Image image = images.get(analysisKey);
        if (image == null || !image.state.equals("ready")) {
            JsonObject r = base(id, "pending");
            r.addProperty("job", "open:" + analysisKey);
            r.addProperty("progress", image == null ? "open_image required" : image.progress);
            send(out, r, null);
            return;
        }
        if (!documents.containsKey(key) && documents.size() >= maxDocuments) {
            sendFailure(out, id, "cache_full", "document cache limit " + maxDocuments + "; raise XODB_GHIDRA_MAX_DOCUMENTS or restart the sidecar");
            return;
        }
        if (!jobs.containsKey(jobId) && jobs.size() >= maxImages + maxDocuments + 128) {
            sendFailure(out, id, "queue_full", "retained job limit reached; restart the sidecar");
            return;
        }
        Work work = jobs.compute(jobId, (ignored, old) -> old == null || old.state.equals("failed") ? startExport(q, key, jobId, background) : old);
        sendWork(out, id, work);
    }

    Work startExport(JsonObject q, String key, String jobId, boolean background) {
            Work made = makeWork(jobId);
            JsonObject copy = q.deepCopy();
            made.future = submitGhidra(made, background, () -> export(copy, key, made));
            return made;
    }

    void export(JsonObject q, String key, Work work) {
        try {
            work.progress = "opening project image";
            String analysisKey = analysisKey(q);
            OpenProgram slot = openProgram(analysisKey);
            Function fn = requestedFunction(slot.program, q);
            work.progress = "decompiling";
            byte[] payload;
            try {
                payload = exportDocument(slot, fn, q, work.monitor);
            } catch (Failure first) {
                if (!first.code.equals("decompile_failed") || work.monitor.isCancelled()) throw first;
                // A native decompiler child may disappear while its pooled
                // interface is open. Reopen the program and retry this request
                // once; a persistent fault is still returned to the caller.
                closeOpenProgram(analysisKey);
                slot = openProgram(analysisKey);
                fn = requestedFunction(slot.program, q);
                payload = exportDocument(slot, fn, q, work.monitor);
            }
            if (payload.length > MAX_PAYLOAD) throw new Failure("document_too_large", Integer.toString(payload.length));
            documents.put(key, payload);
            work.payload = payload;
            work.progress = "ready";
            work.state = "ready";
        } catch (Throwable e) { failed(work, e); }
    }

    static Function functionAt(Program program, long entry) throws Failure {
        Address address = program.getAddressFactory().getDefaultAddressSpace().getAddress(entry);
        Function fn = program.getFunctionManager().getFunctionContaining(address);
        if (fn == null) fn = program.getFunctionManager().getFunctionAt(address);
        if (fn == null) throw new Failure("function_not_found", "no Ghidra function contains " + hx(entry));
        return fn;
    }

    static Function functionNamed(Program program, String requested) throws Failure {
        Function exact = null;
        Function alias = null;
        boolean exactAmbiguous = false;
        boolean aliasAmbiguous = false;
        for (Function fn : program.getFunctionManager().getFunctions(true)) {
            String name = fn.getName();
            if (name.equals(requested)) {
                if (exact != null) exactAmbiguous = true;
                exact = fn;
                continue;
            }
            boolean matchesAlias = name.equals("_" + requested) || requested.equals("_" + name);
            if (!matchesAlias) continue;
            if (alias != null) aliasAmbiguous = true;
            alias = fn;
        }
        if (exactAmbiguous) throw new Failure("function_ambiguous", "more than one Ghidra function is named " + requested);
        if (exact != null) return exact;
        if (alias != null && !aliasAmbiguous) return alias;
        throw new Failure(aliasAmbiguous ? "function_ambiguous" : "function_not_found",
            aliasAmbiguous ? "more than one Ghidra function matches " + requested : "no Ghidra function is named " + requested);
    }

    static Function requestedFunction(Program program, JsonObject request) throws Failure {
        if (request.has("symbol")) {
            String symbol = required(request, "symbol");
            if (symbol.isEmpty()) {
                for (String candidate : new String[]{"main", "_main", "entry", "_entry"}) {
                    try { return functionNamed(program, candidate); } catch (Failure ignored) {}
                }
                throw new Failure("function_not_found", "no default main or entry function was found; pass --function NAME");
            }
            return functionNamed(program, symbol);
        }
        return functionAt(program, unsignedHex(required(request, "entry")));
    }

    void cancel(OutputStream out, String id, String jobId) throws Exception {
        Work work = findWork(jobId);
        if (work == null) { sendFailure(out, id, "unknown_job", jobId); return; }
        work.monitor.cancel();
        if (work.future != null) work.future.cancel(true);
        work.state = "failed"; work.code = "cancelled"; work.detail = "request cancelled";
        sendWork(out, id, work);
    }

    void shutdown(OutputStream out, String id) throws Exception {
        send(out, base(id, "ready"), null);
        requestStop("shutdown");
    }

    void sendWork(OutputStream out, String id, Work work) throws Exception {
        JsonObject r = base(id, work.state);
        r.addProperty("job", work.id);
        r.addProperty("progress", work.progress);
        if (work.state.equals("failed")) { r.addProperty("code", work.code); r.addProperty("detail", work.detail); }
        send(out, r, work.state.equals("ready") ? work.payload : null);
    }


    void trimAnalysis(Program program) {
        Options options = project.getAnalysisOptions(program);
        // These analyzers do not contribute to the function graph, pseudo-C,
        // symbols, debug types, calls, strings, or switch recovery exported by
        // this milestone. Keep format/debug analyzers and core references on.
        for (String name : new String[]{"Embedded Media", "Function ID", "Library Identification"})
            if (options.contains(name)) options.setBoolean(name, false);
    }

    static int envInt(String name, int fallback, int low, int high) {
        try {
            String value = System.getenv(name);
            if (value == null || value.isBlank()) return fallback;
            int parsed = Integer.parseInt(value);
            return Math.max(low, Math.min(high, parsed));
        } catch (NumberFormatException ignored) { return fallback; }
    }

    static long envLong(String name, long fallback, long low, long high) {
        try {
            String value = System.getenv(name);
            if (value == null || value.isBlank()) return fallback;
            long parsed = Long.parseLong(value);
            return Math.max(low, Math.min(high, parsed));
        } catch (NumberFormatException ignored) { return fallback; }
    }

    static double envDouble(String name, double fallback, double low, double high) {
        try {
            String value = System.getenv(name);
            if (value == null || value.isBlank()) return fallback;
            double parsed = Double.parseDouble(value);
            if (!Double.isFinite(parsed)) return fallback;
            return Math.max(low, Math.min(high, parsed));
        } catch (NumberFormatException ignored) { return fallback; }
    }

    static void failed(Work work, Throwable error) {
        Throwable e = error instanceof ExecutionException && error.getCause() != null ? error.getCause() : error;
        work.state = "failed";
        work.code = e instanceof Failure ? ((Failure)e).code : e instanceof CancellationException ? "cancelled" : "ghidra_failed";
        work.detail = e.getMessage() == null ? e.toString() : e.getMessage();
        work.progress = "failed";
        System.err.println(work.id + ": " + work.code + ": " + work.detail);
    }

    byte[] exportDocument(OpenProgram slot, Function fn, JsonObject request, TaskMonitor monitor) throws Exception {
        long t0 = System.nanoTime();
        slot.lastUsedNanos = t0;
        int seconds = Math.max(1, Math.min(600, request.has("deadline_ms") ? request.get("deadline_ms").getAsInt() / 1000 : 60));
        DecompileResults result = slot.decompiler.decompileFunction(fn, seconds, monitor);
        if (!result.decompileCompleted()) throw new Failure("decompile_failed", result.getErrorMessage());
        JsonObject doc = graphDocument(slot.program, fn, result, request, t0);
        return JSON.toJson(doc).getBytes(StandardCharsets.UTF_8);
    }

    JsonObject graphDocument(Program program, Function fn, DecompileResults result, JsonObject request, long t0) throws Exception {
        HighFunction high = result.getHighFunction();
        JsonObject doc = new JsonObject();
        doc.addProperty("schema", "xodb.ghidra.function_graph");
        doc.addProperty("schema_version", "0.4.1");
        doc.addProperty("contract", "XODB-GHIDRA-SIDECAR.v1");
        doc.addProperty("status", "ok");
        String sha = required(request, "sha256");
        String analysisKey = analysisKey(request);
        String entryText = hx(fn.getEntryPoint().getOffset());
        doc.addProperty("artifact_id", artifact(analysisKey, entryText, text(request, "options", "default")));
        JsonObject producer = new JsonObject();
        producer.addProperty("kind", "ghidra_java_sidecar"); producer.addProperty("worker_version", PRODUCER);
        producer.addProperty("ghidra_commit", Application.getApplicationVersion()); producer.addProperty("java", true);
        doc.add("producer", producer);
        JsonObject image = new JsonObject();
        image.addProperty("path", text(request, "path", program.getExecutablePath()));
        image.addProperty("sha256", sha);
        if (request.has("debug_sha256") && !request.get("debug_sha256").isJsonNull())
            image.addProperty("debug_sha256", request.get("debug_sha256").getAsString());
        if (request.has("build_id") && !request.get("build_id").isJsonNull()) image.addProperty("gnu_build_id", request.get("build_id").getAsString());
        image.addProperty("format", program.getExecutableFormat());
        doc.add("image", image);
        JsonObject language = new JsonObject();
        language.addProperty("id", program.getLanguageID().getIdAsString());
        language.addProperty("processor", program.getLanguage().getProcessor().toString());
        language.addProperty("compiler_spec", program.getCompilerSpec().getCompilerSpecID().getIdAsString());
        doc.add("language", language);
        doc.add("address_spaces", addressSpaces(program));
        doc.add("function", function(program, fn, request));
        doc.add("qualification", qualification());
        doc.add("instructions", instructions(program, fn, high));
        JsonObject admission = new JsonObject();
        admission.addProperty("rule", "Ghidra listing instructions in the project function body; bytes are read from program memory and p-code is emitted by the selected language");
        admission.add("refused", new JsonArray()); doc.add("instruction_admission", admission);
        doc.add("high_pcode", highPcode(program, high));
        doc.add("blocks", blocks(high));
        doc.add("calls", calls(program, high));
        doc.add("pseudocode", pseudocode(result));
        doc.add("variables", variables(program, high, fn));
        doc.add("types", types(high, fn));
        doc.add("function_index", functionIndex(program, fn));
        JsonObject timing = new JsonObject(); timing.addProperty("sidecar_us", (System.nanoTime() - t0) / 1000); doc.add("timing", timing);
        return doc;
    }

    JsonArray addressSpaces(Program program) {
        JsonArray list = new JsonArray();
        AddressSpace def = program.getAddressFactory().getDefaultAddressSpace();
        int index = 0;
        for (AddressSpace space : program.getAddressFactory().getAllAddressSpaces()) {
            JsonObject row = new JsonObject(); row.addProperty("name", space.getName()); row.addProperty("index", index++);
            String type = space.isConstantSpace() ? "constant" : space.isUniqueSpace() ? "internal" : space.isStackSpace() ? "spacebase" : space.getName().equals("join") ? "join" : space.getName().equals("fspec") ? "fspec" : space.getName().equals("iop") ? "iop" : "processor";
            row.addProperty("type", type); row.addProperty("addr_size", Math.max(1, space.getSize() / 8));
            row.addProperty("word_size", space.getAddressableUnitSize()); row.addProperty("default_code", space.equals(def));
            list.add(row);
        }
        // Spaces the decompiler uses in varnodes but the address factory does not list.
        for (String[] extra : new String[][]{{"iop", "iop"}, {AddressSpace.VARIABLE_SPACE.getName(), "join"}}) {
            if (program.getAddressFactory().getAddressSpace(extra[0]) != null) continue;
            JsonObject row = new JsonObject(); row.addProperty("name", extra[0]); row.addProperty("index", index++); row.addProperty("type", extra[1]);
            row.addProperty("addr_size", 8); row.addProperty("word_size", 1); row.addProperty("default_code", false); list.add(row);
        }
        return list;
    }

    JsonObject function(Program program, Function fn, JsonObject request) {
        JsonObject f = new JsonObject(); f.addProperty("entry", hx(fn.getEntryPoint().getOffset()));
        f.addProperty("name", fn.getName()); f.addProperty("name_provenance", fn.getSymbol().getSource().toString());
        f.addProperty("entry_provenance", "ghidra_project"); f.addProperty("bounds_provenance", "ghidra_project");
        f.addProperty("bounds_policy", "project_function"); f.addProperty("declared_size", text(request, "size", hx(fn.getBody().getNumAddresses())));
        f.addProperty("flow_size", fn.getBody().getNumAddresses()); f.addProperty("has_unreachable_blocks", false);
        f.add("instructions_crossing_declared_bounds", new JsonArray()); f.add("instructions_outside_declared_bounds", new JsonArray()); f.add("warnings", new JsonArray());
        JsonObject proto = new JsonObject(); proto.addProperty("model", fn.getCallingConventionName()); proto.addProperty("provenance", fn.getSignatureSource().toString()); proto.addProperty("varargs", fn.hasVarArgs());
        proto.addProperty("return_type", fn.getReturnType().getDisplayName());
        proto.addProperty("signature", fn.getSignature().getPrototypeString());
        JsonArray params = new JsonArray();
        for (Parameter p : fn.getParameters()) {
            JsonObject pr = new JsonObject(); pr.addProperty("index", p.getOrdinal()); pr.addProperty("name", p.getName()); pr.addProperty("type", p.getDataType().getDisplayName()); pr.addProperty("size", p.getLength());
            Varnode v = p.getFirstStorageVarnode();
            if (v != null) { pr.addProperty("storage_space", v.getAddress().getAddressSpace().getName()); pr.addProperty("storage_offset", hx(v.getOffset())); if (v.isRegister()) { Register r = program.getRegister(v.getAddress(), v.getSize()); if (r != null) pr.addProperty("register", r.getName()); } }
            params.add(pr);
        }
        proto.add("params", params); f.add("prototype", proto); return f;
    }

    JsonObject qualification() {
        JsonObject q = new JsonObject(); q.addProperty("level", "qualified"); q.addProperty("note", "Ghidra project analysis; status ok is not semantic verification"); q.add("reasons", new JsonArray()); return q;
    }

    JsonArray instructions(Program program, Function fn, HighFunction high) throws MemoryAccessException {
        Map<Long, JsonArray> highByPc = new HashMap<>();
        for (Iterator<PcodeOpAST> it = high.getPcodeOps(); it.hasNext();) {
            PcodeOpAST op = it.next();
            highByPc.computeIfAbsent(op.getSeqnum().getTarget().getOffset(), unused -> new JsonArray()).add(opid(op));
        }
        JsonArray rows = new JsonArray();
        InstructionIterator it = program.getListing().getInstructions(fn.getBody(), true);
        while (it.hasNext()) {
            Instruction instruction = it.next(); long address = instruction.getAddress().getOffset();
            JsonObject row = new JsonObject(); row.addProperty("id", "insn:" + hx(address));
            row.addProperty("addr", hx(address)); row.addProperty("length", instruction.getLength());
            row.addProperty("discovery", "ghidra_project_function"); row.addProperty("admission", "admitted");
            row.addProperty("bytes", hex(instruction.getBytes())); row.addProperty("mnemonic", instruction.getMnemonicString());
            row.addProperty("operands", instruction.toString());
            JsonArray raw = new JsonArray(); int index = 0;
            for (PcodeOp op : instruction.getPcode()) {
                JsonObject effect = new JsonObject(); effect.addProperty("id", "raw:" + hx(address) + ":" + index++);
                effect.addProperty("opcode", op.getMnemonic()); raw.add(effect);
            }
            row.add("raw_pcode", raw); row.add("high_ops", highByPc.getOrDefault(address, new JsonArray())); rows.add(row);
        }
        return rows;
    }

    JsonObject highPcode(Program program, HighFunction high) {
        JsonObject hp = new JsonObject(); hp.addProperty("kind", "decompiler_final_ssa");
        JsonArray ops = new JsonArray(); Map<Integer, JsonObject> vars = new TreeMap<>();
        Map<Long, Integer> spaceIndex = new HashMap<>(); int position = 0;
        for (AddressSpace space : program.getAddressFactory().getAllAddressSpaces()) spaceIndex.put((long)space.getSpaceID(), position++);
        for (Iterator<PcodeOpAST> it = high.getPcodeOps(); it.hasNext();) {
            PcodeOpAST op = it.next(); JsonObject row = new JsonObject(); row.addProperty("id", opid(op)); row.addProperty("pc", hx(op.getSeqnum().getTarget().getOffset())); row.addProperty("opcode", op.getMnemonic());
            row.addProperty("block", op.getParent() == null ? "" : "bb:" + op.getParent().getIndex());
            Varnode out = op.getOutput(); row.add("out", out == null ? JsonNull.INSTANCE : new JsonPrimitive(vnid((VarnodeAST)out)));
            JsonArray in = new JsonArray(); for (Varnode v : op.getInputs()) { VarnodeAST va = (VarnodeAST)v; in.add(vnid(va)); vars.putIfAbsent(va.getUniqueId(), varnode(program, va)); }
            // LOAD/STORE input 0 is Ghidra's space id; the graph wants the
            // index this document gives that space in address_spaces.
            if ((op.getOpcode() == PcodeOp.LOAD || op.getOpcode() == PcodeOp.STORE) && op.getNumInputs() > 0) {
                VarnodeAST space = (VarnodeAST)op.getInput(0); Integer index = spaceIndex.get(space.getOffset());
                if (index != null) vars.get(space.getUniqueId()).addProperty("offset", hx(index));
            }
            // INDIRECT input 1 arrives as a constant holding the time of the
            // op that causes the effect; the graph wants it as an op reference.
            if (op.getOpcode() == PcodeOp.INDIRECT && op.getNumInputs() == 2) {
                VarnodeAST cause = (VarnodeAST)op.getInput(1); JsonObject reference = vars.get(cause.getUniqueId());
                reference.addProperty("space", "iop"); reference.addProperty("offset_encoding", "reference_elided"); reference.addProperty("ref_op", "op:" + Long.toUnsignedString(cause.getOffset()));
            }
            if (out != null) vars.putIfAbsent(((VarnodeAST)out).getUniqueId(), varnode(program, (VarnodeAST)out));
            row.add("in", in); if (op.getOpcode() == PcodeOp.CBRANCH) row.addProperty("boolean_flip", false); ops.add(row);
        }
        JsonArray va = new JsonArray(); for (JsonObject v : vars.values()) va.add(v); hp.add("ops", ops); hp.add("varnodes", va); return hp;
    }

    JsonObject varnode(Program program, VarnodeAST v) {
        // Ghidra sign-extends small constants to 64 bits; the graph wants the value in its own width.
        long offset = v.isConstant() && v.getSize() > 0 && v.getSize() < 8 ? v.getOffset() & ((1L << (8 * v.getSize())) - 1) : v.getOffset();
        JsonObject o = new JsonObject(); o.addProperty("id", vnid(v)); o.addProperty("space", v.getAddress().getAddressSpace().getName()); o.addProperty("offset", hx(offset)); o.addProperty("size", v.getSize());
        o.add("def", v.getDef() == null ? JsonNull.INSTANCE : new JsonPrimitive(opid((PcodeOpAST)v.getDef())));
        JsonArray flags = new JsonArray(); if (v.isConstant()) flags.add("constant"); if (v.isFree()) flags.add("free"); if (v.isInput()) flags.add("input"); if (v.isPersistent()) flags.add("persist"); if (v.isAddrTied()) flags.add("addrtied"); if (v.isFree() && !v.isConstant() && !v.isInput()) flags.add("annotation"); o.add("flags", flags);
        if (v.isRegister()) { Register r = program.getRegister(v.getAddress(), v.getSize()); if (r != null) o.addProperty("register", r.getName()); }
        if (v.getAddress().getAddressSpace().getName().equals("iop")) { o.addProperty("offset_encoding", "reference_elided"); o.addProperty("ref_op", "op:" + Long.toUnsignedString(v.getOffset())); }
        HighVariable h = v.getHigh(); if (h != null) { o.addProperty("high_name", h.getName()); DataType t = h.getDataType(); if (t != null) o.addProperty("type", t.getDisplayName()); }
        return o;
    }

    JsonArray blocks(HighFunction high) {
        JsonArray list = new JsonArray();
        for (PcodeBlockBasic b : high.getBasicBlocks()) {
            JsonObject row = new JsonObject(); row.addProperty("id", "bb:" + b.getIndex()); row.addProperty("start", hx(b.getStart().getOffset())); row.addProperty("stop", hx(b.getStop().getOffset()));
            JsonArray ops = new JsonArray(); for (Iterator<PcodeOp> it = b.getIterator(); it.hasNext();) ops.add(opid((PcodeOpAST)it.next())); row.add("ops", ops);
            JsonArray pred = new JsonArray(); for (int i=0;i<b.getInSize();i++) pred.add("bb:" + b.getIn(i).getIndex()); row.add("pred", pred);
            JsonArray succ = new JsonArray();
            for (int i=0;i<b.getOutSize();i++) { PcodeBlock to = b.getOut(i); JsonObject edge = new JsonObject(); edge.addProperty("to", "bb:" + to.getIndex()); edge.addProperty("slot", i); edge.add("flags", new JsonArray()); String kind = b.getOutSize()>2 ? "switch" : b.getOutSize()==2 && to==b.getTrueOut() ? "true_out" : b.getOutSize()==2 && to==b.getFalseOut() ? "false_out" : "unconditional"; edge.addProperty("kind", kind); succ.add(edge); }
            row.add("succ", succ); list.add(row);
        }
        return list;
    }

    JsonArray calls(Program program, HighFunction high) {
        JsonArray list = new JsonArray();
        for (Iterator<PcodeOpAST> it=high.getPcodeOps();it.hasNext();) { PcodeOpAST op=it.next(); if(op.getOpcode()!=PcodeOp.CALL && op.getOpcode()!=PcodeOp.CALLIND) continue; JsonObject c=new JsonObject(); c.addProperty("op",opid(op)); c.addProperty("pc",hx(op.getSeqnum().getTarget().getOffset())); c.addProperty("kind",op.getOpcode()==PcodeOp.CALL?"direct":"indirect"); if(op.getOpcode()==PcodeOp.CALL){Address target=op.getInput(0).getAddress(); c.addProperty("target",hx(target.getOffset())); Function f=program.getFunctionManager().getFunctionAt(target); if(f!=null)c.addProperty("target_name",f.getName());} list.add(c); }
        return list;
    }

    JsonObject pseudocode(DecompileResults result) {
        JsonObject p = new JsonObject(); String text=result.getDecompiledFunction().getC(); p.addProperty("language","c"); p.addProperty("printer","Ghidra DecompInterface"); p.addProperty("text",text); p.addProperty("address_map_status","partial: only Ghidra-linked tokens carry PCs"); p.addProperty("position_basis","line 1-based, col byte offset");
        // Columns are byte offsets into the printed line, indentation included.
        // The markup carries no indentation and wraps comments differently, so
        // each token is located in its printed line; one that is not found
        // keeps the running column and the document says so.
        String[] printed = text.split("\n", -1);
        JsonArray tokens = new JsonArray(); int index = 0; boolean aligned = true;
        for (ClangLine line : DecompilerUtils.toLines(result.getCCodeMarkup())) {
            int number = line.getLineNumber();
            byte[] row = number >= 1 && number <= printed.length ? printed[number - 1].getBytes(StandardCharsets.UTF_8) : new byte[0];
            int col = 0;
            for (ClangToken token : line.getAllTokens()) {
                String s = token.getText(); if (s.isEmpty()) continue;
                byte[] bytes = s.getBytes(StandardCharsets.UTF_8);
                int at = find(row, bytes, col);
                if (at < 0) { aligned = false; at = col; } else col = at + bytes.length;
                JsonObject t = new JsonObject(); t.addProperty("i", index++); t.addProperty("line", number); t.addProperty("col", at); t.addProperty("kind", tokenKind(token)); t.addProperty("text", s);
                if (token.getPcodeOp() != null) t.addProperty("op", opid((PcodeOpAST)token.getPcodeOp()));
                if (token.getMinAddress() != null) t.addProperty("pc", hx(token.getMinAddress().getOffset()));
                tokens.add(t);
            }
        }
        p.addProperty("token_status", aligned ? "ok" : "partial_alignment"); p.add("tokens", tokens); return p;
    }

    static int find(byte[] row, byte[] part, int from) {
        outer: for (int i = from; i + part.length <= row.length; i++) {
            for (int k = 0; k < part.length; k++) if (row[i + k] != part[k]) continue outer;
            return i;
        }
        return -1;
    }

    JsonArray variables(Program program, HighFunction high, Function fn) {
        JsonArray list = new JsonArray();
        for (Iterator<HighSymbol> it = high.getLocalSymbolMap().getSymbols(); it.hasNext();) {
            HighSymbol symbol = it.next();
            JsonObject row = new JsonObject();
            DataType type = symbol.getDataType();
            row.addProperty("name", symbol.getName());
            row.addProperty("type", type == null ? "" : type.getDisplayName());
            row.addProperty("size", Math.max(0, symbol.getSize()));
            row.addProperty("parameter", symbol.isParameter());
            VariableStorage storage = symbol.getStorage();
            Varnode[] pieces = storage == null ? new Varnode[0] : storage.getVarnodes();
            Varnode varnode = pieces.length == 0 ? null : pieces[0];
            long[] proven = null;
            if (varnode != null) {
                row.addProperty("storage", pieces.length > 1 ? "split" : varnode.isRegister() ? "register" : varnode.getAddress().getAddressSpace().getName().equals("stack") ? "stack" : "temp");
                row.addProperty("storage_offset", hx(varnode.getOffset()));
                if (pieces.length == 1 && varnode.isRegister()) {
                    Register register = program.getRegister(varnode.getAddress(), varnode.getSize());
                    if (register != null) {
                        Register base = register.getBaseRegister();
                        row.addProperty("register", base.getName());
                        row.addProperty("register_bit_offset", register.getLeastSignificantBitInBaseRegister());
                    }
                }
                JsonArray pieceRows = new JsonArray();
                int valueBytes = 0;
                boolean supported = symbol.getSize() > 0 && symbol.getSize() <= 32;
                long start = fn.getEntryPoint().getOffset(), end = fn.getBody().getMaxAddress().getOffset() + 1;
                for (Varnode piece : pieces) {
                    JsonObject item = new JsonObject();
                    item.addProperty("size", piece.getSize());
                    int valueOffset = program.getLanguage().isBigEndian()
                        ? storage.size() - valueBytes - piece.getSize() : valueBytes;
                    item.addProperty("value_bit_offset", valueOffset * 8);
                    long[] interval = null;
                    if (piece.isRegister()) {
                        Register register = program.getRegister(piece.getAddress(), piece.getSize());
                        if (register != null) {
                            Register base = register.getBaseRegister();
                            item.addProperty("storage", "register");
                            item.addProperty("register", base.getName());
                            item.addProperty("register_bit_offset", register.getLeastSignificantBitInBaseRegister());
                            interval = registerLifetime(program, fn, symbol, piece, base);
                        }
                    } else if (piece.getAddress().getAddressSpace().getName().equals("stack")) {
                        item.addProperty("storage", "stack");
                        PrototypeModel model = fn.getCallingConvention();
                        if (model == null) model = program.getCompilerSpec().getDefaultCallingConvention();
                        int stackshift = model == null ? 0 : model.getStackshift();
                        item.addProperty("cfa_offset", piece.getOffset() - stackshift);
                        interval = stackLifetime(program, fn, symbol, piece);
                    } else item.addProperty("storage", "temp");
                    if (interval == null) supported = false;
                    else { start = Math.max(start, interval[0]); end = Math.min(end, interval[1]); }
                    pieceRows.add(item);
                    valueBytes += piece.getSize();
                }
                row.add("pieces", pieceRows);
                long none = fn.getEntryPoint().getOffset();
                proven = supported && valueBytes == symbol.getSize() && start < end ? new long[]{start, end} : new long[]{none, none};
            } else row.addProperty("storage", "temp");
            long functionStart = fn.getBody().getMinAddress().getOffset();
            long functionEnd = fn.getBody().getMaxAddress().getOffset() + 1;
            Address firstUse = symbol.getPCAddress();
            long validStart = symbol.isParameter() || firstUse == null ? functionStart : firstUse.getOffset();
            long lastUse = validStart;
            HighVariable variable = symbol.getHighVariable();
            if (variable != null) for (Varnode instance : variable.getInstances()) {
                Address at = instance.getPCAddress();
                if (at != null && at.getAddressSpace().equals(program.getAddressFactory().getDefaultAddressSpace()))
                    lastUse = Math.max(lastUse, at.getOffset());
                PcodeOp definition = instance.getDef();
                if (definition != null) lastUse = Math.max(lastUse, definition.getSeqnum().getTarget().getOffset());
                for (Iterator<PcodeOp> uses = instance.getDescendants(); uses.hasNext();)
                    lastUse = Math.max(lastUse, uses.next().getSeqnum().getTarget().getOffset());
            }
            Instruction lastInstruction = program.getListing().getInstructionContaining(
                program.getAddressFactory().getDefaultAddressSpace().getAddress(lastUse));
            long validEnd = lastInstruction == null ? lastUse + 1 : lastInstruction.getMaxAddress().getOffset() + 1;
            validStart = Math.max(functionStart, Math.min(validStart, functionEnd - 1));
            validEnd = Math.max(validStart + 1, Math.min(validEnd, functionEnd));
            // Every storage kind xodb may read uses a proven interval, and an
            // unsupported or ambiguous piece makes the whole value unavailable.
            if (proven != null) { validStart = proven[0]; validEnd = proven[1]; }
            row.addProperty("valid_start", hx(validStart));
            row.addProperty("valid_end", hx(validEnd));
            list.add(row);
        }
        return list;
    }

    static boolean opaque(Instruction instruction) {
        try {
            for (PcodeOp op : instruction.getPcode()) if (op.getOpcode() == PcodeOp.CALLOTHER) return true;
            return false;
        } catch (Exception e) { return true; }
    }

    static boolean joined(ReferenceManager references, Address at) {
        for (ReferenceIterator it = references.getReferencesTo(at); it.hasNext();)
            if (it.next().getReferenceType().isFlow()) return true;
        return false;
    }

    static boolean writes(Instruction instruction, Register base) {
        long low = base.getAddress().getOffset(), high = low + base.getNumBytes();
        try {
            for (PcodeOp op : instruction.getPcode()) {
                Varnode out = op.getOutput();
                if (out != null && out.isRegister() && out.getOffset() < high && out.getOffset() + out.getSize() > low) return true;
            }
            return false;
        } catch (Exception e) { return true; }
    }

    /**
     * The [start, end) stop PCs at which the storage register is proven to
     * hold the variable. High p-code names values, not places: after copy
     * propagation a use can sit where the register was long overwritten, so
     * first-to-last use is not a lifetime. The proof here is straight-line
     * only. It starts at the function entry for a parameter, or just after
     * the instruction that wrote the register for a local (a call's return
     * value, or a plain instruction whose p-code writes it), and runs while
     * no instruction can change the register and no other path can join:
     * it ends at the first write, call, branch, user-defined p-code op or
     * jump target. The instruction that ends it is included, since a stop
     * there precedes its execution. An unproven variable gets an empty
     * interval and xodb shows no value for it.
     */
    long[] registerLifetime(Program program, Function fn, HighSymbol symbol, Varnode storage, Register base) {
        Listing listing = program.getListing();
        ReferenceManager references = program.getReferenceManager();
        Address entry = fn.getEntryPoint();
        long none = entry.getOffset();
        Address start = null;
        if (symbol.isParameter()) start = entry;
        else {
            Address pc = symbol.getPCAddress();
            HighVariable variable = symbol.getHighVariable();
            Instruction definer = pc == null ? null : listing.getInstructionAt(pc);
            if (variable != null && definer != null) for (Varnode instance : variable.getInstances()) {
                PcodeOp def = instance.getDef();
                if (def == null || !instance.getAddress().equals(storage.getAddress()) || !def.getSeqnum().getTarget().equals(pc)) continue;
                int opcode = def.getOpcode();
                boolean returned = definer.getFlowType().isCall() && (opcode == PcodeOp.CALL || opcode == PcodeOp.CALLIND);
                boolean computed = definer.getFlowType().isFallthrough() && opcode != PcodeOp.INDIRECT && opcode != PcodeOp.MULTIEQUAL
                    && writes(definer, base) && !opaque(definer);
                if (returned || computed) start = definer.getFallThrough();
                break;
            }
        }
        if (start == null) return new long[] { none, none };
        long end = start.getOffset();
        for (Address at = start; at != null && fn.getBody().contains(at);) {
            Instruction instruction = listing.getInstructionAt(at);
            if (instruction == null) break;
            if (!(symbol.isParameter() && at.equals(entry)) && joined(references, at)) break;
            end = at.getOffset() + 1;
            if (!instruction.getFlowType().isFallthrough() || writes(instruction, base) || opaque(instruction)) break;
            at = instruction.getFallThrough();
        }
        return new long[] { start.getOffset(), end };
    }

    static boolean storesMemory(Instruction instruction) {
        try {
            for (PcodeOp op : instruction.getPcode()) if (op.getOpcode() == PcodeOp.STORE) return true;
            return false;
        } catch (Exception e) { return true; }
    }

    /** Conservative straight-line proof for a CFA-relative stack piece. */
    long[] stackLifetime(Program program, Function fn, HighSymbol symbol, Varnode storage) {
        Listing listing = program.getListing();
        ReferenceManager references = program.getReferenceManager();
        Address entry = fn.getEntryPoint();
        long none = entry.getOffset();
        Address start = null;
        if (symbol.isParameter()) start = entry;
        else {
            Address pc = symbol.getPCAddress();
            HighVariable variable = symbol.getHighVariable();
            Instruction definer = pc == null ? null : listing.getInstructionAt(pc);
            if (variable != null && definer != null && storesMemory(definer) && !opaque(definer))
                for (Varnode instance : variable.getInstances()) {
                    PcodeOp def = instance.getDef();
                    if (def == null || !instance.isAddrTied() || !instance.getAddress().equals(storage.getAddress()) ||
                        instance.getSize() != storage.getSize() || !def.getSeqnum().getTarget().equals(pc)) continue;
                    int opcode = def.getOpcode();
                    if (opcode != PcodeOp.INDIRECT && opcode != PcodeOp.MULTIEQUAL) start = definer.getFallThrough();
                    break;
                }
        }
        if (start == null) return new long[]{none, none};
        long end = start.getOffset();
        for (Address at = start; at != null && fn.getBody().contains(at);) {
            Instruction instruction = listing.getInstructionAt(at);
            if (instruction == null) break;
            if (!(symbol.isParameter() && at.equals(entry)) && joined(references, at)) break;
            end = at.getOffset() + 1;
            if (!instruction.getFlowType().isFallthrough() || instruction.getFlowType().isCall() ||
                storesMemory(instruction) || opaque(instruction)) break;
            at = instruction.getFallThrough();
        }
        return new long[]{start.getOffset(), end};
    }

    JsonArray types(HighFunction high, Function fn) {
        TreeMap<String, DataType> found = new TreeMap<>();
        ArrayDeque<DataType> pending = new ArrayDeque<>();
        pending.add(fn.getReturnType());
        for (Parameter parameter : fn.getParameters()) pending.add(parameter.getDataType());
        for (Iterator<HighSymbol> it = high.getLocalSymbolMap().getSymbols(); it.hasNext();) {
            DataType type = it.next().getDataType();
            if (type != null) pending.add(type);
        }
        while (!pending.isEmpty() && found.size() < 4096) {
            DataType type = pending.removeFirst();
            if (type == null || found.putIfAbsent(type.getDisplayName(), type) != null) continue;
            if (type instanceof Pointer pointer && pointer.getDataType() != null) pending.add(pointer.getDataType());
            if (type instanceof Array array && array.getDataType() != null) pending.add(array.getDataType());
            if (type instanceof TypeDef alias && alias.getBaseDataType() != null) pending.add(alias.getBaseDataType());
            if (type instanceof Composite composite)
                for (DataTypeComponent field : composite.getComponents())
                    if (field.getDataType() != null) pending.add(field.getDataType());
        }
        JsonArray list = new JsonArray();
        for (DataType type : found.values()) {
            JsonObject row = new JsonObject();
            row.addProperty("name", type.getDisplayName());
            row.addProperty("size", type.getLength());
            row.addProperty("kind", type instanceof Structure ? "struct" : type instanceof Union ? "union" :
                type instanceof Pointer ? "pointer" : type instanceof Array ? "array" :
                type instanceof TypeDef ? "typedef" : "scalar");
            if (type instanceof Pointer pointer && pointer.getDataType() != null)
                row.addProperty("target", pointer.getDataType().getDisplayName());
            if (type instanceof Array array) {
                row.addProperty("element", array.getDataType().getDisplayName());
                row.addProperty("count", array.getNumElements());
            }
            if (type instanceof TypeDef alias)
                row.addProperty("target", alias.getBaseDataType().getDisplayName());
            if (type instanceof Composite composite) {
                JsonArray fields = new JsonArray();
                for (DataTypeComponent component : composite.getComponents()) {
                    JsonObject field = new JsonObject();
                    field.addProperty("name", component.getFieldName() == null ? "" : component.getFieldName());
                    field.addProperty("type", component.getDataType().getDisplayName());
                    field.addProperty("offset", component.getOffset());
                    field.addProperty("size", component.getLength());
                    fields.add(field);
                }
                row.add("fields", fields);
            }
            list.add(row);
        }
        return list;
    }

    JsonObject functionIndex(Program program, Function fn) {
        JsonObject out = new JsonObject();
        out.addProperty("start", hx(fn.getBody().getMinAddress().getOffset()));
        out.addProperty("end", hx(fn.getBody().getMaxAddress().getOffset() + 1));
        JsonArray callers = new JsonArray();
        for (Function f : fn.getCallingFunctions(TaskMonitor.DUMMY)) {
            JsonObject row = new JsonObject(); row.addProperty("name", f.getName());
            row.addProperty("entry", hx(f.getEntryPoint().getOffset())); callers.add(row);
        }
        out.add("direct_callers", callers);
        JsonArray callees = new JsonArray();
        for (Function f : fn.getCalledFunctions(TaskMonitor.DUMMY)) {
            JsonObject row = new JsonObject(); row.addProperty("name", f.getName());
            row.addProperty("entry", hx(f.getEntryPoint().getOffset())); callees.add(row);
        }
        out.add("direct_callees", callees);
        JsonArray strings = new JsonArray(); int count = 0;
        InstructionIterator instructions = program.getListing().getInstructions(fn.getBody(), true);
        while (instructions.hasNext() && count < 256) {
            Instruction instruction = instructions.next();
            for (Reference ref : program.getReferenceManager().getReferencesFrom(instruction.getAddress())) {
                Data data = program.getListing().getDataAt(ref.getToAddress());
                if (data != null && data.hasStringValue()) {
                    JsonObject row = new JsonObject(); row.addProperty("address", hx(ref.getToAddress().getOffset()));
                    row.addProperty("text", String.valueOf(data.getValue())); strings.add(row); count++;
                }
            }
        }
        out.add("strings", strings);
        return out;
    }

    static String tokenKind(ClangToken t){String n=t.getClass().getSimpleName();if(n.contains("Type"))return"type";if(n.contains("Variable"))return"variable";if(n.contains("FuncName"))return"funcname";if(n.contains("Field"))return"field";if(n.contains("Op"))return"operator";if(n.contains("Comment"))return"comment";if(n.contains("Label"))return"label";return"syntax";}
    static String opid(PcodeOpAST op){return"op:"+op.getSeqnum().getTime();} static String vnid(VarnodeAST v){return"vn:"+v.getUniqueId();}
    static String analysisKey(JsonObject request)throws Exception{String sha=required(request,"sha256");String debugPath=text(request,"debug_path",null);String debugSha=text(request,"debug_sha256",null);if((debugPath==null)!=(debugSha==null))throw new Failure("bad_debug_identity","debug_path and debug_sha256 must be supplied together");if(debugSha==null)return sha;if(!debugSha.matches("[0-9a-f]{64}"))throw new Failure("bad_debug_sha256",debugSha);return digest((sha+"\n"+debugSha).getBytes(StandardCharsets.UTF_8));}
    static String artifact(String sha,String entry,String options)throws Exception{return"ghj1-"+digest((sha+":"+entry+":"+options+":"+PRODUCER).getBytes(StandardCharsets.UTF_8));}
    static String sha256(Path path)throws Exception{MessageDigest md=MessageDigest.getInstance("SHA-256");try(InputStream in=Files.newInputStream(path)){byte[]b=new byte[1<<20];for(int n;(n=in.read(b))>0;)md.update(b,0,n);}return hex(md.digest());}
    static String digest(byte[]bytes)throws Exception{return hex(MessageDigest.getInstance("SHA-256").digest(bytes));}static String hex(byte[]bytes){StringBuilder b=new StringBuilder(bytes.length*2);for(byte x:bytes)b.append(String.format("%02x",x&255));return b.toString();}
    static String hx(long value){return"0x"+Long.toUnsignedString(value,16);}static long unsignedHex(String text){return new java.math.BigInteger(text.startsWith("0x")?text.substring(2):text,16).longValue();}
    static String text(JsonObject o,String key,String fallback){return o.has(key)&&!o.get(key).isJsonNull()?o.get(key).getAsString():fallback;}static String required(JsonObject o,String key)throws Failure{String v=text(o,key,null);if(v==null)throw new Failure("missing_field",key);return v;}
    static JsonObject base(String id,String state){JsonObject r=new JsonObject();r.addProperty("id",id);r.addProperty("state",state);return r;}
    static void sendFailure(OutputStream out,String id,String code,String detail)throws Exception{JsonObject r=base(id,"failed");r.addProperty("code",code);r.addProperty("detail",detail==null?"":detail);send(out,r,null);}
    static void send(OutputStream out,JsonObject reply,byte[]payload)throws Exception{if(payload!=null)reply.addProperty("payload_length",payload.length);out.write((JSON.toJson(reply)+"\n").getBytes(StandardCharsets.UTF_8));if(payload!=null){ByteBuffer b=ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN).putLong(payload.length);out.write(b.array());out.write(payload);}out.flush();}
    static String readLine(InputStream in)throws Exception{ByteArrayOutputStream b=new ByteArrayOutputStream();for(;;){int ch=in.read();if(ch<0)return b.size()==0?null:b.toString(StandardCharsets.UTF_8);if(ch=='\n')return b.toString(StandardCharsets.UTF_8);if(ch!='\r')b.write(ch);if(b.size()>MAX_LINE)throw new IOException("request line too long");}}
    static final class Failure extends Exception{final String code;Failure(String code,String detail){super(detail);this.code=code;}}
}
