package Provision::Unix::VirtualOS;

use warnings;
use strict;

our $VERSION = '0.46';

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

    $prov = $p{prov};
    my $debug = $p{debug};
    my $fatal = $p{fatal};
    $util = Provision::Unix::Utility->new( prov=> $prov )
        or die "unable to load P:U:Utility\n";

    my $self = {
        prov    => $p{prov},
        debug   => $debug,
        fatal   => $fatal,
        etc_dir => $p{etc_dir},
        util    => $util,
    };
    bless( $self, $class );

    $prov->audit( $class . sprintf( " loaded by %s, %s, %s", caller ) );

    $self->{vtype} = $self->_get_virt_type( fatal => $fatal, debug => $debug )
        or die $prov->{errors}[-1]{errmsg};

    return $self;
}

sub create {

# Usage      : $virtual->create( name => 'mysql', ip=>'127.0.0.2' );
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
    my @opt_scalars = qw/ config cpu disk_root disk_size hostname 
            kernel_version mac_address nameservers password ram 
            searchdomain ssh_key template /;
    my %opt_scalars = map { $_ => { type => SCALAR, optional => 1 } } @opt_scalars;
    my @opt_bools = qw/ skip_start /;
    my %opt_bools = map { $_ => { type => BOOLEAN, optional => 1 } } @opt_bools;

    my %p = validate(
        @_,
        {   name   => { type => SCALAR },
            ip     => { type => SCALAR },
            %opt_scalars,
            %opt_bools,
            %std_opts,
        }
    );

    $prov->audit( "initializing request to create virtual os '$p{name}'");

    $self->{name} = $self->set_name( $p{name} );
    $self->{ip}   = $self->get_ips( $p{ip} ) or return;

    foreach ( @opt_scalars, @opt_bools, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    if ( $p{nameservers} ) {
        $prov->audit( "getting nameserver IP list");
        $self->{nameservers} = $self->get_ips( $p{nameservers} );
    };

    my ($delegate) = $self->{vtype} =~ m/^(.*)=HASH/;
    $prov->audit("\tdelegating create request to $delegate");
    $self->{vtype}->create();
}

sub destroy {

    # Usage      : $virtual->destroy( name => 'mysql' );
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

    $self->{vtype}->destroy();
}

sub start {

    # Usage      : $virtual->start( name => 'mysql' );
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

    $self->{vtype}->start();
}

sub stop {

    # Usage      : $virtual->stop( name => 'mysql' );
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

    $self->{vtype}->stop();
}

sub restart {

    # Usage      : $virtual->restart( name => 'mysql' );
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

    $self->{vtype}->restart();
}

sub disable {

    # Usage      : $virtual->disable( name => 'mysql' );
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

    $self->{vtype}->disable();
}

sub enable {

    # Usage      : $virtual->enable( name => 'mysql' );
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

    $self->{vtype}->enable();
}

sub migrate {
    my $self = shift;
    my @req_scalars = qw/ name new_node /;
    my %req_scalars = map { $_ => { type => SCALAR } } @req_scalars;
    my @opt_scalars = qw/ /;
    my %opt_scalars = map { $_ => { type => SCALAR, optional => 1 } } @opt_scalars;
    my @opt_bools = qw/ connection_test /;
    my %opt_bools = map { $_ => { type => BOOLEAN, optional => 1 } } @opt_bools;

    my %p = validate( @_, { %req_scalars, %opt_scalars, %opt_bools, %std_opts, } );

    my $name = $p{name};
    my $new_node = $p{new_node};

    $prov->audit("initializing request to migrate VE '$name' to $new_node");

    foreach ( @req_scalars, @opt_scalars, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };
    foreach ( @opt_bools ) {
        $self->{$_} = defined $p{$_} ? $p{$_} : 0;
    };

    $prov->audit("\tdelegating request to $self->{vtype}");

    $self->{vtype}->migrate();
};

sub modify {

    # Usage      : $virtual->modify( name => 'mysql' );
    # Purpose    : modify a VE
    # Returns    : true or undef on failure
    # Parameters :
    #   Required : name      - name/ID of the virtual OS

    my $self = shift;
    my @req_scalars = qw/ name disk_size hostname ip ram /;
    my %req_scalars = map { $_ => { type => SCALAR } } @req_scalars;
    my @opt_scalars = qw/ config cpu disk_root nameservers 
                          password searchdomain ssh_key template /;
    my %opt_scalars = map { $_ => { type => SCALAR, optional => 1 } } @opt_scalars;

    my %p = validate( @_, {   %req_scalars, %opt_scalars, %std_opts, } );

    $prov->audit("initializing request to modify VE '$p{name}'");

    foreach ( @req_scalars, @opt_scalars, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $self->{ip} = $self->get_ips( $p{ip} ) if $p{ip};

    $prov->audit("\tdelegating request to $self->{vtype}");

    $self->{vtype}->modify();
}

sub reinstall {

# Usage      : $virtual->reinstall( name => 'mysql', ip=>'127.0.0.2' );
# Purpose    : reinstall the OS in virtual machine
# Returns    : true or undef on failure
# Parameters :
#   Required : name      - name/ID of the virtual OS
#            : template  - a 'template' or tarball the OS is patterned after
#            : ip        - IP address(es), space delimited
#   Optional : hostname  - the FQDN of the virtual OS
#            : disk_root - the root directory of the virt os
#            : disk_size - disk space allotment (MB)
#            : ram       - (MB)
#            : config    - a config file with virtual specific settings
#            : password  - the root/admin password for the virtual
#            : nameservers -
#            : searchdomain -

    my $self = shift;
    my @opt_scalars = qw/ config cpu disk_root disk_size hostname 
                    kernel_version mac_address nameservers password ram 
                    searchdomain ssh_key template /;
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
    $self->{vtype}->reinstall();
}

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

sub do_connectivity_test {
    my $self = shift;

    return 1 if ! $self->{connection_test};

    my $new_node = $self->{new_node};
    my $debug = $self->{debug};
    my $ssh = $util->find_bin( 'ssh', debug => $debug );
    my $r = $util->syscmd( "$ssh $new_node /bin/uname -a", debug => $debug, fatal => 0)
        or return $prov->error("could not validate connectivity to $new_node", fatal => 0);
    $prov->audit("connectivity to $new_node is good");
    return 1;
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

sub set_ssh_key {
    my $self = shift;
    my %p = validate(
        @_,
        {   name      => { type => SCALAR },
            user      => { type => SCALAR | UNDEF, optional => 1 },
            disk_root => { type => SCALAR,  optional => 1 },
            ssh_key   => { type => SCALAR,  optional => 1 },
            %std_opts,
        }
    );

    $self->{user} = $p{user} || 'root';

    foreach ( qw/ name ssh_key disk_root /, @std_opts ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    return $self->{vtype}->set_ssh_key();
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
        $util->syscmd( $cmd, debug => 0 );
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

    return $self->_get_virt_type_linux( %p ) if lc($OSNAME) eq 'linux';

    if ( lc( $OSNAME) eq 'freebsd' ) {
        my $ezjail = $util->find_bin( 'ezjail-admin', fatal => 0, debug => 0 );
        if ( $ezjail ) {
            require Provision::Unix::VirtualOS::FreeBSD::Ezjail;
            return Provision::Unix::VirtualOS::FreeBSD::Ezjail->new( vos => $self );
        };

        require Provision::Unix::VirtualOS::FreeBSD::Jail;
        return Provision::Unix::VirtualOS::FreeBSD::Jail->new( vos => $self );
    };
    $prov->error( 
        "No virtualization methods for $OSNAME yet",
        fatal   => $fatal,
        debug   => $debug,
    );
    return;
}

sub _get_virt_type_linux {
    my $self = shift;
    my %p = validate( @_, { %std_opts });

    my $err_before = scalar @{ $prov->{errors} };
    my $xm = $util->find_bin( 'xm', fatal => 0, debug => 0);
    my $vzctl = $util->find_bin( 'vzctl', fatal => 0, debug => 0);
    if ( scalar @{$prov->{errors}} > $err_before ) {
        delete $prov->{errors}[-1];  # clear the last error
        delete $prov->{errors}[-1] if scalar @{$prov->{errors}} > $err_before;
    };

    require Provision::Unix::VirtualOS::Linux;
    $self->{linux} = Provision::Unix::VirtualOS::Linux->new( vos => $self );

    if ( $xm && ! $vzctl ) {
        require Provision::Unix::VirtualOS::Linux::Xen;
        return Provision::Unix::VirtualOS::Linux::Xen->new( vos => $self );
    };
    if ( $vzctl && ! $xm ) {
        # this could be Virtuozzo or OpenVZ. The way to tell is by
        # checking for the presence of /vz/template/cache (OpenVZ only) 
        # also, a Virtuozzo VE will have a cow directory inside the
        # VE home directory.
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
    };

    $prov->error( 
        "Unable to determine your virtualization method. You need one supported hypervisor (xen, openvz) installed.",
        fatal => $p{fatal},
        debug => $p{debug},
    );
};

1;

__END__

=head1 NAME

Provision::Unix::VirtualOS - Provision virtual environments (VEs)

=head1 SYNOPSIS

    use Provision::Unix;
    use Provision::Unix::VirtualOS;

    my $prov = Provision::Unix->new();
    my $vos = Provision::Unix::VirtualOS->new( prov => $prov );

    $vos->create(
         name        => 42,
         password    => 't0ps3kretWerD',
         ip          => '10.1.1.43',
         hostname    => 'test_debian_5.example.com',
         disk_size   => 1000,
         ram         => 512,
         template    => 'debian-5-i386-default.tar.gz',
         nameservers => '10.1.1.2 10.1.1.3',
         searchdomain => 'example.com',
    )
    or $prov->error( "unable to create VE" );


=head1 DESCRIPTION

Provision::Unix::VirtualOS aims to provide a clean, consistent way to manage virtual machines on a variety of virtualization platforms including Xen, OpenVZ, Vmware, FreeBSD jails, and others. P:U:V provides a command line interface (prov_virtual) and a stable programming interface (API) for provisioning virtual machines on supported platforms. To start a VE on any supported virtualization platform, you run this command:

  prov_virtual --name=42 --action=start

Versus this:

  xen: xm create /home/xen/42/42.cfg
  ovz: vzctl start 42
  ezj: ezjail-admin start 42

P:U:V tries very hard to insure that every valid command that can succeed will. There is abundant code for handling common errors, such as unmounting xen volumes before starting a VE, making sure a disk volume is not in use before mounting it, and making sure connectivity to the new HW node exists before attempting to migrate.

In addition to the pre-flight checks, there are also post-action checks to determine if the action succeeded. When actions fail, they provide reasonably good error messages geared towards comprehension by sysadmins. Where feasible, actions that fail are rolled back so that when the problem(s) is corrected, the action can be safely retried.


=head1 USAGE

If you are looking for a command line utility, have a look at the docs for prov_virtual. If you are looking to mate an existing Customer Relationship Manager (CRM) or billing system (like Ubersmith, WHMCS, Modernbill, etc..) with a rack full of hardware nodes, this class is it. There are two existing implementations, the prov_virtual CLI, and an RPC agent. The CLI and remote portion of the RPC agent is included in the distribution as bin/remoteagent. 

=head2 CLI

The best way to interface with P:U:V is using a RPC agent to drive this class directly. However, doing so requires a programmer to write an application that accepts/processes requests from your CRMS system and formats them into P:U:V requests. 

If you don't have the resources to write your own RPC agent, and your CRM/billing software supports it, you may be able to dispatch the requests to the HW nodes via a terminal connection. If you do this, your CRM software will need to inspect the result code of the script to determine success or failure. 

P:U calls are quiet by default. If you want to see all the logging, append each CLI request with --verbose. Doing so will dump the audit and error reports to stdout. 

=head2 API

The implementation I use implements RPC over SSH. The billing system we use is rather 'limited' so I wrote a separate request brokering application (maitred). It uses the billing systems API as a trigger to perform basic account management actions (create, destroy, enable, disable). We also provide a control panel so our clients can manage their VEs. The control panel also generates requests (start, stop, install, reinstall, reboot, upgrade, etc). Administrators also have their own control panel which also generates requests.

When a request is initiated, the broker allocates any necessary resources (IPs, licences, a slot on a HW node, etc) and then dispatches the request. The dispatcher builds an appropriate SSH invocation that connects to the remote HW node and runs the remoteagent. Once connected to the remoteagent, the P:U:V class is loaded and its  methods are invoked directly. The RPC agent checks the result code of each call, as well as the audit and error logs, feeding those request events back. The RPC local agent logs the request events into the request brokers database so there's a complete audit trail.

=head2 RPC methods

RPC is often implemented over HTTP, using SOAP or XML::RPC. However, our VEs are deployed with local storage. We needed the ability to move a VE from one node to another. In addition to the broker to node relationship, we would have also need temporary trust relationships between the nodes, in order to move files between them with root permissions. 

The trust relationships are much easier to manage with SSH keys. In our environment, only the request brokers are trusted. In addition to being able to connect to any node, they can also connect from node to node using using ssh-agent and key forwarding. 

=head2 RPC gotcha

The $vos->migrate() function expects to be running as a user that has the ability to initiate a SSH connection from the node on which it's running, to the node on which you are moving the VE. Our RPC agent connects to the HW nodes as the maitred user and then invokes the remoteagent using sudo. Our sudo config on the HW nodes looks like this: 

    Cmnd_Alias MAITRED_CMND=/usr/bin/remoteagent, /usr/bin/prov_virtual
    maitred     ALL=NOPASSWD: SETENV: MAITRED_CMND

Since the RPC remoteagent is running as root, the request broker has access to a wide variety of tools (tar over ssh pipe, rsync, etc) to move files from one node to another, without the nodes having any sort of trust relationship between them. 

=head1 FUNCTIONS

    $vos->start(   name => 42 );
    $vos->stop(    name => 42 );
    $vos->restart( name => 42 );

    $vos->enable(  name => 42 );
    $vos->disable( name => 42 );

    $vos->set_hostname(    name => 42, hostname => 'new-host.example.com' );
    $vos->set_nameservers( name => 42, nameservers => '10.1.1.3 10.1.1.4' );
    $vos->set_password(    name => 42, password    => 't0ps3kretWerD' );
    $vos->set_ssh_key(     name => 42, ssh_key     => 'ssh-rsa AAAAB3N..' );

    $vos->modify(
        name      => 42,
        disk_size => 2000,
        hostname  => 'new-host.example.com',
        ip        => '10.1.1.43 10.1.1.44',
        ram       => 768,
    );

    $vos->get_status( name => 42 );
    $vos->migrate( name => 42, new_node => '10.1.1.13' );
    $vos->destroy( name => 42 );


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


=head1 COPYRIGHT & LICENSE

Copyright 2008 Matt Simerson

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

