package Provision::Unix::VirtualOS::Linux::Xen;

our $VERSION = '0.43';

use warnings;
use strict;

#use Data::Dumper;
use English qw( -no_match_vars );
use File::Copy;
use File::Path;
use Params::Validate qw(:all);

use lib 'lib';
use Provision::Unix::User;

my ( $prov, $vos, $linux, $user, $util );

sub new {
    my $class = shift;

    my %p = validate( @_, { 'vos' => { type => OBJECT }, } );

    $vos   = $p{vos};
    $prov  = $vos->{prov};
    $linux = $vos->{linux};
    $util  = $vos->{util};

    my $self = { prov => $prov };
    bless( $self, $class );

    $prov->audit("loaded P:U:V::Linux::Xen");

    $vos->{disk_root} ||= '/home/xen';    # xen default

    return $self;
}

sub create_virtualos {
    my $self = shift;

    $EUID == 0
        or $prov->error( "Create function requires root privileges." );

    my $ctid = $vos->{name} or return $prov->error( "VE name missing in request!");

    return $prov->error( "VE $ctid already exists", fatal => 0 ) 
        if $self->is_present();

    return $prov->error( "no valid template specified", fatal => 0 )
        if ! $self->is_valid_template();

    my $err_count_before = @{ $prov->{errors} };
    my $xm = $util->find_bin( bin => 'xm', debug => 0, fatal => 1 );

    return $prov->audit("test mode early exit") if $vos->{test_mode};

    $self->create_swap_image() or return;
    $self->create_disk_image() or return;
    $self->mount_disk_image() or return;

# make sure we trap any errors here and clean up after ourselves.
    my $r;
    $self->extract_template() or $self->unmount_disk_image() and return;

    my $template = $vos->{template};
    my $fs_root  = $self->get_fs_root();
    eval {
        $linux->install_kernel_modules( 
            fs_root => $fs_root, 
            version => $self->get_kernel_version(),
        );
    };
    $prov->error( $@, fatal => 0 ) if $@;

    $self->set_ips();

    eval { $linux->set_rc_local( fs_root => $fs_root ); };
    $prov->error( $@, fatal => 0 ) if $@;

    eval { 
        $linux->set_hostname(
            host    => $vos->{hostname},
            fs_root => $fs_root,
            distro  => $template,
        );
    };
    $prov->error( $@, fatal => 0 ) if $@;

    $vos->set_nameservers() if $vos->{nameservers};

    eval { $self->create_console_user(); };
    $prov->error( $@, fatal => 0 ) if $@;

    if ( $vos->{password} ) {
        eval { $self->set_password('setup');  };
        $prov->error( $@, fatal=>0) if $@;
    };

    eval { $self->set_fstab(); };
    $prov->error( $@, fatal=>0) if $@;

    eval { $self->set_libc(); };
    $prov->error( $@, fatal=>0) if $@;

    eval { $linux->setup_inittab( fs_root => $fs_root, template => $template ); };
    $prov->error( $@, fatal=>0) if $@;

    eval { $vos->setup_ssh_host_keys( fs_root => $fs_root ); };
    $prov->error( $@, fatal=>0) if $@;
   
    eval { $vos->setup_log_files( fs_root => $fs_root ); };
    $prov->error( $@, fatal=>0) if $@;

    $self->unmount_disk_image();

    $self->gen_config()
        or return $prov->error( "unable to install config file", fatal => 0 );

    my $err_count_after = @{ $prov->{errors} };
    $self->start_virtualos();

    return if $err_count_after > $err_count_before;
    return 1;

}

sub destroy_virtualos {

    my $self = shift;

    $EUID == 0
        or $prov->error( "Destroy function requires root privileges." );

    my $ctid = $vos->{name};

    if ( !$self->is_present( debug => 0 ) ) {
        return $prov->error( "container $ctid does not exist",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        ); 
    };

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    if ( $self->is_running( debug => 0 ) ) {
        $self->stop_virtualos() or return;
    };

    $self->unmount_disk_image() or return $prov->error("could not unmount disk image");

    $prov->audit("\tctid '$ctid' is stopped. Nuking it...");
    $self->destroy_disk_image() or return;
    $self->destroy_swap_image() or return;

    my $ve_home = $self->get_ve_home() or
        $prov->error( "could not deduce the containers home dir" );

    return 1 if ! -d $ve_home;

    $self->destroy_console_user();
    if ( -d $ve_home ) {
        my $cmd = $util->find_bin( bin => 'rm', debug => 0 );
        $util->syscmd(
            cmd   => "$cmd -rf $ve_home",
            debug => 0,
            fatal => $vos->{fatal},
        );
        if ( -d $ve_home ) {
            $prov->error( "failed to delete $ve_home" );
        }
    };

    my $ve_name = $self->get_ve_name();
    my $startup = "/etc/xen/auto/$ve_name.cfg";
    unlink $startup if -e $startup;

    return 1;
}

sub start_virtualos {
    my $self = shift;

    my $ctid  = $vos->{name} or die "name of container missing!\n";
    my $debug = $vos->{debug};
    my $fatal = $vos->{fatal};

    $prov->audit("starting $ctid");

    if ( !$self->is_present() ) {
        return $prov->error( "ctid $ctid does not exist",
            fatal   => $fatal,
            debug   => $debug,
        ); 
    };

    if ( $self->is_running() ) {
        $prov->audit("$ctid is already running.");
        return 1;
    };

# disk images often get left mounted, preventing a VE from starting. 
# Try unmounting them, just in case.
    $self->unmount_disk_image( 'quiet' );

    my $config_file = $self->get_ve_config_path();
    if ( !-e $config_file ) {
        return $prov->error( "config file for $ctid at $config_file is missing.");
    }

# -c option to xm create will start the vm in a console window. Could be useful
# when doing test VEs to look for errors
    my $cmd = $util->find_bin( bin => 'xm', debug => 0 );
    $cmd .= " create $config_file";
    $util->syscmd( cmd => $cmd, debug => 0, fatal => $fatal )
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

    my $ctid = $vos->{name} or die "name of container missing!\n";

    $prov->audit("shutting down $ctid");

    if ( !$self->is_present() ) {
        return $prov->error( "$ctid does not exist",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        ); 
    };

    if ( ! $self->is_running() ) {
        $prov->audit("$ctid is already shutdown.");
        return 1;
    };

    my $ve_name = $self->get_ve_name();
    my $xm = $util->find_bin( bin => 'xm', debug => 0 );

    # try a 'friendly' shutdown for 10 seconds
    $util->syscmd(
        cmd     => "$xm shutdown -w $ve_name",
        timeout => 10,
        debug   => 0,
        fatal   => 0,
    );

    # wait up to 15 seconds for it to finish shutting down
    foreach ( 1..15 ) {
        return 1 if ! $self->is_running();
        sleep 1;   # xm shutdown may exit before the VE is stopped.
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
        sleep 1;   # xm destroy may exit before the VE is stopped.
    };

    return 1 if !$self->is_running();
    $prov->error( "failed to stop virtual $ve_name", fatal => 0 );
    return;
}

sub restart_virtualos {
    my $self = shift;

    my $ve_name = $self->get_ve_name();

    $self->stop_virtualos() or return;
    return $self->start_virtualos();
}

sub disable_virtualos {
    my $self = shift;

    my $ctid = $vos->{name};
    $prov->audit("disabling $ctid");

    # make sure CTID exists
    return $prov->error( "$ctid does not exist",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if !$self->is_present();

    # is it already disabled?
    my $config = $self->get_ve_config_path();
    if ( !-e $config && -e "$config.suspend" ) {
        $prov->audit( "container is already disabled." );
        return 1;
    };

    # make sure config file exists
    if ( !-e $config ) {
        return $prov->error( "configuration file ($config) for $ctid does not exist",
            fatal => $vos->{fatal},
            debug => $vos->{debug},
        );
    }

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    # see if VE is running, and if so, stop it
    if ( $self->is_running() ) {
        $self->stop_virtualos() or return; 
    };

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
    $prov->audit("enabling $ctid");

    # make sure CTID exists
    return $prov->error( "$ctid does not exist",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if !$self->is_present();

    # is it already enabled?
    if ( $self->is_enabled() ) {
        $prov->audit("\t$ctid is already enabled");
        return $self->start_virtualos();
    };

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
    my $self = shift;

    my $ctid = $vos->{name};
    $prov->audit("modifying $ctid");

    # hostname ips nameservers searchdomain disk_size ram config 

    $self->stop_virtualos() or return;
    $self->mount_disk_image() or return;

    my $fs_root = $self->get_fs_root();
    my $hostname = $vos->{hostname};

    $self->set_ips() if $vos->{ip};
    $linux->set_hostname( host => $hostname, fs_root => $fs_root ) 
        if $hostname && ! $vos->{ip};

    $user ||= Provision::Unix::User->new( prov => $prov );

    if ( $user ) {
        $user->install_ssh_key(
            homedir => "$fs_root/root",
            ssh_key => $vos->{ssh_key},
            debug   => $vos->{debug},
        ) 
        if $vos->{ssh_key};

        my $pass = $vos->{password};
        if ( $pass ) {
            my $pass_file = $self->get_ve_passwd_file( $fs_root );
            my @lines = $util->file_read( file => $pass_file, fatal => 0 );
            grep { /^root:/ } @lines 
                or $prov->error( "\tcould not find root in $pass_file!", fatal => 0);

            my $crypted = $user->get_crypted_password($pass);

            foreach ( @lines ) {
                s/root\:.*?\:/root\:$crypted\:/ if m/^root\:/;
            };
            $util->file_write( 
                file => $pass_file, lines => \@lines, 
                debug => $vos->{debug}, fatal => 0,
            );
        };
    };

    $self->gen_config();
    $self->unmount_disk_image() or return;
    $self->resize_disk_image();
    $self->start_virtualos() or return;
    return 1;
}

sub upgrade_virtualos {
# temp placeholder, delete after 11/01/09
    my $self = shift;
    return $self->modify_virtualos();
};

sub reinstall_virtualos {
    my $self = shift;

    $self->destroy_virtualos()
        or
        return $prov->error( "unable to destroy virtual $vos->{name}",
            fatal => $vos->{fatal},
            debug => $vos->{debug},
        );

    return $self->create_virtualos();
}

sub create_console_user {
    my $self = shift;

    $user ||= Provision::Unix::User->new( prov => $prov );
    my $username = $self->get_console_username();
    my $ve_home = $self->get_ve_home();
    my $ve_name = $self->get_ve_name();
    my $debug   = $vos->{debug};

    if ( ! $user->exists( $username ) ) { # see if user exists
        $user->create_group( group => $username, debug => $debug );
        $user->create(
            username => $username,
            password => $vos->{password},
            homedir  => $ve_home,
            shell    => '',
            debug    => $debug,
        )
        or return $prov->error( "unable to create console user $username", fatal => 0 ); 
        $prov->audit("created console user account");
    };   

    foreach ( qw/ .bashrc .bash_profile / ) {
        $util->file_write( 
            file  => "$ve_home/$_", 
            lines => [ "/usr/bin/sudo /usr/sbin/xm console $ve_name", 'exit' ],
            fatal => 0,
            debug => 0,
        )
        or $prov->error( "failed to configure console login script", fatal => 0 );
    }
    $prov->audit("installed console login script");

    if ( ! `grep '^$username' /etc/sudoers` ) {
        $util->file_write(
            file   => '/etc/sudoers',
            lines  => [ "$username  ALL=(ALL) NOPASSWD: /usr/sbin/xm console $ve_name" ],
            append => 1,
            mode   => '0440',
            fatal  => 0,
            debug  => 0
        )
        or $prov->error( "failed to update sudoers for console login");

        $util->file_write(
            file   => '/etc/sudoers.local',
            lines  => [ "$username  ALL=(ALL) NOPASSWD: /usr/sbin/xm console $ve_name" ],
            append => 1,
            fatal  => 0,
            debug  => 0
        )
        or $prov->error( "failed to update sudoers for console login");
        $prov->audit("updated sudoers for console account $username");
    };

    $prov->audit( "configured remote SSH console" );
    return 1;
};

sub create_disk_image {
    my $self = shift;

    my $disk_image = $self->get_disk_image();
    my $size = $self->get_ve_disk_size();
    my $ram  = $self->get_ve_ram();
    $size = $size - ( $ram * 2 );   # subtract swap from their disk allotment

    # create the disk image
    my $cmd = $util->find_bin( bin => 'lvcreate', debug => 0, fatal => 0 ) or return;
    $cmd .= " --size=${size}M --name=${disk_image} vol00";
    $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 )
        or return $prov->error( "unable to create $disk_image with: $cmd", fatal => 0 );

    # format as ext3 file system
    $cmd = $util->find_bin( bin => 'mkfs.ext3', debug => 0, fatal => 0 ) or return;
    $cmd .= " /dev/vol00/${disk_image}";
    $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 )
        or return $prov->error( "unable for format disk image with: $cmd", fatal => 0);

    $prov->audit("disk image for $vos->{name} created");
    return 1;
}

sub create_swap_image {
    my $self = shift;

    my $img_name = $self->get_swap_image();
    my $ram      = $self->get_ve_ram();
    my $size     = $ram * 2;

    # create the swap image
    my $cmd = $util->find_bin( bin => 'lvcreate', debug => 0, fatal => 0 ) or return;
    $cmd .= " --size=${size}M --name=${img_name} vol00";
    $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 )
        or return $prov->error( "unable to create $img_name", fatal => 0 );

    # format the swap file system
    $cmd = $util->find_bin( bin => 'mkswap', debug => 0, fatal => 0) or return;
    $cmd .= " /dev/vol00/${img_name}";
    $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 )
        or return $prov->error( "unable to format $img_name", fatal => 0 );

    $prov->audit( "created a $size MB swap partition" );
    return 1;
}

sub destroy_console_user {
    my $self = shift;

    $user ||= Provision::Unix::User->new( prov => $prov );
    my $username = $self->get_console_username();
    my $ve_home = $self->get_ve_home();
    my $ve_name = $self->get_ve_name();

    if ( $user->exists( $username ) ) { # see if user exists
        $user->destroy(
            username => $username,
            homedir  => $ve_home,
            debug    => 0,
        )
        or return $prov->error( "unable to destroy console user $username", fatal => 0 ); 
        $prov->audit( "deleted system user $username" );

        $user->destroy_group( group => $username, fatal => 0, debug => 0 );
    };   

    $prov->audit( "deleted system user $username" );
    return 1;
};

sub destroy_disk_image {
    my $self = shift;

    my $disk_image = $self->get_disk_image();

    #$prov->audit("checking for presense of disk image $disk_image");
    if ( ! -e "/dev/vol00/$disk_image" ) {
        $prov->audit("disk image does not exist: $disk_image");
        return 1;
    };

    $prov->audit("My name is Inigo Montoya. You killed my father. Prepare to die!");

    my $cmd  = $util->find_bin( bin => 'lvremove', debug => 0 );
       $cmd .= " -f vol00/${disk_image}";
    my $r = $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 );
    if ( ! $r ) {
        $prov->audit("My name is Inigo Montoya. You killed my father. Prepare to die!");
        sleep 3;  # wait a few secs and try again
        $r = $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 )
            and pop @{ $prov->{errors} };  # clear the last error
    };
    $r or return $prov->error( "unable to destroy disk image: $disk_image" );
    return 1;
}

sub destroy_swap_image {
    my $self = shift;

    my $img_name = $self->get_swap_image();

    return $prov->audit("disk image does not exist: $img_name")
        if ! -e "/dev/vol00/$img_name";

    my $cmd = $util->find_bin( bin => 'lvremove', debug => 0 );
    $cmd .= " -f vol00/$img_name";
    $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 )
        or return $prov->error( "unable to destroy swap $img_name", fatal => 0 );
    return 1;
}

sub extract_template {
    my $self = shift;

    $self->is_valid_template()
        or return $prov->error( "no valid template specified", fatal => 0 );

    my $ve_name = $self->get_ve_name();
    my $fs_root = $self->get_fs_root();
    my $template = $vos->{template};
    my $template_dir = $self->get_template_dir();

    #tar -zxf $template_dir/$OSTEMPLATE.tar.gz -C /home/xen/$ve_name/mnt

    # untar the template
    my $cmd = $util->find_bin( bin => 'tar', debug => 0, fatal => 0 ) or return;
    $cmd .= " -zxf $template_dir/$template.tar.gz -C $fs_root";
    $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 )
        or return $prov->error( "unable to extract template $template. Do you have enough disk space?",
            fatal => 0
        );
    return 1;
}

sub get_console {
    my $self = shift;
    my $ctid = $vos->{name} . '.vm';
    my $cmd = $util->find_bin( bin => 'xm', debug => 0 );
    exec "$cmd console $ctid";
};

sub get_console_username {
    my $self = shift;
    my $ctid = $vos->{name};
       $ctid .= 'vm';
    return $ctid;
};

sub get_disk_image {
    my $self = shift;
    my $name = $vos->{name} or die "missing VE name!";
    return $name . '_rootimg';
};

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

sub get_kernel_dir {
    my $self = shift;
    return '/boot/domU' if -d "/boot/domU";
    return '/boot';
};

sub get_kernel_version {
    my $self = shift;
    return $vos->{kernel_version} if $vos->{kernel_version};
    my $kernel_dir = $self->get_kernel_dir();
    my @kernels = <$kernel_dir/vmlinuz-*xen>;
    my $kernel = $kernels[0];
    my ($version) = $kernel =~ /-([0-9\.\-]+)\./;
    return $prov->error("unable to detect a xen kernel (vmlinuz-*xen) in standard locations (/boot, /boot/domU)", fatal => 0) if ! $version;
    $vos->{kernel_version} = $version;
    return $version;
};

sub get_mac_address {
    my $self = shift;
    my $mac = $vos->{mac_address};
    return $mac if $mac;

    my $i;
    $mac = '00:16:3E';

    while ( ++$i ) {
        last if $i > 6;
        $mac .= ':' if $i % 2;
        $mac .= sprintf "%" . ( qw (X x) [ int( rand(2) ) ] ),
            int( rand(16) );
    }

    # TODO:
    #   make sure random MAC does not conflict with an existing one.

    return $mac;
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

sub get_swap_image {
    my $self = shift;
    my $name = $vos->{name} or die "missing VE name!";
    return $name . '_vmswap';
};

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

sub get_ve_ram {
    my $self = shift;
    return $vos->{ram} || 256;
};

sub get_ve_disk_size {
    my $self = shift;
    my $ram = $self->get_ve_ram();
    my $swap = $ram * 2;
    my $allocation = $vos->{disk_size} || 2500;
    return $allocation - $swap;
};

sub get_fs_root {
    my $self = shift;
    my @caller = caller;
    my $ve_home = $self->get_ve_home( shift )
        or return $prov->error( "VE name unset when called by $caller[0] at $caller[2]");
    my $fs_root = "$ve_home/mnt";
    return $fs_root;
};

sub get_ve_home {
    my $self = shift;
    my @caller = caller;
    my $ve_name = $self->get_ve_name( shift )
        or return $prov->error( "VE name unset when called by $caller[0] at $caller[2]");
    my $homedir = "$vos->{disk_root}/$ve_name";
    return $homedir;
};

sub get_ve_name {
    my $self = shift;
    my @caller = caller;
    my $ctid = shift || $vos->{name}
        or return $prov->error( "missing VE name when called by $caller[0] at $caller[2]");
    $ctid .= '.vm';  # TODO: make this a config file option
    return $ctid;
};

sub get_ve_passwd_file {
    my $self = shift;
    my $ve_home = shift || '';

    my $pass_file = "$ve_home/mnt/etc/shadow";  # SYS 5
    return $pass_file if -f $pass_file;

    $pass_file = "$ve_home/mnt/etc/master.passwd";  # BSD
    return $pass_file if -f $pass_file;

    $pass_file = "$ve_home/mnt/etc/passwd";
    return $pass_file if -f $pass_file;

    $prov->error( "\tcould not find password file", fatal => 0);
    return;
};

sub is_mounted {
    my $self = shift;
    my $image = $self->get_disk_image();
    my $found = `/bin/mount | grep $image`; chomp $found;
    return $found;
};

sub is_present {
    my $self = shift;
    my %p = validate(
        @_,
        {   name    => { type => SCALAR, optional => 1 },
            refresh => { type => BOOLEAN, optional => 1, default => 1 },
            debug   => { type => BOOLEAN, optional => 1 },
        }
    );

    my $debug = defined $p{debug} ? $p{debug} : $vos->{debug};
    my $name = $p{name} || $vos->{name} or
        $prov->error( 'is_present was called without a VE name' );

    my $ve_home = $self->get_ve_home();

    $prov->audit("checking if VE $name exists") if $debug;

    my $disk_image = $self->get_disk_image();
    my $swap_image = $self->get_swap_image();

    my @possible_paths = (
        $ve_home, "/dev/vol00/$disk_image", "/dev/vol00/$swap_image"
    );

    foreach my $path (@possible_paths) {
        #$prov->audit("\tchecking at $path") if $debug;
        if ( -e $path ) {
            $prov->audit("\tfound $name at $path");
            return $path;
        }
    }

    $prov->audit("\tVE $name does not exist");
    return;
}

sub is_running {
    my $self = shift;
    my %p = validate(
        @_, 
        {   refresh => { type => SCALAR, optional => 1, default => 1 }, 
            debug   => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $self->get_status() if $p{refresh};
    my $debug = defined $p{debug} ? $p{debug} : $vos->{debug};

    my $ve_name = $self->get_ve_name();

    if ( $self->{status}{$ve_name} ) {
        my $state = $self->{status}{$ve_name}{state};
        if ( $state && $state eq 'running' ) {
            $prov->audit("$ve_name is running") if $debug;
            return 1;
        };
    }
    $prov->audit("$ve_name is not running") if $debug;
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

    my $disk_image = $self->get_disk_image();
    my $ve_name   = $self->get_ve_name();
    my $fs_root   = $self->get_fs_root();

# returns 2 (true) if image is already mounted
    return 2 if $self->is_mounted();

    mkpath $fs_root if !-d $fs_root;

    return $prov->error( "unable to create $fs_root", fatal => 0 )
        if ! -d $fs_root;

    #$mount /dev/vol00/${VMNAME}_rootimg /home/xen/$ve_name/mnt
    my $cmd = $util->find_bin( bin => 'mount', debug => 0, fatal => 0 ) or return;
    $cmd .= " /dev/vol00/$disk_image $fs_root";
    $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 )
        or return $prov->error( "unable to mount $disk_image", fatal => 0 );
    return 1;
}

sub resize_disk_image {
    my $self = shift;

    my $name = $vos->{name} or die "missing VE name!";

    $self->destroy_swap_image();
    $self->create_swap_image();

    my $image_name = $self->get_disk_image();
    my $disk_image = '/dev/vol00/' . $image_name;
    my $target_size = $self->get_ve_disk_size();

    # check existing disk size.
    $self->mount_disk_image() or $prov->error( "unable to mount disk image" );
    my $fs_root = $self->get_fs_root();
    my $df_out = qx{/bin/df -m $fs_root | /usr/bin/tail -n1};
    my (undef, $current_size, $df_used, $df_free) = split /\s+/, $df_out;
    $self->unmount_disk_image();

    my $difference = $target_size - $current_size;

    # return if the same
    return $prov->audit( "no disk partition changes required" ) if ! $difference;
    my $percent_diff = abs($difference / $target_size ) * 100;
    return $prov->audit( "disk partition is close enough: $current_size vs $target_size" ) 
        if $percent_diff < 5;

    my $fsck   = $util->find_bin( bin => 'e2fsck', debug => 0 );
       $fsck  .= " -y -f $disk_image";
    my $pvscan = $util->find_bin( bin => 'pvscan', debug => 0);
    my $resize2fs = $util->find_bin( bin => 'resize2fs', debug => 0 );

    # if new size is bigger
    if ( $target_size > $current_size ) {
# make sure there is sufficient free disk space on the HW node
        my $free = qx{$pvscan};
        $free =~ /(\d+\.\d+)\s+GB\s+free\]/;
        $free = $1 * 1024;
        return $prov->error("Not enough disk space on HW node: needs $target_size but only $free MB free. Migrate account and manually increase disk space.") if $free <= $target_size;
        # resize larger
        $prov->audit("Extending disk $image_name from $current_size to $target_size");
        my $cmd = "/usr/sbin/lvextend --size=${target_size}M $disk_image";
        $prov->audit($cmd);
        system $cmd and $prov->error( "failed to extend $image_name to $target_size megs");
        system $fsck;
        $cmd = "$resize2fs $disk_image";
        $prov->audit($cmd);
        system $cmd and $prov->error( "unable to resize filesystem $image_name");
        system $fsck;
        return 1;
    }

    if ( $current_size > $target_size ) {
       # see if volume can be safely shrunk - per SA team: Andrew, Ryan, & Ted

# if cannot be safely shrunk, fail.
        return $prov->error( "volume has more than $target_size used, failed to shrink" ) 
            if $df_used > $target_size;

        # shrink it
        $prov->audit( "Reducing $image_name from $current_size to $target_size MB");
        system $fsck;
        my $cmd = "$resize2fs -f $disk_image ${target_size}M";
        $prov->audit($cmd);
        system $cmd and $prov->error( " Unable to resize filesystem $image_name" );
        $prov->audit("reduced file system");

        $cmd  = $util->find_bin( bin => 'lvresize', debug => 0 );
        $cmd .= " --size=${target_size}M $disk_image";
        $prov->audit($cmd);
        #system $cmd and $prov->error( "Error:  Unable to reduce filesystem on $image_name" );
        open(FH, "| $cmd" ) or return $prov->error("failed to shrink logical volume");
        print FH "y\n";  # deals with the non-suppressible "Are you sure..." 
        close FH;        # waits for the open process to exit
        $prov->audit("completed shrinking logical volume size");
        system $fsck;
        return 1;
    };
};

sub set_hostname {
    my $self = shift;

    $self->stop_virtualos() or return;
    $self->mount_disk_image() or return;

    $linux->set_hostname( 
        host    => $vos->{hostname},
        fs_root => $self->get_fs_root(),
        fatal   => 0,
    )
    or $prov->error("unable to set hostname", fatal => 0);

    $self->unmount_disk_image();
    $self->start_virtualos() or return;
    return 1;
};

sub set_ips {
    my $self     = shift;
    my $fs_root  = $self->get_fs_root();
    my $template = $vos->{template};
    my $ctid     = $vos->{name};

    my %request = (
        hostname => $vos->{hostname},
        ips      => $vos->{ip},
        device   => $vos->{net_device} || 'eth0',
        fs_root  => $fs_root,
    );
    $request{distro} = $vos->{template} if $vos->{template};

    eval { $linux->set_ips( %request ); };
    $prov->error( $@, fatal => 0 ) if $@;

    # update the config file, if it exists
    my $config_file = $self->get_ve_config_path() or return;
    return if ! -f $config_file;

    my @ips      = @{ $vos->{ip} };
    my $ip_list  = shift @ips;
    foreach ( @ips ) { $ip_list .= " $_"; };
    my $mac      = $self->get_mac_address();

    my @lines = $util->file_read( file => $config_file, debug => 0, fatal => 0) 
        or return $prov->error("could not read $config_file", fatal => 0);

    foreach my $line ( @lines ) {
        next if $line !~ /^vif/;
        $line =~ /mac=([\w\d\:\-]+)\'\]/;
        $mac = $1 if $1;   # use the existing mac if possible
        $line = "vif        = ['ip=$ip_list, vifname=vif${ctid},  mac=$mac']";
    };
    $util->file_write( file => $config_file, lines => \@lines, fatal => 0 )
        or return $prov->error( "could not write to $config_file", fatal => 0);

    return 1;
};

sub set_libc {
    my $self = shift;

    my $fs_root = $self->get_fs_root();
    my $libdir  = "/etc/ld.so.conf.d";
    my $libfile = "/etc/ld.so.conf.d/libc6-xen.conf";

    if ( ! -f "$fs_root/$libfile" ) {
        if ( ! -d "$fs_root/$libdir" ) {
            mkpath "$fs_root/$libdir" or return 
                $prov->error("unable to create $libdir", fatal => 0);
            $prov->audit("created $libdir");
        };
        return $prov->error("could not create $libdir", fatal => 0) 
            if ! -d "$fs_root/$libdir";
        $util->file_write( 
            file  => "$fs_root/$libfile", 
            lines => [ 'hwcap 0 nosegneg' ], 
            debug => 0 , fatal => 0 )
            or return $prov->error("could not install $libfile", fatal => 0);
        $prov->audit("installed $libfile");
    };

    if ( -d "$fs_root/lib/tls" ) {
        move( "$fs_root/lib/tls", "$fs_root/lib/tls.disabled" );
        $prov->audit("disabled /lib/tls");
    };
    return 1;
};

sub set_password {
    my $self = shift;
    my $arg = shift;

    my $ve_name = $self->get_ve_name();
    my $ve_home = $self->get_ve_home();
    my $pass    = $vos->{password}
        or return $prov->error( 'no password provided', fatal => 0 );

    $prov->audit("setting VPS password");

    my $i_stopped;
    my $i_mounted;

    if ( ! $arg || $arg ne 'setup' ) {
        if ( $self->is_running( debug => 0 ) ) {
            $self->stop_virtualos() or return;
            $i_stopped++;
        };
    
        my $r = $self->mount_disk_image();
        $i_mounted++ if $r == 1;
    }

    my $errors;

    # set the VE root password
    my $pass_file = $self->get_ve_passwd_file( $ve_home ) or $errors++;

    $user ||= Provision::Unix::User->new( prov => $prov );
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
            $prov->audit("installing ssh key");
            eval {
                $user->install_ssh_key(
                    homedir => "$ve_home/mnt/root",
                    ssh_key => $vos->{ssh_key},
                );
            };
            $prov->error( $@, fatal => 0 ) if $@;
        };
        $prov->audit( "VE root password configured." );
    };

    # create the VE console user
    $prov->audit( "creating the console account and password." );
    my %request = ( username => $ve_name, password => $pass );
    $request{username} =~ s/\.//g;  # strip the . out of the veid name: NNNNN.vm
    if ( $user->exists( $request{username} ) ) {  # see if user exists
        if ( $vos->{ssh_key} ) {
            $request{ssh_key} = $vos->{ssh_key};
            $request{ssh_restricted} = "sudo /usr/sbin/xm console $ve_name";
        };
        $user->set_password( %request, fatal => 0, debug => 0 ) or $errors++;
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
        debug => 0,
        fatal => 0,
    ) or return;
    $prov->audit("installed /etc/fstab");
    return 1;
};

sub unmount_disk_image {
    my $self = shift;
    my $quiet = shift;

    my $debug = $vos->{debug};
    my $fatal = $vos->{fatal};

    return 1 if ! $self->is_mounted();
    $debug = $fatal = 0 if $quiet;

    my $disk_image = $self->get_disk_image();

    my $cmd = $util->find_bin( bin => 'umount', debug => 0, fatal => $fatal )
        or return $prov->error( "unable to find 'umount' program");
    $cmd .= " /dev/vol00/$disk_image";

    my $r = $util->syscmd( cmd => $cmd, debug => 0, fatal => $fatal );
    if ( ! $r && ! $quiet ) {
        $prov->error( "unable to unmount $disk_image" );
    };
    return $r;
}

sub gen_config {
    my $self = shift;

    my $ctid        = $vos->{name};
    my $ve_name     = $self->get_ve_name();
    my $config_file = $self->get_ve_config_path();
    #warn "config file: $config_file\n" if $vos->{debug};

    my $ram      = $self->get_ve_ram();
    my $hostname = $vos->{hostname} || $ctid;

    my @ips      = @{ $vos->{ip} };
    my $ip_list  = shift @ips;
    foreach ( @ips ) { $ip_list .= " $_"; };
    my $mac      = $self->get_mac_address();

    my $disk_image = $self->get_disk_image();
    my $swap_image = $self->get_swap_image();
    my $kernel_dir = $self->get_kernel_dir();
    my $kernel_version = $self->get_kernel_version();

    my ($kernel) = <$kernel_dir/vmlinuz*$kernel_version*>;
    my ($ramdisk) = <$kernel_dir/initrd*$kernel_version*>;
    ($kernel) ||= </boot/vmlinuz-*xen>;
    ($ramdisk) ||= </boot/initrd-*xen.img>;
    my $cpu = $vos->{cpu} || 1;
    my $time_dt = $prov->get_datetime_from_epoch();

    my $config = <<"EOCONF"
# Config file generated by Provision::Unix at $time_dt
kernel     = '$kernel'
ramdisk    = '$ramdisk'
memory     = $ram
name       = '$ve_name'
hostname   = '$hostname'
vif        = ['ip=$ip_list, vifname=vif${ctid},  mac=$mac']
vnc        = 0
vncviewer  = 0
serial     = 'pty'
disk       = ['phy:/dev/vol00/$disk_image,sda1,w', 'phy:/dev/vol00/$swap_image,sda2,w']
root       = '/dev/sda1 ro'
extra      = 'console=xvc0'
vcpus      = $cpu
EOCONF
;

    # These can also be set in the config file.
    #console    =
    #nics       =
    #dhcp       =

    $util->file_write( 
        file => $config_file, 
        lines => [$config],
        debug => 0,
        fatal => 0,
    ) or return $prov->error("unable to install VE config file", fatal => 0);

    link $config_file, "/etc/xen/auto/$ve_name.cfg";
    return 1;
}

sub is_valid_template {

    my $self = shift;
    my $template = shift || $vos->{template} or return;

    my $template_dir = $self->get_template_dir();
    return $template if -f "$template_dir/$template.tar.gz";

    # is $template a URL?
    if ( $template =~ /http|rsync/ ) {
        $prov->audit("fetching $template");
        my $uri = URI->new($template);
        my @segments = $uri->path_segments;
        my @path_bits = grep { /\w/ } @segments;  # ignore empty fields
        my $file = $segments[-1];

        $util->file_get( url => $template, dir => $template_dir, fatal => 0, debug => 0 );
        return $file if -f "$template_dir/$file";
    }

    return $template if -f "$template_dir/$template.tar.gz";

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

Copyright (c) 2009 Matt Simerson

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

