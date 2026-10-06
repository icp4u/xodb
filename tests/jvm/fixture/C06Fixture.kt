// xodb C06 Kotlin/JVM frame-import fixture. Owned, self-contained workload.
// Nested calls, a lambda, an inline function, worker/deep/virtual threads, a
// deliberately caught exception, a Unicode/space method name and coroutine
// suspension. Usage: C06Fixture SECONDS READY_FILE [PROBE_DUMP_FILE]
@file:JvmName("C06Fixture")
package xodb.c06

import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineName
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield

val running = AtomicBoolean(true)
val sink = AtomicLong()
val caught = AtomicLong()

fun mix(v: Long, i: Int): Long {
    var h = v
    repeat(256) { h = h * 6364136223846793005L + i + it; h = h xor (h ushr 29) }
    return h
}

class Pipeline(private val scale: Int) {
    fun outer(seed: Long): Long = middle(seed xor 0x5DEECE66DL) + 1

    private fun middle(x: Long): Long {
        var acc = x
        for (i in 0 until scale) acc = inner(acc, i)
        return acc
    }

    private fun inner(x: Long, i: Int): Long {
        val step: (Long) -> Long = { v -> mix(v, i) }
        return listOf(x, x + 1, x + 2).map(step).fold(0L) { a, b -> a xor b }
    }
}

inline fun <T> measured(block: () -> T): T {
    val result = block()
    sink.incrementAndGet()
    return result
}

fun `ünïcode spin – odd name`(n: Int): Long {
    var h = 0L
    for (i in 0 until n) h = mix(h, i)
    return h
}

fun thrower(depth: Int): Int =
    if (depth == 0) throw IllegalStateException("c06 deliberate failure") else thrower(depth - 1) + 1

fun catcher(): Int =
    try {
        thrower(8)
    } catch (e: IllegalStateException) {
        caught.incrementAndGet()
        -1
    }

fun deep(n: Int): Long = if (n == 0) mix(n.toLong(), 7) else deep(n - 1) + 1

suspend fun suspendingWork(round: Int): Long {
    val value = withContext(Dispatchers.Default) { mix(round.toLong(), round) }
    delay(2)
    yield()
    return value
}

fun workerLoop() {
    var seed = 1L
    var round = 0
    while (running.get()) {
        sink.addAndGet(measured { Pipeline(4).outer(seed++) })
        if (++round % 1000 == 0) catcher()
    }
}

fun main(args: Array<String>) {
    val seconds = args.getOrNull(0)?.toLongOrNull() ?: 6L
    val ready = args.getOrNull(1)
    val probeDump = args.getOrNull(2)
    val threads = ArrayList<Thread>()
    threads += Thread({ workerLoop() }, "c06-worker")
    threads += Thread({ while (running.get()) sink.addAndGet(deep(200)) }, "c06-deep")
    threads += Thread({
        runBlocking(CoroutineName("c06-root")) {
            launch(Dispatchers.Default + CoroutineName("c06-parent")) {
                launch(CoroutineName("c06-child")) {
                    var round = 0
                    while (running.get()) sink.addAndGet(suspendingWork(round++))
                }
                while (running.get()) delay(20)
            }
        }
    }, "c06-coroutines")
    threads += Thread({ while (running.get()) Thread.sleep(5) }, "c06 \"odd\" \\ ü thread")
    for (t in threads) t.start()
    val virtual = Thread.ofVirtual().name("c06-virtual").start {
        while (running.get()) {
            sink.addAndGet(`ünïcode spin – odd name`(400))
            Thread.sleep(1)
        }
    }
    if (ready != null) File(ready).writeText("${ProcessHandle.current().pid()}\n")
    Thread.sleep(seconds * 500)
    if (probeDump != null) ProbeDump.dump(probeDump)
    Thread.sleep(seconds * 500)
    running.set(false)
    for (t in threads) t.join()
    virtual.join()
    println("c06 done sink=${sink.get()} caught=${caught.get()}")
}
