use strict;
use warnings;

use Data::Dumper qw( Dumper );
use English qw( -no_match_vars );

use lib "lib";
use Provision::Unix;
use Provision::Unix::Utility;
use Provision::Unix::VirtualOS;

my $prov = Provision::Unix->new( debug => 0 );
my $util = Provision::Unix::Utility->new( prov => $prov );
my $vos  = Provision::Unix::VirtualOS->new( prov => $prov, fatal => 0, debug => 0 );

my $virt_class = ref $vos->{vtype};
my @parts = split /::/, $virt_class;
my $virt_type = lc( $parts[-1] );
print "virtualization type: $virt_type\n";


my $container_id_or_name = $util->ask( question => 'VPS name' );

if ( $vos->is_present( name => $container_id_or_name ) ) {
    my $r = $vos->get_status( name => $container_id_or_name ) or
        die "could not find $container_id_or_name\n";
    warn Dumper($r);
};

my $user = $util->ask(question=>'user name', default => 'root');
my $pass = $util->ask(question=>'password', password => 1 );
my $ssh_key = $util->ask(question=>'ssh_key' );

$vos->set_password( 
    name     => $container_id_or_name,
    user     => $user,
    password => $pass,
    ssh_key  => $ssh_key,
); 

$prov->error( message => 'dump' );
