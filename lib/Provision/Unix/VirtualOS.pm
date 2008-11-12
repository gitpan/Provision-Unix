package Provision::Unix::VirtualOS;

use warnings;
use strict;

our $VERSION = '0.04';

use English qw( -no_match_vars );
use Params::Validate qw(:all);

sub new {
    my $class = shift;
    my %p     = validate(
        @_,
        {   prov  => { type => HASHREF },
            debug => { type => BOOLEAN, optional => 1, default => 1 },
            fatal => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $self = {
        prov  => $p{prov},
        debug => $p{debug},
        fatal => $p{fatal},
    };
    bless( $self, $class );

    $self->{prov}->audit("loaded Virtual OS");
    $self->{vtype} = $self->_get_virt_type();
    return $self;
}

sub create_virtualos {

# Usage      : $virtual->create_virtualos( name => 'mysql', ip=>'127.0.0.2' );
# Purpose    : create a virtual OS instance
# Returns    : true or undef on failure
# Parameters :
#   Required : name     - name/ID of the virtual instance
#            : ip       - IP address(es), space delimited
#   Optional : fsroot   - the root directory of the virt os
#            : template - a 'template' or tarball to pattern as
#            : size     - disk space allotment

    my $self = shift;
    $self->{vtype}->create_virtualos(@_);
};

sub _get_virt_type {

    my $self = shift;
    my $prov = $self->{prov};

    my $type = $prov->{config}{VirtualOS}{type}
        or $prov->error(
        message => 'missing [VirtualOS] settings in provision.conf' );

    if ( $type eq 'jail' ) {
        require Provision::Unix::VirtualOS::FreeBSD::Jail;
        return Provision::Unix::VirtualOS::FreeBSD::Jail->new( prov => $prov );
    }
    elsif ( $type eq 'ezjail' ) {
        require Provision::Unix::VirtualOS::FreeBSD::Ezjail;
        return Provision::Unix::VirtualOS::FreeBSD::Ezjail->new( prov => $prov );
    }
    elsif ( $type eq 'container' ) {
        require Provision::Unix::VirtualOS::Solaris::Container;
        return Provision::Unix::VirtualOS::Solaris::Container->new( prov => $prov );
    }
    elsif ( $type eq 'xen' ) {
        require Provision::Unix::VirtualOS::Linux::Xen;
        return Provision::Unix::VirtualOS::Linux::Xen->new( prov => $prov );
    }
    elsif ( $type eq 'openvz' ) {
        require Provision::Unix::VirtualOS::Linux::OpenVZ;
        return Provision::Unix::VirtualOS::Linux::OpenVZ->new( prov => $prov );
    }
    else {
        $prov->error( message => "no support for $type yet" );
    }
}


1;

__END__

=head1 NAME

Provision::Unix::VirtualOS - Provision virtual OS instances (jail|vps|container)

=head1 VERSION

Version 0.04


=head1 SYNOPSIS


    use Provision::Unix::VirtualOS;

    my $foo = Provision::Unix::VirtualOS->new();
    ...


=head1 FUNCTIONS


=head1 AUTHOR

Matt Simerson, C<< <matt at tnpi.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-unix-provision-virtualos at rt.cpan.org>, or through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Provision-Unix>.  I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.  



=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Provision::Unix::VirtualOS


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Provision-Unix-VirtualOS>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Provision-Unix-VirtualOS>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Provision-Unix-VirtualOS>

=item * Search CPAN

L<http://search.cpan.org/dist/Provision-Unix-VirtualOS>

=back


=head1 ACKNOWLEDGEMENTS


=head1 COPYRIGHT & LICENSE

Copyright 2008 Matt Simerson, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

