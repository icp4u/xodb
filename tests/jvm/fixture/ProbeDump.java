// xodb C06: write kotlinx.coroutines debug-probe state as JSON. Requires the
// probes to be installed (java -javaagent:kotlinx-coroutines-core-jvm.jar).
// Parentage comes only from Job.getParent() of tracked coroutines; a parent
// that the probes do not track is reported as such, never synthesized.
package xodb.c06;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.IdentityHashMap;
import java.util.List;
import kotlin.coroutines.CoroutineContext;
import kotlinx.coroutines.CoroutineId;
import kotlinx.coroutines.CoroutineName;
import kotlinx.coroutines.Job;
import kotlinx.coroutines.debug.internal.DebugCoroutineInfo;
import kotlinx.coroutines.debug.internal.DebugProbesImpl;

public final class ProbeDump {
    private ProbeDump() {}

    private static void str(StringBuilder b, String s) {
        if (s == null) { b.append("null"); return; }
        b.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '"' || c == '\\') b.append('\\').append(c);
            else if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
            else b.append(c);
        }
        b.append('"');
    }

    private static void frames(StringBuilder b, List<StackTraceElement> list) {
        b.append('[');
        for (int i = 0; i < list.size(); i++) {
            if (i > 0) b.append(',');
            str(b, list.get(i).toString());
        }
        b.append(']');
    }

    public static void dump(String path) throws IOException {
        DebugProbesImpl probes = DebugProbesImpl.INSTANCE;
        StringBuilder b = new StringBuilder();
        Instant now = Instant.now();
        long nano = System.nanoTime();
        boolean installed = probes.isInstalled$kotlinx_coroutines_debug();
        b.append("{\"format\":\"xodb-c06-coroutine-probes\",\"version\":1");
        b.append(",\"pid\":").append(ProcessHandle.current().pid());
        b.append(",\"wall_time\":"); str(b, now.toString());
        b.append(",\"nano_time\":\"").append(Long.toUnsignedString(nano)).append('"');
        b.append(",\"nano_time_domain\":\"java.lang.System.nanoTime (process-local monotonic)\"");
        b.append(",\"probes_installed\":").append(installed);
        b.append(",\"runtime_version\":"); str(b, Runtime.version().toString());
        b.append(",\"coroutines\":[");
        if (installed) {
            List<DebugCoroutineInfo> infos = probes.dumpCoroutinesInfo();
            IdentityHashMap<Job, Long> bySequence = new IdentityHashMap<>();
            for (DebugCoroutineInfo info : infos) {
                Job job = info.getContext().get(Job.Key);
                if (job != null) bySequence.put(job, info.getSequenceNumber());
            }
            boolean first = true;
            for (DebugCoroutineInfo info : infos) {
                CoroutineContext ctx = info.getContext();
                if (!first) b.append(',');
                first = false;
                b.append("{\"sequence\":").append(info.getSequenceNumber());
                CoroutineId id = ctx.get(CoroutineId.Key);
                b.append(",\"coroutine_id\":").append(id == null ? "null" : Long.toString(id.getId()));
                CoroutineName name = ctx.get(CoroutineName.Key);
                b.append(",\"name\":"); str(b, name == null ? null : name.getName());
                b.append(",\"state\":"); str(b, info.getState());
                Job job = ctx.get(Job.Key);
                String relation;
                Long parentSequence = null;
                if (job == null) relation = "no_job_in_context";
                else {
                    Job parent = job.getParent();
                    if (parent == null) relation = "no_parent";
                    else {
                        parentSequence = bySequence.get(parent);
                        relation = parentSequence == null ? "parent_not_tracked" : "observed";
                    }
                }
                b.append(",\"parent_relation\":"); str(b, relation);
                b.append(",\"parent_sequence\":").append(parentSequence == null ? "null" : parentSequence.toString());
                Thread t = info.getLastObservedThread();
                if (t == null) b.append(",\"last_thread\":null");
                else {
                    b.append(",\"last_thread\":{\"name\":"); str(b, t.getName());
                    b.append(",\"java_thread_id\":").append(t.threadId());
                    b.append(",\"virtual\":").append(t.isVirtual()).append('}');
                }
                b.append(",\"last_observed_frames\":"); frames(b, info.lastObservedStackTrace());
                b.append(",\"creation_frames\":"); frames(b, info.getCreationStackTrace());
                b.append('}');
            }
        }
        b.append("]}\n");
        Files.writeString(Path.of(path), b.toString(), StandardCharsets.UTF_8);
    }
}
