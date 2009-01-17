package Provision::Unix::Mail;

use warnings;
use strict;

our $VERSION = '0.04';

sub new {
    my $class = shift;
    my $self = { debug => 1, fatal => 1 };
    bless( $self, $class );
    return $self;
}

sub create_ {

}

1;

__END__

=head1 NAME

Provision::Unix::Mail - Provision email user and domain accounts

=head1 VERSION

Version 0.04

=head1 SYNOPSIS

Provision email accounts and domains on various Unix based email servers.

    use Provision::Unix::Mail;

    my $mail = Provision::Unix::Mail->new();
    ...

=head1 FUNCTIONS



=head1 AUTHOR

Matt Simerson, C<< <matt at tnpi.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-unix-provision-mail at rt.cpan.org>, or through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Provision-Unix>.  I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Provision::Unix::Mail


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

1;
