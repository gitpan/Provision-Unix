package Provision::Unix::VirtualOS::Linux::OpenVZ;

our $VERSION = '0.38';

use warnings;
use strict;

use English qw( -no_match_vars );
use File::Copy;
use Params::Validate qw(:all);
use URI;

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
        or $prov->error( "Create function requires root privileges." );

    my $ctid = $vos->{name};

    # do not create if it exists already
    return $prov->error( "ctid $ctid already exists",
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
        return $prov->error( $err,
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        );
    }

    # TODO
    # validate the config (package). <- HUH? -mps 7/21/09

    $prov->audit("\tctid '$ctid' does not exist, creating...");

    # build the shell command to create
    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );

    $cmd .= " create $ctid";
    if ( $vos->{disk_root} ) {
        my $disk_root = "$vos->{disk_root}/root/$ctid";
        if ( -e $disk_root ) {
            return $prov->error( "the root directory for $ctid ($disk_root) already exists!",
                fatal   => $vos->{fatal},
                debug   => $vos->{debug},
            );
        };
        $cmd .= " --root $disk_root";
        $cmd .= " --private $vos->{disk_root}/private/$ctid";
    };

    if ( $vos->{config} ) {
        $cmd .= " --config $vos->{config}";
    }
    else {
        $self->set_config_default();
        $cmd .= " --config default";
    };

    if ( $vos->{template} ) {
        my $template = $self->_is_valid_template( $vos->{template} ) or return;
        $cmd .= " --ostemplate $template";
    }

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    my $r = $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 );
    if ( ! $r ) {
        $prov->error( "VPS creation failed, unknown error",
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
        or $prov->error( "Destroy function requires root privileges." );

    my $name = $vos->{name};

    # make sure container name/ID exists
    return $prov->error( "container $name does not exist",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if !$self->is_present();

    # if disabled, enable it, else vzctl pukes when it attempts to destroy
    my $config = $self->get_config();
    if ( ! -e $config ) {
        my $suspended_config = "$config.suspend";
# humans often rename the config file to .suspended instead of our canonical '.suspend'
        $suspended_config = "$config.suspended" if ! -e $suspended_config;
        if ( ! -e $suspended_config ) {
            return $prov->error( "config file for VE $name is missing",
                fatal   => $vos->{fatal},
                debug   => $vos->{debug},
            );
        };
        move( $suspended_config, $config )
            or return $prov->error( "unable to move file '$suspended_config' to '$config': $!",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
            );
    };

    # if VE is running, shut it down
    if ( $self->is_running( refresh => 0 ) ) {
        $prov->audit("\tcontainer '$name' is running, stopping...");
        $self->stop_virtualos() 
            or return
            $prov->error( "shut down failed. I cannot continue.",
                fatal   => $vos->{fatal},
                debug   => $vos->{debug},
            );
    };

    # if VE is mounted, unmount it
    if ( $self->is_mounted( refresh => 0 ) ) {
        $prov->audit("\tcontainer '$name' is mounted, unmounting...");
        $self->unmount_disk_image() 
            or return
            $prov->error( "unmount failed. I cannot continue.",
                fatal   => $vos->{fatal},
                debug   => $vos->{debug},
            );
    };

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

    return $prov->error( "destroy failed, unknown error",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    );
}

sub start_virtualos {

    my $self = shift;
    my $ctid = $vos->{name};

    $prov->audit("starting $ctid");

    if ( !$self->is_present() ) {
        return $prov->error( "container $ctid does not exist",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        ) 
    };

    if ( $self->is_running() ) {
        $prov->audit("$ctid is already running.");
        return 1;
    };

    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );

    $cmd .= ' start';
    $cmd .= " $vos->{name}";
    $cmd .= " --force" if $vos->{force};
    $cmd .= " --wait" if $vos->{'wait'};

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};
    $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 );

# the results of vzctl start are not reliable. Use vzctl to
# check the VE status and see if it actually started.

    foreach ( 1..8 ) {
        return 1 if $self->is_running();
        sleep 1;   # the xm start create returns before the VE is running.
    };
    return 1 if $self->is_running();

    return $prov->error( "unable to start VE",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    );
}

sub stop_virtualos {

    my $self = shift;

    my $ctid = $vos->{name};
    
    $prov->audit("stopping $ctid");

    if ( !$self->is_present() ) {
        return $prov->error( "$ctid does not exist",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        ) 
    };

    if ( ! $self->is_running( refresh => 0 ) ) {
        $prov->audit("$ctid is already shutdown.");
        return 1;
    };

    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );
    $cmd .= " stop $vos->{name}";

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};
    $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 );

    foreach ( 1..8 ) {
        return 1 if ! $self->is_running();
        sleep 1;
    };
    return 1 if ! $self->is_running();

    return $prov->error( "unable to stop VE",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    );
}

sub restart_virtualos {

    my $self = shift;

    $self->stop_virtualos()
        or
        return $prov->error( "unable to stop virtual $vos->{name}",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        );

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
    my $config = $self->get_config();
    if ( ! -e $config && ( -e "$config.suspend" || -e "$config.suspended" ) ) {
        $prov->audit( "container is already disabled." );
        return 1;
    };

    # make sure config file exists
    if ( !-e $config ) {
        return $prov->error( "configuration file ($config) for $ctid does not exist.",
            fatal => $vos->{fatal},
            debug => $vos->{debug},
        );
    }

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    # see if VE is running, and if so, stop it
    $self->stop_virtualos() if $self->is_running( refresh => 0 );

    $self->unmount_disk_image() if $self->is_mounted( refresh => 0 );

    move( $config, "$config.suspend" )
        or return $prov->error( "unable to move file '$config' to '$config.suspend': $!",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
        );

    $prov->audit( "virtual $ctid is disabled." );

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
    ) if ! $self->is_present();

    # see if VE is currently enabled
    my $config = $self->get_config();
    if ( -e $config ) {
        $prov->audit("\t$ctid is already enabled");
        return $self->start_virtualos();
    };

    # make sure config file exists
    my $suspended_config = "$config.suspend";
    $suspended_config = "$config.suspended" if ! -e $suspended_config;
    if ( !-e $suspended_config ) {
        return $prov->error( "configuration file ($config.suspend) for $ctid does not exist",
            fatal => $vos->{fatal},
            debug => $vos->{debug},
        );
    }

    # make sure container directory exists
    my $ct_dir = $self->get_ve_home();  # "/vz/private/$ctid";
    if ( !-e $ct_dir ) {
        return $prov->error( "container directory '$ct_dir' for $ctid does not exist",
            fatal => $vos->{fatal},
            debug => $vos->{debug},
        );
    }

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};

    move( $suspended_config, $config )
        or return $prov->error( "unable to move file '$config': $!",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
        );

    return $self->start_virtualos();
}

sub modify_virtualos {

    my $self = shift;

    $EUID == 0
        or $prov->error( "Modify function requires root privileges." );

    my $ctid = $vos->{name};

    # cannot modify unless it exists
    return $prov->error( "ctid $ctid does not exist",
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

    return $prov->error( "modify failed, unknown error",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    );
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

sub upgrade_virtualos {
    my $self = shift;

# generate updated config file
    my $config = $self->gen_config();
    my $conf_file = $self->get_config();
    
# install config file
    $util->file_write( file => $conf_file, lines => [ $config ] );
    $prov->audit("updated config file, restarting VE");

# restart VE
    $self->restart_virtualos()
        or return $prov->error( "unable to restart virtual $vos->{name}",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        );

    return 1;
};

sub unmount_disk_image {

    my $self = shift;

    my $ctid = $vos->{name};
    $prov->audit("unmounting virtual $ctid");

    # make sure CTID exists
    return $prov->error( "container $ctid does not exist",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    ) if !$self->is_present();

    # see if VE is mounted
    if ( !$self->is_mounted( refresh => 0 ) ) {
        return $prov->error( "container $ctid is not mounted",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        );
    }

    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );
    $cmd .= " umount $vos->{name}";

    return $prov->audit("\ttest mode early exit") if $vos->{test_mode};
    $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 );

    foreach ( 1..8 ) {
        return 1 if ! $self->is_mounted();
        sleep 1;
    };
    return 1 if ! $self->is_mounted();

    return $prov->error( "unable to unmount VE",
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
    );
}

sub gen_config {
    my $self = shift;
# most of this method was written by Max Vohra - 2009

    my $ram  = $vos->{ram} or die "unable to determine RAM";
    my $disk = $vos->{disk_size} or die "unable to determine disk space";

    my $MAX_ULONG = "2147483647";
    if( ($CHILD_ERROR>>8) == 0 ){
        $MAX_ULONG = "9223372036854775807"
    };

    # UBC parameters (in form of barrier:limit)
    my $config = {
        NUMPROC      => [ int($ram*5),   int($ram*5)   ],
        AVNUMPROC    => [ int($ram*2.5), int($ram*2.5) ],
        NUMTCPSOCK   => [ int($ram*5),   int($ram*5)   ],
        NUMOTHERSOCK => [ int($ram*5),   int($ram*5)   ],
        VMGUARPAGES  => [ int($ram*256), $MAX_ULONG    ],
    };

    # Secondary parameters
    $config->{KMEMSIZE} = [ $config->{NUMPROC}[0]*45*1024, $config->{NUMPROC}[0]*45*1024 ];
    $config->{TCPSNDBUF} = [ int($ram*2*23819), int($ram*2*23819)+$config->{NUMTCPSOCK}[0]*4096 ];
    $config->{TCPRCVBUF} = [ int($ram*2*23819), int($ram*2*23819)+$config->{NUMTCPSOCK}[0]*4096 ];
    $config->{OTHERSOCKBUF} = [ int(23819*$ram), int(23819*$ram)+$config->{NUMOTHERSOCK}[0]*4096 ];
    $config->{DGRAMRCVBUF} = [ int(23819*$ram), int(23819*$ram) ];
    $config->{OOMGUARPAGES} = [ int(23819*$ram), $MAX_ULONG ];
    $config->{PRIVVMPAGES} = [ int(250*$ram), int(256*$ram) ];

    # Auxiliary parameters
    $config->{LOCKEDPAGES} = [ int($config->{NUMPROC}[0]*2), int($config->{NUMPROC}[0]*2) ];
    $config->{SHMPAGES} = [ int($ram*100), int($ram*100) ]; 
    $config->{PHYSPAGES} = [ 0, $MAX_ULONG ];
    $config->{NUMFILE} = [ 16*$config->{NUMPROC}[0], 16*$config->{NUMPROC}[0] ];
    $config->{NUMFLOCK} = [ 1000, 1000 ];
    $config->{NUMPTY} = [ 256, 256 ];
    $config->{NUMSIGINFO} = [ 1024, 1024 ];
    $config->{DCACHESIZE} = [ int($config->{NUMFILE}[1]*576*0.95), $config->{NUMFILE}[1]*576 ];

    $config->{NUMIPTENT}  = $ram < 513  ? [ 1536, 1536 ]
                          : $ram < 1025 ? [ 3072, 3072 ]
                          : [ 6144, 6144 ];

    # Disk Resource Limits
    $config->{DISKSPACE}  = [ int($disk*1024*1024*0.95), int($disk*1024*1024) ]; 
    $config->{DISKINODES} = [ int($disk*114000), int($disk*120000) ];
    $config->{QUOTAUGIDLIMIT} = [ 3000 ];
    $config->{QUOTATIME}  = [ 0 ];

    # CPU Resource Limits
    $config->{CPUUNITS}   = [ 1000 ];
    $config->{RATE}       = [ 'eth0', 1, 6000 ];

    $config->{IPTABLES}   = [ join(" ", qw(
        ipt_REJECT ipt_tos ipt_limit ipt_multiport
        iptable_filter iptable_mangle ipt_TCPMSS 
        ipt_tcpmss ipt_ttl ipt_length ip_conntrack 
        ip_conntrack_ftp ipt_LOG ipt_conntrack 
        ipt_helper ipt_state iptable_nat ip_nat_ftp 
        ipt_TOS ipt_REDIRECT ) ) ];
    $config->{DEVICES} = [ "c:10:229:rw c:10:200:rw" ];
    $config->{ONBOOT}  = [ "yes" ]; 
    
    my $result = <<EO_MAX_CONFIG
# This is a configuration file generated by Provision::Unix
# The config parameters are: $ram RAM, and $disk disk space
#
EO_MAX_CONFIG
;
    for my $var ( sort keys %$config ){
        #print $var, '="', join(":",@{$config->{$var}}),"\"\n";
        $result .= $var . '="' . join(":",@{$config->{$var}}) . "\"\n";
    };

    my $name = $vos->{name};
    my $disk_root = $vos->{disk_root} || '/vz';
    my $ip_string = join(' ', @{ $vos->{ip} } ) if $vos->{ip};

    $result .= <<EO_VE_CUSTOM
\n# Provision::Unix Custom VE Additions
VE_ROOT="$disk_root/root/\$VEID"
VE_PRIVATE="$disk_root/private/\$VEID"
OSTEMPLATE="$vos->{template}"
ORIGIN_SAMPLE="$vos->{config}"
HOSTNAME="$vos->{hostname}"
IP_ADDRESS="$ip_string"
EO_VE_CUSTOM
;

    return $result;
};

sub get_config {
    my $ctid   = $vos->{name};
    my $etc_dir = $prov->{etc_dir} || '/etc/vz/conf';
    my $config = "$etc_dir/$ctid.conf";
    return $config;
};

sub get_console {
    my $self = shift;
    my $ctid = $vos->{name};
    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );
    exec "$cmd enter $ctid";
};

sub get_disk_usage {
    
    my $self = shift;

    $EUID == 0
        or return $prov->error( "Sorry, getting disk usage requires root.",
        fatal   => 0,
        );

    my $name = $vos->{name};
    my $vzquota = $util->find_bin( bin => 'vzquota', debug => 0, fatal => 0 );
    $vzquota or return $prov->error( "Cannot find vzquota.", fatal => 0 );

    $vzquota .= " show $name";
    my $r = `$vzquota 2>/dev/null`;
# VEID 1002362 exist mounted running
# VEID 1002362 exist unmounted down
    if ( $r =~ /usage/ ) {
        my ($usage) = $r =~ /1k-blocks\s+(\d+)\s+/;
        if ( $usage ) {
            $prov->audit("found disk usage of $usage 1k blocks");
            return $usage;
        };
    };
    $prov->audit("encounted error while trying to get disk usage");
    return;

#    my $homedir = $self->get_ve_home();
#    $cmd .= " -s $homedir";
#    my $r = `$cmd`;
#    my ($usage) = split /\s+/, $r;
#    if ( $usage =~ /^\d+$/ ) {
#        return $usage;
#    };
#    return $prov->error( "du returned unknown result: $r", fatal => 0 );
}

sub get_os_template {
    
    my $self = shift;

    my $config = $self->get_config();
    return if ! -f $config;
    my $grep = $util->find_bin(bin=>'grep', debug => 0, fatal => 0);
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
        or return $prov->error( "Status function requires root privileges.",
        fatal   => 0
        );

    my $vzctl = $util->find_bin( bin => 'vzctl', debug => 0, fatal => 0 );
    $vzctl or 
        return $prov->error( "Cannot find vzctl.", fatal => 0 );

# VEID 1002362 exist mounted running
# VEID 1002362 exist unmounted down
# VEID 100236X deleted unmounted down

    $vzctl .= " status $name";
    my $r = `$vzctl`;
    if ( $r =~ /deleted/i ) {
        my $config = $self->get_config();
        if ( -e "$config.suspend" || -e "$config.suspended" ) {
            $exists++;
            $ve_info{state} = 'suspended';
        }
        else {
            $ve_info{state} = 'non-existent';
        };
    }
    elsif ( $r =~ /exist/i ) {
        $exists++;
        if    ( $r =~ /running/i ) { $ve_info{state} = 'running'; }
        elsif ( $r =~ /down/i    ) { $ve_info{state} = 'shutdown'; };

        if    ( $r =~ /unmounted/ ) { $ve_info{mount} = 'unmounted'; }
        elsif ( $r =~ /mounted/   ) { $ve_info{mount} = 'mounted';   };
    }
    else {
        return $prov->error( "unknown output from vzctl status.", fatal => 0 );
    };

    return \%ve_info if ! $exists;
    $prov->audit("found VE in state $ve_info{state}");

    if ( $ve_info{state} =~ /running|shutdown/ ) {
        my $vzlist = $util->find_bin( bin => 'vzlist', debug => 0, fatal => 0 );
        if ( $vzlist ) {
            my $vzs = `$vzlist --all`;

            if ( $vzs =~ /NPROC/ ) {

            # VEID      NPROC STATUS  IP_ADDR         HOSTNAME
            # 10          -   stopped 64.79.207.11    lbox-bll

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
    my $name = $vos->{name} || shift || die "missing VE name";
    my $disk_root = $vos->{disk_root} || '/vz';
    my $homedir = "$disk_root/private/$name";
    return $homedir;
};

sub set_config {
    my $self = shift;
    my $config = shift || _default_config();
    my $ctid = $vos->{name};
    my $config_file = $prov->{etc_dir} . "/$ctid.conf";

    return $util->file_write(
        file  => $config_file,
        lines => [ $config ],
        debug => 0,
    );
};

sub set_config_default {
    my $self = shift;

    my $config_file = $prov->{etc_dir} . "/ve-default.conf-sample";
    return if -f $config_file;

    return $util->file_write(
        file  => $config_file,
        lines => [ _default_config() ],
        debug => 0,
        fatal => 0,
    );
};

sub set_ips {
    my $self = shift;

    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );
    $cmd .= " set $vos->{name}";

    my $ips = $vos->{ip};
    @$ips > 0
        or return $prov->error( 'set_ips called but no valid IPs were provided',
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
        or return $prov->error( 'set_password function called but password not provided',
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
        or return $prov->error( 'set_nameservers function called with no valid nameserver ips',
        fatal => $vos->{fatal},
        debug => $vos->{debug},
        );

    foreach my $ns (@$nameservers) { $cmd .= " --nameserver $ns"; }

    $cmd .= " --searchdomain $search" if $search;
#    $cmd .= " --save";

    return $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 );
}

sub set_hostname {
    my $self = shift;

    my $hostname = $vos->{hostname}
        or return $prov->error( 'no hostname defined',
        fatal   => $vos->{fatal},
        debug   => $vos->{debug},
        );

    my $cmd = $util->find_bin( bin => 'vzctl', debug => 0 );
    $cmd .= " set $vos->{name}";
    $cmd .= " --hostname $hostname --save";

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

sub is_mounted {
    my $self = shift;

    my %p = validate(
        @_,
        {   name   => { type => SCALAR,  optional => 1 },
            refresh=> { type => BOOLEAN, optional => 1, default => 1 },
            debug  => { type => BOOLEAN, optional => 1, default => 1 },
            fatal  => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $name = $p{name} || $vos->{name} or
        $prov->error( 'is_mounted was called without a CTID' );

    $self->get_status() if $p{refresh};
    return 1 if $self->{status}{$name}{mount} eq 'mounted';
    return;
};

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
        $prov->error( 'is_present was called without a CTID' );

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
         $prov->error( 'is_running was called without a CTID' );

    $self->get_status() if $p{refresh};
    return 1 if $self->{status}{$name}{state} eq 'running';
    return;
}

sub _is_valid_template {

    my $self     = shift;
    my $template = shift;

    my $template_dir = $self->{prov}{config}{ovz_template_dir} || '/vz/template/cache';

    if ( $template =~ /^http/ ) {

        my $uri = URI->new($template);
        my @segments = $uri->path_segments;
        my @path_bits = grep { /\w/ } @segments;  # ignore empty fields
        my $file = $segments[-1];

        $prov->audit("fetching $file from " . $uri->host);

        $util->file_get(
            url   => $template,
            dir   => $template_dir,
            fatal => 0,
            debug => 0,
        );
        return $file if -f "$template_dir/$file";
    }
    else {
        return $template if -f "$template_dir/$template.tar.gz";
    }

    return $prov->error( "template '$template' does not exist and is not a valid URL",
        debug => $vos->{debug},
        fatal => $vos->{fatal},
    );
}

sub _is_valid_name {
    my $self = shift;
    my $name = shift;

    if ( $name !~ /^[0-9]+$/ ) {
        return $prov->error( "OpenVZ requires the name (VEID/CTID) to be numeric",
            fatal   => $vos->{fatal},
            debug   => $vos->{debug},
        );
    }
    return 1;
}

sub _default_config {

    return <<'EOCONFIG'
ONBOOT="yes"
NUMPROC="2550:2550"
AVNUMPROC="1275:1275"
NUMTCPSOCK="2550:2550"
NUMOTHERSOCK="2550:2550"
VMGUARPAGES="131072:9223372036854775807"

# Secondary parameters
KMEMSIZE="104506470:114957117"
TCPSNDBUF="24390690:34835490"
TCPRCVBUF="24390690:34835490"
OTHERSOCKBUF="12195345:22640145"
DGRAMRCVBUF="12195345:12195345"
OOMGUARPAGES="75742:9223372036854775807"
PRIVVMPAGES="128000:131072"

# Auxiliary parameters
LOCKEDPAGES="5102:5102"
SHMPAGES="45445:45445"
PHYSPAGES="0:9223372036854775807"
NUMFILE="40800:40800"
NUMFLOCK="1000:1100"
NUMPTY="255:255"
NUMSIGINFO="1024:1024"
DCACHESIZE="22816310:23500800"
NUMIPTENT="1536:1536"

# Disk Resource Limits
DISKINODES="2280000:2400000"
DISKSPACE="19922944:20971520"

# Quota Resource Limits
QUOTATIME="0"
QUOTAUGIDLIMIT="3000"

# CPU Resource Limits
CPUUNITS="1000"
RATE="eth0:1:6000"

# IPTables config
IPTABLES="ipt_REJECT ipt_tos ipt_limit ipt_multiport iptable_filter iptable_mangle ipt_TCPMSS ipt_tcpmss ipt_ttl ipt_length ip_conntrack ip_conntrack_ftp ipt_LOG ipt_conntrack ipt_helper ipt_state iptable_nat ip_nat_ftp ipt_TOS ipt_REDIRECT"

# Default Devices
DEVICES="c:10:229:rw c:10:200:rw "
EOCONFIG
;
};


1

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

