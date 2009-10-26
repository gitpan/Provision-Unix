package Provision::Unix::VirtualOS::FreeBSD::Jail;

use warnings;
use strict;

our $VERSION = '0.06';

use English qw( -no_match_vars );
use Params::Validate qw(:all);

my ( $prov, $vos, $util );

sub new {
    my $class = shift;

    my %p = validate( @_, { 'vos' => { type => OBJECT }, } );

    $vos  = $p{vos};
    $prov = $vos->{prov};

    my $self = { prov => $prov };
    bless( $self, $class );

    die "Not finished. Only ezjail is currently supported on FreeBSD";

    $prov->audit( $class . sprintf( " loaded by %s, %s, %s", caller ) );

    return $self;
}

sub create_virtualos {

# Usage      : $virtual->create_virtualos( name => 'mysql', ip=>'127.0.0.2' );
# Purpose    : create a virtual OS instance
# Returns    : true or undef on failure
# Parameters :
#   Required : name     - name/ID of the virtual instance
#            : ip       - IP address(es), space delimited
#   Optional : disk_root   - the root directory of the virt os
#            : template - a 'template' or tarball to pattern as
#            :

    my $self = shift;

    $EUID == 0
        or $prov->error( "Create function requires root privileges." );

    my $ctid = $vos->{name};
    my %std_opts = ( debug => $vos->{debug}, fatal => $vos->{fatal} );

    return $prov->error( "ctid $ctid already exists", %std_opts) 
        if $self->is_present();

    $prov->audit("\tctid '$ctid' does not exist, creating...");


}

sub is_present {
    my $self = shift;
    my $homedir = $self->get_ve_home();
    return $homedir if -d $homedir;
    return;
};

sub get_console {
    my $self = shift;
    my $ctid = $vos->{name};
    my $cmd = $util->find_bin( bin => 'jexec', debug => 0 );
    exec "$cmd $ctid su";
};

sub get_ve_home {
    my $self = shift;
    my $ctid = $vos->{name} || shift;
    return if ! $ctid;
    return "/usr/jails/$ctid";
};

sub enable_virtualos {
};
sub destroy_virtualos {
};
sub disable_virtualos {
};
sub restart_virtualos {
};
sub start_virtualos {
};
sub stop_virtualos {
};
sub set_password {
};

1;

__END__

=head1 NAME

Provision::Unix::VirtualOS::FreeBSD::Jail - 

=head1 SYNOPSIS

Quick summary of what the module does.

Perhaps a little code snippet.

    use Provision::Unix::VirtualOS::FreeBSD::Jail;

    my $foo = Provision::Unix::VirtualOS::FreeBSD::Jail->new();
    ...


=head1 FUNCTIONS

=head2 function1

=cut

=head1 AUTHOR

Matt Simerson, C<< <matt at tnpi.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-unix-provision-virtualos at rt.cpan.org>, or through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Provision-Unix>.  I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Provision::Unix::VirtualOS::FreeBSD::Jail


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Provision-Unix>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Provision-Unix>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Provision-Unix>

=item * Search CPAN

L<http://search.cpan.org/dist/Provision-Unix>

=back


=head1 ACKNOWLEDGEMENTS


=head1 COPYRIGHT & LICENSE

Copyright 2008 Matt Simerson

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
