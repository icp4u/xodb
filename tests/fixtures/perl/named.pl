use strict;
use warnings;
use feature 'state';
use PadWalker ();
use DynaLoader ();
use JSON::PP ();
use Scalar::Util ();
use B ();
$| = 1;
our $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
our $boot = DynaLoader::dl_find_symbol($lib, 'boot_XodbNamed') or die DynaLoader::dl_error();
DynaLoader::dl_install_xsub('XodbNamed::bootstrap', $boot, $ARGV[0])->();
if ($ENV{XODB_PERL_NAMED_READY}) { print "ready\n"; scalar <STDIN>; }
sub capture {
    my @frames;
    for (my $level = 1; $level < 16; ++$level) {
        my $vars = eval { PadWalker::peek_my($level) };
        last if $@;
        push @frames, $vars;
    }
    if ($ENV{XODB_PERL_NAMED_EXPORT}) {
        my @out;
        for my $vars (@frames) {
            my @rows;
            for my $name (sort keys %$vars) {
                my $ref = $vars->{$name};
                my $kind = Scalar::Util::reftype($ref);
                my $display;
                if ($kind eq 'ARRAY') { $display = 'AV ('.scalar(@$ref).' slots)'; }
                elsif ($kind eq 'HASH') { $display = 'HV ('.scalar(keys %$ref).' entries)'; }
                elsif ($kind eq 'SCALAR' || $kind eq 'REF') {
                    my $flags = B::svref_2object($ref)->FLAGS;
                    if ($flags & B::SVf_ROK()) { } # pointer identity is compared separately
                    elsif ($flags & B::SVf_POK()) {
                        $display = 'PV "'.join('', map { $_ >= 32 && $_ < 127 && $_ != 34 && $_ != 92 ? chr($_) : sprintf('\\x%02x', $_) } unpack('C*', $$ref)).'"';
                    }
                    elsif ($flags & B::SVf_IOK()) { $display = 'IV '.$$ref; }
                    elsif ($flags & B::SVf_NOK()) { $display = 'NV '.sprintf('%.17g', $$ref); }
                    else { $display = 'undef'; }
                }
                push @rows, {name => $name, address => Scalar::Util::refaddr($ref), display => $display};
            }
            push @out, {bindings => \@rows};
        }
        print JSON::PP::encode_json({frames => \@out})."\n";
    }
    return \@frames;
}
sub recurse {
    my ($n) = @_;
    my $shadow = $n;
    state $retained = 73;
    my @array = (4,5,6); my %hash = (answer => 42);
    my $text = "owned\x00bytes"; my $empty;
    {
        my $shadow = $n + 100;
        if ($n) { recurse($n-1) }
        else { XodbNamed::snapshot(capture()); }
    }
}
recurse(3);
sub make_closure {
    my $closed = 321;
    return sub { my ($argument) = @_; XodbNamed::snapshot(capture()); return $closed + $argument; };
}
our $closure = make_closure(); $closure->(17);
sub expired {
    { my $expired = 99; }
    my $active = 21;
    XodbNamed::snapshot(capture());
}
expired();
sub package_shadow {
    my $masked = 17;
    { our $masked = 44; my $active = 9; XodbNamed::snapshot(capture()); }
    XodbNamed::snapshot(capture());
}
package_shadow();
sub alias_loop {
    my @values = (51,52);
    for my $entry (@values) { XodbNamed::snapshot(capture()); }
}
alias_loop();
# A generated owned lexical scope exercises pagination without repetitive source.
our $many = eval 'sub { '.join('; ',map { 'my $v'.$_.' = '.$_ } 0..42).'; XodbNamed::snapshot(capture()); }';
die $@ if $@; $many->();
{ my $main_local = 29; XodbNamed::snapshot(capture()); }
XodbNamed::finished();
