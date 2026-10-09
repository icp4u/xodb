use strict;
use warnings;
use PadWalker ();
use DynaLoader ();
use Hash::Util ();
$|=1;
our $lib=DynaLoader::dl_load_file($ARGV[0],0) or die DynaLoader::dl_error();
our $boot=DynaLoader::dl_find_symbol($lib,'boot_XodbPaths') or die DynaLoader::dl_error();
DynaLoader::dl_install_xsub('XodbPaths::bootstrap',$boot,$ARGV[0])->();
our $magic_calls=0;
{ package OwnedTie;
  sub TIEHASH {bless {},shift} sub TIEARRAY {bless {},shift}
  sub FETCH {++$main::magic_calls;die 'FETCH must not run'}
  sub FETCHSIZE {++$main::magic_calls;die 'FETCHSIZE must not run'}
}
{ package OwnedObject; use overload '%{}'=>sub {++$main::magic_calls;die 'overload must not run'},fallback=>1; }
print "ready\n";scalar <STDIN>;
sub watched {
    my $root={player=>{score=>7,text=>'a'x220},list=>[10,20]};
    my $x=7;
    my %hash=(score=>7,''=>31,'a b'=>32);
    my @array=(40,41);
    my %tied_hash;tie %tied_hash,'OwnedTie';
    my @tied_array;tie @tied_array,'OwnedTie';
    my $object=bless {score=>99},'OwnedObject';
    my %restricted=(score=>17);Hash::Util::lock_keys(%restricted);
    my %large=map {("key$_",$_)} 0..599;
    my $hole=[1,2,3];delete $hole->[1];
    my $label='initial';
    for my $phase (0..6) {
        if($phase==1) {$label='replaced';$root={player=>{score=>8,text=>'a'x219 .'b'},list=>[10,21]};$hash{score}=8;$x=8;$array[1]=42;}
        if($phase==2) {$label='equal';}
        if($phase==3) {$label='missing';delete $root->{player}{score};}
        if($phase==4) {$label='recovered';$root->{player}{score}=8;}
        if($phase==5) {$label='container_replaced';$root->{player}={score=>9,text=>'last'};}
        if($phase==6) {$label='array_shrunk';pop @{$root->{list}};}
        my @rows=(
            ['$root->{player}{score}','$root',$phase==3?undef:\$root->{player}{score},$phase==3?'PerlPathKeyNotFound':''],
            ['$root->{player}{text}','$root',\$root->{player}{text},''],
            ['$root->{list}[1]','$root',$phase==6?undef:\$root->{list}[1],$phase==6?'PerlPathIndexOutOfRange':''],
            ['$hash{score}','%hash',\$hash{score},''],
            ['$hash{""}','%hash',\$hash{''},''],
            ['$hash{"a b"}','%hash',\$hash{'a b'},''],
            ['$array[1]','@array',\$array[1],''],
            ['$root->{absent}','$root',undef,'PerlPathKeyNotFound'],
            ['$tied_hash{x}','%tied_hash',undef,'PerlPathMagicOrObjectUnsupported'],
            ['$tied_array[0]','@tied_array',undef,'PerlPathMagicOrObjectUnsupported'],
            ['$object->{score}','$object',undef,'PerlPathMagicOrObjectUnsupported'],
            ['$restricted{missing}','%restricted',undef,'PerlPathRestrictedHashUnsupported'],
            ['$large{key1}','%large',undef,'PerlPathHashLimit'],
            ['$hole->[1]','$hole',undef,'PerlPathArrayHole'],
        );
        XodbPaths::snapshot($label,PadWalker::peek_my(0),\@rows);
    }
    die 'magic was invoked' if $magic_calls;
}
watched();
print "done magic=$magic_calls\n";
