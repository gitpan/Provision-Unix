use strict;
use warnings;

use Config::Std { def_sep => '=' };
use English qw( -no_match_vars );
use Test::More 'no_plan';

use lib "lib";

BEGIN {
    use_ok('Provision::Unix');
    use_ok('Provision::Unix::Web');
}
require_ok('Provision::Unix');
require_ok('Provision::Unix::Web');

# let the testing begin

# basic OO mechanism
my $prov = Provision::Unix->new( debug => 0 );
my $web = Provision::Unix::Web->new( prov => $prov );
ok( defined $web,                      'get Provision::Unix::Web object' );
ok( $web->isa('Provision::Unix::Web'), 'check object class' );

# get_vhost_attributes
ok( $web->get_vhost_attributes( request => { vhost => 'test.com' }, ),
    'get_vhost_attributes' );

if ( 0 == 1 ) {
    ok( $web->get_vhost_attributes( prompt => 1, ), 'get_vhost_attributes' );
}

# create
ok( $web->create(
        request   => { vhost => 'test.com' },
        test_mode => 1,
    ),
    'create'
);

exit;

ok( $web->_(), '' );
ok( $web->_(), '' );
ok( $web->_(), '' );

# exists
ok( $web->exists( vhost => 'test.com' ), 'exists' );

