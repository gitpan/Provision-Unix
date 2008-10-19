#!perl

use strict;
use warnings;

use Data::Dumper qw( Dumper );
use English qw( -no_match_vars );
use Getopt::Long;
use Pod::Usage;

use lib "lib";
use Provision::Unix;
use Provision::Unix::DNS;
use Provision::Unix::Utility;

my $prov = Provision::Unix->new( debug => 0 );
my $dns  = Provision::Unix::DNS->new( prov => $prov );
my $util = Provision::Unix::Utility->new( prov => $prov, debug => 0);

# process command line options
Getopt::Long::GetOptions(

    'action=s' => \my $action,
    'zone=s'   => \my $zone,
    'type=s'   => \my $type,

    'serial=s'  => \my $serial,
    'ttl=s'     => \my $ttl,
    'refresh=s' => \my $refresh,
    'retry=s'   => \my $retry,
    'expire=s'  => \my $expire,
    'minimum=s' => \my $minimum,
    'nameserver=s' => \my $nameserver,
    'name=s'     => \my $name,
    'address=s'  => \my $address,
    'weight=s'   => \my $weight,
    'priority=s' => \my $priority,
    'port=s'     => \my $port,

    'verbose'    => \my $debug,

) or die "error parsing command line options";

my $questions = {
    action   => "the action to perform: create, delete", 
    zone     => "the zone name",

    serial   => "the serial number",
    ttl      => "the TTL",
    refresh  => "the zone refresh interval",
    retry    => "the zone retry   interval",
    expire   => "the zone expiration time",
    minimum  => "the zone minimum",
    nameserver => "a nameserver authoritative for this zone",
    name     => "the zone record name",
    address  => "the zone record address",
    weight   => "the zone record weight",
    priority => "the zone record priority",
    port     => "the zone record port",
};

$action ||= $util->ask( question=> $questions->{action}, default=>'create' );
$action = lc($action);

my %actions = map { $_ => 1 } qw/ create destroy /;
pod2usage( { -verbose => 1 } ) if !$actions{$action};

$zone ||= $util->ask( question=>"the zone name" );
$zone = lc($zone);

my %types = map { $_ => 1 } qw/ zone a ptr ns mx txt srv cname aaaa /;
while ( ! $types{$type} ) {
    $type = $util->ask( question=>"the DNS entity would you like to $action:
\t zone, A, PTR, NS, MX, TXT, SRV, CNAME, or AAAA" );
    $type = lc($type);
};

  $action eq 'create'   ? dns_create()
: $action eq 'destroy'  ? dns_destroy()
#: $action eq 'modify'   ? dns_modify()
: die "oops, the action ($action) is invalid\n";


sub dns_create {

    print "creating!\n";

    my %request = (
        zone => $zone,
        debug => 0,
        fatal => 0,
    );

    if ( $type =~ /zone/i ) {
        
        my @d = $util->get_the_date(debug=>0);

        $request{serial} =  $serial || $util->ask( 
                question => $questions->{serial},  
                default  => "$d[2]$d[1]$d[0]01" );
        $request{ttl}    =  $ttl || $util->ask( 
                question => $questions->{ttl},  
                default  => $prov->{config}{DNS}{zone_ttl} );
        $request{refresh} = $refresh || $util->ask( 
                question => $questions->{refresh}, 
                default  => $prov->{config}{DNS}{zone_refresh} );
        $request{retry}  =  $retry  || $util->ask( 
                question => $questions->{retry},   
                default  => $prov->{config}{DNS}{zone_retry}  );
        $request{expire} =  $expire || $util->ask( 
                question => $questions->{expire},  
                default  => $prov->{config}{DNS}{zone_expire} );
        $request{minimum} = $minimum || $util->ask( 
                question => $questions->{minimum}, 
                default  => $prov->{config}{DNS}{zone_minimum} );
        $request{nameserver} =$nameserver || $util->ask( 
                question => $questions->{nameserver}, 
                default  => "a.ns.$zone" );

        return $dns->create_zone( %request );
    }
    
    # create a zone record (A, AAAA, PTR, NS, MX, TXT, SRV, CNAME)
    $request{type}    = uc($type);
    $request{name}    = $name || $util->ask( question => $questions->{name} );
    if ( lc( $prov->{config}{DNS}{server} ) ne 'nictool' ) {
        $request{name} = $dns->fully_qualify( $zone, $request{name} );
    }
    $request{address} = $name || $util->ask( question => $questions->{address} );
    $request{ttl}     = $name || $util->ask( 
            question => $questions->{ttl},
            default  => $prov->{config}{DNS}{ttl} );

    if ( $type =~ /mx|srv/i ) {
        $request{weight} = $weight || $util->ask( 
            question => $questions->{weight},
            default => $prov->{config}{DNS}{weight} );
    }
    elsif ($type =~ /srv/i ) {
        $request{priority} = $priority || $util->ask(
            question => $questions->{priority},
            default  => 5 );
        $request{port} = $port || $util->ask(
            question => $questions->{port} )
            or $prov->error( message => 'SRV records require a port' );
    }

    return $dns->create_zone_record( %request );
}

sub dns_destroy {

    if ( $type =~ /zone/i ) {
        return $dns->destroy_zone(
            zone  => $zone,
            fatal => 0,
            debug => 0,
        );
    }

    # TODO: add support for deleting zone records
    warn "no support for removing zone records yet.\n";
}

sub dns_modify {
}

