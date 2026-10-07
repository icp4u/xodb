use strict;
use warnings;
use DynaLoader ();
$| = 1;
my ($mode, $library, $export, $exporter) = @ARGV;
$exporter //= './scripts/logical-frames/xodb_lframes.pl';
require $exporter;
if ($mode ne 'array') {
    my $lib = DynaLoader::dl_load_file($library, 0) or die DynaLoader::dl_error();
    my $boot = DynaLoader::dl_find_symbol($lib, 'boot_XodbFixture') or die DynaLoader::dl_error();
    my $call = DynaLoader::dl_install_xsub('XodbFixture::bootstrap', $boot, $library);
    $call->();
}
sub ready { print "ready\n"; scalar <STDIN>; }
# Export and native stop intentionally share a source line for exact location comparison.
sub array_leaf { my @a=(0)x4; XodbLFrames::emit($export); ready(); delete $a[3]; $a[3]=42; }
sub descend { my ($n)=@_; if ($n) { descend($n-1) } else { array_leaf() } }
sub value_leaf {
    my ($integer, $number, $string) = (42, 3.25, "hello\x00bytes");
    my @array = (0, 1, 2, 42); my %hash = (answer => 42, label => 'demo');
    my $object = bless \%hash, 'Fixture::Nested::Widget';
    XodbLFrames::emit($export); ready(); XodbFixture::inspect($integer,$number,$string,$object,\@array,\%hash,\&value_leaf,\*Fixture::Nested::Widget::entry);
}
sub inside { value_leaf(); }
if ($mode eq 'array') { descend(4); }
elsif ($mode eq 'values') { value_leaf(); }
elsif ($mode eq 'reenter') { XodbFixture::reenter(); }
elsif ($mode eq 'embed') { XodbFixture::embed($0, $library, $export); }
else { die "unknown fixture mode"; }
