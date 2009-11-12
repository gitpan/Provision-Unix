
use Test::More tests => 10;

use lib "lib";

ok( -d 'bin', 'bin directory' ) or die 'could not find bin directory';
my $perl = `which perl`; chomp $perl;

my @bins = <bin/*>;
foreach ( @bins ) {
    my $cmd = "$perl -c $_";
    my $r = system "$cmd 2>/dev/null >/dev/null";
    ok( $r == 0, "syntax $_");
};

