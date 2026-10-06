use strict;
use warnings;
use Config ();
use List::Util ();
require './scripts/logical-frames/xodb_lframes.pl';
my ($mode, $path) = @ARGV;
sub leaf { XodbLFrames::emit($path); }
sub recurse { my ($n)=@_; $n ? recurse($n-1) : leaf(); }
if ($mode eq 'recursive') { recurse(4); }
elsif ($mode eq 'eval') { eval { leaf(); die "owned fixture exception\n" }; die 'exception missing' unless $@; }
elsif ($mode eq 'truncated') { XodbLFrames::emit($path, max_depth => 1); }
elsif ($mode eq 'thread') { require threads; threads->create(sub { leaf(); })->join(); }
elsif ($mode eq 'xs') { List::Util::reduce { leaf(); $a + $b } 1,2; }
elsif ($mode eq 'invalid-depth') { XodbLFrames::emit($path, max_depth => 0); }
else { die 'unknown fixture mode'; }
