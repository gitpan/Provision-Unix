package Provision::Unix::VirtualOS::FreeBSD::Ezjail;

our $VERSION = '0.08';

use warnings;
use strict;

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

    $prov->audit("loaded VirtualOS::FreeBSD::Ezjail");

    require Provision::Unix::Utility;
    $util = Provision::Unix::Utility->new( prov => $prov );

    return $self;
}

sub create_virtualos {
    my $self = shift;

    # Templates in ezjail are 'flavours' or archives

    # ezjail-admin create -f default [-r jailroot] [-i|c -s 512]
    # ezjail-admin create -a archive

    my $admin = $util->find_bin( bin => 'ezjail-admin', debug => 0 );
    my $cmd = "$admin ";

    my $jails_root = _get_jails_root() || '/usr/jails';

    if (   $vos->{disk_root}
        && $vos->{disk_root} ne "$jails_root/$vos->{name}" )
    {
        $cmd .= " -r $vos->{disk_root}";
    }

    my $template = $vos->{template} || 'default';
    if ($template) {
        if ( -d "$jails_root/flavours/$template" ) {
            $prov->audit("detected ezjail flavour $template");
            $cmd .= " -f $template";
        }
        elsif ( -f "$jails_root/$template.tgz" ) {
            $prov->audit("installing from archive $template");
            $cmd .= " -a $jails_root/$template.tgz";
        }
        else {
            $prov->error( message =>
                    "You chose the template ($template) but it is not defined as a flavor in $jails_root/flavours or an archive at $jails_root/$template.tgz"
            );
        }
    }

    $cmd .= " -s $vos->{disk_size}" if $vos->{disk_size};

    $prov->audit("cmd: $cmd $vos->{name} $vos->{ip}");
    return 1 if $vos->{test_mode};
    return $util->syscmd( cmd => $cmd );
}

sub _get_jails_root {
    my $r = `grep '^ezjail_jaildir' /usr/local/etc/ezjail.conf`;
    if ($r) {
        chomp $r;
        ( undef, $r ) = split /=/, $r;
        return $r;
    }
    return undef;
}

1;

__END__

=head1 NAME

Provision::Unix::VirtualOS::FreeBSD::Ezjail - 

=head1 VERSION

Version 0.08

=head1 SYNOPSIS

Quick summary of what the module does.

Perhaps a little code snippet.

    use Provision::Unix::VirtualOS::FreeBSD::Ezjail;

    my $foo = Provision::Unix::VirtualOS::FreeBSD::Ezjail->new();
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

    perldoc Provision::Unix::VirtualOS::FreeBSD::Ezjail


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
