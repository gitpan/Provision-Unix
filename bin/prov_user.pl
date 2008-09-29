#!/usr/bin/perl

use strict;
use warnings;
use English;
use Getopt::Long;
use Pod::Usage;

if ( !$EFFECTIVE_USER_ID == 0 ) {
    die "\n$0 must be run as root!\n\n";
}

use lib 'lib';

use Provision::Unix;
use Provision::Unix::User;

my ( $action, $vals );

# process command line options
Getopt::Long::GetOptions(

    'create'  => \$action->{'create'},
    'modify'  => \$action->{'modify'},
    'destroy' => \$action->{'destroy'},

    'suspend' => \$action->{'suspend'},
    'restore' => \$action->{'restore'},

    'show'   => \$action->{'show'},
    'repair' => \$action->{'repair'},
    'test'   => \$action->{'test'},

    'comment=s'  => \$vals->{'gecos'},
    'domain=s'   => \$vals->{'domain'},
    'expire=s'   => \$vals->{'expire'},
    'gid=s'      => \$vals->{'gid'},
    'homedir=s'  => \$vals->{'homedir'},
    'password=s' => \$vals->{'password'},
    'quota=s'    => \$vals->{'quota'},
    'shell=s'    => \$vals->{'shell'},
    'uid=s'      => \$vals->{'uid'},
    'username=s' => \$vals->{'username'},
    'verbose'    => \$vals->{'debug'},

) or die "erorr parsing command line options";

$vals->{'debug'} ||= 0;

my $prov = Provision::Unix->new();
my $user = Provision::Unix::User->new( prov => $prov, request => $vals );

$action->{'create'}
    ? $user->create( prompt => 1 )
    : $action->{'destroy'} ? $user->destroy( prompt => 1 )

    # future functions....
    #: $action->{'modify'}  ? $user->modify ( prompt=>1 )
    #: $action->{'suspend'} ? $user->suspend( prompt=>1 )
    #: $action->{'restore'} ? $user->restore( prompt=>1 )
    #: $action->{'show'}    ? $user->show   ( prompt=>1 )
    #: $action->{'repair'}  ? $user->repair ( prompt=>1 )
    #: $action->{'test'}    ? $user->test   ( prompt=>1 )
    : pod2usage( { -verbose => $vals->{'verbose'} } );

=head1 NAME 

prov_user.pl - a command line interface for provisioning system accounts

=head1 SYNOPSIS

  prov_user.pl <action>

Where action is one of the following:

  --create   - creates a new system user
  --modify   - make changes to an existing user
  --destroy  - remove a user from the system
  --suspend  - disable an account
  --restore  - restore an account

Additionally, --username is required but if you fail to pass it, you'll be prompted.

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

When there are required options that are not set on the command line, you will be prompted for them.

=head1 USAGE
 
 prov_user.pl --create  --user=matt --pass='neat0app!'
 prov_user.pl --destroy --user=matt
 prov_user.pl --modify  --user=matt --quota=500
 

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
