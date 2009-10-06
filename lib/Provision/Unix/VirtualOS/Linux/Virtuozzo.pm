package Provision::Unix::VirtualOS::Linux::Virtuozzo;
use base Provision::Unix::VirtualOS::Linux::OpenVZ;

our $VERSION = '0.05';

use warnings;
use strict;

use English qw( -no_match_vars );
use File::Copy;
use Params::Validate qw(:all);

my ($vos, $prov, $util, $linux);

sub new {
    my $class = shift;
    my %p = validate( @_, { vos => { type => OBJECT } } );

    $vos   = $p{vos};
    $prov  = $vos->{prov};
    $util  = $vos->{util};
    $linux = $vos->{linux};

    my $self = bless { }, $class;

    $prov->audit("loaded P:U:V::Linux::Virtuozzo");

    $prov->{etc_dir} ||= '/etc/vz/conf';    # define a default

    return $self;
}

sub create_virtualos {
    my $self = shift;

    my $ctid = $vos->{name};

    $EUID == 0
        or $prov->error( "That requires root privileges." ); 

    # make sure it doesn't exist already
    return $prov->error( "container $ctid already exists",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if $self->is_present();

    # make sure $ctid is within accepable ranges
    my $err;
    my $min = $prov->{config}{VirtualOS}{id_min};
    my $max = $prov->{config}{VirtualOS}{id_max};    
    if ( $ctid =~ /^\d+$/ ) {
        $err = "container must be greater than $min" if ( $min && $ctid < $min );
        $err = "container must be less than $max"    if ( $max && $ctid > $max );
    };

    if ( $err && $err ne '' ) {
        return $prov->error( $err,
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        );
    }

    $prov->audit("\tcontainer '$ctid' does not exist, creating...");

#/usr/sbin/vzctl create 72000 --pkgset centos-4 --config vps.256MB

    # build the shell command to create
    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );

    $cmd .= " create $ctid";
    $cmd .= " --root $vos->{disk_root}" if $vos->{disk_root};
    $cmd .= " --hostname $vos->{hostname}" if $vos->{hostname};
    $cmd .= " --config $vos->{config}" if $vos->{config};

    if ( $vos->{template} ) {
        my $template = $self->_is_valid_template( $vos->{template} )
            or return;
        my @bits = split '-', $template;
        pop @bits;    # remove the stuff after the last hyphen
        my $pkgset = join '-', @bits;
        $cmd .= " --pkgset $pkgset";
        # $cmd .= " --ostemplate $template";
    }
    
    my @configs = </etc/vz/conf/ve-*.conf-sample>;
    no warnings;
    my @sorted = 
        sort { ( $b =~ /(\d+)/)[0] <=> ($a =~ /(\d+)/)[0] } 
            grep { /vps/ } @configs;
    use warnings;
    if ( scalar @sorted > 1 ) {
        my ( $config ) = $sorted[0] =~ /ve-(.*)\.conf-sample$/;
        $cmd .= " --config $config";
    };

    $prov->audit("\tcmd: $cmd");

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    if ( $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 ) ) {
        $linux->set_hostname()   if $vos->{hostname};
        $linux->set_ips();
        $self->set_password()    if $vos->{password};
        $self->set_nameservers() if $vos->{nameservers};
        return $prov->audit("\tvirtual os created");
    }

    return $prov->error( "create failed, unknown error",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    );
}

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

        return $prov->error( 'template does not exist and programmers have not yet written the code to retrieve templates via URL',
            fatal => 0
        );
    }
        
    return $prov->error( 
            "template '$template' does not exist and is not a valid URL",
        debug => $vos->{debug},
        fatal => $vos->{fatal},
    );  
}   


1;

__END__

=head1 NAME

Provision::Unix::VirtualOS::Linux::Virtuozzo - 


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

