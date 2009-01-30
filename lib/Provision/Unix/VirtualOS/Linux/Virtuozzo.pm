package Provision::Unix::VirtualOS::Linux::Virtuozzo;

our $VERSION = '0.02';

use lib 'lib';
use base Provision::Unix::VirtualOS::Linux::OpenVZ;

use warnings;
use strict;

use English qw( -no_match_vars );
use File::Copy;
use Params::Validate qw(:all);

sub _is_valid_template {

    my $self     = shift;
    my $template = shift;

    my $vos  = $self->{vos};
    my $util = $self->{util};
    my $prov = $vos->{prov};

    my $template_dir = $self->{prov}{config}{virtuozzo_template_dir} || '/vz/template';
    if ( -f "$template_dir/$template.tar.gz" ) {
        return $template;
    }

    # is $template a URL?
    my ( $protocol, $host, $path, $file )
        = $template
        =~ /^((http[s]?|rsync):\/)?\/?([^:\/\s]+)((\/\w+)*\/)([\w\-\.]+[^#?\s]+)(.*)?(#[\w\-]+)?$/;
    if ( $protocol && $protocol =~ /http|rsync/ ) {
        $prov->audit("fetching $file with $protocol");

        # TODO        # stor01:/usr/local/cosmonaut/templates/vpslink

        return $prov->error(
            message =>
                'template does not exist and programmers have not yet written the code to retrieve templates via URL',
            fatal => 0
        );
    }
        
    return $prov->error(
        message =>
            "template '$template' does not exist and is not a valid URL",
        debug => $vos->{debug},
        fatal => $vos->{fatal},
    );  
}   


1;

__END__

=head1 NAME

Provision::Unix::VirtualOS::Linux::Virtuozzo - 

=head1 VERSION

Version 0.12

=head1 SYNOPSIS

Quick summary of what the module does.

Perhaps a little code snippet.

    use Provision::Unix::VirtualOS::Virtuozzo;

    my $foo = Provision::Unix::VirtualOS::Virtuozzo->new();
    ...

=head1 FUNCTIONS

=head2 function1


=head1 AUTHOR

Matt Simerson, C<< <matt at tnpi.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-unix-provision-virtualos at rt.cpan.org>, or through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Provision-Unix>.  I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Provision::Unix


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

