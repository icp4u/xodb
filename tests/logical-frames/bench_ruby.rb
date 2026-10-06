# Fixed-work overhead benchmark: one worker computes fib(N) K times.
# usage: bench_ruby.rb OUT.jsonl INTERVAL_MS(0=no exporter) N K [EXT] -> prints JSON.
require "json"
require_relative "../../scripts/logical-frames/xodb_lframes"
out, interval, n, k, ext = ARGV[0], ARGV[1].to_f, ARGV[2].to_i, ARGV[3].to_i, ARGV[4]
def fib(x) = x < 2 ? x : fib(x - 1) + fib(x - 2)
def now(c = Process::CLOCK_MONOTONIC) = Process.clock_gettime(c, :nanosecond)
exporter = interval > 0 ? XodbLFramesExporter.new(out, interval_s: interval / 1000, extension: ext) : nil
exporter&.start
result = {}
p0 = now(Process::CLOCK_PROCESS_CPUTIME_ID)
Thread.new do
  Thread.current.name = "bench-worker"
  t0, c0 = now, now(Process::CLOCK_THREAD_CPUTIME_ID)
  k.times { fib(n) }
  result.merge!("wall_ns" => now - t0, "worker_cpu_ns" => now(Process::CLOCK_THREAD_CPUTIME_ID) - c0)
end.join
stats = exporter&.stop
puts JSON.generate(result.merge("process_cpu_ns" => now(Process::CLOCK_PROCESS_CPUTIME_ID) - p0, "interval_ms" => interval, "exporter" => stats))
