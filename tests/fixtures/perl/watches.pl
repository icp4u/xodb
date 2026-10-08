use strict;
use warnings;
use utf8;
use PadWalker ();
use DynaLoader ();
use Scalar::Util ();
$| = 1;
our $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
our $boot = DynaLoader::dl_find_symbol($lib, 'boot_XodbWatch') or die DynaLoader::dl_error();
DynaLoader::dl_install_xsub('XodbWatch::bootstrap', $boot, $ARGV[0])->();
print "ready\n"; scalar <STDIN>;
sub capture {
    my @frames;
    for (my $level = 1; $level < 128; ++$level) {
        my $vars = eval { PadWalker::peek_my($level) };
        last if $@;
        push @frames, $vars;
    }
    return \@frames;
}
our $magic_reads = 0;
{ package OwnedTie;
  sub TIESCALAR { bless {}, shift }
  sub FETCH { ++$main::magic_reads; 77 }
  sub STORE { }
}
sub grow {
    my ($depth) = @_;
    if ($depth) { grow($depth-1); }
    else { XodbWatch::snapshot('deep',capture()); }
}
sub watched {
    my $x = 7;
    my $élan = 17;
    my $dual = Scalar::Util::dualvar(1,'same');
    my $word = 'a' x 200;
    my $number = 3.25;
    my $empty;
    my $reference = [1,2];
    tie my $tied, 'OwnedTie';
    XodbWatch::snapshot('initial',capture());
    $x = 8; $élan = 18; $dual = Scalar::Util::dualvar(2,'same'); substr($word,199,1) = 'b';
    XodbWatch::snapshot('changed',capture());
    XodbWatch::snapshot('equal',capture());
    { my $x = 900; XodbWatch::snapshot('shadow',capture()); }
    XodbWatch::snapshot('outer',capture());
    $number = -0.0; $empty = "a\x00b";
    XodbWatch::snapshot('typed',capture());
    $word = "\x{e4}"; utf8::downgrade($word);
    XodbWatch::snapshot('bytes',capture());
    utf8::upgrade($word);
    XodbWatch::snapshot('unicode',capture());
    $word = 'x' x 1025;
    XodbWatch::snapshot('limit',capture());
    $word = 'recovered';
    grow(88);
    XodbWatch::snapshot('unwound',capture());
    die 'magic invoked' if $magic_reads;
}
watched();
XodbWatch::snapshot('gone',capture());
watched();
print "done\n";
