package Provision::Unix::VirtualOS;

use warnings;
use strict;

our $VERSION = '0.38';

use Data::Dumper;
use English qw( -no_match_vars );
use LWP::Simple;
use LWP::UserAgent;
use Params::Validate qw(:all);
use Time::Local;

use lib 'lib';
use Provision::Unix::Utility;

my ($prov, $util);
my @std_opts = qw/ test_mode debug fatal /;
my %std_opts = (
    test_mode => { type => BOOLEAN, optional => 1 },
    debug     => { type => BOOLEAN, optional => 1, default => 1 },
    fatal     => { type => BOOLEAN, optional => 1, default => 1 },
);


sub new {

    # Usage      : $virtual->new( prov => $prov );
    # Purpose    : create a $virtual object
    # Returns    : a Provision::Unix::VirtualOS object
    # Parameters :
    #   Required : prov      - a Provision::Unix object
    #   Optional : etc_dir   - an etc directory used by some P:U:V classes

    my $class = shift;
    my %p     = validate(
        @_,
        {   prov    => { type => OBJECT },
            etc_dir => { type => SCALAR,  optional => 1 },
            debug   => { type => BOOLEAN, optional => 1, default => 1 },
            fatal   => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $self = {
        prov    => $p{prov},
        debug   => $p{debug},
        fatal   => $p{fatal},
        etc_dir => $p{etc_dir},
    };
    bless( $self, $class );

    $prov = $p{prov};
    $prov->audit("loaded Provision::Unix::VirtualOS");

    $util = Provision::Unix::Utility->new( prov=> $prov )
        or die "unable to load P:U:Utility\n";
    $self->{vtype} = $self->_get_virt_type( fatal => $p{fatal}, debug => $p{debug} )
        or die $prov->{errors}[-1]{errmsg};
    return $self;
}

sub create_virtualos {

# Usage      : $virtual->create_virtualos( name => 'mysql', ip=>'127.0.0.2' );
# Purpose    : create a virtual OS instance
# Returns    : true or undef on failure
# Parameters :
#   Required : name      - name/ID of the virtual OS
#            : ip        - IP address(es), space delimited
#   Optional : hostname  - the FQDN of the virtual OS
#            : disk_root - the root directory of the virt os
#            : disk_size - disk space allotment in MB
#            : ram       - in MB
#            : config    - a config file with virtual specific settings
#            : template  - a 'template' or tarball the OS is patterned after
#            : password  - the root/admin password for the virtual
#            : nameservers -
#            : searchdomain -

    my $self = shift;
    my @opt_scalars = qw/ hostname disk_root disk_size ram config 
                    template password nameservers searchdomain ssh_key
                    kernel_version mac_address /;
    my %opt_scalars = map { $_ => { type => SCALAR, optional => 1 } } @opt_scalars;

    my %p = validate(
        @_,
        {   name   => { type => SCALAR },
            ip     => { type => SCALAR },
            %opt_scalars,
            %std_opts,
        }
    );

    $prov->audit( "initializing request to create virtual os '$p{name}'");

    $self->{name} = $self->set_name( $p{name} );
    $self->{ip}   = $self->get_ips( $p{ip} ) or return;

    foreach ( @opt_scalars, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    if ( $p{nameservers} ) {
        $prov->audit( "getting nameserver IP list");
        $self->{nameservers} = $self->get_ips( $p{nameservers} );
    };

    my ($delegate) = $self->{vtype} =~ m/^(.*)=HASH/;
    $prov->audit("\tdelegating create request to $delegate");
    $self->{vtype}->create_virtualos();
}

sub destroy_virtualos {

    # Usage      : $virtual->destroy_virtualos( name => 'mysql' );
    # Purpose    : destroy a virtual OS instance
    # Returns    : true or undef on failure
    # Parameters :
    #   Required : name  - name/ID of the virtual OS

    my $self = shift;
    my %p = validate(
        @_,
        {   'name'      => { type => SCALAR },
            'disk_root' => { type => SCALAR,  optional => 1 },
            %std_opts
        }
    );

    my $name = $self->set_name( $p{name} );
    $prov->audit("initializing request to destroy virtual os '$name'");

    foreach ( @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{vtype}->destroy_virtualos();
}

sub start_virtualos {

    # Usage      : $virtual->start_virtualos( name => 'mysql' );
    # Purpose    : start a virtual OS instance
    # Returns    : true or undef on failure
    # Parameters :
    #   Required : name      - name/ID of the virtual OS
    #   Optional : test_mode -

    my $self = shift;
    my %p = validate(
        @_,
        {  'name' => { type => SCALAR },
            %std_opts
        }
    );

    foreach ( 'name', @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{vtype}->start_virtualos();
}

sub stop_virtualos {

    # Usage      : $virtual->stop_virtualos( name => 'mysql' );
    # Purpose    : stop a virtual OS instance
    # Returns    : true or undef on failure
    # Parameters :
    #   Required : name      - name/ID of the virtual OS
    #   Optional : test_mode -

    my $self = shift;

    my %p = validate(
        @_,
        {   'name' => { type => SCALAR },
            %std_opts,
        }
    );

    foreach ( 'name', @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{vtype}->stop_virtualos();
}

sub restart_virtualos {

    # Usage      : $virtual->restart_virtualos( name => 'mysql' );
    # Purpose    : restart a virtual OS instance
    # Returns    : true or undef on failure
    # Parameters :
    #   Required : name      - name/ID of the virtual OS

    my $self = shift;

    my %p = validate(
        @_,
        {   'name'      => { type => SCALAR },
            %std_opts
        }
    );

    foreach ( 'name', @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{vtype}->restart_virtualos();
}

sub disable_virtualos {

    # Usage      : $virtual->disable_virtualos( name => 'mysql' );
    # Purpose    : disable a virtual OS instance
    # Returns    : true or undef on failure
    # Parameters :
    #   Required : name      - name/ID of the virtual OS
    #   Optional : test_mode -

    my $self = shift;

    my %p = validate(
        @_,
        {   name      => { type => SCALAR },
            disk_root => { type => SCALAR,  optional => 1 },
            %std_opts
        }
    );

    foreach ( qw/ name disk_root /, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{vtype}->disable_virtualos();
}

sub enable_virtualos {

    # Usage      : $virtual->enable_virtualos( name => 'mysql' );
    # Purpose    : enable/reactivate/unsuspend a virtual OS instance
    # Returns    : true or undef on failure
    # Parameters :
    #   Required : name      - name/ID of the virtual OS
    #   Optional : test_mode -

    my $self = shift;

    my %p = validate(
        @_,
        {   name      => { type => SCALAR },
            disk_root => { type => SCALAR,  optional => 1 },
            %std_opts
        }
    );

    foreach ( qw/ name disk_root /, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{vtype}->enable_virtualos();
}

sub modify_virtualos {

    # Usage      : $virtual->modify_virtualos( name => 'mysql' );
    # Purpose    : modify a container
    # Returns    : true or undef on failure
    # Parameters :
    #   Required : name      - name/ID of the virtual OS

    my $self = shift;
    my @opt_scalars = qw/ ip hostname disk_root disk_size config 
                    ssh_key template password nameservers searchdomain /;
    my %opt_scalars = map { $_ => { type => SCALAR, optional => 1 } } @opt_scalars;

    my %p = validate(
        @_,
        {   name   => { type => SCALAR },
            %opt_scalars,
            %std_opts,
        }
    );

    $prov->audit("initializing request to modify container '$p{name}'");

    foreach ( 'name', @opt_scalars, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{ip} = $self->get_ips( $p{ip} );

    $prov->audit("\tdelegating request to $self->{vtype}");

    $self->{vtype}->modify_virtualos();
}

sub reinstall_virtualos {

# Usage      : $virtual->reinstall_virtualos( name => 'mysql', ip=>'127.0.0.2' );
# Purpose    : reinstall the OS in virtual machine
# Returns    : true or undef on failure
# Parameters :
#   Required : name      - name/ID of the virtual OS
#            : template  - a 'template' or tarball the OS is patterned after
#            : ip        - IP address(es), space delimited
#   Optional : hostname  - the FQDN of the virtual OS
#            : disk_root - the root directory of the virt os
#            : disk_size - disk space allotment
#            : ram
#            : config    - a config file with virtual specific settings
#            : password  - the root/admin password for the virtual
#            : nameservers -
#            : searchdomain -

    my $self = shift;
    my @opt_scalars = qw/ hostname disk_root disk_size ram config 
                    template password nameservers searchdomain ssh_key
                    kernel_version mac_address /;
    my %opt_scalars = map { $_ => { type => SCALAR, optional => 1 } } @opt_scalars;

    my %p = validate(
        @_,
        {   name    => { type => SCALAR },
            ip      => { type => SCALAR },
            %opt_scalars,
            %std_opts,
        }
    );

    $prov->audit( "initializing request to reinstall ve '$p{name}'");

    foreach ( 'name', @opt_scalars, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{name}        = $self->set_name( $p{name} );
    $self->{ip}          = $self->get_ips( $p{ip} ) or return;
    $self->{nameservers} = $self->get_ips( $p{nameservers} ) if $p{nameservers};

    $prov->audit("\tdelegating request to $self->{vtype}");
    $self->{vtype}->reinstall_virtualos();
}

sub upgrade_virtualos {
    my $self = shift;
    my @req_scalars = qw/ name hostname disk_size ram config template ip /;
    my %req_scalars = map { $_ => { type => SCALAR } } @req_scalars;

    my %p = validate(
        @_,
        {   %req_scalars,
            disk_root    => { type => SCALAR|UNDEF, optional => 1 },
            %std_opts,
        }
    );

    $prov->audit( "initializing request to upgrade ve '$p{name}'");

    foreach ( qw/ disk_root /, @req_scalars, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{ip} = $self->get_ips( $p{ip} ) or return;

    $self->{vtype}->upgrade_virtualos();
};

sub mount_disk_image {
    my $self = shift;
    my %p = validate(
        @_,
        {   name      => { type => SCALAR },
            refresh   => { type => BOOLEAN, optional => 1, default => 1 },
            %std_opts,
        }
    );

    $prov->audit( "initializing request to mount ve '$p{name}'");

    foreach ( qw/ name refresh /, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{vtype}->mount_disk_image();
};

sub unmount_disk_image {
    my $self = shift;
    my %p = validate(
        @_,
        {   name      => { type => SCALAR },
            refresh   => { type => BOOLEAN, optional => 1, default => 1 },
            %std_opts,
        }
    );

    $prov->audit( "initializing request to unmount ve '$p{name}'");

    foreach ( qw/ name refresh /, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{vtype}->unmount_disk_image();
};

sub gen_config {
    my $self = shift;
    my %p = validate(
        @_,
        {   name      => { type => SCALAR },
            ram       => { type => SCALAR },
            disk_root => { type => SCALAR },
            disk_size => { type => SCALAR },
            template  => { type => SCALAR },
            config    => { type => SCALAR },
            hostname  => { type => SCALAR },
            ip        => { type => SCALAR },
            %std_opts,
        }
    );

    foreach ( qw/ name ram disk_size disk_root template config hostname /, 
        @std_opts ) 
    {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{ip} = $self->get_ips( $p{ip} );

    $self->{vtype}->gen_config();
};

sub get_console {
    my $self = shift;
    my %p = validate( 
        @_, 
        {   name  => { type => SCALAR | UNDEF,  optional => 1 },
            %std_opts,
        }
    );

    foreach ( qw/ name /, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{vtype}->get_console();
}

sub get_fs_root {
    my $self = shift;
    my $name = shift || $self->{name};
    my $fs_root;
    if ( $self->{vtype}->can('get_fs_root') ) {
        return $self->{vtype}->get_fs_root( $name );
    }
    return $self->{vtype}->get_ve_home( $name );
};

sub get_ve_home {
    my $self = shift;
    my $name = shift || $self->{name};
    my $fs_root;
    if ( $self->{vtype}->can('get_ve_home') ) {
        return $self->{vtype}->get_ve_home( $name );
    }
    return;
};

sub get_ips {
    my $self      = shift;
    my $ip_string = shift;

    $prov->audit("\textracting IPs from string: $ip_string");

    my @r;
    my @ips = split / /, $ip_string;
    foreach my $ip (@ips) {
        my $ip = $self->is_valid_ip($ip);
        push @r, $ip if $ip;
    }

    my $ips = @r;
    if ( $ips == 0 ) {
        return $prov->error( "no valid IPs in request!",
            debug   => $self->{debug},
            fatal   => $self->{fatal},
        );
    }
    my $ip_plural = $ips > 1 ? 'ips' : 'ip';
    $prov->audit("\tfound $ips valid $ip_plural");
    return \@r;
}

sub get_status {
    my $self = shift;
    my %p = validate(
        @_,
        {   name      => { type => SCALAR | UNDEF,  optional => 1 },
            %std_opts,
        }
    );

    foreach ( qw/ name /, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{vtype}->get_status();
}

sub get_template_dir {

    my $self = shift;
    my %p = validate(
        @_,
        {   v_type => { type => SCALAR  },
            %std_opts,
        }
    );

    my $v_type = $p{v_type};

    my $dir = $prov->{config}{VirtualOS}{"${v_type}_template_dir"};
    return $dir if $dir;  # they defined it in provision.conf, use it

    # try to autodetect
    $dir = -d "/templates"         ? '/templates'
         : -d "/vz/template/cache" ? '/vz/template/cache'
         : -d "/vz/template"       ? '/vz/template'
         : undef;

    $dir and return $dir;

    return $prov->error( 'unable to determine template directory',
            fatal  => $p{fatal},
            debug  => $p{debug},
        );
};

sub get_template_list {
    my $self = shift;
    my %p = validate(
        @_,
        {   v_type    => { type => SCALAR },
            url       => { type => SCALAR, optional => 1 },
            %std_opts,
        }
    );

    my $url    = $p{url};
    my $v_type = $p{v_type};
    my @templates;

    if ( ! $url ) {
        my $template_dir = $self->get_template_dir( v_type=> $v_type ) 
            or return $prov->error( 'unable to determine template directory',
                fatal  => $p{fatal},
                debug  => $p{debug},
            );

        my @template_names = <$template_dir/*.tar.gz>;
        foreach my $template ( @template_names ) {
            ($template) = $template =~ /\/([\w\.\-]+)\.tar\.gz$/;
            push @templates, { name => $template };
        };

        return \@templates if scalar @templates;
        return;
    };

    my $ua = LWP::UserAgent->new( timeout => 10);
    my $response = $ua->get($url);

    die $response->status_line if ! $response->is_success;

    my $content = $response->content;
#warn Dumper($content);

#  >centos-5-i386-plesk-8.6.tar.gz<
    my @fields = grep { /\-.*?\-/ } split /<.*?>/, $content;
    while ( scalar @fields ) {
        my $file = shift @fields or last;
        next if $file !~ /tar.gz/;
        my $date = shift @fields;
        my $timestamp = $self->get_template_timestamp($date);
        push @templates, { name => $file, date => $date, timestamp => $timestamp }; 
    };

    return \@templates;
};

sub get_template_timestamp {
    my ( $self, $time ) = @_;
    
    my %months = (
        'jan' => 1, 'feb' =>  2, 'mar' =>  3, 'apr' =>  4, 
        'may' => 5, 'jun' =>  6, 'jul' =>  7, 'aug' =>  8,
        'sep' => 9, 'oct' => 10, 'nov' => 11, 'dec' => 12,
    );

    my ( $Y, $M, $D, $h, $m, $s )
        = ( $time =~ /^(\d{4})-(\w{3})-(\d{2})\s+(\d{2})?:?(\d{2})?:?(\d{2})?/ )
        or die "invalid timestamp format: $time\n";

    my $txt_m = lc($M);
    $M = $months{$txt_m};  # convert to an integer
    $M -= 1;
    $Y -= 1900;
    return timelocal( $s, $m, $h, $D, $M, $Y );
};

sub get_version {
    return $prov->get_version();
};

sub set_hostname {
    my $self = shift;
    my %p = validate(
        @_,
        {   'name'     => { type => SCALAR },
            'hostname' => { type => SCALAR },
            %std_opts,
        }
    );

    foreach ( qw/ name hostname /, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{vtype}->set_hostname();
}

sub set_name {
    my $self = shift;
    my $name = shift || $self->{name} || die "unable to set VE name\n";
    $self->{name} = $name;
    return $name; 
};

sub set_nameservers {
    my $self = shift;
    my %p = validate(
        @_,
        {   name         => { type => SCALAR, optional => 1 },
            nameservers  => { type => SCALAR, optional => 1 },
            searchdomain => { type => SCALAR, optional => 1 },
            %std_opts,
        }
    );

    my $name              = $self->set_name( $p{name} ) if $p{name};
    $self->{nameservers}  = $self->get_ips( $p{nameservers} ) if $p{nameservers};
    $self->{nameservers}  or die 'missing nameservers';
    $self->{searchdomain} = $p{searchdomain};
    $self->{test_mode}    = $p{test_mode};
    my $debug = $self->{debug} = $p{debug};
    my $fatal = $self->{fatal} = $p{fatal};

    # if the virtualzation package has the method, call it. 
    if ( $self->{vtype}->can( 'set_nameservers' ) ) {
        return $self->{vtype}->set_nameservers();
    };

    # otherwise, use this default method
    my $fs_root = $self->get_fs_root();
    my $nameservers = $self->{nameservers};
    my $resolv = "$fs_root/etc/resolv.conf";

    my @new;
    my @lines = $util->file_read( file => $resolv, fatal => $fatal );
    foreach my $line ( @lines ) {
        next if $line =~ /^nameserver\s/i;
        push @new, $line;
    };

    foreach ( @$nameservers ) {
        push @new, "nameserver $_";
    };

    return $util->file_write( 
        file => $resolv, lines => \@new, fatal => $fatal,
    );
}

sub set_password {
    my $self = shift;

    my %p = validate(
        @_,
        {   name      => { type => SCALAR },
            password  => { type => SCALAR },
            user      => { type => SCALAR | UNDEF, optional => 1 },
            disk_root => { type => SCALAR,  optional => 1 },
            ssh_key   => { type => SCALAR,  optional => 1 },
            %std_opts,
        }
    );

    $self->{user} = $p{user} || 'root';

    foreach ( qw/ name password ssh_key disk_root /, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    return $self->{vtype}->set_password();
}

sub setup_log_files {
    my $self = shift;

    my %p = validate( @_, { fs_root => { type => SCALAR }  } );

    my $fs_root = $p{fs_root};

    my @logfiles = `find $fs_root/var/log/ -maxdepth 1 -type f -print`;
    foreach ( @logfiles ) {
        chomp $_;
        $util->file_write( file => $_, lines => [ '' ], fatal => 0, debug => 0 );
    };
};

sub setup_ssh_host_keys {
    my $self = shift;

    my %p = validate( @_, { fs_root => { type => SCALAR }  } );

    my $fs_root = $p{fs_root};

    foreach my $type ( qw/ dsa rsa / ) {
        my $file_path = "$fs_root/etc/ssh/ssh_host_${type}_key";

        unlink "$file_path"     if -e "$file_path";
        unlink "$file_path.pub" if -e "$file_path.pub";

        my $cmd = "/usr/bin/ssh-keygen -q -t $type -f $file_path -N ''";
        $util->syscmd( cmd => $cmd, debug => 0 );
    };
};

sub is_mounted {
    my $self = shift;

    my %p = validate(
        @_,
        {   name      => { type => SCALAR },
            refresh   => { type => BOOLEAN, optional => 1, default => 1 },
            %std_opts,
        }
    );

    foreach ( qw/ name refresh /, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{vtype}->is_mounted();
}

sub is_present {
    my $self = shift;
    my %p = validate(
        @_,
        {   name      => { type => SCALAR },
            %std_opts,
        }
    );

    foreach ( qw/ name /, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{vtype}->is_present();
}

sub is_running {
    my $self = shift;
    my %p = validate(
        @_,
        {   name      => { type => SCALAR },
            %std_opts
        }
    );

    foreach ( qw/ name /, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{vtype}->is_running();
}

sub is_valid_ip {
    my $self  = shift;
    my $ip    = shift;
    my $error = "'$ip' is not a valid IPv4 address";

    my $r = grep /\./, split( //, $ip );    # need 3 dots
    return $prov->error( $error, fatal => 0, debug => 0 )
        if $r != 3;

    my @octets = split /\./, $ip;
    return $prov->error( $error, fatal => 0, debug => 0 )
        if @octets != 4;

    foreach (@octets) {
        return unless /^\d{1,3}$/ and $_ >= 0 and $_ <= 255;
        $_ = 0 + $_;
    }

    return $prov->error( $error, fatal => 0, debug => 0 )
        if $octets[0] == 0;    # 0. is invalid

    return $prov->error( $error, fatal => 0, debug => 0 )
        if 0 + $octets[0] + $octets[1] + $octets[2] + $octets[3]
            == 0;              # 0.0.0.0 is invalid

    return $prov->error( $error, fatal => 0, debug => 0 )
        if grep( $_ eq '255', @octets ) == 4;    # 255.255.255.255 is invalid

    return join( '.', @octets );
}

sub _get_virt_type {
    my $self = shift;
    my %p = validate( @_, { %std_opts });

    my $debug = $p{debug};
    my $fatal = $p{fatal};
    my $prov = $self->{prov};

    if ( lc($OSNAME) eq 'linux' ) {
        my $xm = $util->find_bin( bin=> 'xm', fatal => 0, debug => 0);
        my $vzctl = $util->find_bin( bin=> 'vzctl', fatal => 0, debug => 0);

        if ( $xm && ! $vzctl ) {
            require Provision::Unix::VirtualOS::Linux::Xen;
            return Provision::Unix::VirtualOS::Linux::Xen->new( vos => $self );
        }
        elsif ( $vzctl && ! $xm ) {
            # this could be Virtuozzo or OpenVZ. The way to tell is by
            # checking for the presence of /vz/template/cache (OpenVZ only) 
            # also, a Virtuozzo container will have a cow directory inside the
            # container home directory.
            if ( -d "/vz/template" ) {
                if ( -d "/vz/template/cache" ) {
                    require Provision::Unix::VirtualOS::Linux::OpenVZ;
                    return Provision::Unix::VirtualOS::Linux::OpenVZ->new( vos => $self );
                }
                else {
                    require Provision::Unix::VirtualOS::Linux::Virtuozzo;
                    return Provision::Unix::VirtualOS::Linux::Virtuozzo->new( vos => $self );
                }
            }
            else {
# has someone moved the template cache directory from the default location?
                require Provision::Unix::VirtualOS::Linux::OpenVZ;
                return Provision::Unix::VirtualOS::Linux::OpenVZ->new( vos => $self );
            };
        }
        else {
            $prov->error( 
                "Unable to determine your virtualization method. You need one supported hypervisor (xen, openvz) installed.",
                fatal => $fatal,
                debug => $debug,
            );
        };
    }
    elsif ( lc( $OSNAME) eq 'freebsd' ) {
        my $ezjail = $util->find_bin( bin => 'ezjail-admin', fatal => 0, debug => 0 );
        if ( $ezjail ) {
            require Provision::Unix::VirtualOS::FreeBSD::Ezjail;
            return Provision::Unix::VirtualOS::FreeBSD::Ezjail->new( vos => $self );
        };

        require Provision::Unix::VirtualOS::FreeBSD::Jail;
        return Provision::Unix::VirtualOS::FreeBSD::Jail->new( vos => $self );
    }
    else {
        print "fatal: $fatal\n";
        $prov->error( 
            "No virtualization methods for $OSNAME are supported yet",
            fatal   => $fatal,
            debug   => $debug,
        );
    };
}


1;

__END__

=head1 NAME

Provision::Unix::VirtualOS - Provision virtual OS instances (jail|vps|container)

=head1 SYNOPSIS


    use Provision::Unix::VirtualOS;

    my $foo = Provision::Unix::VirtualOS->new();
    ...


=head1 FUNCTIONS


=head1 AUTHOR

Matt Simerson, C<< <matt at tnpi.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-unix-provision-virtualos at rt.cpan.org>, or through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Provision-Unix>.  I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.  



=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Provision::Unix::VirtualOS


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Provision-Unix-VirtualOS>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Provision-Unix-VirtualOS>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Provision-Unix-VirtualOS>

=item * Search CPAN

L<http://search.cpan.org/dist/Provision-Unix-VirtualOS>

=back


=head1 ACKNOWLEDGEMENTS


=head1 COPYRIGHT & LICENSE

Copyright 2008 Matt Simerson

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

