package Provision::Unix::VirtualOS::Linux::Xen;

our $VERSION = '0.24';

use warnings;
use strict;

#use Data::Dumper;
use English qw( -no_match_vars );
use File::Copy;
use Params::Validate qw(:all);

use lib 'lib';
use Provision::Unix::User;

my ( $prov, $vos, $util );

sub new {

    my $class = shift;

    my %p = validate( @_, { 'vos' => { type => OBJECT }, } );

    $vos  = $p{vos};
    $prov = $vos->{prov};

    my $self = { prov => $prov };
    bless( $self, $class );

    $prov->audit("loaded P:U:V::Linux::Xen");

    $vos->{disk_root} ||= '/home/xen';    # xen default

    require Provision::Unix::Utility;
    $util = Provision::Unix::Utility->new( prov => $prov );

    return $self;
}

sub create_virtualos {
    my $self = shift;

    $EUID == 0
        or $prov->error( "Create function requires root privileges." );

    my $ctid = $vos->{name} or return $prov->error( "name of container missing!");

    if ( $self->is_present() ) {
        return $prov->error( "ctid $ctid already exists",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        ); 
    };

    if ( !  $self->is_valid_template( $vos->{template} ) ) {
        return $prov->error( "no valid template specified",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        );
    };

    my $errors;
    my $xm = $util->find_bin( bin => 'xm', debug => $vos->{debug}, fatal => $vos->{fatal} );

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    $self->create_swap_image()
        or $prov->error( "unable to create swap" );

    $self->create_disk_image()
        or $prov->error( "unable to create disk image" );

    $self->mount_disk_image();

# make sure we trap any errors here and clean up after ourselves.
    $self->extract_template()
        or $prov->error( "unable to extract template onto disk image",
            fatal => 0,
        );

    if ( $vos->{password} ) {
        eval { $self->set_password('setup'); };
        if ( $@ ) {
            $errors++;
            $prov->error( $@, fatal=>0) 
        };
    };

    eval { $self->set_fstab(); };
    if ( $@ ) {
        $errors++;
        $prov->error( $@, fatal=>0) 
    };

    $self->unmount_disk_image();

    $self->install_config_file()
        or $prov->error( "unable to install config file" );

    # TODO:
    # set_hostname
    # set_ips
    # set_nameservers
   
    return if $errors;
    return 1;
}

sub destroy_virtualos {

    my $self = shift;

    $EUID == 0
        or $prov->error( "Destroy function requires root privileges." );

    my $ctid = $vos->{name};

    if ( !$self->is_present() ) {
        return $prov->error( "container $ctid does not exist",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        ); 
    };

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    if ( $self->is_running() ) {
        $self->stop_virtualos() or return $prov->error("could not shut down VPS");
    };

    $prov->audit("\tctid '$ctid' is stopped. Nuking it...");
    $self->destroy_disk_image();
    $self->destroy_swap_image();

    my $container_dir = $self->get_ve_home() or
        $prov->error( "could not deduce the containers home dir" );

    return 1 if ! -d $container_dir;

    my $cmd = $util->find_bin( bin => 'rm', debug => 0 );
    $util->syscmd(
        cmd   => "$cmd -rf $container_dir",
        debug => $vos->{debug},
        fatal => $vos->{fatal},
    );
    if ( -d $container_dir ) {
        $prov->error( "failed to delete $container_dir" );
    }
    return 1;
}

sub start_virtualos {
    my $self = shift;

    my $ctid = $vos->{name} or die "name of container missing!\n";

    if ( !$self->is_present() ) {
        return $prov->error( "ctid $ctid does not exist",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        ); 
    };

    return 1 if $self->is_running();

    my $config_file = $self->get_ve_config_path();
    if ( !-e $config_file ) {
        return $prov->error( "config file for $ctid at $config_file is missing.");
    }

    my $cmd = $util->find_bin( bin => 'xm', debug => 0 );
    $cmd .= " create $config_file";
    $util->syscmd( cmd => $cmd, debug => 0, fatal => $vos->{fatal} )
        or $prov->error( "unable to start $ctid" );

    foreach ( 1..15 ) {
        return 1 if $self->is_running();
        sleep 1;   # the xm start create returns before the VE is running.
    };
    return 1 if $self->is_running();
    return;
}

sub stop_virtualos {
    my $self = shift;

    my $ve_name = $self->get_ve_name();

    return 1 if ! $self->is_running();

    $prov->audit("\tstopping '$ve_name' ");
    my $xm = $util->find_bin( bin => 'xm', debug => 0 );

    # try a 'friendly' shutdown first for 10 seconds
    $util->syscmd(
        cmd     => "$xm shutdown -w $ve_name",
        timeout => 10,
        debug   => 0,
        fatal   => 0,
    );

    # wait up to 15 seconds for it to finish shutting down
    foreach ( 1..15 ) {
        return 1 if ! $self->is_running();
        sleep 1;   # the xm destroy may exit before the VE is stopped.
    };

    # whack it with the bigger hammer
    $util->syscmd(
        cmd   => "$xm destroy $ve_name",
        timeout => 20,
        fatal => 0,
        debug => 0,
    );

    # wait up to 15 seconds for it to finish shutting down
    foreach ( 1..15 ) {
        return 1 if ! $self->is_running();
        sleep 1;   # the xm destroy may exit before the VE is stopped.
    };

    return 1 if !$self->is_running();
    return;
}

sub restart_virtualos {
    my $self = shift;

    my $ve_name = $self->get_ve_name();

    if ( ! $self->stop_virtualos() ) {
        $prov->error( "unable to stop virtual $ve_name", fatal => 0 );
        return;
    };

    return $self->start_virtualos();
}

sub disable_virtualos {
    my $self = shift;

    my $ctid = $vos->{name};
    $prov->audit("disabling virtual $ctid");

    # make sure CTID exists
    return $prov->error( "container $ctid does not exist",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if !$self->is_present();

    # make sure config file exists
    my $config = $self->get_ve_config_path();
    if ( !-e $config ) {
        return $prov->error( "configuration file ($config) for $ctid does not exist",
            fatal => $vos->{fatal},
            debug => $vos->{debug},
        );
    }

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    # see if VE is running, and if so, stop it
    $self->stop_virtualos() if $self->is_running();

    move( $config, "$config.suspend" )
        or return $prov->error( "\tunable to move file '$config': $!",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
        );

    $prov->audit("\tdisabled $ctid.");
    return 1;
}

sub enable_virtualos {

    my $self = shift;

    my $ctid = $vos->{name};
    $prov->audit("enabling virtual $ctid");

    # make sure CTID exists
    return $prov->error( "container $ctid does not exist",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if !$self->is_present();

    # make sure CTID is disabled
    return $prov->error( "container $ctid is not disabled",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if $self->is_enabled();

    # make sure config file exists
    my $config = $self->get_ve_config_path();
    if ( !-e "$config.suspend" ) {
        return $prov->error( "configuration file ($config.suspend) for $ctid does not exist",
            fatal => $vos->{fatal},
            debug => $vos->{debug},
        );
    }

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    move( "$config.suspend", $config )
        or return $prov->error( "\tunable to move file '$config': $!",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
        );

    return $self->start_virtualos();
}

sub modify_virtualos {

}

sub reinstall_virtualos {

    my $self = shift;

    $self->destroy_virtualos()
        or
        return $prov->error( "unable to destroy virtual $vos->{name}",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        );

    return $self->create_virtualos();
}

sub create_disk_image {
    my $self = shift;

    my $img_name = "$vos->{name}_rootimg";
    my $size = $vos->{disk_size} || 1000;

    # create the disk image
    my $cmd = $util->find_bin( bin => 'lvcreate', debug => $vos->{debug} );
    $cmd .= " -L$size -n${img_name} vol00";
    $util->syscmd( cmd => $cmd, debug => 0 )
        or return $prov->error( "unable to create $img_name" );

    # format it as ext3 file system
    $cmd = $util->find_bin( bin => 'mkfs.ext3', debug => $vos->{debug} );
    $cmd .= " /dev/vol00/${img_name}";
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
    $util->syscmd( cmd => $cmd, debug => 0, fatal => $vos->{fatal} )
        or return $prov->error( "unable to create $img_name" );

    # format the swap file system
    $cmd = $util->find_bin( bin => 'mkswap', debug => $vos->{debug} );
    $cmd .= " /dev/vol00/${img_name}";
    $util->syscmd( cmd => $cmd, debug => 0, fatal => $vos->{fatal} )
        or return $prov->error( "unable to create $img_name" );

    return 1;
}

sub destroy_disk_image {
    my $self = shift;

    my $img_name = "$vos->{name}_rootimg";

    $prov->audit("checking for presense of $img_name");
    if ( -e "/dev/vol00/$img_name" ) {
        $prov->audit("\tfound it. You killed my father, prepare to die!");
        my $cmd = $util->find_bin( bin => 'lvremove', debug => $vos->{debug} );
        $cmd .= " -f vol00/${img_name}";
        $util->syscmd( cmd => $cmd, debug => 0 )
            or return $prov->error( "unable to destroy $img_name" );
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
        $util->syscmd( cmd => $cmd, debug => 0, fatal => $vos->{fatal} )
            or return $prov->error( "unable to destroy $img_name" );
        return 1;
    }
    return;
}

sub extract_template {
    my $self = shift;

    $self->is_valid_template( $vos->{template} )
        or return $prov->error( "no valid template specified",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
        );

    my $ve_name      = $self->get_ve_name();
    my $mount_dir    = "$vos->{disk_root}/$ve_name/mnt";
    my $template_dir = $self->get_template_dir();

    #tar -zxf $template_dir/$OSTEMPLATE.tar.gz -C /home/xen/$ve_name/mnt

    # untar the template
    my $cmd = $util->find_bin( bin => 'tar', debug => $vos->{debug} );
    $cmd .= " -zxf $template_dir/$vos->{template}.tar.gz -C $mount_dir";
    $util->syscmd( cmd => $cmd, debug => 0, fatal => $vos->{fatal} )
        or return $prov->error( "unable to extract tarball $vos->{template}" );
    return 1;
}

sub get_disk_usage {
    my $self = shift;
    my $image = shift or return;

    my $cmd = $util->find_bin( bin => 'dumpe2fs', fatal => 0, debug => 0 );
    return if ! -x $cmd;

    $cmd .= " -h $image";
    my $r = `$cmd 2>&1`;
    my ($block_size) = $r =~ /Block size:\s+(\d+)/;
    my ($blocks_tot) = $r =~ /Block count:\s+(\d+)/;
    my ($blocks_free) = $r =~ /Free blocks:\s+(\d+)/; 

    my $disk_total = ( $blocks_tot * $block_size ) / 1024;
    my $disk_free = ( $blocks_free * $block_size ) / 1024;
    my $disk_used = $disk_total - $disk_free;

    return $disk_used;
};

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

    $self->{status} = {};    # reset status

    if ( ! $self->is_present() ) {
        $prov->audit( "The xen VE $ve_name does not exist", fatal => 0 );
        $self->{status}{$ve_name} = { state => 'non-existent' };
        return $self->{status}{$ve_name};
    };

    # get IPs and disks from the containers config file
    my ($ips, $disks, $disk_usage );
    my $config_file = $self->get_ve_config_path();
    if ( ! -e $config_file ) {
        return { state => 'disabled' } if -e "$config_file.suspend";

        $prov->audit( "\tmissing config file $config_file" );
        return { state => 'broken' };
    };

    my ($xen_conf, $config);
    eval "require Provision::Unix::VirtualOS::Xen::Config";
    if ( ! $EVAL_ERROR ) {
        $xen_conf = Provision::Unix::VirtualOS::Xen::Config->new();
    };

    if ( $xen_conf && $xen_conf->read_config($config_file) ) {
        $ips   = $xen_conf->get_ips();
        $disks = $xen_conf->get('disk');
    };
    foreach ( @$disks ) {
        my ($image) = $_ =~ /phy:(.*?),/;
        next if ! -e $image;
        next if $image =~ /swap/i;
        $disk_usage = $self->get_disk_usage($image);
    };

    my $cmd = $util->find_bin( bin => 'xm', debug => 0 );
    $cmd .= " list $ve_name";
    my $r = `$cmd 2>&1`;

    if ( $r =~ /does not exist/ ) {

        # a Xen VE that is shut down won't show up in the output of 'xm list'
        $self->{status}{$ve_name} = {
            ips      => $ips,
            disks    => $disks,
            state    => 'shutdown',
        };
        return $self->{status}{$ve_name};
    };

    $r =~ /VCPUs/ 
        or $prov->error( "could not get valid output from '$cmd'", fatal => 0 );

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
            disk_use => $disk_usage,
            dom_id   => $dom_id,
            mem      => $mem + 1,
            cpus     => $cpus,
            state    => _run_state($state),
            cpu_time => $time,
        };
        return $self->{status}{$ctid};
    }

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
       $ctid .= '.vm';  # TODO: make this a config file option
    return $ctid;
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
        $prov->error( 'is_present was called without a CTID' );

    my $ve_home = $self->get_ve_home();

    $prov->audit("checking for presense of VE $name");

    my @possible_paths = (
        $ve_home, "/dev/vol00/${name}_rootimg", "/dev/vol00/${name}_vmswap"
    );

    foreach my $path (@possible_paths) {
        $prov->audit("\tchecking at $path") if $vos->{debug};
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

    $self->get_status() if $p{refresh};

    my $ve_name = $self->get_ve_name();

    if ( $self->{status}{$ve_name} ) {
        my $state = $self->{status}{$ve_name}{state};
        if ( $state && $state eq 'running' ) {
            $prov->audit("$ve_name is running");
            return 1;
        };
    }
    $prov->audit("$ve_name is not running");
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
        || $prov->error( 'is_enabled was called without a CTID' );
    $prov->audit("testing if virtual container $name is enabled");

    my $ve_name     = $self->get_ve_name();
    my $config_file = $self->get_ve_config_path();

    if ( -e $config_file ) {
        $prov->audit("\tfound $name at $config_file") if $p{debug};
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
        return $prov->error( "unable to create $mount_dir",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        );
    }

    return if ( -d "$mount_dir/etc" );   # already mounted

    #$mount /dev/vol00/${VMNAME}_rootimg /home/xen/$ve_name/mnt
    my $cmd = $util->find_bin( bin => 'mount', debug => $vos->{debug} );
    $cmd .= " /dev/vol00/$img_name $disk_root/$ve_name/mnt";
    $util->syscmd( cmd => $cmd, debug => $vos->{debug}, fatal => $vos->{fatal} )
        or $prov->error( "unable to mount $img_name" );
    return 1;
}

sub set_password {
    my $self = shift;
    my $arg = shift;

    my $ve_name = $self->get_ve_name();
    my $ve_home = $self->get_ve_home();
    my $pass    = $vos->{password}
        or return $prov->error( 'no password provided',
        fatal   => $vos->{fatal},
    );

    $prov->audit("setting VPS password");

    my $i_stopped;
    my $i_mounted;

    if ( ! $arg || $arg ne 'setup' ) {
        if ( $self->is_running ) {
            $self->stop_virtualos()
            or
            return $prov->error( "\tunable to stop virtual $ve_name" );
            $i_stopped++;
        };
    
        $i_mounted++ if $self->mount_disk_image();
    }

    my $errors;

    # set the VE root password
    my $pass_file = "$ve_home/mnt/etc/shadow";  # SYS 5
    if ( ! -f $pass_file ) {
        $pass_file = "$ve_home/mnt/etc/master.passwd";  # BSD
        if ( ! -f $pass_file ) {
            $pass_file = "$ve_home/mnt/etc/passwd";
            if ( !  -f $pass_file ) {
                $errors++;
                $prov->error( "\tcould not find password file", fatal => 0);
            };
        };
    };

    my $user = Provision::Unix::User->new( prov => $prov );
    if ( ! $errors ) {
        my @lines = $util->file_read( file => $pass_file, fatal => 0 );
        grep { /^root:/ } @lines 
            or $prov->error( "\tcould not find root password entry in $pass_file!", fatal => 0);

        my $crypted = $user->get_crypted_password($pass);

        foreach ( @lines ) {
            s/root\:.*?\:/root\:$crypted\:/ if m/^root\:/;
        };
        $util->file_write( 
            file => $pass_file, lines => \@lines, 
            debug => $vos->{debug}, fatal => 0,
        );

        # install the SSH key
        if ( $vos->{ssh_key} ) {
            eval {
                $user->install_ssh_key(
                    homedir => "$ve_home/mnt/root",
                    ssh_key => $vos->{ssh_key},
                );
            };
            $prov->error( $@, fatal => 0 ) if $@;
        };
    };

    # set the VE console password
    my %request = ( username => $ve_name, password => $pass );
    $request{username} =~ s/\.//g;  # strip the . out of the veid name: NNNNN.vm
    if ( $user->exists( $request{username} ) ) {  # see if user exists
        $request{ssh_key} = $vos->{ssh_key} if $vos->{ssh_key};
        eval { $user->set_password( %request ); };
        if ( $@ ) {
            $errors++;
            $prov->error( $@, fatal => 0 );
        };
    };

    if ( ! $arg || $arg ne 'setup' ) {
        $self->unmount_disk_image() if $i_mounted;
        $self->start_virtualos() if $i_stopped;
    };
    return 1 if ! $errors;
    return;
};

sub set_fstab {
    my $self = shift;

    my $contents = <<EOFSTAB
/dev/sda1               /                       ext3    defaults,noatime 1 1
/dev/sda2               none                    swap    sw       0 0
none                    /dev/pts                devpts  gid=5,mode=620 0 0
none                    /dev/shm                tmpfs   defaults 0 0
none                    /proc                   proc    defaults 0 0
none                    /sys                    sysfs   defaults 0 0
EOFSTAB
;

    my $ve_home = $self->get_ve_home();
    $util->file_write( 
        file => "$ve_home/mnt/etc/fstab", 
        lines => [ $contents ],
        debug => $vos->{debug},
        fatal => $vos->{fatal},
    );
};

sub unmount_disk_image {
    my $self = shift;

    my $img_name = "$vos->{name}_rootimg";

    my $cmd = $util->find_bin( bin => 'umount', debug => $vos->{debug} );
    $cmd .= " /dev/vol00/$img_name";

    $util->syscmd( cmd => $cmd, debug => 0, fatal => $vos->{fatal} )
        or $prov->error( "unable to unmount $img_name" );
}

sub install_config_file {
    my $self = shift;

    my $ctid        = $vos->{name};
    my $ve_name     = $self->get_ve_name();
    my $config_file = $self->get_ve_config_path();
    warn "config file: $config_file\n" if $vos->{debug};

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
root       = '/dev/sda1 ro'
extra      = 'console=xvc0'
EOCONF
        ;

    # These can also be set in the config file.
    #vcpus      =
    #console    =
    #nics       =
    #dhcp       =

    $util->file_write( 
        file => $config_file, 
        lines => [$config],
        debug => $vos->{debug},
    ) or return;
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

        return $prov->error( 'template does not exist and programmers have not yet written the code to retrieve templates via URL',
            fatal => 0,
        );
    }

    return $prov->error( "template '$template' does not exist and is not a valid URL",
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

Copyright 2009 Matt Simerson

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

