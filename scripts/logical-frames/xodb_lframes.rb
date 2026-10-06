# Cooperating in-process CRuby exporter for xodb.logical-frames v1, draft C05-1.
#
# This is COOPERATING INSTRUMENTATION: the observed program loads this file
# and runs a sampler thread inside its own VM. With the owned C extension
# (tests/logical-frames/ext/xodb_lframes_rb.c) stacks come from the public
# rb_profile_thread_frames() API, which distinguishes iseq frames from C
# methods. Without it, Thread#backtrace_locations is used and frame kinds are
# "unclassified" because that API reports C methods with the caller's path and
# line. Threads are read one after another while the sampler holds the GVL, so
# different threads' stacks are acquired at different moments; each stack has
# its own [start_ns, end_ns]. Ruby frames never carry native PCs.
require "digest"
require "json"

class XodbLFramesExporter
  FORMAT = "xodb.logical-frames"
  DRAFT = "C05-1"
  PRODUCER = "xodb-lframes-cruby"
  PRODUCER_VERSION = "1"

  attr_reader :method_name

  def self.file_sha256(path)
    d = Digest::SHA256.new
    n = 0
    File.open(path, "rb") do |f|
      while (b = f.read(1 << 20))
        n += b.bytesize
        raise IOError, "file exceeds hashing limit" if n > (1 << 30)
        d.update(b)
      end
    end
    [d.hexdigest, n]
  end

  # NT_GNU_BUILD_ID of a 64-bit little-endian ELF file, or nil.
  def self.gnu_build_id(path)
    File.open(path, "rb") do |f|
      ident = f.read(64)
      return nil unless ident && ident.bytesize == 64 && ident[0, 4] == "\x7fELF".b && ident.getbyte(4) == 2 && ident.getbyte(5) == 1
      phoff = ident[32, 8].unpack1("Q<")
      phentsize, phnum = ident[54, 4].unpack("S<S<")
      [phnum, 256].min.times do |i|
        f.seek(phoff + i * phentsize)
        ph = f.read(56)
        next unless ph[0, 4].unpack1("L<") == 4
        f.seek(ph[8, 8].unpack1("Q<"))
        notes = f.read([ph[32, 8].unpack1("Q<"), 1 << 16].min) || "".b
        at = 0
        while at + 12 <= notes.bytesize
          namesz, descsz, kind = notes[at, 12].unpack("L<L<L<")
          name_at = at + 12
          desc_at = name_at + ((namesz + 3) & ~3)
          return notes[desc_at, descsz].unpack1("H*") if kind == 3 && notes[name_at, namesz] == "GNU\0".b
          at = desc_at + ((descsz + 3) & ~3)
        end
      end
    end
    nil
  rescue SystemCallError, IOError
    nil
  end

  def self.image_identity(path)
    return nil unless path
    sha, = file_sha256(path)
    { "path" => path, "sha256" => sha, "gnu_build_id" => gnu_build_id(path) }
  rescue SystemCallError, IOError => e
    { "path" => path, "sha256" => nil, "gnu_build_id" => nil, "unavailable" => "unreadable: #{e.message}" }
  end

  def initialize(path, interval_s: 0.005, max_depth: 512, extension: nil)
    @path = path
    @interval_ns = (interval_s * 1e9).to_i
    @max_depth = max_depth
    @use_ext = false
    if extension
      require extension
      @use_ext = true
    end
    @method_name = @use_ext ? "rb_profile_thread_frames" : "Thread#backtrace_locations"
    @lock = Mutex.new
    @out = File.open(path, "w:UTF-8")
    @records = 0
    @seq = 0
    @stacks = 0
    @codes = {}
    @functions = {}
    @threads = {}
    @cost_ns = 0
    @lost_ticks = 0
    @skipped = 0
    @stop = false
    header
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)

  def utf8(s)
    return nil if s.nil?
    s = s.to_s.dup.force_encoding(Encoding::UTF_8)
    s.valid_encoding? ? s : s.scrub("�")
  end

  def write(record)
    @out.write(JSON.generate(record) << "\n")
    @records += 1
  end

  def header
    exe = File.realpath("/proc/self/exe")
    maps = File.readlines("/proc/self/maps").map { |l| l.split[5] }.compact.uniq
    library = maps.find { |p| File.basename(p).start_with?("libruby") }
    stat = File.read("/proc/self/stat")
    start_ticks = stat[(stat.rindex(")") + 2)..].split[19]
    boot_id = File.read("/proc/sys/kernel/random/boot_id").strip
    write({
      "type" => "header", "format" => FORMAT, "version" => 1, "draft" => DRAFT,
      "producer" => { "name" => PRODUCER, "version" => PRODUCER_VERSION, "kind" => "cooperating_in_process",
                      "sha256" => self.class.file_sha256(__FILE__)[0] },
      "source_kind" => "cooperative_sample",
      "runtime" => { "language" => "ruby", "implementation" => RUBY_ENGINE, "version" => RUBY_VERSION,
                     "build" => RUBY_DESCRIPTION, "executable" => self.class.image_identity(exe),
                     "library" => self.class.image_identity(library) },
      "process" => { "pid" => Process.pid, "start_ticks" => start_ticks, "boot_id" => boot_id },
      "clock" => { "domain" => "CLOCK_MONOTONIC", "unit" => "ns" },
      "command" => [exe, *ARGV.map { |a| utf8(a) }],
      "collection" => {
        "method" => "#{@method_name} per thread from a sampler thread; Exception#backtrace_locations; explicit emits",
        "trigger" => "timer thread (sleep); also exception and explicit",
        "interval_ns" => @interval_ns.to_s,
        "atomicity" => "per_thread_sequential",
        "notes" => "Each thread's stack is read separately while the sampler holds the GVL; acquisition moments " \
                   "differ between threads and are given per stack. The sampler thread is excluded. Exception " \
                   "stacks use backtrace_locations, which cannot distinguish C methods, so they are unclassified.",
      },
      "frame_order" => "innermost_first",
      "weight_unit" => "observation",
      "weight_semantics" => "one stack observation per thread per acquisition; not CPU time",
      "x_command_note" => "command is the executable followed by ARGV; the script path is $0=#{utf8($0)}",
      "x_mn_threads" => ENV["RUBY_MN_THREADS"],
    })
  end

  def code(path)
    return nil if path.nil?
    id = @codes[path]
    return id if id
    id = "c#{@codes.size + 1}"
    @codes[path] = id
    rec = { "type" => "code", "id" => id, "path" => utf8(path) }
    if path.start_with?("<internal:")
      rec.merge!("kind" => "builtin", "sha256" => nil, "bytes" => nil, "unavailable" => "VM built-in source")
    elsif path.start_with?("(eval") || path == "-e"
      rec.merge!("kind" => "generated", "sha256" => nil, "bytes" => nil, "unavailable" => "no file for #{utf8(path)}")
    else
      begin
        sha, size = self.class.file_sha256(path)
        rec.merge!("kind" => "source_file", "sha256" => sha, "bytes" => size, "x_hashed_at_ns" => now.to_s,
                   "x_identity_note" => "file content at first observation; not proof of loaded iseq")
      rescue SystemCallError, IOError => e
        rec.merge!("kind" => "unknown", "sha256" => nil, "bytes" => nil, "unavailable" => "unreadable: #{e.message}")
      end
    end
    write(rec)
    id
  end

  # kind: "interpreter", "native" or "unclassified"
  def function(kind, label, base, path, first_line)
    key = [kind, label, path, first_line]
    id = @functions[key]
    return id if id
    id = "f#{@functions.size + 1}"
    @functions[key] = id
    write({ "type" => "function", "id" => id, "name" => utf8(base || label), "qualified" => utf8(label),
            "code" => kind == "native" ? nil : code(path), "first_line" => first_line,
            "frame_kind" => kind, "runtime_id" => nil })
    id
  end

  def thread(t)
    native = t.native_thread_id rescue nil
    key = [t.object_id, native]
    id = @threads[key]
    return id if id
    id = "t#{@threads.size + 1}"
    @threads[key] = id
    rec = { "type" => "thread", "id" => id, "language_id" => "object_id:#{t.object_id}",
            "name" => utf8(t.name) }
    if ENV["RUBY_MN_THREADS"] == "1"
      rec.merge!("os_tid" => nil, "os_tid_reason" => "RUBY_MN_THREADS=1: native thread may change")
    elsif native
      comm = File.read("/proc/self/task/#{native}/comm").chomp rescue nil
      rec.merge!("os_tid" => native, "os_tid_source" => "Thread#native_thread_id", "x_os_comm" => comm)
    else
      rec.merge!("os_tid" => nil, "os_tid_reason" => "Thread#native_thread_id is nil (not started or exited)")
    end
    write(rec)
    id
  end

  def ext_frames(rows)
    rows.map do |kind, label, base, path, abs, first_line, line, _classpath|
      if kind == :cfunc
        { "function" => function("native", label, base, nil, nil), "kind" => "native", "line" => nil,
          "provenance" => "runtime", "reason" => "C method: no source line or PC exported" }
      else
        p = abs || path
        f = { "function" => function("interpreter", label, base, p, first_line), "kind" => "interpreter",
              "provenance" => "runtime" }
        if line && line > 0
          f["line"] = line
        else
          f["line"] = nil
          f["reason"] = "runtime reported line #{line.inspect}"
        end
        f
      end
    end
  end

  def location_frames(locations)
    locations.map do |l|
      p = l.absolute_path || l.path
      f = { "function" => function("unclassified", l.label, l.base_label, p, nil), "kind" => "unclassified",
            "provenance" => "runtime" }
      if l.lineno && l.lineno > 0
        f["line"] = l.lineno
      else
        f["line"] = nil
        f["reason"] = "runtime reported line #{l.lineno.inspect}"
      end
      f
    end
  end

  # Returns [frames, truncated]; nil if the thread has no frames.
  def read_thread(t, skip_self: false)
    if @use_ext
      rows = XodbLFrames.thread_frames(t, @max_depth + 8)
      if skip_self
        # Drop the leading exporter region: exporter iseq frames and the
        # runtime methods they called (thread_frames, Mutex#synchronize, which
        # is a C method in 3.4 and <internal:thread_sync> Ruby in 4.1).
        last = -1
        rows.each_with_index do |r, i|
          own = r[0] == :iseq && (r[4] || r[3]) == __FILE__
          builtin = r[0] == :iseq && r[3].to_s.start_with?("<internal:")
          break unless own || builtin || r[0] == :cfunc
          last = i if own
        end
        rows = rows[(last + 1)..]
      end
      truncated = rows.size > @max_depth
      [ext_frames(rows.first(@max_depth)), truncated]
    else
      locs = t.backtrace_locations(0, @max_depth + 8)
      return nil if locs.nil?
      locs.shift while skip_self && locs.any? && (locs[0].absolute_path || locs[0].path) == __FILE__
      truncated = locs.size > @max_depth
      [location_frames(locs.first(@max_depth)), truncated]
    end
  end

  def stack(seq, tid, start, finish, trigger, frames, truncated, exception = nil)
    @stacks += 1
    write({ "type" => "stack", "id" => "s#{@stacks}", "acquisition" => seq, "thread" => tid,
            "start_ns" => start.to_s, "end_ns" => finish.to_s, "trigger" => trigger, "weight" => "1",
            "state" => truncated ? "truncated" : "complete", "omitted" => nil,
            "reason" => truncated ? "max_depth #{@max_depth} reached; omitted count not collected" : nil,
            "exception" => exception, "frames" => frames })
  end

  def sample
    @lock.synchronize do
      acq_start = now
      items = []
      Thread.list.each do |t|
        next if t == @sampler || !t.alive?
        s = now
        r = read_thread(t)
        e = now
        if r.nil? || r[0].empty?
          @skipped += 1
          next
        end
        items << [t, s, e, r]
      end
      acq_end = now
      @seq += 1
      write({ "type" => "acquisition", "seq" => @seq, "start_ns" => acq_start.to_s, "end_ns" => acq_end.to_s,
              "stacks" => items.size })
      items.each { |t, s, e, (frames, truncated)| stack(@seq, thread(t), s, e, "timer", frames, truncated) }
      @cost_ns += acq_end - acq_start
    end
  end

  def emit_here(trigger = "explicit")
    @lock.synchronize do
      s = now
      frames, truncated = read_thread(Thread.current, skip_self: true)
      e = now
      @seq += 1
      write({ "type" => "acquisition", "seq" => @seq, "start_ns" => s.to_s, "end_ns" => e.to_s, "stacks" => 1 })
      stack(@seq, thread(Thread.current), s, e, trigger, frames, truncated)
    end
  end

  def emit_exception(exc)
    @lock.synchronize do
      s = now
      locs = exc.backtrace_locations || []
      frames = location_frames(locs.first(@max_depth))
      e = now
      @seq += 1
      write({ "type" => "acquisition", "seq" => @seq, "start_ns" => s.to_s, "end_ns" => e.to_s, "stacks" => 1 })
      stack(@seq, thread(Thread.current), s, e, "exception", frames, locs.size > @max_depth,
            { "type" => exc.class.name, "message" => utf8(exc.message)[0, 512] })
    end
  end

  def start
    @sampler = Thread.new do
      next_tick = now + @interval_ns
      until @stop
        delay = next_tick - now
        sleep(delay / 1e9) if delay > 0
        break if @stop
        sample
        t = now
        next_tick += @interval_ns
        missed = t > next_tick ? (t - next_tick) / @interval_ns : 0
        if missed > 0
          next_tick += missed * @interval_ns
          @lost_ticks += missed
          @lock.synchronize do
            write({ "type" => "loss", "reason" => "timer_overrun", "count" => missed.to_s, "acquisition" => @seq })
          end
        end
      end
    end
    @sampler.name = "xodb-lframes-sampler"
  end

  def stop(status = "complete")
    @stop = true
    @sampler&.join
    @lock.synchronize do
      write({ "type" => "end", "records" => @records, "acquisitions" => @seq, "stacks" => @stacks, "status" => status })
      @out.close
    end
    { "acquisitions" => @seq, "stacks" => @stacks, "records" => @records, "sampling_cost_ns" => @cost_ns,
      "lost_ticks" => @lost_ticks, "threads_skipped_empty" => @skipped, "method" => @method_name }
  end
end
