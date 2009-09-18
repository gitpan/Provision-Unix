package Provision::Unix::VirtualOS::Linux;

our $VERSION = '0.22';

use File::Copy;
use File::Path;

use warnings;
use strict;

#use English qw( -no_match_vars );
use Params::Validate qw(:all);

use lib 'lib';
use Provision::Unix;
use Provision::Unix::Utility;

my ($prov, $util);

sub new {
    my $class = shift;
    my %p = validate(@_, { prov => { type => HASHREF, optional => 1 } } );

    my $self = {};
    bless $self, $class;

    $prov = $p{prov} || Provision::Unix->new();
    $util = Provision::Unix::Utility->new( prov => $prov );

    return $self;
}

sub get_distro {

  # credit to Max Vohra. Logic implemented here was taken from his Template.pm

    my ($fs_root) = @_;

    return -e "$fs_root/etc/debian_version"
        ? { distro => 'debian', pack_mgr => 'apt' }
        : -e "$fs_root/etc/redhat-release"
        ? { distro => 'redhat', pack_mgr => 'yum' }
        : -e "$fs_root/etc/SuSE-release"
        ? { distro => 'suse', pack_mgr => 'zypper' }
        : -e "$fs_root/etc/slackware-version"
        ? { distro => 'slackware', pack_mgr => 'unknown' }
        : -e "$fs_root/etc/gentoo-release"
        ? { distro => 'gentoo', pack_mgr => 'emerge' }
        : -e "$fs_root/etc/arch-release"
        ? { distro => 'arch', pack_mgr => 'packman' }
        : { distro => undef, pack_mgr => undef };
}

sub install_kernel_modules {
    my $self = shift;
    my %p = validate(@_,
        {   fs_root   => { type => SCALAR, },
            url       => { type => SCALAR, optional => 1 },
            version   => { type => SCALAR, optional => 1 },
            test_mode => { type => BOOLEAN, optional => 1 },
        },
    );

    my $fs_root = $p{fs_root};
    my $url     = $p{url} || 'http://mirror.vpslink.com/xen';
    my $version = $p{version} = `uname -r`; chomp $version;

    if ( -d "/boot/domU" ) {
        my ($modules) = </boot/domU/modules*$version*>;
        $modules or return $prov->error( 
            "unable to find kernel modules in /boot/domU", fatal => 0);
        my $module_dir = "$fs_root/lib/modules";
        mkpath $module_dir if ! -d $module_dir;
        -d $module_dir or return $prov->error("unable to create $module_dir", fatal => 0);
        my $cmd = "tar -zxpf $modules -C $module_dir";
        $util->syscmd( cmd => $cmd, fatal => 0, debug => 0 ) or return;
    }
    else {
# try fetching them via curl
        chdir $fs_root;
        foreach my $mod ( qw/ modules headers / ) {
# fuse modules not yet available by sysadmin team, 2009.08.20 - mps
#    foreach my $mod ( qw/ modules module-fuse headers / ) {
            next if $mod eq 'headers' && ! "$fs_root/usr/src";
            my $cmd = "curl -s $url/xen-$mod-$version.tar.gz | tar -zxf - -C $fs_root";
            print "cmd: $cmd\n" and next if $p{test_mode};
            $util->syscmd( cmd => $cmd, fatal => 0, debug => 0 );
        };
        chdir "/home/xen";
    };

    # clean up behind template authors
    unlink "$fs_root/.bash_history" if -e "$fs_root/.bash_history";
    unlink "$fs_root/root/.bash_history" if -e "$fs_root/root/.bash_history";
    return 1;

#   $util->syscmd( cmd => "depmod -a -b $fs_root $version" );
};

sub set_rc_local {
    my $self = shift;
    my %p = validate(@_, { fs_root => { type => SCALAR } } );

    my $fs_root = $p{fs_root};

    my $rc_local = "$fs_root/etc/conf.d/local.start"; # gentoo
    if ( ! -f $rc_local ) {
        $rc_local = "$fs_root/etc/rc.local";  # everything else
    };

    return $util->file_write( 
        append => 1,
        file   => $rc_local, 
        lines  => [ 'pkill -9 -f nash', 
                    'ldconfig > /dev/null', 
                    'depmod -a > /dev/null', 
                    'exit 0',
                  ],
        mode   => '0755',
        fatal  => 0,
    );
};

sub set_ips {
    my $self = shift;
    my %p = validate(@_,
        {   ips       => { type => ARRAYREF },
            fs_root   => { type => SCALAR },
            dist      => { type => SCALAR },
            device    => { type => SCALAR,  optional => 1 },
            hostname  => { type => SCALAR,  optional => 1 },
            test_mode => { type => BOOLEAN, optional => 1 },
        }
    );

    my $dist = delete $p{dist};
    if ( $dist =~ /debian|ubuntu/ ) {
        return $self->set_ips_debian(%p);
    }
    elsif ( $dist =~ /redhat|fedora|centos/i ) {
        return $self->set_ips_redhat(%p);
    }
    elsif ( $dist =~ /gentoo/i ) {
        return $self->set_ips_gentoo(%p);
    }
    $prov->error( "unable to set up networking on distro $dist", fatal => 0 );
    return;
};

sub set_ips_debian {
    my $self = shift;
    my %p = validate(@_,
        {   ips       => { type => ARRAYREF },
            fs_root   => { type => SCALAR },
            device    => { type => SCALAR,  optional => 1 },
            hostname  => { type => SCALAR,  optional => 1 },
            test_mode => { type => BOOLEAN, optional => 1 },
        }
    );

    my $device = $p{device} || 'eth0';
    my @ips = @{ $p{ips} };
    my $test_mode = $p{test_mode};
    my $hostname = $p{hostname};
    my $fs_root  = $p{fs_root};

    my $ip = shift @ips;
    my @octets = split /\./, $ip;
    my $gw  = "$octets[0].$octets[1].$octets[2].1";
    my $net = "$octets[0].$octets[1].$octets[2].0";

    my $config = <<EO_FIRST_IP
# This configuration file is auto-generated by Provision::Unix.
# WARNING: Do not edit this file, else your changes will be lost.

# Auto generated interfaces
auto $device lo
iface lo inet loopback
iface $device inet static
    address $ip
    netmask 255.255.255.0
    up route add -net $net netmask 255.255.255.0 dev $device
    up route add default gw $gw
EO_FIRST_IP
;

    my $alias_count = 0;
    foreach ( @ips ) {
        $config .= <<EO_ADDTL_IPS

auto $device:$alias_count
iface $device:$alias_count inet static
    address $_
    netmask 255.255.255.255
    broadcast 0.0.0.0
EO_ADDTL_IPS
;
        $alias_count++;
    };
    #return $config;

    my $config_file = "/etc/network/interfaces";
    return $config if $test_mode;
    if ( $util->file_write( 
            file => "$fs_root/$config_file", 
            lines => [ $config ], 
            fatal => 0, debug => 0 ) 
        ) 
    {
        $prov->audit( "updated debian $config_file with network settings");
    }
    else {
        $prov->error( "failed to update $config_file with network settings", fatal => 0);
    };

    if ( $hostname) {
        $self->set_hostname_debian( host => $hostname, fs_root => $fs_root );
    };
    return $config;
};

sub set_ips_gentoo {
    my $self = shift;
    my %p = validate(@_,
        {   ips       => { type => ARRAYREF },
            fs_root   => { type => SCALAR },
            device    => { type => SCALAR,  optional => 1 },
            hostname  => { type => SCALAR,  optional => 1 },
            test_mode => { type => BOOLEAN, optional => 1 },
        }
    );

    my $device = $p{device} || 'eth0';
    my @ips = @{ $p{ips} };
    my $test_mode = $p{test_mode};
    my $hostname = $p{hostname};
    my $fs_root  = $p{fs_root};

    my $ip = shift @ips;
    my @octets = split /\./, $ip;
    my $gw  = "$octets[0].$octets[1].$octets[2].1";

    my $conf_dir = "$fs_root/etc/conf.d";
    my $net_conf = "$conf_dir/net";

    my (@lines, @new_lines);
    if ( -r $net_conf ) {
        @lines = $util->file_read( file => $net_conf, fatal => 0 )
            or $prov->error("error trying to read /etc/conf.d/net", fatal => 0);
    };
    foreach ( @lines ) {
        next if $_ =~ /^config_$device/;
        next if $_ =~ /^routes_$device/;
        push @new_lines, $_;
    };
    my $ip_string = "config_$device=( \n\t\"$ip/24\"";
    foreach ( @ips ) { $ip_string .= "\n\t\"$_/32\""; };
    $ip_string .= ")";
    push @new_lines, $ip_string;
    push @new_lines, "routes_$device=(\n\t\"default via $gw\"\n)";
    $prov->audit("net config: $ip_string");
    $util->file_write( file => $net_conf, lines => \@new_lines, fatal => 0 )
        or return $prov->error(
        "error setting up networking, unable to write to $net_conf", fatal => 0);

    return 1;
    #my $script = "/etc/runlevels/default/net.$device";
};

sub set_ips_redhat {
    my $self = shift;
    my %p = validate(@_,
        {   ips       => { type => ARRAYREF },
            fs_root   => { type => SCALAR },
            device    => { type => SCALAR,  optional => 1 },
            hostname  => { type => SCALAR,  optional => 1 },
            test_mode => { type => BOOLEAN, optional => 1 },
        }
    );

    my $etc       = "$p{fs_root}/etc";
    my $device    = $p{device} || 'eth0';
    my @ips       = @{ $p{ips} };
    my $hostname  = $p{hostname} || 'localhost';
    my $test_mode = $p{test_mode};

    my $ip = shift @ips;
    my @octets = split /\./, $ip;
    my $gw  = "$octets[0].$octets[1].$octets[2].1";
    my $net = "$octets[0].$octets[1].$octets[2].0";

    my $netfile = "sysconfig/network";
    my $if_file = "sysconfig/network-scripts/ifcfg-$device";
    my $route_f = "sysconfig/network-scripts/route-$device";
    my $errors_before = scalar @{ $prov->{errors} };

    my $contents = <<EO_NETFILE
NETWORKING="yes"
GATEWAY="$gw"
HOSTNAME="$hostname"
EO_NETFILE
;
    return $contents if $test_mode;
    my $r = $util->file_write( file => "$etc/$netfile", lines => [ $contents ], debug => 0, fatal => 0 );
    $r ? $prov->audit("updated /etc/$netfile with hostname $hostname and gateway $gw")
       : $prov->error("failed to update $netfile", fatal => 0);

    $contents = <<EO_IF_FILE
DEVICE=$device
BOOTPROTO=static
ONBOOT=yes
IPADDR=$ip
NETMASK=255.255.255.0
EO_IF_FILE
;
    $r = $util->file_write( file => "$etc/$if_file", lines => [ $contents ], debug => 0, fatal => 0 );
    $r ? $prov->audit("updated /etc/$if_file with ip $ip")
       : $prov->error("failed to update $if_file", fatal => 0);

    $contents = <<EO_ROUTE_FILE
$net/24 dev $device scope host
default via $gw
EO_ROUTE_FILE
;
    $r = $util->file_write( file => "$etc/$route_f", lines => [ $contents ], debug => 0, fatal => 0 );
    $r ? $prov->audit("updated /etc/$route_f with net $net and gw $gw")
       : $prov->error("failed to update $route_f", fatal => 0);

    my $alias_count = 0;
    foreach ( @ips ) {
        $if_file = "sysconfig/network-scripts/ifcfg-$device:$alias_count";
        $contents = <<EO_IF_FILE
DEVICE=$device:$alias_count
BOOTPROTO=static
ONBOOT=yes
IPADDR=$_
NETMASK=255.255.255.0
EO_IF_FILE
;
        $alias_count++;
        $r = $util->file_write( file => "$etc/$if_file", lines => [ $contents ], debug => 0, fatal => 0 );
        $r ? $prov->audit("updated /etc/$if_file with device $device and ip $_")
           : $prov->error("failed to update $if_file", fatal => 0);
    };
    return if scalar @{ $prov->{errors}} > $errors_before;
    return 1;
};

sub set_hostname {
    my $self = shift;
    my %p = validate(@_,
        {   host    => { type => SCALAR },
            fs_root => { type => SCALAR },
            dist    => { type => SCALAR },
        }
    );

    my $dist = delete $p{dist};
    if ( $dist =~ /debian|ubuntu/ ) {
        return $self->set_hostname_debian(%p);
    }
    elsif ( $dist =~ /redhat|fedora|centos/i ) {
        return $self->set_hostname_redhat(%p);
    }
    elsif ( $dist =~ /gentoo/i ) {
        return $self->set_hostname_gentoo(%p);
    }
    $prov->error( "unable to set hostname on distro $dist", fatal => 0 );
    return;
};

sub set_hostname_debian {
    my $self = shift;
    my %p = validate(@_,
        {   host    => { type => SCALAR },
            fs_root => { type => SCALAR },
        }
    );

    my $host    = $p{host};
    my $fs_root = $p{fs_root};

    #print "$host > $etc/hostname";
    $util->file_write( file => "$fs_root/etc/hostname" , lines => [ $host ], debug => 0, fatal => 0 )
        or return $prov->error("unable to set hostname", fatal => 0 );
    $prov->audit("wrote hostname to /etc/hostname");
    return 1;
};

sub set_hostname_gentoo {
    my $self = shift;
    my %p = validate(@_,
        {   host    => { type => SCALAR },
            fs_root => { type => SCALAR },
        }
    );

    my $host    = $p{host};
    my $fs_root = $p{fs_root};

    mkpath "$fs_root/etc/conf.d" if ! "$fs_root/etc/conf.d";

    $util->file_write( 
        file => "$fs_root/etc/conf.d/hostname" , 
        lines => [ "HOSTNAME=$host" ],
        fatal => 0,
        debug => 0,
    )
    or return $prov->error("error setting hostname", fatal => 0);
    $prov->audit("updated /etc/conf.d/hostname with $host");
    return 1;
};

sub set_hostname_redhat {
    my $self = shift;
    my %p = validate(@_,
        {   host    => { type => SCALAR },
            fs_root => { type => SCALAR },
        }
    );

    my $fs_root = $p{fs_root};
    my $host    = $p{host};

    my $config = "$fs_root/etc/sysconfig/network";
    my @new;
    if ( -r $config ) {
        my @lines = $util->file_read( file => $config, debug => 0, fatal => 0 );
        foreach ( @lines ) {
            next if $_ =~ /^HOSTNAME/;
            push @new, $_;
        };
    };
    push @new, "HOSTNAME=$host";

    $util->file_write( 
        file => $config, 
        lines => \@new, 
        debug => 0, 
        fatal => 0,
    )
    or return $prov->error("failed to update $config with hostname $host", fatal => 0);

    $prov->audit("updated $config with hostname $host");
    return 1;
};

sub set_upstart_console {
    my $self = shift;
    my ($fs_root, $getty_cmd) = @_;

    my $contents = <<EO_INITTAB
#
# This service maintains a getty on xvc0 from the point the system is
# started until it is shut down again.

start on runlevel 2
start on runlevel 3

stop on runlevel 0
stop on runlevel 1
stop on runlevel 4
stop on runlevel 5
stop on runlevel 6

respawn
exec $getty_cmd

EO_INITTAB
;

    $util->file_write( 
        file  => "$fs_root/etc/event.d/xvc0", 
        lines => [ $contents ],
        debug => 0,
        fatal => 0,
    ) or return;
    $prov->audit( "installed /etc/event.d/xvc0" );

    my $serial = "$fs_root/etc/event.d/serial";
    return if ! -e $serial;

    my @lines = $util->file_read( file => $serial, debug => 0, fatal => 0 );
    my @new;
    foreach my $line ( @lines ) {
        if ( $line =~ /^[start|stop]/ ) {
            push @new, "#$line";
            next;
        };
        push @new, $line;
    }
    $util->file_write( 
        file  => "$fs_root/etc/event.d/serial", 
        lines => \@new,
        debug => 0,
        fatal => 0,
    ) or return;
    $prov->audit("updated /etc/event.d/serial");
    return;
}

sub setup_inittab {
    my $self = shift;
    my %p = validate(@_, 
        {   fs_root  => { type => SCALAR }, 
            template => { type => SCALAR },
        } 
    );

    my $fs_root = $p{fs_root};
    my $template = $p{template};
    my $login;
    my $tty_dev = 'xvc0';
#    $tty_dev = 'console' 
#        if ( -e "$fs_root/dev/console" && ! -e "$fs_root/dev/xvc0" );

    if ( $template !~ /debian|ubuntu/i ) {
        $login = $self->setup_autologin( fs_root => $fs_root );
    };
    if ( $template =~ /redhat|fedora|centos/ ) {
        $tty_dev = 'console';
    };
    $login ||= -e "$fs_root/bin/bash" ? '/bin/bash' : '/bin/sh';

    my $getty_cmd = -e "$fs_root/sbin/getty" ?
        "/sbin/getty -n -l $login 38400 $tty_dev"
                  : -e "$fs_root/sbin/agetty" ?
        "/sbin/agetty -n -i -l $login $tty_dev 38400"
                  : '/bin/sh';

    # check for upstart
    if ( -e "$fs_root/etc/event.d" ) {   
        $self->set_upstart_console( $fs_root, $getty_cmd );
    };

    my $inittab = "$fs_root/etc/inittab";
    my @lines = $util->file_read( file => $inittab, debug => 0, fatal => 0 );
    my @new;
    foreach ( @lines ) {
        next if $_ =~ /^1:/;
        push @new, $_;
    }
    push @new, "1:2345:respawn:$getty_cmd";
    copy $inittab, "$inittab.dist";
    $util->file_write( file => $inittab, lines => \@new, fatal => 0, debug => 0 )
        or return $prov->error( "unable to write $inittab", fatal => 0);

    $prov->audit("updated /etc/inittab ");
    return 1;
};

sub setup_autologin {
    my $self = shift;
    my %p = validate(@_, { fs_root => { type => SCALAR, } } );

    my $fs_root = $p{fs_root};

    my $auto = <<'EO_C_CODE'
#include <unistd.h>
/* 
  http://wiki.archlinux.org/index.php/Automatically_login_some_user_to_a_virtual_console_on_startup
*/
int main() {
    printf( "%s \n", "Logging on to VPS console. Press Ctrl-] to Quit.");
    printf( "%s \n", "Press Enter to start." );
    execlp( "login", "login", "-f", "root", 0);
}
EO_C_CODE
;

    $util->file_write( 
        file  => "$fs_root/tmp/autologin.c", 
        lines => [ $auto ], 
        fatal => 0, debug => 0 
    ) or return;

    my $chroot = $util->find_bin( bin=>'chroot', fatal => 0, debug => 0 ) or return;
    my $gcc = $util->find_bin( bin=>'gcc', fatal => 0, debug => 0 ) or return;
    my $cmd = "$chroot $fs_root $gcc -m32 -o /bin/autologin /tmp/autologin.c";
    $util->syscmd( cmd => $cmd, debug => 0, fatal => 0 ) or return;
    unlink "$fs_root/tmp/autologin.c";
    return if ! -x "$fs_root/bin/autologin";
    return '/bin/autologin';
}


1;

