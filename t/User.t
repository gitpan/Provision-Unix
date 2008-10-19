
use strict;
use warnings;

use English qw( -no_match_vars );
use Test::More 'no_plan';

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

# exists
my $user_that_exists_by_default
    = lc($OSNAME) eq 'darwin'  ? 'daemon'
    : lc($OSNAME) eq 'linux'   ? 'daemon'
    : lc($OSNAME) eq 'freebsd' ? 'daemon'
    :                            'daemon';

ok( $user->exists($user_that_exists_by_default), 'exists' );

# _is_valid_username
$user->{username} = 'provunix';
ok( $user->_is_valid_username(), '_is_valid_username valid' )
    or diag $prov->{errors}[-1]{errmsg};
$user->{username} = 'unix_geek';
ok( !$user->_is_valid_username(), '_is_valid_username invalid' );
$user->{username} = 'unix,geek';
ok( !$user->_is_valid_username(), '_is_valid_username invalid' );

my $gid      = 65530;
my $uid      = 65530;
my $group    = 'provunix';
my $username = 'provuser';

#   invalid request, no username
ok( !eval {
        $user->create(
            test_mode => 1,
            usrename  => $username,
            uid       => $uid,
            gid       => $gid,
            debug     => 0,
            fatal     => 0,
        );
    },
    'create user, missing username param'
);

#   invalid username, invalid chars
ok( !$user->create(
        username => 'bob_builder',
        uid      => $uid,
        gid      => $gid,
        debug    => 0,
    ),
    'create user, invalid chars'
);

#   invalid username, too short
ok( !$user->create(
        username => 'b',
        uid      => $uid,
        gid      => $gid,
        debug    => 0,
    ),
    'create user, too short'
);

#   invalid username, too long
ok( !$user->create(
        username => 'bobthebuilderiscool',
        uid      => $uid,
        gid      => $gid,
        debug    => 0,
    ),
    'create user, too long'
);

SKIP: {
    skip "you are not root", 7 if $EFFECTIVE_USER_ID != 0;

    # destroy group if exists
    ok( $user->destroy_group(
            group => $group,
            gid   => $gid,
            debug => 0,
        ),
        "destroy_group $group"
    ) if $user->exists_group($group);

    # create group
    ok( $user->create_group(
            group => $group,
            gid   => $gid,
            debug => 0,
        ),
        "create group $group ($gid)"
    );

    # destroy user
    ok( $user->destroy(
            username => $username,
            debug    => 0
        ),
        'destroy valid'
    ) if $user->exists( username => $username );
    sleep 1;

    # create user, valid request in test mode
    ok( $user->create(
            username  => $username,
            uid       => $uid,
            gid       => $gid,
            debug     => 0,
            test_mode => 1,
        ),
        'create user, valid test'
    );

    # destroy user, valid request in test mode
    ok( $user->destroy(
            username  => $username,
            debug     => 0,
            test_mode => 1,
        ),
        'destroy user, test'
    );

    #   valid request

    # only run if provuser does not exist
    if ( !`grep '^$username:' /etc/passwd` ) {
        ok( $user->create(
                username => $username,
                uid      => $uid,
                gid      => $gid,
                debug    => 0,
            ),
            'create valid'
        );

        ok( $user->destroy(
                username => $username,
                debug    => 0,
            ),
            'destroy valid'
        );
    }
}

# quota_set
SKIP: {
    eval { require Quota; };

    skip "Quota.pm is not installed", 1 if $@;

    ok( $prov->quota_set( user => 'matt', debug => 0 ), 'quota_set' );
}

# user
#ok ( $prov->user ( vals=>{action=>'create', user=>'matt2'} ), 'user');

# web
#ok ( $prov->web ( vals=>{action=>'create', vhost=>'foo.com'} ), 'web');

# what_am_i
#   invalid request, no username

# quota_set
#my $mod = "Quota";
#if (eval "require $mod")
#{
#    ok ( $prov->quota_set( user=>'matt', debug=>0 ), 'quota_set');
#};

# user
#ok ( $prov->user ( vals=>{action=>'create', user=>'matt2'} ), 'user');

# web
#ok ( $prov->web ( vals=>{action=>'create', vhost=>'foo.com'} ), 'web');

# what_am_i
#ok ( $prov->what_am_i(), 'what_am_i');

