
use strict;
use warnings;

use English qw( -no_match_vars );
use Test::More 'no_plan';

use lib "inc";
use lib "lib";

BEGIN {
    use_ok('Provision::Unix');
    use_ok('Provision::Unix::DNS');
}

require_ok('Provision::Unix');
require_ok('Provision::Unix::DNS');
require_ok('Provision::Unix::Utility');

# let the testing begin

my $prov = Provision::Unix->new( debug => 0 );

# basic OO mechanism
my $dns = Provision::Unix::DNS->new( prov => $prov );
ok( defined $dns,                      'get Provision::Unix::DNS object' );
ok( $dns->isa('Provision::Unix::DNS'), 'check object class' );

use Data::Dumper qw( Dumper );

#warn Dumper ( $dns );

# fully_qualify
if ( lc( $prov->{config}{DNS}{server} ) ne 'nictool' ) {
    ok( $dns->fully_qualify( 't.com', 'w' ) eq 'w.t.com', 'fully_qualify' );
    ok( $dns->fully_qualify( 't.com', 'w.t.com' ) eq 'w.t.com',
        'fully_qualify' );
    ok( $dns->fully_qualify( 't.com', 'w.t.com.' ) eq 'w.t.com.',
        'fully_qualify' );
}

#$prov->error(message=>'test breakpoint');

my $server = $prov->{config}{DNS}{server};
if ( $server eq 'tinydns' ) {
    my $service_dir = $prov->{config}{tinydns}{service_dir};
    if ( !-d $service_dir ) {
        warn
            "tinydns service dir missing ($service_dir). Skipping DNS tests\n";
        exit;
    }

    if ( !-d "$service_dir/root/data" ) {
        system("touch $service_dir/root/data");
    }

    my $util = Provision::Unix::Utility->new( prov => $prov );
    my $tdata
        = $util->find_bin( bin => 'tinydns-data', fatal => 0, debug => 0 );
    if ( !$tdata || !-x $tdata ) {

        #$prov->error( message => 'djbdns is not installed' );
        diag('tinydns is selected but djbdns is not installed!');
        exit;
    }
}

my @zones = qw/ example.com 2.2.2.in-addr.arpa /;

foreach my $zone (@zones) {

    my $zone_id = $dns->get_zone( zone => $zone, fatal => 0, debug => 0 );

    next if $zone_id;

    # create_zone +
    ok( $dns->create_zone( zone => $zone, fatal => 0, debug => 0 ),
        'create_zone +' );

    # get_zone
    $zone_id = $dns->get_zone( zone => $zone );
    ok( $zone_id, 'get_zone' );

    if ($zone_id) {

        # create_zone -
        ok( !$dns->create_zone( zone => $zone, fatal => 0, debug => 0 ),
            'create_zone -' );
    }
}

#$prov->error(message=>'test breakpoint');

my $zone_name = 'example.com';
my $zone_id = $dns->get_zone( zone => $zone_name, fatal => 0, debug => 0 );

my $reverse = '2.2.2.in-addr.arpa';
my $reverse_id = $dns->get_zone( zone => $reverse, fatal => 0, debug => 0 );

my $i = 1;
my @a_records
    = qw/ www www.example.com www.example.com. mail a.ns b.ns c.ns /;

foreach my $name (@a_records) {

    ok( $dns->create_zone_record(
            zone_id => $zone_id,
            zone    => $zone_name,
            name    => $name,
            address => "2.2.2.$i",
            type    => 'A',
            debug   => 0,
        ),
        'create_zone_record A'
    );
    $i++;
}

foreach my $mail (qw/ mail mail1.example.com mail2.example.com. mail3 /) {
    ok( $dns->create_zone_record(
            zone_id => $zone_id,
            zone    => $zone_name,
            name    => $zone_name,
            address => $mail,
            type    => 'MX',
            weight  => 10 + $i,
            debug   => 0,
        ),
        'create_zone_record MX'
    );
    $i++;
}

# NicTool generates these automatically
if ( lc( $prov->{config}{DNS}{server} ) ne 'nictool' ) {
    foreach my $ns (qw/ a.ns b.ns.example.com c.ns /) {
        ok( $dns->create_zone_record(
                zone_id => $zone_id,
                zone    => $zone_name,
                name    => $zone_name,
                address => $ns,
                type    => 'NS',
                debug   => 0,
            ),
            'create_zone_record NS'
        );
    }

    # NicTool correctly declines multiple CNAMES, which is bothersome in
    # testing.
    ok( $dns->create_zone_record(
            zone_id => $zone_id,
            zone    => $zone_name,
            name    => "web",
            address => "www",
            type    => 'CNAME',
            debug   => 0,
        ),
        'create_zone_record CNAME'
    );

    ok( $dns->create_zone_record(
            zone_id => $zone_id,
            zone    => $zone_name,
            name    => "web",
            address => '2001:0db8:0000:0000:0000:0000:1428:57ab',
            type    => 'AAAA',
            debug   => 0,
        ),
        'create_zone_record AAAA'
    );

}

ok( $dns->create_zone_record(
        zone_id => $zone_id,
        zone    => $zone_name,
        name    => $zone_name,
        address => "v=spf1 a mx ~all",
        type    => 'TXT',
        debug   => 0,
    ),
    'create_zone_record TXT'
);

ok( $dns->create_zone_record(
        zone_id => $zone_id,
        zone    => $zone_name,
        name    => $zone_name,
        address => "v=spf1 a mx ~all",
        type    => 'TXT',
        debug   => 0,
    ),
    'create_zone_record TXT'
);

ok( $dns->create_zone_record(
        zone_id => $reverse_id,
        zone    => $reverse,
        name    => $i,
        address => "$i.example.com.",
        type    => 'PTR',
        debug   => 0,
    ),
    'create_zone_record PTR'
);

ok( $dns->create_zone_record(
        zone_id  => $zone_id,
        zone     => $zone_name,
        name     => "_caldav._tcp",
        address  => "calendar",
        type     => 'SRV',
        port     => 443,
        priority => 5,
        weight   => 100,
        debug    => 0,
    ),
    'create_zone_record SRV'
);

#$prov->error(message=>'test breakpoint',debug=>0);

# delete_zone
ok( $dns->delete_zone(
        id    => $zone_id,
        zone  => $zone_name,
        fatal => 0,
        debug => 0,
    ),
    'delete_zone'
);

