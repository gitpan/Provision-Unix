
use strict;
use warnings;

use English qw( -no_match_vars );
use Test::More;

my $prov = Provision::Unix->new( debug => 0 );
my $web = Provision::Unix::Web->new( prov => $prov, fatal => 0, debug => 0 );

if ( ! $web) {
    plan skip_all => "Could not load Provision::Unix::Web";
};

plan 'no_plan';

use lib "lib";
use Provision::Unix;
use Provision::Unix::Web;

# let the testing begin
ok( defined $web, 'get Provision::Unix::Web object' );
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

__END__

ok( $web->_(), '' );
ok( $web->_(), '' );
ok( $web->_(), '' );

# exists
ok( $web->exists( vhost => 'test.com' ), 'exists' );

