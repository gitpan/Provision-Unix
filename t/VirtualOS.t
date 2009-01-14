#!perl

use strict;
use warnings;

use Data::Dumper qw( Dumper );
use English qw( -no_match_vars );
use Test::More;

use lib "lib";
use Provision::Unix;
use Provision::Unix::VirtualOS;

my $prov = Provision::Unix->new( debug => 0 );
my $vos;

eval { $vos = Provision::Unix::VirtualOS->new( prov => $prov, fatal => 0, debug => 0 ) };
if ( $EVAL_ERROR ) {
    my $message = $EVAL_ERROR; chop $message;
    $message .= " on " . $OSNAME;
    plan skip_all => $message;
} 
else {
    plan 'no_plan';
};

use_ok('Provision::Unix::Utility');
require_ok('Provision::Unix::Utility');

# basic OO mechanism
ok( defined $vos, 'get Provision::Unix::VirtualOS object' );
ok( $vos->isa('Provision::Unix::VirtualOS'), 'check object class' );

my $util = Provision::Unix::Utility->new( prov => $prov, debug => 0 );

my $virt_class = ref $vos->{vtype};
my @parts = split /::/, $virt_class;
my $virt_type = lc( $parts[-1] );
warn "virtualos type: $virt_type\n";

# let the testing begin
my $template_that_exists
    = $virt_type eq 'openvz' ? 'centos-5-i386-default'
    : $virt_type eq 'xen'    ? 'centos-5-i386-default'
    : $virt_type eq 'ezjail' ? 'default'
    :                          undef;

my $container_id_or_name
    = $virt_type eq 'openvz' ? 72000
    : $virt_type eq 'xen'    ? 'test1'
    : $virt_type eq 'ezjail' ? 'test1'
    : $virt_type eq 'jails'  ? 'test1'
    :                          undef;

my $required_bin
    = $virt_type eq 'openvz' ? 'vzlist'
    : $virt_type eq 'xen'    ? 'xm'
    :                          undef;

my %requires_template = map { $_ => 1 } qw/ xen /;

if ( defined $required_bin ) {
    my $found_bin
        = $util->find_bin( bin => $required_bin, fatal => 0, debug => 0 );
    if ( !$found_bin || !-x $found_bin ) {
        print
            "Skipped tests b/c virtual type $virt_type chosen but $required_bin not found.\n";
        exit;
    }
}

ok( !$vos->is_valid_ip('1.1.1'),           'is_valid_ip -' );
ok( !$vos->is_valid_ip('1.1.1.1.1'),       'is_valid_ip -' );
ok( $vos->is_valid_ip('1.1.1.1'),          'is_valid_ip +' );
ok( !$vos->is_valid_ip('0.0.0.0'),         'is_valid_ip -' );
ok( !$vos->is_valid_ip('255.255.255.255'), 'is_valid_ip -' );
ok( !$vos->is_valid_ip('0.1.1.1'),         'is_valid_ip -' );
ok( $vos->is_valid_ip('2.1.1.1'),          'is_valid_ip +' );

#ok( $vos->_check_template( 'non-existing' ), '_check_default' );
#ok( $vos->_check_template( $template_that_exists), '_check_default' );

SKIP: {
    skip "you are not root", 12 if $EFFECTIVE_USER_ID != 0;

    my $r;
    ok( $vos->get_status(), 'get_status' );
    if ( $virt_type eq 'xen' ) {

        #    $r = $vos->install_config_file();
        #    ok( $vos->is_running( name => $container_id_or_name ), 'is_running');
    }

#exit;

    if ( $vos->is_present( name => $container_id_or_name ) ) {
        ok( $vos->destroy_virtualos(
                name      => $container_id_or_name,
                test_mode => 0,
                debug     => 0,
                fatal     => 0,
            ),
            'destroy_virtualos'
        );
        sleep 3;
    }

#$prov->error( message => 'dump' );

#SKIP: {
#    skip "negative tests for now", 3;

    $r = $vos->create_virtualos(
        name      => $container_id_or_name,
        ip        => '10.0.1.68',
        test_mode => 1,
        debug     => 0,
        fatal     => 0,
    );

    if ( $requires_template{$virt_type} ) {
        ok( !$r, 'create_virtualos, no template' );
    }
    else {
        ok( $r, 'create_virtualos, no template' );
    }

    ok( !$vos->create_virtualos(
            name      => $container_id_or_name,
            ip        => '10.0.1.',
            test_mode => 1,
            debug     => 0,
            fatal     => 0,
        ),
        'create_virtualos, no valid IPs'
    );

    ok( !$vos->create_virtualos(
            name      => $container_id_or_name,
            ip        => '10.0.1.70',
            template  => 'non-existing',
            test_mode => 1,
            debug     => 0,
            fatal     => 0,
        ),
        'create_virtualos, non-existing template'
    );

#};

    ok( $vos->create_virtualos(
            name      => $container_id_or_name,
            ip        => '10.0.1.73 10.0.1.74 10.0.1.75',
            template  => $template_that_exists,
            test_mode => 1,
            debug     => 0,
            fatal     => 0,
        ),
        'create_virtualos, valid template'
    );

    ok( $vos->create_virtualos(
            name        => $container_id_or_name,
            hostname    => 'test1.example.com',
            ip          => '10.0.1.73 10.0.1.74 10.0.1.75',
            template    => $template_that_exists,
            nameservers => '64.79.200.111 64.79.200.113',
            test_mode   => 0,
            debug       => 0,
            fatal       => 0,
        ),
        'create_virtualos, valid request'
    );

    ok( $vos->start_virtualos(
            name  => $container_id_or_name,
            debug => 0,
            fatal => 0,
        ),
        'start_virtualos'
    );

#exit;
#$prov->error( message => 'dump' );

    ok( $vos->restart_virtualos(
            name  => $container_id_or_name,
            debug => 0,
            fatal => 0,
        ),
        'restart_virtualos'
    );

    ok( $vos->disable_virtualos(
            name  => $container_id_or_name,
            debug => 0,
            fatal => 0,
        ),
        'disable_virtualos'
    );

    ok( $vos->enable_virtualos(
            name  => $container_id_or_name,
            debug => 0,
            fatal => 0,
        ),
        'enable_virtualos'
    );

    ok( $vos->stop_virtualos(
            name  => $container_id_or_name,
            debug => 0,
            fatal => 0,
        ),
        'stop_virtualos'
    );
};

#$prov->error( message => 'dump' );
