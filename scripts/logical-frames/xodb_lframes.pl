# Cooperating, explicit Perl stack export. This runs inside the program;
# the stopped-interpreter reader is a separate, memory-only facility.
# require './scripts/logical-frames/xodb_lframes.pl'; XodbLFrames::emit('stack.jsonl');
package XodbLFrames;
use strict;
use warnings;
use B ();
use Config ();
use Digest::SHA ();
use Encode ();
use Fcntl qw(O_CREAT O_EXCL O_WRONLY O_RDONLY O_NONBLOCK S_ISREG);
use JSON::PP ();
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

sub text {
    my ($value, $limit) = @_;
    return undef unless defined $value;
    $value = Encode::decode('UTF-8', $value, Encode::FB_CROAK) unless utf8::is_utf8($value);
    die 'embedded NUL in exported identity' if $value =~ /\x00/;
    die 'exported identity exceeds string limit' if length($value) > ($limit // 1024);
    return $value;
}
sub now { return sprintf('%.0f', clock_gettime(CLOCK_MONOTONIC) * 1e9); }
sub contents {
    my ($path, $limit) = @_;
    sysopen(my $fh, $path, O_RDONLY | O_NONBLOCK) or return undef;
    my @stat = stat($fh);
    return undef unless @stat && S_ISREG($stat[2]);
    my $out = '';
    while (1) {
        my $n = sysread($fh, my $part, 8192);
        return undef unless defined $n;
        last unless $n;
        return undef if length($out) + $n > $limit;
        $out .= $part;
    }
    close($fh) or return undef;
    return $out;
}
sub identity {
    my ($path) = @_;
    my $data = defined($path) ? contents($path, 16 * 1024 * 1024) : undef;
    return { path => text($path), sha256 => defined($data) ? Digest::SHA::sha256_hex($data) : undef,
             gnu_build_id => undef, unavailable => 'image build-id not exported; file digest is from this acquisition, not loaded-byte proof' };
}
sub frame_kind {
    local $@;
    my ($name) = @_;
    return 'interpreter' if $name eq '(eval)' || $name eq 'main';
    # caller() includes XS callers too. Only classify a native function when
    # B confirms an XSUB; an anonymous/unresolved caller stays unclassified.
    return 'unclassified' if $name =~ /__ANON__/;
    no strict 'refs';
    my $cv = *{$name}{CODE};
    return 'unclassified' unless $cv;
    my $xsub = eval { B::svref_2object($cv)->XSUB };
    return $@ ? 'unclassified' : $xsub ? 'native' : 'interpreter';
}

sub emit {
    local $@;
    my ($path, %options) = @_;
    die 'emit requires an output path' unless defined($path) && length($path);
    my $max = $options{max_depth} // 128;
    die 'max_depth must be between 1 and 256' unless $max =~ /^\d+$/ && $max >= 1 && $max <= 256;
    my $start = now();
    my (@frames, @codes, @functions);
    my %source;
    my $previous = [caller(0)];
    my $truncated = 0;
    for (my $depth = 1; @$previous; ++$depth) {
        if (@frames == $max) { $truncated = 1; last; }
        my @call = caller($depth);
        my $name = @call ? ($call[3] // '(anonymous)') : 'main';
        my $file = $previous->[1];
        my $line = $previous->[2];
        my $kind = frame_kind($name);
        my $id = scalar(@frames) + 1;
        my $key = $file // '';
        unless (exists $source{$key}) {
            my $bytes = defined($file) && $file ne '-e' && $file !~ /^\(eval/ ? contents($file, 1024 * 1024) : undef;
            $source{$key} = { sha256 => defined($bytes) ? Digest::SHA::sha256_hex($bytes) : undef,
                              bytes => defined($bytes) ? length($bytes) : undef };
        }
        my $info = $source{$key};
        push @codes, {type => 'code', id => "c$id", kind => defined($info->{sha256}) ? 'source_file' : 'unknown',
            path => text($file), sha256 => $info->{sha256}, bytes => $info->{bytes},
            unavailable => 'source bytes at emission are not proof of compiled code identity'};
        push @functions, {type => 'function', id => "f$id", name => text($name, 256), qualified => text($name, 256),
            code => "c$id", first_line => undef, frame_kind => $kind, runtime_id => undef};
        push @frames, {function => "f$id", kind => $kind, line => $kind eq 'native' ? undef : $line,
            provenance => 'runtime', x_file => text($file),
            x_context_type => $name eq '(eval)' ? 'eval' : @call ? 'sub' : 'main',
            reason => $kind eq 'native' ? 'B confirms XSUB; caller supplies no native PC' :
                      $kind eq 'unclassified' ? 'caller function kind could not be established' : undef};
        last unless @call;
        $previous = \@call;
    }
    my $end = now();
    my $stat = contents('/proc/self/stat', 8192) // '';
    $stat =~ s/^.*\) //;
    my @stat = split /\s+/, $stat;
    my $ticks = $stat[19];
    my $boot = contents('/proc/sys/kernel/random/boot_id', 128);
    $boot =~ s/\s+$// if defined $boot;
    my $thread = readlink('/proc/thread-self') // '';
    my ($tid) = $thread =~ m{/task/(\d+)$};
    my $exe = readlink('/proc/self/exe');
    my $library = "$Config::Config{archlib}/CORE/$Config::Config{libperl}";
    my $producer = contents(__FILE__, 1024 * 1024);
    my @records = ({type => 'header', format => 'xodb.logical-frames', version => 1, draft => 'C05-1',
        producer => {name => 'xodb-lframes-perl', version => '1', kind => 'cooperating_in_process',
                     sha256 => defined($producer) ? Digest::SHA::sha256_hex($producer) : undef},
        source_kind => 'cooperative_emit',
        runtime => {language => 'perl', implementation => 'perl5', version => sprintf('%vd', $^V),
            build => $Config::Config{archname}, executable => identity($exe), library => identity($library)},
        process => {pid => 0 + $$, start_ticks => defined($ticks) ? "$ticks" : undef,
            boot_id => $boot, unavailable => 'process identity fields unavailable when procfs cannot be read'},
        clock => {domain => 'CLOCK_MONOTONIC', unit => 'ns'}, command => undef,
        collection => {method => 'caller and B::CV::XSUB, current thread only', trigger => 'explicit call',
            interval_ns => undef, atomicity => 'single_thread',
            notes => 'Exporter frames excluded; complete describes the caller chain only, which can omit XS/native frames; line is the active call site; time is rounded from Time::HiRes double seconds; no async sampling or CPU-time claim'},
        frame_order => 'innermost_first', weight_unit => 'observation', weight_semantics => 'one explicit stack observation; not CPU time'},
        @codes, @functions,
        {type => 'thread', id => 't1', language_id => undef, name => undef,
            os_tid => defined($tid) ? 0 + $tid : undef,
            defined($tid) ? (os_tid_source => '/proc/thread-self') : (os_tid_reason => 'procfs thread identity unavailable')},
        {type => 'acquisition', seq => 1, start_ns => $start, end_ns => $end, stacks => 1},
        {type => 'stack', id => 's1', acquisition => 1, thread => 't1', start_ns => $start, end_ns => $end,
            trigger => 'explicit call', weight => '1', state => $truncated ? 'truncated' : 'complete',
            omitted => $truncated ? undef : '0', reason => $truncated ? 'max_depth reached' : undef, frames => \@frames});
    push @records, {type => 'end', records => scalar(@records), acquisitions => 1, stacks => 1, status => 'complete'};
    my $json = JSON::PP->new->utf8->canonical;
    my $tmp = "$path.tmp.$$";
    sysopen(my $out, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0644) or die "create export: $!";
    my $ok = eval {
        for my $record (@records) { print {$out} $json->encode($record), "\n" or die "write export: $!"; }
        close($out) or die "close export: $!";
        # Publish without overwriting; a reader never sees a partial document.
        link($tmp, $path) or die "publish export: $!";
        1;
    };
    my $error = $@;
    close($out) if defined(fileno($out));
    unlink($tmp);
    die $error unless $ok;
    return scalar @frames;
}
1;
