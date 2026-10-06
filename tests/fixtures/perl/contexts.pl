use strict;
use warnings;
no warnings 'recursion';
use feature 'try';
use DynaLoader ();
$| = 1;
my ($mode, $library) = @ARGV;
my $lib = DynaLoader::dl_load_file($library, 0) or die DynaLoader::dl_error();
my $boot = DynaLoader::dl_find_symbol($lib, 'boot_XodbFixture') or die DynaLoader::dl_error();
DynaLoader::dl_install_xsub('XodbFixture::bootstrap', $boot, $library)->();
sub probe {
    my ($integer, $number, $string) = (42, 3.25, "demo");
    my @array = (1, 2); my %hash = (answer => 42);
    XodbFixture::inspect($integer, $number, $string, \$integer, \@array, \%hash, \&probe, \*STDOUT);
}
sub descend { my ($n) = @_; if ($n) { descend($n-1) } else { probe() } }
sub pp_leaf { getppid(); }
print "ready\n"; scalar <STDIN>;
if ($mode eq 'ppentry') { pp_leaf(); }
elsif ($mode eq 'xsentry') { XodbFixture::callback(sub { pp_leaf(); }); }
elsif ($mode eq 'deep300') { descend(300); }
elsif ($mode eq 'deep5000') { descend(5000); }
elsif ($mode eq 'evalblock') { eval { probe(); 1 } or die $@; }
elsif ($mode eq 'evalstring') { eval 'probe(); 1' or die $@; }
elsif ($mode eq 'try') { try { probe(); } catch ($error) { die $error; } }
elsif ($mode eq 'thread') { require threads; threads->create(sub { probe() })->join(); }
else { die "unknown context fixture mode"; }
