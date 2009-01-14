package Provision::Unix::VirtualOS::Linux::OpenVZ;

our $VERSION = '0.12';

use warnings;
use strict;

use English qw( -no_match_vars );
use File::Copy;
use Params::Validate qw(:all);

my ( $prov, $vos, $util );

sub new {

    my $class = shift;

    my %p = validate( @_, { 'vos' => { type => OBJECT }, } );

    $vos  = $p{vos};
    $prov = $vos->{prov};

    my $self = { prov => $prov, };
    bless( $self, $class );

    $prov->audit("loaded VirtualOS::Linux::OpenVZ");

    $prov->{etc_dir} ||= '/etc/vz/conf';    # define a default

    require Provision::Unix::Utility;
    $util = Provision::Unix::Utility->new( prov => $prov );

    return $self;
}

sub create_virtualos {

    my $self = shift;

    $EUID == 0
        or $prov->error(
        message => "Create function requires root privileges." );

    my $ctid = $vos->{name};

    # do not create if it exists already
    return $prov->error(
        message => "ctid $ctid already exists",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if $self->is_present();

    # make sure $ctid is within accepable ranges
    my $err;
    my $min = $prov->{config}{VirtualOS}{id_min};
    my $max = $prov->{config}{VirtualOS}{id_max};
    $err = "ctid must be greater than $min" if ( $min && $ctid < $min );
    $err = "ctid must be less than $max"    if ( $max && $ctid > $max );
    if ( $err && $err ne '' ) {
        return $prov->error(
            message => $err,
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        );
    }

    # TODO
    # validate the config (package)

    $prov->audit("\tctid '$ctid' does not exist, creating...");

    # build the shell command to create
    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );

    $cmd .= " create $ctid";
    $cmd .= " --root $vos->{disk_root}" if $vos->{disk_root};
    $cmd .= " --hostname $vos->{hostname}" if $vos->{hostname};
    $cmd .= " --config $vos->{config}" if $vos->{config};

    if ( $vos->{template} ) {
        my $template = $self->_is_valid_template( $vos->{template} )
            or return;
        $cmd .= " --ostemplate $template";
    }

    $prov->audit("\tcmd: $cmd");

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    if ( $util->syscmd( cmd => $cmd, debug => 0, fatal => $vos->{fatal} ) ) {
        $self->set_hostname() if $vos->{hostname};
        $self->set_ips();
        $self->set_password()    if $vos->{password};
        $self->set_nameservers() if $vos->{nameservers};
        return $prov->audit("\tvirtual os created");
    }

    return $prov->error(
        message => "create failed, unknown error",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    );
}

sub destroy_virtualos {

    my $self = shift;

    $EUID == 0
        or $prov->error(
        message => "Destroy function requires root privileges." );

    my $ctid = $vos->{name};

    # make sure CTID exists
    return $prov->error(
        message => "container $ctid does not exist",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if !$self->is_present();

    $prov->audit("\tctid '$ctid' found, destroying...");

    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );
    $cmd .= " destroy $vos->{name}";
    $prov->audit("\tcmd: $cmd");

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    # see if VE is running, and if so, stop it
    $self->stop_virtualos() if $self->is_running( refresh => 0 );

    if ( $util->syscmd( cmd => $cmd, debug => 0, fatal => $vos->{fatal} ) ) {
        return $prov->audit("\tdestroyed container");
    }

    return $prov->error(
        message => "destroy failed, unknown error",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    );
}

sub start_virtualos {

    my $self = shift;

    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );

    $cmd .= ' start';
    $cmd .= " $vos->{name}";
    $cmd .= " --force" if $vos->{force};
    $cmd .= " --wait" if $vos->{'wait'};

    $prov->audit("\tcmd: $cmd");

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};
    return $util->syscmd( cmd => $cmd, debug => 0 );
}

sub stop_virtualos {

    my $self = shift;

    my $ctid = $vos->{name};
    $prov->audit("stopping virtual $ctid");

    # make sure CTID exists
    return $prov->error(
        message => "\tcontainer $ctid does not exist",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if !$self->is_present();

    # see if VE is running
    if ( !$self->is_running( refresh => 0 ) ) {
        return $prov->error(
            message => "\tcontainer $ctid is not running",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        );
    }

    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );
    $cmd .= " stop $vos->{name}";

    $prov->audit("\tcmd: $cmd");

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};
    return $util->syscmd( cmd => $cmd, debug => 0 );
}

sub restart_virtualos {

    my $self = shift;

    $self->stop_virtualos()
        or
        return $prov->error( message => "unable to stop virtual $vos->{name}",
        );

    return $self->start_virtualos();
}

sub disable_virtualos {

    my $self = shift;

    my $ctid = $vos->{name};
    $prov->audit("disabling virtual $ctid");

    # make sure CTID exists
    return $prov->error(
        message => "\tcontainer $ctid does not exist",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if !$self->is_present();

    # make sure config file exists
    my $config = "$prov->{etc_dir}/$ctid.conf";
    if ( !-e $config ) {
        return $prov->error(
            message =>
                "\tconfiguration file ($config) for $ctid does not exist",
            fatal => $vos->{fatal},
            debug => $vos->{debug},
        );
    }

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    # see if VE is running, and if so, stop it
    $self->stop_virtualos() if $self->is_running( refresh => 0 );

    move( $config, "$config.suspend" )
        or return $prov->error(
        message => "\tunable to move file '$config': $!",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
        );

    return 1;
}

sub enable_virtualos {

    my $self = shift;

    my $ctid = $vos->{name};
    $prov->audit("enabling virtual $ctid");

    # make sure CTID does not exist (if it does, account is not disabled)
    return $prov->error(
        message => "\tcontainer $ctid exists and should not (when disabled)",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if $self->is_present();

    # make sure config file exists
    my $config = "$prov->{etc_dir}/$ctid.conf";
    if ( !-e "$config.suspend" ) {
        return $prov->error(
            message =>
                "\tconfiguration file ($config.suspend) for $ctid does not exist",
            fatal => $vos->{fatal},
            debug => $vos->{debug},
        );
    }

    # make sure container directory exists
    my $ct_dir = "/vz/private/$ctid";
    if ( !-e $ct_dir ) {
        return $prov->error(
            message =>
                "\tcontainer directory '$ct_dir' for $ctid does not exist",
            fatal => $vos->{fatal},
            debug => $vos->{debug},
        );
    }

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    move( "$config.suspend", $config )
        or return $prov->error(
        message => "\tunable to move file '$config': $!",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
        );

    return $self->start_virtualos();
}

sub modify_virtualos {

    my $self = shift;

    $EUID == 0
        or $prov->error(
        message => "Modify function requires root privileges." );

    my $ctid = $vos->{name};

    # cannot modify unless it exists
    return $prov->error(
        message => "ctid $ctid does not exist",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if !$self->is_present();

    $prov->audit("\tcontainer '$ctid' exists, modifying...");

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    $self->set_hostname()    if $vos->{hostname};
    $self->set_ips()         if $vos->{ip};
    $self->set_password()    if $vos->{password};
    $self->set_nameservers() if $vos->{nameservers};

# TODO: this almost certainly needs some error checking, as well as more code to do other things that should be done here. If I knew what, I'd have put them here. mps.

    return $prov->audit("\tcontainer modified");

    return $prov->error(
        message => "modify failed, unknown error",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    );
}

sub get_status {

    my $self = shift;

    $EUID == 0
        or return $prov->error(
        message => "Status function requires root privileges.",
        fatal   => 0
        );

    my $cmd = $util->find_bin( bin => 'vzlist', debug => 0, fatal => 0 );
    ($cmd)
        or
        return $prov->error( message => "Cannot find vzlist.", fatal => 0 );

    my $vzs = `$cmd --all`;
    $vzs =~ /NPROC/
        or return $prov->error(
        message => "vzlist did not return valid output.",
        fatal   => 0
        );

    #       VEID      NPROC STATUS  IP_ADDR         HOSTNAME
    #       10          - stopped 64.79.207.11    lbox-bll

    $self->{status} = {};
    foreach my $line ( split /\n/, $vzs ) {

        #print "line: $line\n";
        my ( undef, $ctid, $proc, $status, $ip, $hostname ) = split /\s+/,
            $line;
        next unless $ctid;
        $self->{status}{$ctid} = {
            proc   => $proc,
            status => $status,
            ip     => $ip,
            host   => $hostname
        };
    }

    if ( $vos->{name} ) {
        return $self->{status}{ $vos->{name} };
    }
    return $self->{status};
}

sub set_ips {
    my $self = shift;

    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );
    $cmd .= " set $vos->{name}";

    my $ips = $vos->{ip};
    @$ips > 0
        or return $prov->error(
        message => 'set_ips called but no valid IPs were provided',
        fatal   => $vos->{fatal},
        );

    foreach my $ip ( @{ $vos->{ip} } ) {
        $cmd .= " --ipadd $ip";
    }
    $cmd .= " --save";

    $prov->audit("\tcmd: $cmd");
    return $util->syscmd( cmd => $cmd, debug => 0 );
}

sub set_password {
    my $self = shift;

    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );
    $cmd .= " set $vos->{name}";

    my $user = $vos->{user} || 'root';
    my $pass = $vos->{password}
        or return $prov->error(
        message => 'set_password function called but password not provided',
        fatal   => $vos->{fatal},
        );

    $cmd .= " --userpasswd $user:$pass";

    $prov->audit("\tcmd: $cmd");
    return $util->syscmd( cmd => $cmd, debug => 0 );
}

sub set_nameservers {
    my $self = shift;

    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );
    $cmd .= " set $vos->{name}";

    my $search      = $vos->{searchdomain};
    my $nameservers = $vos->{nameservers}
        or return $prov->error(
        message =>
            'set_nameservers function called with no valid nameserver ips',
        fatal => $vos->{fatal},
        debug => $vos->{debug},
        );

    foreach my $ns (@$nameservers) {
        $cmd .= " --nameserver $ns";
    }

    $cmd .= " --searchdomain $search" if $search;
    $cmd .= " --save";

    $prov->audit("cmd: $cmd");
    return $util->syscmd( cmd => $cmd, debug => 0 );
}

sub set_hostname {
    my $self = shift;

    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );
    $cmd .= " set $vos->{name}";

    my $hostname = $vos->{hostname}
        or return $prov->error(
        message => 'set_hostname function called with no hostname defined',
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
        );

    $cmd .= " --hostname $hostname  --save" if $hostname;

    $prov->audit("\tcmd: $cmd");

    return $util->syscmd( cmd => $cmd, debug => $vos->{debug} );
}

sub pre_configure {

    # create /var/log/VZ (1777) and /vz/DELETED_VZ (0755)
    # get lock
    # do action(s)
    # release lock

}

sub is_present {
    my $self = shift;

    my %p = validate(
        @_,
        {   'name' =>
                { type => SCALAR, optional => 1, default => $vos->{name} },
            'refresh' => { type => SCALAR, optional => 1, default => 1 },
            'test_mode' => { type => SCALAR | UNDEF, optional => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $p{name}
        || $prov->error( message => 'is_present was called without a CTID' );
    $self->get_status() if $p{refresh};
    return 1 if $self->{status}{ $p{name} };
    return;
}

sub is_running {
    my $self = shift;

    my %p = validate(
        @_,
        {   'name' =>
                { type => SCALAR, optional => 1, default => $vos->{name} },
            'refresh' => { type => SCALAR, optional => 1, default => 1 },
            'test_mode' => { type => SCALAR | UNDEF, optional => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $p{name}
        || $prov->error( message => 'is_running was called without a CTID' );
    $self->get_status() if $p{refresh};
    return 1 if $self->{status}{ $p{name} }{status} eq 'running';
    return;
}

sub _is_valid_template {

    my $self     = shift;
    my $template = shift;

    my $template_dir = $self->{prov}{config}{ovz_template_dir} || '/vz/template/cache';
    if ( -f "$template_dir/$template.tar.gz" ) {
        return $template;
    }

    # is $template a URL?
    my ( $protocol, $host, $path, $file )
        = $template
        =~ /^((http[s]?|rsync):\/)?\/?([^:\/\s]+)((\/\w+)*\/)([\w\-\.]+[^#?\s]+)(.*)?(#[\w\-]+)?$/;
    if ( $protocol && $protocol =~ /http|rsync/ ) {
        $prov->audit("fetching $file with $protocol");

        # TODO
        # stor01:/usr/local/cosmonaut/templates/vpslink

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

sub _is_valid_name {
    my $self = shift;
    my $name = shift;

    if ( $name !~ /^[0-9]+$/ ) {
        return $prov->error(
            message => "OpenVZ requires the name (VEID/CTID) to be numeric",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        );
    }
    return 1;
}

1;

__END__

=head1 NAME

Provision::Unix::VirtualOS::Linux::OpenVZ - 

=head1 VERSION

Version 0.12

=head1 SYNOPSIS

Quick summary of what the module does.

Perhaps a little code snippet.

    use Provision::Unix::VirtualOS::OpenVZ;

    my $foo = Provision::Unix::VirtualOS::OpenVZ->new();
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

Copyright 2008 Matt Simerson, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

