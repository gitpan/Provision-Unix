#!perl
use strict;
use warnings;

use Data::Dumper qw( Dumper );
use English qw( -no_match_vars );
use Test::More 'no_plan';

use lib "lib";

BEGIN {
    use_ok('Provision::Unix');
    use_ok('Provision::Unix::VirtualOS');
}

require_ok('Provision::Unix');
require_ok('Provision::Unix::VirtualOS');
require_ok('Provision::Unix::Utility');

# let the testing begin

my $prov = Provision::Unix->new( debug => 0 );

# basic OO mechanism
my $vos = Provision::Unix::VirtualOS->new( prov => $prov );
ok( defined $vos, 'get Provision::Unix::VirtualOS object' );
ok( $vos->isa('Provision::Unix::VirtualOS'), 'check object class' );

#warn Dumper ( $vos );

exit;

my $r = $vos->create_virtualos( 
        name=> 'test', 
        ip=>'10.0.1.68', 
        test_mode=>1,
    );

$r = $vos->create_virtualos( 
        name=> 'test', 
        ip=>'10.0.1.68', 
        template=>'default', 
        test_mode=>1,
    );

$r = eval { 
    $vos->create_virtualos( 
        name=> 'test', 
        ip=>'10.0.1.68', 
        template=>'silly', 
        test_mode=>1,
    ) 
};
