
use Config qw/ myconfig /;
use Data::Dumper;
use English qw/ -no_match_vars /;
use Test::More tests => 11;

use lib 'lib';

ok( -d 'bin', 'bin directory' ) or die 'could not find bin directory';

my $this_perl = $Config{'perlpath'} || $EXECUTABLE_NAME;

ok( $this_perl, "this_perl: $this_perl" );

if ($OSNAME ne 'VMS' && $Config{_exe} ) {
    $this_perl .= $Config{_exe}
        unless $this_perl =~ m/$Config{_exe}$/i;
}

my @bins = <bin/*>;
foreach ( @bins ) {
    my $cmd = "$this_perl -c $_";
    my $r = system "$cmd 2>/dev/null >/dev/null";
    ok( $r == 0, "syntax $_");
};

