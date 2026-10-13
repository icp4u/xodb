// Persistent Ghidra producer for xodb (GPLv3). Ghidra is an optional Apache-2.0 dependency.
import java.io.*;
import java.lang.management.ManagementFactory;
import java.net.StandardProtocolFamily;
import java.net.UnixDomainSocketAddress;
import java.nio.*;
import java.nio.channels.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

import com.google.gson.*;
import com.sun.security.auth.module.UnixSystem;
import ghidra.GhidraApplicationLayout;
import ghidra.app.decompiler.*;
import ghidra.app.plugin.core.analysis.AutoAnalysisManager;
import ghidra.app.decompiler.component.DecompilerUtils;
import ghidra.base.project.GhidraProject;
import ghidra.framework.Application;
import ghidra.framework.HeadlessGhidraApplicationConfiguration;
import ghidra.framework.options.Options;
import ghidra.program.model.address.*;
import ghidra.program.model.data.*;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.*;
import ghidra.program.model.pcode.*;
import ghidra.program.model.symbol.Reference;
import ghidra.util.task.TaskMonitor;
import ghidra.util.task.TaskMonitorAdapter;

public final class XodbGhidraSidecar {
    static final int PROTOCOL = 1;
    static final int SCHEMA = 1;
    static final String PRODUCER = "ghidra-jvm-sidecar-0.1.0";
    static final Gson JSON = new GsonBuilder().disableHtmlEscaping().serializeNulls().create();
    static final int MAX_LINE = 1 << 20;
    static final int MAX_PAYLOAD = 64 << 20;

    final Path socketPath;
    final Path cacheDir;
    final Path logPath;
    final long uid = new UnixSystem().getUid();
    final AtomicBoolean stopping = new AtomicBoolean(false);
    final ExecutorService clients = Executors.newCachedThreadPool();
    final ExecutorService ghidra = Executors.newSingleThreadExecutor();
    final ConcurrentMap<String, Work> jobs = new ConcurrentHashMap<>();
    final ConcurrentMap<String, Image> images = new ConcurrentHashMap<>();
    final ConcurrentMap<String, byte[]> documents = new ConcurrentHashMap<>();
    final int maxImages = envInt("XODB_GHIDRA_MAX_IMAGES", 64, 1, 4096);
    final int maxDocuments = envInt("XODB_GHIDRA_MAX_DOCUMENTS", 1024, 1, 65536);
    final GhidraProject project;
    ServerSocketChannel listener;

    static final class Image {
        final String sha;
        final String path;
        volatile String state = "pending";
        volatile String progress = "queued";
        volatile String code;
        volatile String detail;
        Image(String sha, String path) { this.sha = sha; this.path = path; }
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
        Work(String id) { this.id = id; }
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
        try {
            while (!stopping.get()) {
                SocketChannel channel;
                try { channel = listener.accept(); }
                catch (AsynchronousCloseException e) { break; }
                clients.submit(() -> serve(channel));
            }
        } finally {
            stopping.set(true);
            try { listener.close(); } catch (Exception ignored) {}
            clients.shutdownNow();
            ghidra.shutdownNow();
            for (Work work : jobs.values()) work.monitor.cancel();
            project.close();
            // Ghidra's helper children (the demangler) must not outlive the sidecar.
            for (ProcessHandle child : ProcessHandle.current().children().toList()) {
                child.destroyForcibly();
                try { child.onExit().get(2, TimeUnit.SECONDS); } catch (Exception ignored) {}
            }
            try { Files.deleteIfExists(socketPath); } catch (Exception ignored) {}
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
            }
        } catch (Exception e) {
            if (!stopping.get()) System.err.println("client: " + e);
        }
    }

    void handle(JsonObject request, OutputStream out) throws Exception {
        String id = text(request, "id", "?");
        String verb = text(request, "verb", "");
        switch (verb) {
            case "hello" -> hello(out, id);
            case "status" -> status(out, id, text(request, "job", null));
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
        for (String c : new String[]{"open_image", "decompile", "cancel", "status", "shutdown", "hints_reserved", "xsg", "pseudocode", "variables", "types", "function_index"}) caps.add(c);
        r.add("capabilities", caps);
        send(out, r, null);
    }

    void status(OutputStream out, String id, String jobId) throws Exception {
        if (jobId != null) {
            Work work = jobs.get(jobId);
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
        r.addProperty("pid", ProcessHandle.current().pid());
        send(out, r, null);
    }

    void openImage(JsonObject q, OutputStream out, String id) throws Exception {
        String sha = required(q, "sha256");
        String path = required(q, "path");
        if (!sha.matches("[0-9a-f]{64}")) { sendFailure(out, id, "bad_sha256", sha); return; }
        String jobId = "open:" + sha;
        if (!images.containsKey(sha) && images.size() >= maxImages) {
            sendFailure(out, id, "cache_full", "image cache limit " + maxImages + "; raise XODB_GHIDRA_MAX_IMAGES or delete the private cache");
            return;
        }
        if (!jobs.containsKey(jobId) && jobs.size() >= maxImages + maxDocuments + 128) {
            sendFailure(out, id, "queue_full", "retained job limit reached; restart the sidecar");
            return;
        }
        Image image = images.compute(sha, (key, old) -> old == null || old.state.equals("failed") ? new Image(key, path) : old);
        Work work = jobs.compute(jobId, (key, old) -> old == null || old.state.equals("failed") ? startImport(image, key) : old);
        sendWork(out, id, work);
    }

    Work startImport(Image image, String key) {
            Work made = new Work(key);
            made.future = ghidra.submit(() -> importImage(image, made));
            return made;
    }

    void importImage(Image image, Work work) {
        try {
            work.progress = image.progress = "hashing";
            String actual = sha256(Paths.get(image.path));
            if (!actual.equals(image.sha)) throw new Failure("image_identity_mismatch", "expected " + image.sha + ", got " + actual);
            work.monitor.checkCanceled();
            if (project.getProjectData().getFile("/" + image.sha) == null) {
                if (project.getRootFolder().getFiles().length >= maxImages)
                    throw new Failure("cache_full", "project image limit " + maxImages + "; raise XODB_GHIDRA_MAX_IMAGES or delete the private cache");
                work.progress = image.progress = "importing";
                Program program = project.importProgram(new File(image.path));
                if (program == null) throw new Failure("import_failed", "Ghidra found no loader for the image");
                try {
                    work.progress = image.progress = "analyzing";
                    trimAnalysis(program);
                    AutoAnalysisManager manager = AutoAnalysisManager.getAnalysisManager(program);
                    manager.initializeOptions();
                    manager.reAnalyzeAll(null);
                    manager.startAnalysis(work.monitor);
                    work.monitor.checkCanceled();
                    project.saveAs(program, "/", image.sha, true);
                } finally { project.close(program); }
            }
            image.state = work.state = "ready";
            image.progress = work.progress = "ready";
        } catch (Throwable e) {
            failed(work, e);
            image.state = "failed";
            image.code = work.code;
            image.detail = work.detail;
        }
    }

    void decompile(JsonObject q, OutputStream out, String id) throws Exception {
        String sha = required(q, "sha256");
        long entry = unsignedHex(required(q, "entry"));
        String options = text(q, "options", "default");
        String key = sha + ":" + Long.toUnsignedString(entry, 16) + ":" + options;
        byte[] cached = documents.get(key);
        if (cached != null) { send(out, base(id, "ready"), cached); return; }
        Image image = images.get(sha);
        if (image == null || !image.state.equals("ready")) {
            JsonObject r = base(id, "pending");
            r.addProperty("job", "open:" + sha);
            r.addProperty("progress", image == null ? "open_image required" : image.progress);
            send(out, r, null);
            return;
        }
        String jobId = "decompile:" + key;
        if (!documents.containsKey(key) && documents.size() >= maxDocuments) {
            sendFailure(out, id, "cache_full", "document cache limit " + maxDocuments + "; raise XODB_GHIDRA_MAX_DOCUMENTS or restart the sidecar");
            return;
        }
        if (!jobs.containsKey(jobId) && jobs.size() >= maxImages + maxDocuments + 128) {
            sendFailure(out, id, "queue_full", "retained job limit reached; restart the sidecar");
            return;
        }
        Work work = jobs.compute(jobId, (ignored, old) -> old == null || old.state.equals("failed") ? startExport(q, key, jobId) : old);
        sendWork(out, id, work);
    }

    Work startExport(JsonObject q, String key, String jobId) {
            Work made = new Work(jobId);
            JsonObject copy = q.deepCopy();
            made.future = ghidra.submit(() -> export(copy, key, made));
            return made;
    }

    void export(JsonObject q, String key, Work work) {
        Program program = null;
        try {
            work.progress = "opening project image";
            String sha = required(q, "sha256");
            program = project.openProgram("/", sha, true);
            if (program == null) throw new Failure("image_not_open", sha);
            long entry = unsignedHex(required(q, "entry"));
            Address address = program.getAddressFactory().getDefaultAddressSpace().getAddress(entry);
            Function fn = program.getFunctionManager().getFunctionContaining(address);
            if (fn == null) fn = program.getFunctionManager().getFunctionAt(address);
            if (fn == null) throw new Failure("function_not_found", "no Ghidra function contains " + hx(entry));
            work.progress = "decompiling";
            byte[] payload = exportDocument(program, fn, q, work.monitor);
            if (payload.length > MAX_PAYLOAD) throw new Failure("document_too_large", Integer.toString(payload.length));
            documents.put(key, payload);
            work.payload = payload;
            work.progress = "ready";
            work.state = "ready";
        } catch (Throwable e) { failed(work, e); }
        finally { if (program != null) project.close(program); }
    }

    void cancel(OutputStream out, String id, String jobId) throws Exception {
        Work work = jobs.get(jobId);
        if (work == null) { sendFailure(out, id, "unknown_job", jobId); return; }
        work.monitor.cancel();
        if (work.future != null) work.future.cancel(true);
        work.state = "failed"; work.code = "cancelled"; work.detail = "request cancelled";
        sendWork(out, id, work);
    }

    void shutdown(OutputStream out, String id) throws Exception {
        send(out, base(id, "ready"), null);
        stopping.set(true);
        listener.close();
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

    static void failed(Work work, Throwable error) {
        Throwable e = error instanceof ExecutionException && error.getCause() != null ? error.getCause() : error;
        work.state = "failed";
        work.code = e instanceof Failure ? ((Failure)e).code : e instanceof CancellationException ? "cancelled" : "ghidra_failed";
        work.detail = e.getMessage() == null ? e.toString() : e.getMessage();
        work.progress = "failed";
        System.err.println(work.id + ": " + work.code + ": " + work.detail);
    }

    byte[] exportDocument(Program program, Function fn, JsonObject request, TaskMonitor monitor) throws Exception {
        long t0 = System.nanoTime();
        DecompInterface di = new DecompInterface();
        try {
            DecompileOptions options = new DecompileOptions();
            options.grabFromProgram(program);
            options.setMaxWidth(80);
            di.setOptions(options);
            di.toggleSyntaxTree(true);
            di.toggleCCode(true);
            di.setSimplificationStyle("decompile");
            if (!di.openProgram(program)) throw new Failure("decompiler_open_failed", di.getLastMessage());
            int seconds = Math.max(1, Math.min(600, request.has("deadline_ms") ? request.get("deadline_ms").getAsInt() / 1000 : 60));
            DecompileResults result = di.decompileFunction(fn, seconds, monitor);
            if (!result.decompileCompleted()) throw new Failure("decompile_failed", result.getErrorMessage());
            JsonObject doc = graphDocument(program, fn, result, request, t0);
            return JSON.toJson(doc).getBytes(StandardCharsets.UTF_8);
        } finally { di.dispose(); }
    }

    JsonObject graphDocument(Program program, Function fn, DecompileResults result, JsonObject request, long t0) throws Exception {
        HighFunction high = result.getHighFunction();
        JsonObject doc = new JsonObject();
        doc.addProperty("schema", "xodb.ghidra.function_graph");
        doc.addProperty("schema_version", "0.4.1");
        doc.addProperty("contract", "XODB-GHIDRA-SIDECAR.v1");
        doc.addProperty("status", "ok");
        String sha = required(request, "sha256");
        String entryText = hx(fn.getEntryPoint().getOffset());
        doc.addProperty("artifact_id", artifact(sha, entryText, text(request, "options", "default")));
        JsonObject producer = new JsonObject();
        producer.addProperty("kind", "ghidra_java_sidecar"); producer.addProperty("worker_version", PRODUCER);
        producer.addProperty("ghidra_commit", Application.getApplicationVersion()); producer.addProperty("java", true);
        doc.add("producer", producer);
        JsonObject image = new JsonObject();
        image.addProperty("path", text(request, "path", program.getExecutablePath()));
        image.addProperty("sha256", sha);
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
        doc.add("high_pcode", highPcode(program, high));
        doc.add("blocks", blocks(high));
        doc.add("calls", calls(program, high));
        doc.add("pseudocode", pseudocode(result));
        doc.add("variables", variables(high, fn));
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

    JsonArray variables(HighFunction high, Function fn) {
        JsonArray list=new JsonArray(); for(Iterator<HighSymbol> it=high.getLocalSymbolMap().getSymbols();it.hasNext();){HighSymbol s=it.next();JsonObject v=new JsonObject();v.addProperty("name",s.getName());v.addProperty("type",s.getDataType()==null?"":s.getDataType().getDisplayName());v.addProperty("parameter",s.isParameter());VariableStorage st=s.getStorage();Varnode n=st==null?null:st.getFirstVarnode();if(n!=null){v.addProperty("storage",n.isRegister()?"register":n.getAddress().getAddressSpace().getName().equals("stack")?"stack":"temp");v.addProperty("storage_offset",hx(n.getOffset()));}else v.addProperty("storage","temp");v.addProperty("valid_start",hx(fn.getBody().getMinAddress().getOffset()));v.addProperty("valid_end",hx(fn.getBody().getMaxAddress().getOffset()+1));list.add(v);}return list;
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
