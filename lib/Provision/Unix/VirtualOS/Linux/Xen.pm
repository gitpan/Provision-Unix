package Provision::Unix::VirtualOS::Linux::Xen;

our $VERSION = '0.18';

use warnings;
use strict;

use English qw( -no_match_vars );

#use Data::Dumper;
use File::Copy;
use Params::Validate qw(:all);

my ( $prov, $vos, $util );

sub new {

    my $class = shift;

    my %p = validate( @_, { 'vos' => { type => OBJECT }, } );

    $vos  = $p{vos};
    $prov = $vos->{prov};

    my $self = { prov => $prov };
    bless( $self, $class );

    $prov->audit("loaded VirtualOS::Linux::Xen");

    $vos->{disk_root} ||= '/home/xen';    # xen default

    require Provision::Unix::Utility;
    $util = Provision::Unix::Utility->new( prov => $prov );

    return $self;
}

sub create_virtualos {
    my $self = shift;

    $EUID == 0
        or $prov->error(
        message => "Create function requires root privileges." );

    my $ctid = $vos->{name} or die "name of container missing!\n";

    # do not create if it exists already
    return $prov->error(
        message => "ctid $ctid already exists",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if $self->is_present();

    $self->is_valid_template( $vos->{template} )
        or return $prov->error(
        message => "no valid template specified",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
        );

    my $xm = $util->find_bin( bin => 'xm', debug => $vos->{debug} );

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    $self->create_swap_image()
        or $prov->error( message => "unable to create swap" );
    $self->create_disk_image()
        or $prov->error( message => "unable to create disk image" );
    $self->extract_template()
        or $prov->error(
        message => "unable to extract template onto disk image" );
    $self->install_config_file()
        or $prov->error( message => "unable to install config file" );

    # TODO:
    # set_hostname
    # set_ips
    # set_password
    # set_nameservers

    return 1;
}

sub destroy_virtualos {

    my $self = shift;

    $EUID == 0
        or $prov->error(
        message => "Destroy function requires root privileges." );

    my $ctid = $vos->{name};

    $prov->audit("checking if $ctid exists");

    # make sure CTID exists
    return $prov->error(
        message => "container $ctid does not exist",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if !$self->is_present();

    $prov->audit("\tctid '$ctid' found, checking state...");

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    # shut it down if running
    $self->stop_virtualos() if $self->is_running();

    $prov->audit("\tctid '$ctid' is stopped. Nuking it...");
    $self->destroy_disk_image();
    $self->destroy_swap_image();

    my $container_dir = $self->get_ve_home() or
        $prov->error( message => "could not deduce the containers home dir" );

    return 1 if ! -d $container_dir;

    my $cmd = $util->find_bin( bin => 'rm', debug => 0 );
    $prov->audit("$cmd -rf $container_dir");
    $util->syscmd(
        cmd   => "$cmd -rf $container_dir",
        debug => $vos->{debug},
        fatal => $vos->{fatal},
    );
    if ( -d $container_dir ) {
        $prov->error( message => "failed to delete $container_dir" );
    }
    return 1;
}

sub start_virtualos {
    my $self = shift;

    my $ctid = $vos->{name} or die "name of container missing!\n";

    # make sure it exists
    return $prov->error(
        message => "ctid $ctid does not exist",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if !$self->is_present();

    my $config_file = $self->get_ve_config_path();
    if ( !-e $config_file ) {
        $prov->error( message =>
                "config file for $ctid should be at $config_file and is missing."
        );
    }

    my $cmd = $util->find_bin( bin => 'xm', debug => 0 );
    $cmd .= " create $config_file";
    $prov->audit("\tcmd: $cmd");
    $util->syscmd( cmd => $cmd, debug => 0 )
        or $prov->error( message => "unable to start $ctid" );

    return 1 if $self->is_running();
    return;
}

sub stop_virtualos {
    my $self = shift;

    $prov->audit("\tctid '$vos->{name}' is running, stopping...");
    my $xm = $util->find_bin( bin => 'xm', debug => 0 );

    my $ve_name = $self->get_ve_name();

    # try a 'friendly' shutdown first for 25 seconds
    $util->syscmd(
        cmd     => "$xm shutdown -w $ve_name",
        debug   => 0,
        timeout => 25,
        fatal   => $vos->{fatal}
        )

        # if that didn't work, whack it with a bigger hammer
        or $util->syscmd(
        cmd   => "$xm destroy $ve_name",
        debug => 0,
        fatal => $vos->{fatal}
        );

    return 1 if !$self->is_running();
    return;
}

sub restart_virtualos {
    my $self = shift;

    my $ve_name = $self->get_ve_name();

    $self->stop_virtualos()
        or
        return $prov->error( message => "unable to stop virtual $ve_name",
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
    my $config = $self->get_ve_config_path();
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
    $self->stop_virtualos() if $self->is_running();

    $prov->audit("\tdisabling $ctid.");
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

    # make sure CTID exists
    return $prov->error(
        message => "\tcontainer $ctid does not exist",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if !$self->is_present();

    # make sure CTID is disabled
    return $prov->error(
        message => "\tcontainer $ctid is not disabled",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if $self->is_enabled();

    # make sure config file exists
    my $config = $self->get_ve_config_path();
    if ( !-e "$config.suspend" ) {
        return $prov->error(
            message =>
                "\tconfiguration file ($config.suspend) for $ctid does not exist",
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
}

sub create_disk_image {
    my $self = shift;

    my $img_name = "$vos->{name}_rootimg";
    my $size = $vos->{disk_size} || 1000;

    # create the disk image
    my $cmd = $util->find_bin( bin => 'lvcreate', debug => $vos->{debug} );
    $cmd .= " -L$size -n${img_name} vol00";
    $prov->audit("\tcmd: $cmd");
    $util->syscmd( cmd => $cmd, debug => 0 )
        or $prov->error( message => "unable to create $img_name" );

    # format it as ext3 file system
    $cmd = $util->find_bin( bin => 'mkfs.ext3', debug => $vos->{debug} );
    $cmd .= " /dev/vol00/${img_name}";
    $prov->audit("\tcmd: $cmd");
    return $util->syscmd( cmd => $cmd, debug => 0 );
}

sub create_swap_image {
    my $self = shift;

    my $img_name = "$vos->{name}_vmswap";
    my $ram      = $vos->{ram} || 128;
    my $size     = $ram * 2;

    # create the swap image
    my $cmd = $util->find_bin( bin => 'lvcreate', debug => $vos->{debug} );
    $cmd .= " -L$size -n${img_name} vol00";
    $prov->audit("\tcmd: $cmd");
    $util->syscmd( cmd => $cmd, debug => 0 )
        or $prov->error( message => "unable to create $img_name" );

    # format the swap file system
    $cmd = $util->find_bin( bin => 'mkswap', debug => $vos->{debug} );
    $cmd .= " /dev/vol00/${img_name}";
    $prov->audit("\tcmd: $cmd");
    $util->syscmd( cmd => $cmd, debug => 0 )
        or $prov->error( message => "unable to create $img_name" );
}

sub destroy_disk_image {
    my $self = shift;

    my $img_name = "$vos->{name}_rootimg";

    $prov->audit("checking for presense of $img_name");
    if ( -e "/dev/vol00/$img_name" ) {
        $prov->audit("\tfound it. You killed my father, prepare to die!");
        my $cmd = $util->find_bin( bin => 'lvremove', debug => $vos->{debug} );
        $cmd .= " -f vol00/${img_name}";
        $prov->audit("\tcmd: $cmd");
        $util->syscmd( cmd => $cmd, debug => 0 )
            or return $prov->error( message => "unable to destroy $img_name" );
        return 1;
    }
    return;
}

sub destroy_swap_image {
    my $self = shift;

    my $img_name = "$vos->{name}_vmswap";

    if ( -e "/dev/vol00/$img_name" ) {
        my $cmd
            = $util->find_bin( bin => 'lvremove', debug => $vos->{debug} );
        $cmd .= " -f vol00/${img_name}";
        $prov->audit("\tcmd: $cmd");
        $util->syscmd( cmd => $cmd, debug => 0 )
            or return $prov->error( message => "unable to destroy $img_name" );
        return 1;
    }
    return;
}

sub extract_template {
    my $self = shift;

    $self->is_valid_template( $vos->{template} )
        or return $prov->error(
        message => "no valid template specified",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
        );

    $self->mount_disk_image();

    my $ve_name      = $self->get_ve_name();
    my $mount_dir    = "$vos->{disk_root}/$ve_name/mnt";
    my $template_dir = $self->get_template_dir();

    #tar -zxf $template_dir/$OSTEMPLATE.tar.gz -C /home/xen/$ve_name/mnt

    # untar the template
    my $cmd = $util->find_bin( bin => 'tar', debug => $vos->{debug} );
    $cmd .= " -zxf $template_dir/$vos->{template}.tar.gz -C $mount_dir";
    $prov->audit("\tcmd: $cmd");
    $util->syscmd( cmd => $cmd, debug => 0 )
        or $prov->error(
        message => "unable to extract tarball $vos->{template}" );

    $self->unmount_disk_image();
}

sub get_random_mac {

    my $i;
    my $lladdr = '00:16:3E';

    while ( ++$i ) {
        last if $i > 6;
        $lladdr .= ':' if $i % 2;
        $lladdr .= sprintf "%" . ( qw (X x) [ int( rand(2) ) ] ),
            int( rand(16) );
    }

    # TODO:
    #   make sure random MAC does not conflict with an existing one.

    return $lladdr;
}

sub get_status {
    my $self = shift;

    my $ve_name = $self->get_ve_name();

    if ( ! $self->is_present() ) {
        my $error = "The xen VE $ve_name does not exist here!";
        return $prov->error( message => $error );
    };

    my $cmd = $util->find_bin( bin => 'xm', debug => 0 );
    $cmd .= ' list $ve_name';
    my $r = `$cmd`;
    my $error = 'could not get valid output from xm list';
    $r =~ /VCPUs/ or return $prov->error( message => $error );

    my ($xen_conf, $config);
    eval "require Provision::Unix::VirtualOS::Xen::Config";
    if ( ! $EVAL_ERROR ) {
        $xen_conf = Provision::Unix::VirtualOS::Xen::Config->new();
    };

    # get IPs and disks from the containers config file
    my ($ips, $disks );
    my $config_file = $self->get_ve_config_path();
    if ( -e $config_file ) {
        if ( $xen_conf && $xen_conf->read_config($config_file) ) {
            $ips   = $xen_conf->get_ips();
            $disks = $xen_conf->get('disk');
        };
    }
    else {
        warn "could not find $config_file\n";
    };

    $self->{status} = {};
    foreach my $line ( split /\n/, $r ) {

 # Name                               ID Mem(MiB) VCPUs State   Time(s)
 #test1.vm                            20       63     1 -b----     34.1

        my ( $ctid, $dom_id, $mem, $cpus, $state, $time ) = split /\s+/, $line;
        next unless $ctid;
        next if $ctid eq 'Name';
        next if $ctid eq 'Domain-0';
        next if $ctid ne $ve_name;

        $self->{status}{$ctid} = {
            ips      => $ips,
            disks    => $disks,
            dom_id   => $dom_id,
            mem      => $mem + 1,
            cpus     => $cpus,
            state    => _run_state($state),
            cpu_time => $time,
        };
        return $self->{status}{$ctid};
    }

    # a Xen VE that is shut down won't show up in the output of 'xm list'
    return {
        ips      => $ips,
        disks    => $disks,
        state    => 'shutdown',
    };

    sub _run_state {
        my $abbr = shift;
        return
              $abbr =~ /r/ ? 'running'
            : $abbr =~ /b/ ? 'running' # blocked is a 'wait' state, poorly named
            : $abbr =~ /p/ ? 'paused'
            : $abbr =~ /s/ ? 'shutdown'
            : $abbr =~ /c/ ? 'crashed'
            : $abbr =~ /d/ ? 'dying'
            :                undef;
    }
}

sub get_template_dir {
    my $self = shift;

    my $template_dir = $prov->{config}{VirtualOS}{xen_template_dir} || '/templates';
    return $template_dir;
};

sub get_ve_config_path {
    my $self = shift;
    my $ve_name     = $self->get_ve_name();
    my $config_file = "$vos->{disk_root}/$ve_name/$ve_name.cfg";
    return $config_file;
};

sub get_ve_home {
    my $self = shift;
    my $ve_name = $self->get_ve_name();
    my $homedir = "$vos->{disk_root}/$ve_name";
    return $homedir;
};

sub get_ve_name {
    my $self = shift;
    my $ctid = $vos->{name};
    my $suffix = '.vm';  # TODO: make this a config file option
    return $ctid . $suffix;
};

sub is_present {
    my $self = shift;

    my %p = validate(
        @_,
        {   'name'    => { type => SCALAR, optional => 1 },
            'refresh' => { type => SCALAR, optional => 1, default => 1 },
        }
    );

    my $name = $p{name} || $vos->{name} or
        $prov->error( message => 'is_present was called without a CTID' );

    my $ve_home = $self->get_ve_home();

    $prov->audit("checking for presense of virtual container $name");

    my @possible_paths = (
        $ve_home, "/dev/vol00/${name}_rootimg", "/dev/vol00/${name}_vmswap"
    );

    foreach my $path (@possible_paths) {
        $prov->audit("\tchecking at $path");
        if ( -e $path ) {
            $prov->audit("\tfound $name at $path");
            return $path;
        }
    }

    $prov->audit("\tdid not find $name");
    return;
}

sub is_running {

    my $self = shift;

    my %p = validate(
        @_, { 'refresh' => { type => SCALAR, optional => 1, default => 1 }, }
    );

    my $ve_name = $self->get_ve_name();

    $self->get_status() if $p{refresh};

    if ( $self->{status}{$ve_name} ) {
        my $state = $self->{status}{$ve_name}{state};
        return 1 if ( $state && $state eq 'running' );
    }
    return;
}

sub is_enabled {
    my $self = shift;

    my %p = validate(
        @_,
        {   'name' =>
                { type => SCALAR, optional => 1, default => $vos->{name} },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $name = $p{name}
        || $prov->error( message => 'is_enabled was called without a CTID' );
    $prov->audit("testing if virtual container $name is enabled");

    my $ve_name     = $self->get_ve_name();
    my $config_file = $self->get_ve_config_path();

    if ( -e $config_file ) {
        $prov->audit("\tfound $name at $config_file");
        return 1;
    }

    $prov->audit("\tdid not find $config_file");
    return;
}

sub mount_disk_image {
    my $self = shift;

    my $disk_root = $vos->{disk_root} or die "disk_root not set!\n";
    my $name      = $vos->{name}      or die "name not set!\n";
    my $img_name  = "${name}_rootimg";
    my $ve_name   = $self->get_ve_name();
    my $mount_dir = "$disk_root/$ve_name/mnt";

    if ( !-d $mount_dir ) {
        my $path;
        foreach my $bit ( split( /\//, $mount_dir ) ) {
            next if !$bit;
            $path .= "/$bit";
            if ( !-e $path ) {

                #warn "mkdir $path\n";
                mkdir $path;
            }
        }
    }

    if ( !-d $mount_dir ) {
        return $prov->error(
            message => "unable to create $mount_dir",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        );
    }

    #$mount /dev/vol00/${VMNAME}_rootimg /home/xen/$ve_name/mnt
    my $cmd = $util->find_bin( bin => 'mount', debug => $vos->{debug} );
    $cmd .= " /dev/vol00/$img_name $disk_root/$ve_name/mnt";
    $prov->audit("\tcmd: $cmd");
    $util->syscmd( cmd => $cmd, debug => 0 )
        or $prov->error( message => "unable to mount $img_name" );
}

sub unmount_disk_image {
    my $self = shift;

    my $img_name = "$vos->{name}_rootimg";

    my $cmd = $util->find_bin( bin => 'umount', debug => $vos->{debug} );
    $cmd .= " /dev/vol00/$img_name";

    $prov->audit("\tcmd: $cmd");
    $util->syscmd( cmd => $cmd, debug => 0 )
        or $prov->error( message => "unable to unmount $img_name" );
}

sub install_config_file {
    my $self = shift;

    my $ctid        = $vos->{name};
    my $ve_name     = $self->get_ve_name();
    my $config_file = $self->get_ve_config_path();
    warn "config file: $config_file\n";

    my $ip       = $vos->{ip}->[0];
    my $ram      = $vos->{ram} || 64;
    my $mac      = $self->get_random_mac();
    my $hostname = $vos->{hostname} || $ctid;

    my $config = <<"EOCONF"
kernel     = '/boot/hypervm-xen-vmlinuz'
ramdisk    = '/boot/hypervm-xen-initrd.img'
memory     = $ram
name       = '$ve_name'
hostname   = '$hostname'
vif        = ['ip=$ip, vifname=vif${ctid},  mac=$mac ']
vnc        = 0
vncviewer  = 0
serial     = 'pty'
disk       = ['phy:/dev/vol00/${ctid}_rootimg,sda1,w', 'phy:/dev/vol00/${ctid}_vmswap,sda2,w']
root = '/dev/sda1 ro'
EOCONF
        ;

    # These can also be set in the config file.
    #vcpus      =
    #console    =
    #nics       =
    #dhcp       =

    $util->file_write( file => $config_file, lines => [$config] ) or return;
    return 1;
}

sub is_valid_template {

    my $self = shift;
    my $template = shift or return;

    my $template_dir = $self->get_template_dir();
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

        return $prov->error(
            message =>
                'template does not exist and programmers have not yet written the code to retrieve templates via URL',
            fatal => 0,
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

Provision::Unix::VirtualOS::Linux::Xen - Provision Xen containers

=head1 SYNOPSIS


=head1 FUNCTIONS


=head1 AUTHOR

Matt Simerson, C<< <matt at tnpi.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-unix-provision-virtualos at rt.cpan.org>, or through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Provision-Unix>.  I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Provision::Unix::VirtualOS::Linux::Xen


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

