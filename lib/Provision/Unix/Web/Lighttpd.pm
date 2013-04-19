package Provision::Unix::Web::Lighttpd;
# ABSTRACT: provision www virtual hosts on lighttpd

use strict;
use warnings;

our $VERSION = '0.02';

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



=pod

=head1 NAME

Provision::Unix::Web::Lighttpd - provision www virtual hosts on lighttpd

=head1 VERSION

version 1.06

=head1 AUTHOR

Matt Simerson <msimerson@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2013 by The Network People, Inc..

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut


__END__

