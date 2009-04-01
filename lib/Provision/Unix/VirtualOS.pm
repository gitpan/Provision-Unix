package Provision::Unix::VirtualOS;

use warnings;
use strict;

our $VERSION = '0.25';

use English qw( -no_match_vars );
use Params::Validate qw(:all);

use lib 'lib';
use Provision::Unix::Utility;

my ($prov, $util);

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

    $util = Provision::Unix::Utility->new( prov=> $p{prov} )
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
#            : disk_size - disk space allotment
#            : ram
#            : config    - a config file with virtual specific settings
#            : template  - a 'template' or tarball the OS is patterned after
#            : password  - the root/admin password for the virtual
#            : nameservers -
#            : searchdomain -

    my $self = shift;

    my %p = validate(
        @_,
        {   'name'         => { type => SCALAR },
            'ip'           => { type => SCALAR },
            'hostname'     => { type => SCALAR, optional => 1 },
            'disk_root'    => { type => SCALAR, optional => 1 },
            'disk_size'    => { type => SCALAR, optional => 1 },
            'ram'          => { type => SCALAR, optional => 1 },
            'config'       => { type => SCALAR, optional => 1 },
            'template'     => { type => SCALAR, optional => 1 },
            'password'     => { type => SCALAR, optional => 1 },
            'ssh_key'      => { type => SCALAR, optional => 1 },
            'nameservers'  => { type => SCALAR, optional => 1 },
            'searchdomain' => { type => SCALAR, optional => 1 },
            'test_mode'    => { type => BOOLEAN, optional => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $prov->audit( "initializing request to create virtual os '$p{name}'");

    $self->{name}        = $p{name};
    $self->{ip}          = $self->get_ips( $p{ip} ) or return;
    $self->{nameservers} = $self->get_ips( $p{nameservers} )
        if $p{nameservers};

    foreach ( qw/ hostname disk_root disk_size ram config
                  template password ssh_key searchdomain
                  fatal debug test_mode / ) {
        $self->{$_} = $p{$_} if defined $p{$_};
    };

    $prov->audit("\tdelegating request to $self->{vtype}");
    $self->{vtype}->create_virtualos();
}

sub destroy_virtualos {

    # Usage      : $virtual->destroy_virtualos( name => 'mysql' );
    # Purpose    : destroy a virtual OS instance
    # Returns    : true or undef on failure
    # Parameters :
    #   Required : name      - name/ID of the virtual OS
    #   Optional : test_mode -

    my $self = shift;

    my %p = validate(
        @_,
        {   'name'      => { type => SCALAR },
            'test_mode' => { type => BOOLEAN, optional => 1 },
            'debug'     => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal'     => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $prov->audit("initializing request to destroy virtual os '$p{name}'");

    foreach ( qw/ name test_mode debug fatal / ) {
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
        {   'name'      => { type => SCALAR },
            'test_mode' => { type => BOOLEAN, optional => 1 },
            'debug'     => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal'     => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    foreach ( qw/ name test_mode debug fatal / ) {
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
        {   'name'      => { type => SCALAR },
            'test_mode' => { type => BOOLEAN, optional => 1 },
            'debug'     => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal'     => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $self->{name}      = $p{name};
    $self->{test_mode} = $p{test_mode};
    $self->{debug}     = $p{debug};
    $self->{fatal}     = $p{fatal};

    $self->{vtype}->stop_virtualos();
}

sub restart_virtualos {

    # Usage      : $virtual->restart_virtualos( name => 'mysql' );
    # Purpose    : restart a virtual OS instance
    # Returns    : true or undef on failure
    # Parameters :
    #   Required : name      - name/ID of the virtual OS
    #   Optional : test_mode -

    my $self = shift;

    my %p = validate(
        @_,
        {   'name'      => { type => SCALAR },
            'test_mode' => { type => BOOLEAN, optional => 1 },
            'debug'     => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal'     => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $self->{name}      = $p{name};
    $self->{test_mode} = $p{test_mode};
    $self->{debug}     = $p{debug};
    $self->{fatal}     = $p{fatal};

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
        {   'name'      => { type => SCALAR },
            'test_mode' => { type => BOOLEAN, optional => 1 },
            'debug'     => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal'     => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $self->{name}      = $p{name};
    $self->{test_mode} = $p{test_mode};
    $self->{debug}     = $p{debug};
    $self->{fatal}     = $p{fatal};

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
        {   'name'      => { type => SCALAR },
            'test_mode' => { type => BOOLEAN, optional => 1 },
            'debug'     => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal'     => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $self->{name}      = $p{name};
    $self->{test_mode} = $p{test_mode};
    $self->{debug}     = $p{debug};
    $self->{fatal}     = $p{fatal};

    $self->{vtype}->enable_virtualos();
}

sub modify_virtualos {

    # Usage      : $virtual->modify_virtualos( name => 'mysql' );
    # Purpose    : modify a container
    # Returns    : true or undef on failure
    # Parameters :
    #   Required : name      - name/ID of the virtual OS
    #   Optional : test_mode -

    my $self = shift;

    my %p = validate(
        @_,
        {   'name'         => { type => SCALAR },
            'ip'           => { type => SCALAR, optional => 1 },
            'hostname'     => { type => SCALAR, optional => 1 },
            'disk_root'    => { type => SCALAR, optional => 1 },
            'disk_size'    => { type => SCALAR, optional => 1 },
            'config'       => { type => SCALAR, optional => 1 },
            'template'     => { type => SCALAR, optional => 1 },
            'password'     => { type => SCALAR, optional => 1 },
            'nameservers'  => { type => SCALAR, optional => 1 },
            'searchdomain' => { type => SCALAR, optional => 1 },
            'test_mode'    => { type => BOOLEAN, optional => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $prov->audit("initializing request to modify container '$p{name}'");

    foreach ( qw/ name hostname disk_root disk_size config
                  template password ssh_key searchdomain
                  fatal debug test_mode / ) {
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

    my %p = validate(
        @_,
        {   'name'         => { type => SCALAR },
            'template'     => { type => SCALAR },
            'ip'           => { type => SCALAR },
            'hostname'     => { type => SCALAR | UNDEF, optional => 1 },
            'disk_root'    => { type => SCALAR | UNDEF, optional => 1 },
            'disk_size'    => { type => SCALAR | UNDEF, optional => 1 },
            'ram'          => { type => SCALAR | UNDEF, optional => 1 },
            'config'       => { type => SCALAR | UNDEF, optional => 1 },
            'password'     => { type => SCALAR | UNDEF, optional => 1 },
            'nameservers'  => { type => SCALAR | UNDEF, optional => 1 },
            'searchdomain' => { type => SCALAR | UNDEF, optional => 1 },

            'test_mode' => { type => BOOLEAN, optional => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $prov->audit( "initializing request to reinstall ve '$p{name}'");

    $self->{debug}     = $p{debug};
    $self->{fatal}     = $p{fatal};
    $self->{test_mode} = $p{test_mode};

    $self->{name}        = $p{name};
    $self->{template}    = $p{template};
    $self->{ip}          = $self->get_ips( $p{ip} ) or return;
    $self->{hostname}    = $p{hostname}    if $p{hostname};
    $self->{disk_root}   = $p{disk_root}   if $p{disk_root};
    $self->{disk_size}   = $p{disk_size}   if $p{disk_size};
    $self->{ram}         = $p{ram}         if $p{ram};
    $self->{config}      = $p{config}      if $p{config};
    $self->{password}    = $p{password}    if $p{password};
    $self->{nameservers} = $self->get_ips( $p{nameservers} ) if $p{nameservers};
    $self->{searchdomain} = $p{searchdomain} if $p{searchdomain};

    $prov->audit("\tdelegating request to $self->{vtype}");
    $self->{vtype}->reinstall_virtualos();
}

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
        return $prov->error(
            message => "no valid IPs in request!",
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
        {   'name'      => { type => SCALAR | UNDEF,  optional => 1 },
            'test_mode' => { type => BOOLEAN, optional => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $self->{name}      = $p{name};
    $self->{test_mode} = $p{test_mode};
    $self->{debug}     = $p{debug};
    $self->{fatal}     = $p{fatal};

    $self->{vtype}->get_status();
}

sub get_template_dir {

    my $self = shift;

    my %p = validate(
        @_,
        {   'v_type'    => { type => SCALAR  },
            'debug'     => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal'     => { type => BOOLEAN, optional => 1, default => 1 },
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

    return $prov->error(
            message => 'unable to determine template directory',
            fatal  => $p{fatal},
            debug  => $p{debug},
        );
};

sub get_template_list {

    my $self = shift;

    my %p = validate(
        @_,
        {   'v_type'    => { type => SCALAR  },
            'debug'     => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal'     => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $v_type = $p{v_type};

    my $template_dir = $self->get_template_dir( v_type=> $v_type ) 
        or return $prov->error(
            message => 'unable to determine template directory',
            fatal  => $p{fatal},
            debug  => $p{debug},
        );

    my @templates = <$template_dir/*.tar.gz>;
    foreach my $template ( @templates ) {
        ($template) = $template =~ /\/([\w\.\-]+)\.tar\.gz$/;
    };

    return \@templates;
};

sub set_hostname {

    my $self = shift;

    my %p = validate(
        @_,
        {   'name'      => { type => SCALAR },
            'hostname'  => { type => SCALAR },
            'test_mode' => { type => BOOLEAN, optional => 1 },
            'debug'     => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal'     => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $self->{name}      = $p{name};
    $self->{hostname}  = $p{hostname};
    $self->{test_mode} = $p{test_mode};
    $self->{debug}     = $p{debug};
    $self->{fatal}     = $p{fatal};

    $self->{vtype}->set_hostname();
}

sub set_nameservers {

    my $self = shift;

    my %p = validate(
        @_,
        {   'name'         => { type => SCALAR },
            'nameservers'  => { type => SCALAR },
            'searchdomain' => { type => SCALAR, optional => 1 },
            'test_mode'    => { type => BOOLEAN, optional => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $self->{name}         = $p{name};
    $self->{nameservers}  = $self->get_ips( $p{nameservers} );
    $self->{searchdomain} = $p{searchdomain};
    $self->{test_mode}    = $p{test_mode};
    $self->{debug}        = $p{debug};
    $self->{fatal}        = $p{fatal};

    $self->{vtype}->set_nameservers();
}

sub set_password {

    my $self = shift;

    my %p = validate(
        @_,
        {   'name'      => { type => SCALAR },
            'user'      => { type => SCALAR | UNDEF, optional => 1 },
            'password'  => { type => SCALAR },
            'ssh_key'   => { type => SCALAR,  optional => 1 },
            'test_mode' => { type => BOOLEAN, optional => 1 },
            'debug'     => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal'     => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $self->{name}      = $p{name};
    $self->{user}      = $p{user} || 'root';
    $self->{password}  = $p{password};
    $self->{ssh_key}   = $p{ssh_key};
    $self->{test_mode} = $p{test_mode};
    $self->{debug}     = $p{debug};
    $self->{fatal}     = $p{fatal};

    $self->{vtype}->set_password();
}

sub is_present {

    my $self = shift;

    my %p = validate(
        @_,
        {   'name'      => { type => SCALAR },
            'test_mode' => { type => BOOLEAN, optional => 1 },
            'debug'     => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal'     => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $self->{name}      = $p{name};
    $self->{test_mode} = $p{test_mode};
    $self->{debug}     = $p{debug};
    $self->{fatal}     = $p{fatal};

    $self->{vtype}->is_present();
}

sub is_running {

    my $self = shift;

    my %p = validate(
        @_,
        {   'name'      => { type => SCALAR },
            'test_mode' => { type => BOOLEAN, optional => 1 },
            'debug'     => { type => BOOLEAN, optional => 1, default => 1 },
            'fatal'     => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $self->{name}      = $p{name};
    $self->{test_mode} = $p{test_mode};
    $self->{debug}     = $p{debug};
    $self->{fatal}     = $p{fatal};

    $self->{vtype}->is_running();
}

sub is_valid_ip {
    my $self  = shift;
    my $ip    = shift;
    my $error = "'$ip' is not a valid IPv4 address";

    my $r = grep /\./, split( //, $ip );    # need 3 dots
    return $prov->error( message => $error, fatal => 0, debug => 0 )
        if $r != 3;

    my @octets = split /\./, $ip;
    return $prov->error( message => $error, fatal => 0, debug => 0 )
        if @octets != 4;

    foreach (@octets) {
        return unless /^\d{1,3}$/ and $_ >= 0 and $_ <= 255;
        $_ = 0 + $_;
    }

    return $prov->error( message => $error, fatal => 0, debug => 0 )
        if $octets[0] == 0;    # 0. is invalid

    return $prov->error( message => $error, fatal => 0, debug => 0 )
        if 0 + $octets[0] + $octets[1] + $octets[2] + $octets[3]
            == 0;              # 0.0.0.0 is invalid

    return $prov->error( message => $error, fatal => 0, debug => 0 )
        if grep( $_ eq '255', @octets ) == 4;    # 255.255.255.255 is invalid

    return join( '.', @octets );
}

sub _get_virt_type {

    my $self = shift;

    my %p = validate(
        @_, { 
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

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
                message => "Unable to determine your virtualization method. You need one supported hypervisor (xen, openvz) installed.",
                fatal => $p{fatal},
                debug => $p{debug},
            );
        };
    }
    elsif ( lc( $OSNAME) eq 'solaris' ) {
        require Provision::Unix::VirtualOS::Solaris::Container;
        return Provision::Unix::VirtualOS::Solaris::Container->new( vos => $self );
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
        print "fatal: $p{fatal}\n";
        $prov->error( 
            message => "No virtualization methods for $OSNAME are supported yet",
            fatal   => $p{fatal},
            debug   => $p{debug},
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

