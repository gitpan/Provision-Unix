
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
ok( $virt_type, "virtualization type: $virt_type");

my $template_dir;
my $template_that_exists = undef;
if ( $virt_type =~ /virtuozzo|ovz|openvz|xen|ezjail/ ) {

# get_template_dir
    $template_dir = $vos->get_template_dir( v_type => $virt_type );
    ok( $template_dir, "get_template_dir, $template_dir");

# get_template_list
    my $templates = $vos->get_template_list(v_type => $virt_type );
    ok( $templates, 'get_template_list' );
#warn Dumper($templates);

# select a template for testing
    my @preferred;
    @preferred = grep {/cpanel/} @$templates or
    @preferred = grep {/debian/} @$templates or
    @preferred = grep {/ubuntu/} @$templates or
    @preferred = grep {/centos/} @$templates or
        $template_that_exists = @$templates[0];

    if ( ! $template_that_exists ) {
        my @list = grep {/default/} sort { $b cmp $a } @preferred;
        if ( scalar @list > 0 ) {
            no warnings;
            my @sorted = sort { ( $b =~ /(\d\.\d)/)[0] <=> ($a =~ /(\d\.\d)/)[0] } @list;
            use warnings;
            $template_that_exists = $sorted[0] if scalar @sorted > 0;
        };
        $template_that_exists ||= $preferred[0];
    };

    ok( $template_that_exists, "template chosen: $template_that_exists") or exit;
    if ( ! -e "$template_dir/$template_that_exists" ) {
        $vos->get_template( 
            template => $template_that_exists, 
            repo     => 'spry-ovz.templates.int.spry.com',
            v_type   => 'openvz',
        );
    };
};

my $container_id_or_name
    = $virt_type eq 'openvz'    ? 72000
    : $virt_type eq 'ovz'       ? 72000
    : $virt_type eq 'virtuozzo' ? 72000
    : $virt_type eq 'xen'       ? 'test1'
    : $virt_type eq 'ezjail'    ? 'test1'
    : $virt_type eq 'jails'     ? 'test1'
    :                             undef;

my $required_bin
    = $virt_type eq 'openvz'    ? 'vzlist'
    : $virt_type eq 'ovz'       ? 'vzlist'
    : $virt_type eq 'virtuozzo' ? 'vzlist'
    : $virt_type eq 'xen'       ? 'xm'
    :                             undef;

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
ok(  $vos->is_valid_ip('1.1.1.1'),         'is_valid_ip +' );
ok( !$vos->is_valid_ip('0.0.0.0'),         'is_valid_ip -' );
ok( !$vos->is_valid_ip('255.255.255.255'), 'is_valid_ip -' );
ok( !$vos->is_valid_ip('0.1.1.1'),         'is_valid_ip -' );
ok(  $vos->is_valid_ip('2.1.1.1'),         'is_valid_ip +' );

#ok( $vos->_check_template( 'non-existing' ), '_check_default' );
#ok( $vos->_check_template( $template_that_exists), '_check_default' );


# these are expensive tests.
SKIP: {
    skip "you are not root", 12 if $EFFECTIVE_USER_ID != 0;
    skip "could not determine a valid name", 12 if ! $container_id_or_name;

my $r;
    if ( $vos->is_present( name => $container_id_or_name ) ) {
        $r = $vos->get_status( name => $container_id_or_name );
        ok( $r, 'get_status' );
    };

    if ( $virt_type eq 'xen' ) {
        # $r = $vos->install_config_file();
        # ok( $vos->is_running( name => $container_id_or_name ), 'is_running');
    }

    if ( $vos->is_present( name => $container_id_or_name ) ) {

        if ( $vos->is_running( name => $container_id_or_name ) ) {
            ok( $vos->stop_virtualos(
                    name  => $container_id_or_name,
                    debug => 0,
                    fatal => 0,
                ),
                'stop_virtualos'
            );
        };

        ok( $vos->destroy_virtualos(
                name      => $container_id_or_name,
                test_mode => 0,
                debug     => 0,
                fatal     => 0,
            ),
            'destroy_virtualos'
        );
        sleep 1;
    }

#$prov->error( 'dump' );

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
            password  => 'p_u_t3stlng',
            ssh_key   => 'ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAv6f4BW89Afnsx51BkxGvPbLeqDK+o6RXp+82KSIhoiWzCJp/dwhB7xNBR0W7Lt/n7KJUGYdlP7h5YlmgvpdJayzMkbsoBW2Hj9/7MkFraUlWYIU9QtAUCOARBPQWC3JIkslVvInGBxMxH5vcCO0/3TM/FFZylPTXjyqmsVDgnY4C1zFW3SdGDh7+1NCDh4Jsved+UVE5KwN/ZGyWKpWXLqMlEFTTxJ1aRk563p8wW3F7cPQ59tLP+a3iHdH9sE09ynbI/I/tnAHcbZncwmdLy0vMA6Jp3rWwjXoxHJQLOfrLJzit8wzG867+RYDfm6SZWg7iYZYUlps1LSXSnUxuTQ== matt@SpryBook-Pro.local',
            test_mode => 1,
            debug     => 0,
            fatal     => 0,
        ),
        "create_virtualos, valid template ($template_that_exists)"
    );

    ok( $vos->create_virtualos(
            name        => $container_id_or_name,
            hostname    => 'test1.example.com',
            ip          => '10.0.1.73 10.0.1.74 10.0.1.75',
            template    => $template_that_exists,
            nameservers => '64.79.200.111 64.79.200.113',
            password  => 'p_u_t3stlng',
            ssh_key   => 'ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAv6f4BW89Afnsx51BkxGvPbLeqDK+o6RXp+82KSIhoiWzCJp/dwhB7xNBR0W7Lt/n7KJUGYdlP7h5YlmgvpdJayzMkbsoBW2Hj9/7MkFraUlWYIU9QtAUCOARBPQWC3JIkslVvInGBxMxH5vcCO0/3TM/FFZylPTXjyqmsVDgnY4C1zFW3SdGDh7+1NCDh4Jsved+UVE5KwN/ZGyWKpWXLqMlEFTTxJ1aRk563p8wW3F7cPQ59tLP+a3iHdH9sE09ynbI/I/tnAHcbZncwmdLy0vMA6Jp3rWwjXoxHJQLOfrLJzit8wzG867+RYDfm6SZWg7iYZYUlps1LSXSnUxuTQ== matt@SpryBook-Pro.local',
            test_mode   => 0,
            debug       => 0,
            fatal       => 0,
        ),
        'create_virtualos, valid request'
    )
    or diag $vos->create_virtualos(
        name      => $container_id_or_name,
        ip        => '10.0.1.76',
        debug     => 1,
        fatal     => 0,
    );

    ok( $vos->start_virtualos(
            name  => $container_id_or_name,
            debug => 0,
            fatal => 0,
        ),
        'start_virtualos'
    );

#exit;
#$prov->error( 'dump' );

    ok( $vos->restart_virtualos(
            name  => $container_id_or_name,
            debug => 0,
            fatal => 0,
        ),
        'restart_virtualos'
    );

    ok( $vos->set_password(
            name => $container_id_or_name,
            user => 'root',
            password => 'letm3iwchlnny',
            ssh_key  => 'ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAv6f4BW89Afnsx51BkxGvPbLeqDK+o6RXp+82KSIhoiWzCJp/dwhB7xNBR0W7Lt/n7KJUGYdlP7h5YlmgvpdJayzMkbsoBW2Hj9/7MkFraUlWYIU9QtAUCOARBPQWC3JIkslVvInGBxMxH5vcCO0/3TM/FFZylPTXjyqmsVDgnY4C1zFW3SdGDh7+1NCDh4Jsved+UVE5KwN/ZGyWKpWXLqMlEFTTxJ1aRk563p8wW3F7cPQ59tLP+a3iHdH9sE09ynbI/I/tnAHcbZncwmdLy0vMA6Jp3rWwjXoxHJQLOfrLJzit8wzG867+RYDfm6SZWg7iYZYUlps1LSXSnUxuTQ== matt@SpryBook-Pro.local',
        ),
        'set_password'
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

#exit;

    ok( $vos->destroy_virtualos(
            name      => $container_id_or_name,
            test_mode => 0,
            debug     => 0,
            fatal     => 0,
        ),
        'destroy_virtualos'
    );
};

#$prov->error( 'dump' );

