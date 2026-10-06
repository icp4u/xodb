// GhxRefExport: Java headless REFERENCE exporter for C01 (xodb, GPLv3).
// Runs inside Ghidra's analyzeHeadless (a JVM). This is a reference route and
// an honest intermediate dependency, NOT a native worker.
//
// args: <spec-file> <out-dir> [timeout-seconds]
//   spec-file lines: "<id> <entry-hex> <size-hex|0x0> <name|->"; writes <out-dir>/<id>.json
//@category xodb
import java.io.FileWriter;
import java.io.Writer;
import java.math.BigInteger;
import java.security.MessageDigest;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.*;

import com.google.gson.*;

import ghidra.app.decompiler.*;
import ghidra.app.decompiler.component.DecompilerUtils;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.*;
import ghidra.program.model.pcode.*;
import ghidra.program.model.symbol.SourceType;
import ghidra.framework.Application;

public class GhxRefExport extends GhidraScript {

	static String hx(long v) { return "0x" + Long.toUnsignedString(v, 16); }

	JsonObject vnode(Varnode v) {
		JsonObject o = new JsonObject();
		AddressSpace sp = v.getAddress().getAddressSpace();
		o.addProperty("space", sp.getName());
		o.addProperty("offset", hx(v.getOffset()));
		o.addProperty("size", v.getSize());
		if (v.isRegister()) {
			Register r = currentProgram.getRegister(v.getAddress(), v.getSize());
			if (r != null) o.addProperty("register", r.getName());
		}
		return o;
	}

	@Override
	public void run() throws Exception {
		String[] args = getScriptArgs();
		int to = args.length > 2 ? Integer.parseInt(args[2]) : 60;
		for (String line : Files.readAllLines(Paths.get(args[0]))) {
			String[] f = line.trim().split("\\s+");
			if (f.length != 4) continue;
			String out = args[1] + "/" + f[0] + ".json";
			try {
				one(new String[] { f[1], f[2], f[3], out, Integer.toString(to) });
			} catch (Exception e) {
				JsonObject j = new JsonObject();
				j.addProperty("schema", "xodb.ghidra.reference_export");
				j.addProperty("schema_version", "0.1.0");
				j.addProperty("status", "error");
				JsonObject er = new JsonObject();
				er.addProperty("code", "exception");
				er.addProperty("message", e.toString());
				j.add("error", er);
				write(out, j);
			}
		}
	}

	void one(String[] a) throws Exception {
		long t0 = System.nanoTime();
		Address entry = toAddr(new BigInteger(a[0].substring(2), 16).longValue());
		long size = new BigInteger(a[1].substring(2), 16).longValue();
		String name = a[2];
		String out = a[3];
		int timeout = a.length > 4 ? Integer.parseInt(a[4]) : 60;

		JsonObject j = new JsonObject();
		j.addProperty("schema", "xodb.ghidra.reference_export");
		j.addProperty("schema_version", "0.1.0");
		j.addProperty("id", Paths.get(a[3]).getFileName().toString().replace(".json", ""));
		JsonObject prod = new JsonObject();
		prod.addProperty("kind", "ghidra_java_headless_reference");
		prod.addProperty("java", true);
		prod.addProperty("ghidra_version", Application.getApplicationVersion());
		prod.addProperty("java_version", System.getProperty("java.version"));
		j.add("producer", prod);
		j.addProperty("source_kind", "static_analysis");

		JsonObject img = new JsonObject();
		img.addProperty("path", currentProgram.getExecutablePath());
		img.addProperty("sha256", currentProgram.getExecutableSHA256());
		img.addProperty("image_base", currentProgram.getImageBase().toString());
		j.add("image", img);
		JsonObject lang = new JsonObject();
		lang.addProperty("id", currentProgram.getLanguageID().getIdAsString());
		lang.addProperty("compiler_spec", currentProgram.getCompilerSpec().getCompilerSpecID().getIdAsString());
		j.add("language", lang);

		// -noanalysis imports have no disassembly yet: disassemble from the
		// declared entry (declared input, not function discovery) and let an
		// imported symbol's function recompute its body.
		boolean disassembledHere = false;
		if (getInstructionAt(entry) == null) {
			disassemble(entry);
			disassembledHere = true;
		}
		Function fn = getFunctionAt(entry);
		boolean bodyFixed = false;
		if (fn != null && fn.getBody().getNumAddresses() <= 1) {
			// imported symbol function without analysis: compute body by flow
			ghidra.app.cmd.function.CreateFunctionCmd.fixupFunctionBody(currentProgram, fn, monitor);
			bodyFixed = true;
		}
		String nameProv;
		if (fn != null) {
			nameProv = fn.getSymbol().getSource().toString();
		} else {
			fn = createFunction(entry, name.equals("-") ? null : name);
			nameProv = "request";
		}
		JsonObject f = new JsonObject();
		f.addProperty("entry", hx(entry.getOffset()));
		if (fn == null) {
			j.addProperty("status", "error");
			JsonObject e = new JsonObject();
			e.addProperty("code", "no_function");
			e.addProperty("message", "could not create function at " + entry);
			j.add("error", e);
			write(out, j);
			return;
		}
		f.addProperty("name", fn.getName());
		f.addProperty("name_provenance", nameProv);
		f.addProperty("disassembled_by_script", disassembledHere);
		f.addProperty("body_fixed_by_script", bodyFixed);
		f.addProperty("declared_size", size == 0 ? null : hx(size));
		JsonArray body = new JsonArray();
		for (AddressRange r : fn.getBody()) {
			JsonArray rr = new JsonArray();
			rr.add(hx(r.getMinAddress().getOffset()));
			rr.add(hx(r.getMaxAddress().getOffset()));
			body.add(rr);
		}
		f.add("body_ranges", body);
		f.addProperty("signature", fn.getSignature().getPrototypeString());
		f.addProperty("signature_source", fn.getSignatureSource().toString());
		j.add("function", f);

		// instructions in the Ghidra function body (+ raw p-code)
		JsonArray insns = new JsonArray();
		InstructionIterator it = currentProgram.getListing().getInstructions(fn.getBody(), true);
		while (it.hasNext()) {
			Instruction in = it.next();
			JsonObject io = new JsonObject();
			io.addProperty("addr", hx(in.getAddress().getOffset()));
			io.addProperty("length", in.getLength());
			io.addProperty("mnemonic", in.getMnemonicString());
			io.addProperty("text", in.toString());
			JsonArray raw = new JsonArray();
			for (PcodeOp p : in.getPcode()) {
				JsonObject po = new JsonObject();
				po.addProperty("opcode", p.getMnemonic());
				po.add("out", p.getOutput() == null ? JsonNull.INSTANCE : vnode(p.getOutput()));
				JsonArray ins = new JsonArray();
				for (Varnode v : p.getInputs()) ins.add(vnode(v));
				po.add("in", ins);
				raw.add(po);
			}
			io.add("raw_pcode", raw);
			insns.add(io);
		}
		j.add("instructions", insns);

		DecompInterface di = new DecompInterface();
		DecompileOptions opt = new DecompileOptions();
		opt.grabFromProgram(currentProgram);
		di.setOptions(opt);
		di.toggleSyntaxTree(true);
		di.toggleCCode(true);
		di.setSimplificationStyle("decompile");
		if (!di.openProgram(currentProgram)) throw new RuntimeException("decompiler open failed: " + di.getLastMessage());
		long t1 = System.nanoTime();
		DecompileResults res = di.decompileFunction(fn, timeout, monitor);
		long t2 = System.nanoTime();
		if (!res.decompileCompleted()) {
			j.addProperty("status", "error");
			JsonObject e = new JsonObject();
			e.addProperty("code", "decompile_failed");
			e.addProperty("message", res.getErrorMessage());
			j.add("error", e);
			write(out, j);
			di.dispose();
			return;
		}
		HighFunction hf = res.getHighFunction();
		j.addProperty("status", "ok");

		JsonArray ops = new JsonArray();
		Map<Integer, JsonObject> vns = new TreeMap<>();
		Iterator<PcodeOpAST> oi = hf.getPcodeOps();
		while (oi.hasNext()) {
			PcodeOpAST op = oi.next();
			JsonObject o = new JsonObject();
			SequenceNumber sq = op.getSeqnum();
			o.addProperty("id", "op:" + sq.getTime());
			o.addProperty("pc", hx(sq.getTarget().getOffset()));
			o.addProperty("opcode", op.getMnemonic());
			o.addProperty("block", op.getParent() == null ? "" : "bb:" + op.getParent().getIndex());
			Varnode ov = op.getOutput();
			o.add("out", ov == null ? JsonNull.INSTANCE : new JsonPrimitive("vn:" + ((VarnodeAST) ov).getUniqueId()));
			JsonArray ins = new JsonArray();
			for (Varnode v : op.getInputs()) {
				if (v == null) { ins.add(JsonNull.INSTANCE); continue; }
				VarnodeAST va = (VarnodeAST) v;
				ins.add("vn:" + va.getUniqueId());
				if (!vns.containsKey(va.getUniqueId())) vns.put(va.getUniqueId(), vjson(va));
			}
			if (ov != null) vns.put(((VarnodeAST) ov).getUniqueId(), vjson((VarnodeAST) ov));
			o.add("in", ins);
			ops.add(o);
		}
		JsonObject hp = new JsonObject();
		hp.addProperty("kind", "decompiler_final_ssa");
		hp.add("ops", ops);
		JsonArray va = new JsonArray();
		for (JsonObject v : vns.values()) va.add(v);
		hp.add("varnodes", va);
		j.add("high_pcode", hp);

		JsonArray blocks = new JsonArray();
		for (PcodeBlockBasic b : hf.getBasicBlocks()) {
			JsonObject bo = new JsonObject();
			bo.addProperty("id", "bb:" + b.getIndex());
			bo.addProperty("start", hx(b.getStart().getOffset()));
			bo.addProperty("stop", hx(b.getStop().getOffset()));
			JsonArray succ = new JsonArray();
			for (int i = 0; i < b.getOutSize(); i++) succ.add("bb:" + b.getOut(i).getIndex());
			bo.add("succ", succ);
			blocks.add(bo);
		}
		j.add("blocks", blocks);

		JsonArray calls = new JsonArray();
		for (PcodeOpAST op : iter(hf.getPcodeOps())) {
			int oc = op.getOpcode();
			if (oc != PcodeOp.CALL && oc != PcodeOp.CALLIND) continue;
			JsonObject c = new JsonObject();
			c.addProperty("op", "op:" + op.getSeqnum().getTime());
			c.addProperty("pc", hx(op.getSeqnum().getTarget().getOffset()));
			c.addProperty("kind", oc == PcodeOp.CALL ? "direct" : "indirect");
			if (oc == PcodeOp.CALL) {
				Address t = op.getInput(0).getAddress();
				c.addProperty("target", hx(t.getOffset()));
				Function tf = getFunctionAt(t);
				c.addProperty("target_name", tf == null ? null : tf.getName());
			}
			calls.add(c);
		}
		j.add("calls", calls);

		JsonArray hv = new JsonArray();
		for (Iterator<HighSymbol> si = hf.getLocalSymbolMap().getSymbols(); si.hasNext();) {
			HighSymbol s = si.next();
			JsonObject so = new JsonObject();
			so.addProperty("name", s.getName());
			so.addProperty("type", s.getDataType() == null ? "" : s.getDataType().getDisplayName());
			so.addProperty("is_parameter", s.isParameter());
			so.addProperty("type_locked", s.isTypeLocked());
			so.addProperty("name_locked", s.isNameLocked());
			hv.add(so);
		}
		j.add("high_symbols", hv);

		JsonObject pc = new JsonObject();
		pc.addProperty("text", res.getDecompiledFunction().getC());
		JsonArray toks = new JsonArray();
		for (ClangLine line : DecompilerUtils.toLines(res.getCCodeMarkup())) {
			for (ClangToken t : line.getAllTokens()) {
				if (t.getText().isEmpty()) continue;
				JsonObject to = new JsonObject();
				to.addProperty("line", line.getLineNumber());
				to.addProperty("kind", t.getClass().getSimpleName());
				to.addProperty("text", t.getText());
				if (t.getPcodeOp() != null) to.addProperty("op", "op:" + t.getPcodeOp().getSeqnum().getTime());
				if (t.getMinAddress() != null) to.addProperty("pc", hx(t.getMinAddress().getOffset()));
				toks.add(to);
			}
		}
		pc.add("tokens", toks);
		j.add("pseudocode", pc);

		JsonObject tm = new JsonObject();
		tm.addProperty("decompile_us", (t2 - t1) / 1000);
		tm.addProperty("script_total_us", (System.nanoTime() - t0) / 1000);
		j.add("timing", tm);
		di.dispose();
		write(out, j);
	}

	JsonObject vjson(VarnodeAST v) {
		JsonObject o = vnode(v);
		o.addProperty("id", "vn:" + v.getUniqueId());
		o.add("def", v.getDef() == null ? JsonNull.INSTANCE : new JsonPrimitive("op:" + v.getDef().getSeqnum().getTime()));
		HighVariable h = v.getHigh();
		if (h != null) {
			o.addProperty("high_name", h.getName());
			o.addProperty("type", h.getDataType() == null ? "" : h.getDataType().getDisplayName());
		}
		return o;
	}

	static <T> Iterable<T> iter(Iterator<T> i) { return () -> i; }

	void write(String path, JsonObject j) throws Exception {
		Gson g = new GsonBuilder().serializeNulls().disableHtmlEscaping().create();
		try (Writer w = new FileWriter(path)) { g.toJson(j, w); }
	}
}
