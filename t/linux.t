use strict;
use warnings;

use English qw( -no_match_vars );
use Test::More;

use lib 'lib';
use Provision::Unix;
use Provision::Unix::VirtualOS;
use Provision::Unix::VirtualOS::Linux;

my $prov = Provision::Unix->new( debug => 0 );

if ( $OSNAME ne 'linux' ) {
    plan skip_all => 'linux specific tests';
} 
else {
    plan 'no_plan';
};

my $vos = Provision::Unix::VirtualOS( prov => $prov );
my $linux = Provision::Unix::VirtualOS::Linux->new();

my $fs_root = $vos->get_fs_root('12345');

my $config = $linux->set_ips_debian( 
    fs_root   => $fs_root,
    ips       => [ '67.223.249.65', '1.1.1.1'  ],
    test_mode => 1,
);

$config = $linux->set_ips( 
    fs_root   => $fs_root,
    ips       => [ '67.223.249.65', '1.1.1.1'  ],
    test_mode => 1,
    distro    => 'redhat',
);
#print $config;

$linux->install_kernel_modules(
    test_mode => 1,
    version   => 2.0,
    fs_root   => $fs_root,
);
