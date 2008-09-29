#!/usr/bin/perl

use strict;
use warnings;

use Config::Std { def_sep => '=' };
use English;
use Getopt::Long;
use Pod::Usage;

if ( $EFFECTIVE_USER_ID != 0 ) {
    die "\n$0 must be run as root!\n\n";
}

use lib 'lib';
use Provision::Unix;
my $prov = Provision::Unix->new;
use Provision::Unix::Web;
my $web = Provision::Unix::Web->new;

###########    SITE CONFIGURATION    ###########
# Load named config file into specified hash...
my $config_file = $prov->find_config( file => 'provision.conf', debug => 0 );
read_config $config_file => my %config;

my ( $action, $vals );

# process command line options
GetOptions(

    'create'  => \$action->{'create'},
    'modify'  => \$action->{'modify'},
    'destroy' => \$action->{'destroy'},

    'suspend' => \$action->{'suspend'},
    'restore' => \$action->{'restore'},

    'show'   => \$action->{'show'},
    'repair' => \$action->{'repair'},
    'test'   => \$action->{'test'},

    "vhost=s"        => \$vals->{'vhost'},
    "ip=s"           => \$vals->{'ip'},
    "serveralias=s"  => \$vals->{'serveralias'},
    "serveradmin=s"  => \$vals->{'serveradmin'},
    "documentroot=s" => \$vals->{'documentroot'},
    "redirect=s"     => \$vals->{'redirect'},
    "options=s"      => \$vals->{'options'},
    "cgi=s"          => \$vals->{'cgi'},
    "ssl"            => \$vals->{'ssl'},
    "sslcert=s"      => \$vals->{'sslcert'},
    "sslkey=s"       => \$vals->{'sslkey'},
    "customlog=s"    => \$vals->{'customlog'},
    "customerror=s"  => \$vals->{'customerror'},
    "awstats"        => \$vals->{'awstats'},
    "phpmyadmin"     => \$vals->{'phpmyadmin'},
    "verbose"        => \$vals->{'debug'},

) or die "erorr parsing command line options";

$action->{'create'}
    ? $web->create( request => $vals, config => \%config, prompt => 1 )
    : $action->{'destroy'}
    ? $web->destroy( request => $vals, config => \%config, prompt => 1 )

    # future functions....
    #: $action->{'modify'}  ? $web->modify ( request=>$vals, prompt=>1 )
    #: $action->{'suspend'} ? $web->suspend( request=>$vals, prompt=>1 )
    #: $action->{'restore'} ? $web->restore( request=>$vals, prompt=>1 )
    #: $action->{'show'}    ? $web->show   ( request=>$vals, prompt=>1 )
    #: $action->{'repair'}  ? $web->repair ( request=>$vals, prompt=>1 )
    #: $action->{'test'}    ? $web->test   ( request=>$vals, prompt=>1 )
    : pod2usage( { -verbose => $vals->{'debug'} } );

=head1 NAME 

prov_web.pl - a command line interface for provisioning web accounts

=head1 SYNOPSIS

  	prov_web.pl --action [--vhost example.com]

Action is one of the following:

  --create   - creates a new system user
  --modify   - make changes to an existing user
  --destroy  - remove a user from the system
  --suspend  - disable an account
  --restore  - restore an account

required arguments:

 -vhost          $vhost        

optional arguments:

 -ip             - IP address to listen on (default *)
 -serveralias    - list of aliases, comma separated
 -serveradmin    - email address of server admin
 -documentroot   - full path to html directory
 -redirect       - url to redirect site to
 -options        - server options ex. FollowSymLinks MultiViews Indexes ExecCGI Includes
 -ssl            - ssl enabled ? 
 -sslcert        - path to ssl certificate
 -sslkey         - path to ssl key
 -cgi            - basic | advanced | custom
 -customlog      - custom logging directive
 -customerror    - custom error logging directive
 -awstats        - include alias for awstats
 -phpmyadmin     - include alias for phpMyAdmin


=head1 USAGE
 
 prov_web.pl --create --vhost=www.example.com
 prov_web.pl --destroy --vhost=www.example.com
 prov_web.pl --modify  --vhost=www.example.com --options='Indexes ExecCGI'


=head1 DESCRIPTION
 
prov_web.pl is a command line interface to the Provision::Web provisioning modules. 

 
=head1 CONFIGURATION AND ENVIRONMENT
 
A full explanation of any configuration system(s) used by the application,
including the names and locations of any configuration files, and the
meaning of any environment variables or properties that can be set. These
descriptions must also include details of any configuration language used

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
