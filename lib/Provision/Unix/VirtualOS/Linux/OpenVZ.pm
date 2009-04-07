package Provision::Unix::VirtualOS::Linux::OpenVZ;

our $VERSION = '0.24';

use warnings;
use strict;

use English qw( -no_match_vars );
use File::Copy;
use Params::Validate qw(:all);

use lib 'lib';
use Provision::Unix::User;

our ( $prov, $vos, $util );

sub new {

    my $class = shift;

    my %p = validate( @_, { 'vos' => { type => OBJECT }, } );

    $vos  = $p{vos};
    $prov = $vos->{prov};

    my $self = { 
        vos  => $vos,
        util => undef,
    };
    bless( $self, $class );

    $prov->audit("loaded P:U:V::Linux::OpenVZ");

    $prov->{etc_dir} ||= '/etc/vz/conf';    # define a default

    require Provision::Unix::Utility;
    $util = Provision::Unix::Utility->new( prov => $prov );
    $self->{util} = $util;

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
    if ( $ctid =~ /^\d+$/ ) {
        $err = "ctid must be greater than $min" if ( $min && $ctid < $min );
        $err = "ctid must be less than $max"    if ( $max && $ctid > $max );
    };
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
    $cmd .= " --root $vos->{disk_root}"    if $vos->{disk_root};
    $cmd .= " --config $vos->{config}"     if $vos->{config};

    if ( $vos->{template} ) {
        my $template = $self->_is_valid_template( $vos->{template} )
            or return;
        $cmd .= " --ostemplate $template";
    }

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    my $r = $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 );
    if ( ! $r ) {
        $prov->error(
            message => "VPS creation failed, unknown error",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        );
    };

    $self->set_hostname()    if $vos->{hostname};
    sleep 1;
    $self->set_ips();
    sleep 1;
    $self->set_nameservers() if $vos->{nameservers};
    sleep 1;
    $self->set_password()    if $vos->{password};
    sleep 1;
    $self->start_virtualos();
    return $prov->audit("\tvirtual os created and launched");
}

sub destroy_virtualos {

    my $self = shift;

    $EUID == 0
        or $prov->error(
        message => "Destroy function requires root privileges." );

    my $name = $vos->{name};

    # make sure container name/ID exists
    return $prov->error(
        message => "container $name does not exist",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if !$self->is_present();

# TODO: if disabled, enable it

    # if VE is running, shut it down
    if ( $self->is_running( refresh => 0 ) ) {
        $prov->audit("\tcontainer '$name' is running, stopping...");
        $self->stop_virtualos() 
            or return
            $prov->error(
                message => "shut down failed. I cannot continue.",
                fatal   => $vos->{fatal},
                debug   => $vos->{debug},
            );
    };

# TODO: make sure none of the mounts are active

# TODO: optionally back it up
    if ( $vos->{safe_delete} ) {
        my $timestamp = localtime( time );
    };

    $prov->audit("\tdestroying $name...");

    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );
    $cmd .= " destroy $name";

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 );

    # we have learned better than to trust the return codes of vzctl
    if ( ! $self->is_present() ) {
        return $prov->audit("\tdestroyed container");
    };

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

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};
    $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 );

# the results of vzctl start are not reliable. Instead, use vzctl to
# check the VE status and see if it started.

    foreach ( 1..8 ) {
        return 1 if $self->is_running();
        sleep 1;   # the xm start create returns before the VE is running.
    };
    return 1 if $self->is_running();

    return $prov->error(
        message => "unable to start VE",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    );
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

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};
    $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 );

    foreach ( 1..8 ) {
        return 1 if ! $self->is_running();
        sleep 1;
    };
    return 1 if ! $self->is_running();

    return $prov->error(
        message => "unable to stop VE",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    );
}

sub restart_virtualos {

    my $self = shift;

    $self->stop_virtualos()
        or
        return $prov->error( 
            message => "unable to stop virtual $vos->{name}",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
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
    my $config = $self->get_config();
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
        message => "\tunable to move file '$config' to '$config.suspend': $!",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
        );

    return 1;
}

sub enable_virtualos {

    my $self = shift;

    my $ctid = $vos->{name};
    $prov->audit("enabling virtual $ctid");

    # make sure CTID exists 
    return $prov->error(
        message => "\tcontainer $ctid does not exist",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if ! $self->is_present();

    # make sure config file exists
    my $config = $self->get_config();
    if ( !-e "$config.suspend" ) {
        return $prov->error(
            message =>
                "\tconfiguration file ($config.suspend) for $ctid does not exist",
            fatal => $vos->{fatal},
            debug => $vos->{debug},
        );
    }

    # make sure container directory exists
    my $ct_dir = $self->get_ve_home();  # "/vz/private/$ctid";
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

sub reinstall_virtualos {

    my $self = shift;

    $self->destroy_virtualos()
        or
        return $prov->error( 
            message => "unable to destroy virtual $vos->{name}",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        );

    return $self->create_virtualos();
}

sub get_config {
    my $ctid   = $vos->{name};
    my $etc_dir = $prov->{etc_dir} || '/etc/vz/conf';
    my $config = "$etc_dir/$ctid.conf";
    return $config;
};

sub get_disk_usage {
    
    my $self = shift;

    $EUID == 0
        or return $prov->error(
        message => "Sorry, that requires root.",
        fatal   => 0,
        );


    my $name = $vos->{name};
    my $vzquota = $util->find_bin( bin => 'vzquota', debug => 0, fatal => 0 );
    $vzquota or return $prov->error( message => "Cannot find vzquota.", fatal => 0 );

    $vzquota .= " show $name";
    my $r = `$vzquota 2>/dev/null`;
# VEID 1002362 exist mounted running
# VEID 1002362 exist unmounted down
    if ( $r =~ /usage/ ) {
        my ($usage) = $r =~ /1k-blocks\s+(\d+)\s+/;
        return $usage if $usage;
    };
    return;

#    my $homedir = $self->get_ve_home();
#    $cmd .= " -s $homedir";
#    my $r = `$cmd`;
#    my ($usage) = split /\s+/, $r;
#    if ( $usage =~ /^\d+$/ ) {
#        return $usage;
#    };
#    return $prov->error( message => "du returned unknown result: $r", fatal => 0 );
}

sub get_os_template {
    
    my $self = shift;

    $EUID == 0 or return $prov->error(
        message => "Sorry, that requires root.",
        fatal   => 0,
    );

    my $config = $self->get_config();
    my $grep = $util->find_bin(bin=>'grep', debug => 0);
    my $r = `$grep OSTEMPLATE $config*`;
    my ($template) = $r =~ /OSTEMPLATE="(.+)"/i;
    return $template;
}

sub get_status {

    my $self = shift;
    my $name = $vos->{name};
    my %ve_info = ( name => $name );
    my $exists;

    $self->{status}{$name} = undef;  # reset this

    $EUID == 0
        or return $prov->error(
        message => "Status function requires root privileges.",
        fatal   => 0
        );

    my $vzctl = $util->find_bin( bin => 'vzctl', debug => 0, fatal => 0 );
    $vzctl or 
        return $prov->error( message => "Cannot find vzctl.", fatal => 0 );

# VEID 1002362 exist mounted running
# VEID 1002362 exist unmounted down
# VEID 100236X deleted unmounted down

    $vzctl .= " status $name";
    my $r = `$vzctl`;
    if ( $r =~ /deleted/i ) {
        my $config = $self->get_config();
        if ( -e "$config.suspend" ) {
            $exists++;
            $ve_info{state} = 'suspended';
        }
        else {
            $ve_info{state} = 'non-existent';
        };
    }
    elsif ( $r =~ /exist/i ) {
        $exists++;
        if ( $r =~ /running/i ) {
            $ve_info{state} = 'running';
        }
        elsif ( $r =~ /down/i ) {
            $ve_info{state} = 'shutdown';
        }
    }
    else {
        return $prov->error( message => "unknown output from vzctl status.", fatal => 0 );
    };

    return \%ve_info if ! $exists;

    if ( $ve_info{state} =~ /running|shutdown/ ) {
        my $vzlist = $util->find_bin( bin => 'vzlist', debug => 0, fatal => 0 );
        if ( $vzlist ) {
            my $vzs = `$vzlist --all`;

            if ( $vzs =~ /NPROC/ ) {

            #       VEID      NPROC STATUS  IP_ADDR         HOSTNAME
            #       10          - stopped 64.79.207.11    lbox-bll

                $self->{status} = {};
                foreach my $line ( split /\n/, $vzs ) {
                    my ( undef, $ctid, $proc, $state, $ip, $hostname ) = 
                        split /\s+/, $line;
                    next if $ctid eq 'VEID';  # omit header
                    next unless ($ctid && $ctid eq $name);
                    $ve_info{proc}  = $proc;
                    $ve_info{ip}    = $ip;
                    $ve_info{host}  = $hostname;
                    $ve_info{state} ||= _run_state($state);
                }
            };
        };
    }

    $ve_info{disk_use} = $self->get_disk_usage();
    $ve_info{os_template} = $self->get_os_template();

    $self->{status}{$name} = \%ve_info;
    return \%ve_info;

    sub _run_state {
        my $raw = shift;
        return $raw =~ /running/ ? 'running'
             : $raw =~ /stopped/ ? 'shutdown'
             :                     $raw;
    }
}

sub get_ve_home {
    my $self = shift;
    my $name = $vos->{name};
    my $disk_root = $vos->{disk_root} || '/vz/private';
    my $homedir = "$disk_root/$name";
    return $homedir;
};

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

    return $util->syscmd( cmd => $cmd, debug => 0, fatal => $vos->{fatal} );
}

sub set_password {
    my $self = shift;

    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );
    $cmd .= " set $vos->{name}";

    my $username = $vos->{user} || 'root';
    my $password = $vos->{password}
        or return $prov->error(
        message => 'set_password function called but password not provided',
        fatal   => $vos->{fatal},
        );

    $cmd .= " --userpasswd '$username:$password'";

    # not sure why but this likes to return gibberish, regardless of succeess or failure
    # $r = $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 );

    # so we do it this way, with no error handling
    system( $cmd );
    # has the added advantage that we don't log the VPS password in the audit log

    if ( $vos->{ssh_key} ) {
        my $user = Provision::Unix::User->new( prov => $prov );
        $user->install_ssh_key( 
            homedir => $self->get_ve_home(),  # "/vz/private/$ctid"
            ssh_key => $vos->{ssh_key},
            debug   => $vos->{debug},
        );
    };

    return 1;
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

    foreach my $ns (@$nameservers) { $cmd .= " --nameserver $ns"; }

    $cmd .= " --searchdomain $search" if $search;
    $cmd .= " --save";

    return $util->syscmd( cmd => $cmd, debug => 0, fatal => $vos->{fatal} );
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

    $cmd .= " --hostname $hostname --save" if $hostname;

    return $util->syscmd( 
        cmd => $cmd, 
        debug => $vos->{debug}, 
        fatal => $vos->{fatal}
    );
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
        {   'name'    => { type => SCALAR, optional => 1 },
            'refresh' => { type => SCALAR, optional => 1, default => 1 },
            'test_mode' => { type => SCALAR | UNDEF, optional => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $name = $p{name} || $vos->{name} or
        $prov->error( message => 'is_present was called without a CTID' );

    $self->get_status() if $p{refresh};
    return 1 if $self->{status}{ $name };
    return;
}

sub is_running {
    my $self = shift;

    my %p = validate(
        @_,
        {   'name'    => { type => SCALAR, optional => 1 },
            'refresh' => { type => SCALAR, optional => 1, default => 1 },
            'test_mode' => { type => SCALAR, optional => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $name = $p{name} || $vos->{name} or
         $prov->error( message => 'is_running was called without a CTID' );

    $self->get_status() if $p{refresh};
    return 1 if $self->{status}{$name}{state} eq 'running';
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

Copyright 2008 Matt Simerson

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

