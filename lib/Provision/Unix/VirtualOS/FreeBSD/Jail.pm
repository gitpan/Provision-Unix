package Provision::Unix::VirtualOS::FreeBSD::Jail;

use warnings;
use strict;

our $VERSION = '0.03';

use English qw( -no_match_vars );
use Params::Validate qw(:all);

sub new {
    my $class = shift;

    my %p = validate( @_, { 'vos' => { type => OBJECT }, } );

    my $vos  = $p{vos};
    my $prov = $vos->{prov};

    my $self = { prov => $prov };
    bless( $self, $class );

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

    my %p = validate(
        @_,
        {   'name'      => { type => SCALAR },
            'ip'        => { type => SCALAR },
            'disk_root' => { type => SCALAR },
            'template'  => { type => SCALAR | UNDEF, optional => 1 },
        }
    );

}

sub is_present {
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
