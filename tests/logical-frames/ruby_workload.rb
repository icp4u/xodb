# Owned CRuby workload for logical-frame export (draft C05-1).
# Threads: rb-fib (recursion), rb-nested (fixed nesting, blocks in sleep),
# rb-cfunc (blocks yielded from the owned C extension and from core C methods),
# rb-raiser (recursive raise, caught and exported).
# Usage: ruby_workload.rb OUT.jsonl META.json [seconds] [interval_ms] [--ext PATH] [--no-export]
require "json"
require_relative "../../scripts/logical-frames/xodb_lframes"

out_path, meta_path = ARGV[0], ARGV[1]
seconds = (ARGV[2] || "2").to_f
interval_ms = (ARGV[3] || "5").to_f
ext = ARGV.include?("--ext") ? ARGV[ARGV.index("--ext") + 1] : nil
export = !ARGV.include?("--no-export")
require ext if ext && !export
$exporter = export ? XodbLFramesExporter.new(out_path, interval_s: interval_ms / 1000.0, extension: ext) : nil
$stop = false
counts = {}

def fib(n) = n < 2 ? n : fib(n - 1) + fib(n - 2)

def nested_d = sleep(0.003)
def nested_c = nested_d
def nested_b = nested_c
def nested_a = nested_b

def raise_at_depth(depth)
  raise ArgumentError, "fixture failure at depth 0" if depth == 0
  raise_at_depth(depth - 1)
end

def block_work(i)
  spin = 0
  40.times { |k| spin += k }
  spin + i
end

def through_native(emit)
  if defined?(XodbNative)
    XodbNative.through_c(200) do |i|
      if emit && i == 0
        $exporter.emit_here("explicit")
      end
      block_work(i)
    end
  else
    200.times { |i| block_work(i) }
  end
  [5, 3, 9, 1].sort_by { |x| block_work(x) }
end

def explicit_leaf = $exporter&.emit_here("explicit")
def explicit_mid = explicit_leaf
def explicit_top = explicit_mid

workers = {
  "rb-fib" => -> { n = 0; until $stop; fib(16); n += 1; end; n },
  "rb-nested" => -> { n = 0; until $stop; nested_a; n += 1; end; n },
  "rb-cfunc" => lambda {
    n = 0
    until $stop
      through_native($exporter && n % 200 == 0)
      n += 1
    end
    n
  },
  "rb-raiser" => lambda {
    n = 0
    until $stop
      begin
        raise_at_depth(5)
      rescue ArgumentError => e
        $exporter&.emit_exception(e)
      end
      n += 1
      sleep 0.05
    end
    n
  },
}
started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
$exporter&.start
threads = workers.map do |name, body|
  # Name the thread before it runs: exporters capture the name at first observation.
  Thread.new { Thread.current.name = name; Thread.current[:result] = body.call }
end
sleep 0.01
native_ids = threads.to_h { |t| [t.name, t.native_thread_id] }
explicit_top
sleep seconds
$stop = true
threads.each { |t| counts[t.name] = (t.join; t[:result]) }
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - started
stats = $exporter&.stop
File.write(meta_path, JSON.pretty_generate({ "runtime" => RUBY_DESCRIPTION, "pid" => Process.pid, "seconds" => seconds,
                                             "interval_ms" => interval_ms, "export" => export, "extension" => ext,
                                             "elapsed_ns" => elapsed, "iterations" => counts, "exporter" => stats,
                                             "native_ids" => native_ids }))
