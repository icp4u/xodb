# The executable and runtime library are private copies supplied by the test.
use DynaLoader;
my ($decoy, $runtime, $mode) = @ARGV;
my $handle = DynaLoader::dl_load_file($decoy) or die DynaLoader::dl_error();
if ($mode eq 'deleted') {
    unlink($runtime) or die $!;
} elsif ($mode ne 'elf') {
    my %magic = (mz => '4d5a', other => '58585858', macho => 'cffaedfe');
    open(my $f, '+<', $runtime) or die $!;
    binmode($f); print $f pack('H*', $magic{$mode}); close($f) or die $!;
}
$| = 1;
print "{\"mode\":\"$mode\"}\n";
sub definer_checkpoint { my $held = 42; my $line = <STDIN>; return $held; }
definer_checkpoint();
