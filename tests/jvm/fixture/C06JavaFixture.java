// xodb C06 Java-only fallback fixture: validates the JVM importer when no
// Kotlin compiler is available. Usage: C06JavaFixture SECONDS READY_FILE
package xodb.c06j;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.LongUnaryOperator;

public final class C06JavaFixture {
    static final AtomicBoolean running = new AtomicBoolean(true);
    static final AtomicLong sink = new AtomicLong();

    static long mix(long v, int i) {
        for (int k = 0; k < 256; k++) { v = v * 6364136223846793005L + i + k; v ^= v >>> 29; }
        return v;
    }

    static long outer(long seed) { return middle(seed) + 1; }
    static long middle(long x) { for (int i = 0; i < 4; i++) x = inner(x, i); return x; }
    static long inner(long x, int i) {
        LongUnaryOperator step = v -> mix(v, i);
        return step.applyAsLong(x) ^ step.applyAsLong(x + 1);
    }
    static int thrower(int d) { if (d == 0) throw new IllegalStateException("c06j"); return thrower(d - 1) + 1; }

    public static void main(String[] args) throws Exception {
        long seconds = args.length > 0 ? Long.parseLong(args[0]) : 4;
        Thread worker = new Thread(() -> {
            long seed = 1;
            int round = 0;
            while (running.get()) {
                sink.addAndGet(outer(seed++));
                if (++round % 1000 == 0) {
                    try { thrower(6); } catch (IllegalStateException e) { sink.incrementAndGet(); }
                }
            }
        }, "c06j-worker");
        worker.start();
        if (args.length > 1) Files.writeString(Path.of(args[1]), ProcessHandle.current().pid() + "\n");
        Thread.sleep(seconds * 1000);
        running.set(false);
        worker.join();
        System.out.println("c06j done " + sink.get());
    }
}
