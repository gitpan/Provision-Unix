
use strict;
use warnings;

use English qw( -no_match_vars );
use Test::More 'no_plan';

$|++;

use lib "lib";

BEGIN { use_ok('Provision::Unix'); }
BEGIN { use_ok('Provision::Unix::User'); }
require_ok('Provision::Unix');
require_ok('Provision::Unix::User');

# let the testing begin

# basic OO mechanism
my $prov = Provision::Unix->new( debug => 0 );
my $user = Provision::Unix::User->new( prov => $prov );    # create object
ok( defined $user,                       'get Provision::Unix::User object' );
ok( $user->isa('Provision::Unix::User'), 'check object class' );

my $gid      = 65530;
my $uid      = 65530;
my $group    = 'provunix';
my $username = 'provuser';

my $group_that_exists
    = $OSNAME eq 'linux'  ? 'daemon'
    : 'daemon';

# exists_group
ok( $user->exists_group($group_that_exists), 'exists_group +' );

if (`grep '^$group:' /etc/group`) {
    ok( $user->exists_group($group), 'exists_group +' );
}
else {
    ok( !$user->exists_group($group), 'exists_group -' );
}

SKIP: {
    skip "you are not root", 7 if $EFFECTIVE_USER_ID != 0;

    # destroy group if exists
    if ( $user->exists_group($group) ) {

        ok( $user->destroy_group(
            group => $group,
            gid   => $gid,
            debug => 0,
        ),
        "destroy_group $group if exists" );
    };

    # exists_group -
    if (`grep '^$group:' /etc/group`) {
        ok( $user->exists_group($group), 'exists_group +' );
    }
    else {
        ok( !$user->exists_group($group), 'exists_group -' );
    }

    sleep 3;

    # create group
    ok( $user->create_group(
            group => $group,
            gid   => $gid,
            debug => 0,
        ),
        "create group $group ($gid)"
    );

    # exists_group +
    if (`grep '^$group:' /etc/group`) {
        ok( $user->exists_group($group), 'exists_group +' );
    }
    else {
        ok( !$user->exists_group($group), 'exists_group -' );
    }

    sleep 3;

    # destroy group
    my $r = $user->destroy_group(
        group => $group,
        gid   => $gid,
        debug => 0,
    );
    ok( $r, "destroy_group $group" );

    if (`grep '^$group:' /etc/group`) {
        ok( $user->exists_group($group), 'exists_group +' );
    }
    else {
        ok( !$user->exists_group($group), 'exists_group -' );
    }

}

