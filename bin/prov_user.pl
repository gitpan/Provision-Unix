#!perl

use strict;
use warnings;

use English qw( -no_match_vars );
use Getopt::Long;
use Pod::Usage;

if ( !$EFFECTIVE_USER_ID == 0 ) {
    die "\n$0 must be run as root!\n\n";
}

use lib 'lib';
use Provision::Unix;
use Provision::Unix::User;
use Provision::Unix::Utility;

my $prov = Provision::Unix->new( debug => 0 );
my $user = Provision::Unix::User->new( prov => $prov, debug => 0 );

# process command line options
Getopt::Long::GetOptions(

    'action=s' => \my $action,

    'comment=s'  => \$user->{gecos},
    'domain=s'   => \$user->{domain},
    'expire=s'   => \$user->{expire},
    'gid=s'      => \$user->{gid},
    'homedir=s'  => \$user->{homedir},
    'password=s' => \$user->{password},
    'quota=s'    => \$user->{quota},
    'shell=s'    => \$user->{shell},
    'uid=s'      => \$user->{uid},
    'username=s' => \$user->{username},
    'verbose'    => \$user->{debug},

) or die "error parsing command line options";

my $conf = $prov->{config};
$user->{debug} || 0;   # so it's not undef

my $util
    = Provision::Unix::Utility->new( prov => $prov, debug => $user->{debug} );

my %actions = map { $_ => 1 }
    qw/ create destroy suspend restore show repair test creategroup destroygroup /;
pod2usage( { -verbose => 1 } ) if !$actions{$action};

  $action eq 'create'       ? user_create() 
: $action eq 'creategroup'  ? group_create() 
: $action eq 'destroy'      ? user_destroy()
: $action eq 'destroygroup' ? group_destroy()
: die "oops, that feature isn't ready yet\n";

# future functions....
#: $action->{'modify'}  ? $user->modify ( prompt=>1 )
#: $action->{'suspend'} ? $user->suspend( prompt=>1 )
#: $action->{'restore'} ? $user->restore( prompt=>1 )
#: $action->{'show'}    ? $user->show   ( prompt=>1 )
#: $action->{'repair'}  ? $user->repair ( prompt=>1 )
#: $action->{'test'}    ? $user->test   ( prompt=>1 )

sub user_create {
    $user->{username} ||= $util->ask( question => 'Username' ) || die;
    $prov->error(message=> "user exists",debug=>0) if $user->exists($user->{username});
    $user->{password} ||= $util->ask( question => 'Password', password => 1 );
    $user->{uid} ||= $util->ask( question => 'uid' ) || die;
    $user->{gid} ||= $util->ask( question => 'gid' ) || die;
    if ( $user->{gid} =~ /^[a-zA-Z]+$/ ) {
        my $gid = getgrnam($user->{gid});
        if ( ! $gid ) {
            $user->create_group(group=>$user->{gid}) 
                if $util->ask( question=>'group does not exist, create it');
            $gid = getgrnam($user->{gid}) || die;
            $user->{gid} = $gid;
        }
    }
    $user->{shell} ||= $util->ask(
        question => 'shell',
        default  => $conf->{User}{shell_default}
    );
    $user->{homedir} ||= $util->ask(
        question => 'homedir',
        default  => "$conf->{User}{home_base}/$user->{username}"
    );
    $user->{gecos} ||= $util->ask( question => 'gecos' );
    if ( $conf->{quota_enable} ) {
        $user->{quota} ||= $util->ask(
            question => 'quota',
            default  => $conf->{User}{quota_default}
        );
    }

    $user->_is_valid_request();
    $user->create(
        username => $user->{username},
        password => $user->{password},
        uid      => $user->{uid},
        gid      => $user->{gid},
        shell    => $user->{shell},
        homedir  => $user->{homedir},
        gecos    => $user->{gecos},
        quota    => $user->{quota},
        debug    => $user->{debug},
    );
};

sub user_destroy {

    $user->{username} ||= $util->ask( question => 'Username' ) || die;

    $user->exists() or die "user $user->{username} does not exist\n";
    $user->_is_valid_request();
    $user->destroy( username => $user->{username} );
};
sub group_create {
    $user->{group} ||= $util->ask( question => 'Group' ) || die;
    $user->create_group( group=>$user->{group} );
}

sub group_destroy {
    my $gid = $user->{gid} || $util->ask( question => 'gid' );
    if ( $gid ) {
        $user->{group} = getgrgid( $gid );
    }
    my $group = $user->{group} || $util->ask( question => 'Group' ) || die;
    $gid   ||= getgrnam($group);
    $group = getgrnam($gid);
    die "invalid group or gid" if ( !$gid || ! $group);
    $user->destroy_group( gid=>$gid, group=>$group );
}


=head1 NAME 

prov_user.pl - a command line interface for provisioning system accounts

=head1 SYNOPSIS

  prov_user.pl --action=[]

Action is one of the following:

  create   - creates a new system user
  modify   - make changes to an existing user
  destroy  - remove a user from the system
  suspend  - disable an account
  restore  - restore an account

Other parameters are optional. Unless you specify --noprompt, you will be prompted for fill in any missing values.

   --username
   --comment   - gecos description
   --domain    - a domain name, if associated with the account
   --expire    - account expiration date
   --gid       - group id
   --homedir   - the full path to the users home directory
   --password
   --quota     - disk quota (in MB)
   --shell
   --uid       - user id
   --verbose   - enable debugging options


=head1 USAGE
 
 prov_user.pl --action create  --user=matt --pass='neat0app!'
 prov_user.pl --action destroy --user=matt
 prov_user.pl --action modify  --user=matt --quota=500
 

=head1 DESCRIPTION
 
prov_user.pl is a command line interface to the Provision::User provisioning modules. 

 
=head1 CONFIGURATION AND ENVIRONMENT
 
Default settings are found in provision.conf, which should be located in your systems local etc directory (/etc, /usr/local/etc, or /opt/local/etc).

=head1 DEPENDENCIES
 
A list of all the other modules that this module relies upon, including any
restrictions on versions, and an indication whether these required modules are
part of the standard Perl distribution, part of the module's distribution,
or must be installed separately.


=head1 AUTHOR
 
Matt Simerson, C<< <matt at tnpi.net> >>
 
 
=head1 LICENCE AND COPYRIGHT
 
Copyright (c) 2008 The Network People, Inc. (info@tnpi.net). All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.
 
This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
