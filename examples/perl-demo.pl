#!/usr/bin/perl
# Demo workload for scripts/demo-perl: nested subs that keep re-storing an element.
use strict;
use warnings;

$| = 1;

sub store_answer {
    my ($list, $value) = @_;
    delete $list->[3];
    $list->[3] = $value;
}

sub tick {
    my ($list, $round) = @_;
    store_answer($list, 42);
}

my @a = (0) x 4;
print "$$\n";
for (my $round = 0; ; $round++) {
    tick(\@a, $round);
}
