package Provision::Unix::Web::Lighttpd;

use warnings;
use strict;

our $VERSION = '0.02';

use Carp;
use Params::Validate qw( :all );

use lib "lib";

use Provision::Unix;
my $prov = Provision::Unix->new;

sub new {
    my $class = shift;
    my $self  = {};
    bless( $self, $class );
    return $self;
}


1;

__END__

=head1 NAME

Provision::Unix::Web::Lighttpd - Provision web hosting accounts on lighttpd

=head1 VERSION

Version 0.02


=head1 SYNOPSIS

Provision web hosting accounts.

    use Provision::Unix::Web::Lighttpd;

    my $foo = Provision::Unix::Web::Lighttpd->new();
    ...

=head1 FUNCTIONS


=head2 new

Creates and returns a new Provision::Unix::Web::Lighttpd object.


=head1 AUTHOR

Matt Simerson, C<< <matt at tnpi.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-unix-provision-web at rt.cpan.org>, or through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Provision-Unix>.  I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.



=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Provision::Unix::Web::Lighttpd


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

Copyright 2008 Matt Simerson, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

