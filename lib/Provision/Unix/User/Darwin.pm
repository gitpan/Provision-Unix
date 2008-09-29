package Provision::Unix::User::Darwin;

use warnings;
use strict;

our $VERSION = '0.10';

use English qw( -no_match_vars );
use Carp;
use Params::Validate qw( :all );

use lib 'lib';
use Provision::Unix::Utility;

my ( $util, $prov, $p_user );

sub new {
    my $class = shift;
    my %p     = validate(
        @_,
        {   'prov' => { type => HASHREF },
            'user' => { type => HASHREF },
        }
    );
    my $self = {
        prov => $p{prov},
        user => $p{user},
    };
    bless( $self, $class );

    $p_user = $p{user};
    $prov   = $p{prov};
    $util   = Provision::Unix::Utility->new( prov => $prov );
    return $self;
}

sub create {

    my $self = shift;

    my %p = validate(
        @_,
        {   'username'  => { type => SCALAR },
            'uid'       => { type => SCALAR },
            'gid'       => { type => SCALAR },
            'password' => { type => SCALAR, optional => 1 },
            'shell'    => { type => SCALAR, optional => 1 },
            'homedir'  => { type => SCALAR, optional => 1 },
            'gecos'    => { type => SCALAR, optional => 1 },
            'domain'   => { type => SCALAR, optional => 1 },
            'expire'   => { type => SCALAR, optional => 1 },
            'quota'    => { type => SCALAR, optional => 1 },
            'prompt'    => { type => BOOLEAN, optional => 1, default => 0 },
            'debug'    => { type => SCALAR, optional => 1, default => 1 },
            'fatal'    => { type => SCALAR, optional => 1, default => 1 },
            'test_mode' => { type => BOOLEAN, optional => 1, default => 0 },
        }
    );

    $p_user->{username} = $p{username};
    $p_user->{uid}      = $p{uid};
    $p_user->{gid}      = $p{gid};
    $p_user->{password} = $p{password};
    $p_user->{shell}    = $p{shell} || $prov->{config}{User}{shell_default};
    $p_user->{homedir}  = $p{homedir}
        || $p{domain} ? "/Users/$p{domain}" : "/Users/$p{username}";
    $p_user->{gecos}  = $p{gecos};
    $p_user->{expire} = $p{expire};
    $p_user->{quota}  = $p{quota} || $prov->{config}{User}{quota_default};
    $p_user->{debug}  = $p{debug};

    $prov->progress( num => 1, desc => 'gathering input' );
    $p_user->get_user_attributes() if $p{prompt};

    $prov->progress( num => 2, desc => 'validating input' );
    $p_user->_is_valid_request() or return;

    $prov->progress( num => 3, desc => 'dispatching' );

    # return success if testing
    return $prov->progress( num => 10, desc => 'ok' ) if $p{test_mode};

    # finally, create the user
    my $dirutil
        = $util->find_bin( bin => "dscl", debug => $p{debug}, fatal => 0 );

    $prov->progress(
        num  => 5,
        desc => "adding Darwin user $p_user->{username}"
    );
    if   ($dirutil) { $self->_create_dscl(); }      # 10.5+
    else            { $self->_create_niutil(); }    # 10.4 and previous

## TODO
    # set the password for newly created accounts

    # validate user creation
    my $uid = $self->exists();
    if ($uid) {
        $prov->progress( num => 10, desc => 'validated' );
        return $uid;
    }

    return $prov->progress(
        num  => 10,
        desc => 'error',
        err  => $prov->{errors}->[-1]->{errmsg},
    );
}

sub _next_uid {

# echo $[$(dscl . -list /Users uid | awk '{print $2}' | sort -n | tail -n1)+1]
}

sub _create_dscl {

    my $self = shift;

    my $user  = $p_user->{username};
    my $debug = $self->{debug};

    my $dirutil = $util->find_bin( bin => "dscl", debug => 0 );

    $util->syscmd(
        cmd   => "$dirutil . -create /users/$user",
        debug => $debug,
    );

    $util->syscmd(
        cmd   => "$dirutil . -createprop /users/$user uid $p_user->{uid}",
        debug => $debug,
    );

    $util->syscmd(
        cmd   => "$dirutil . -createprop /users/$user gid $p_user->{gid}",
        debug => $debug,
    );

    $util->syscmd(
        cmd   => "$dirutil . -createprop /users/$user shell $p_user->{shell}",
        debug => $debug,
    );

    $util->syscmd(
        cmd => "$dirutil . -createprop /users/$user home $p_user->{homedir}",
        debug => $debug,
    ) if $p_user->{homedir};

    $util->syscmd(
        cmd   => "$dirutil . -createprop /users/$user passwd '*'",
        debug => $debug,
    );

    if ( $p_user->{homedir} ) {
        my $homedir = $p_user->{homedir};
        mkdir $homedir, 0755;
        $util->chown( dir => $homedir, uid => $user, debug => $debug );
    }

    return getpwnam($user);
}

sub _create_niutil {

    my $self  = shift;
    my $user  = $p_user->{username};
    my $debug = $p_user->{debug};

    # use niutil on 10.4 and prior
    my $dirutil = $util->find_bin( bin => "niutil", debug => 0 );

    $util->syscmd(
        cmd   => "$dirutil -create . /users/$user",
        debug => $debug,
    ) or croak "failed to create user $user\n";

    $prov->progress( num => 6, desc => "configuring $user" );

    $util->syscmd(
        cmd   => "$dirutil -createprop . /users/$user uid $p_user->{uid}",
        debug => $debug,
    );

    $util->syscmd(
        cmd   => "$dirutil -createprop . /users/$user gid $p_user->{gid}",
        debug => $debug,
    );

    $util->syscmd(
        cmd   => "$dirutil -createprop . /users/$user shell $p_user->{shell}",
        debug => $debug,
    );

    $util->syscmd(
        cmd => "$dirutil -createprop . /users/$user home $p_user->{homedir}",
        debug => $debug,
    );

    $util->syscmd(
        cmd   => "$dirutil -createprop . /users/$user _shadow_passwd",
        debug => $debug,
    );

    $util->syscmd(
        cmd   => "$dirutil -createprop . /users/$user passwd '*'",
        debug => $debug,
    );

    if ( $p_user->{homedir} ) {
        my $homedir = $p_user->{homedir};
        mkdir $homedir, 0755;
        $util->chown( dir => $homedir, uid => $user, debug => $debug );
    }

    return getpwnam($user);
}

sub destroy {

    my $self = shift;

    my %p = validate(
        @_,
        {   'username' => { type => SCALAR, optional => 0 },
            'debug'    => { type => SCALAR, optional => 1, default => 1 },
            'test_mode'=> { type => SCALAR, optional => 1, },
        }
    );

    my $user = $p{username};

    print "destroy user $user on Darwin (MacOS)\n" if $p{debug};

    return 1 if $p{test_mode};

    # this works on 10.5
    my $dirutil = $util->find_bin( bin => "dscl", debug => 0, fatal => 0 );

    if ($dirutil) {

        # 10.5
        $util->syscmd(
            cmd   => "$dirutil . -destroy /users/$user",
            debug => 0,
        );
        $self->exists($user) ? return : return 1;
    }

    # this works on 10.4 and previous
    $dirutil = $util->find_bin( bin => "niutil", debug => 0 );

    $util->syscmd(
        cmd   => "$dirutil -destroy . /users/$user",
        debug => 0,
    );

    $self->exists($user) ? return : return 1;
}

sub exists {

    my ( $self, $user ) = @_;
    $user ||= $p_user->{username};
    $user = lc($user);

    ( getpwnam($user) && getpwnam($user) > 0 ) ? return 1 : return;
}

sub create_group {

    my $self = shift;

    my %p = validate(
        @_,
        {   'group' => { type => SCALAR },
            'gid'   => { type => SCALAR, optional => 0 },
            'debug' => { type => SCALAR, optional => 1, default => 1 },
        }
    );

    print "create_group '$p{group}' on Darwin (Mac OS X)\n" if $p{debug};

    my $dirutil
        = $util->find_bin( bin => "dscl", debug => $p{debug}, fatal => 0 );

    $prov->progress( num => 5, desc => "adding Darwin group $p{group}" );
    if ( !$dirutil ) {
        return $self->_create_niutil( $p{group}, $p{gid} )
            ;    # 10.4 and previous
    }
    else {
        return $self->_create_dscl( $p{group}, $p{gid} );    # 10.5
    }
}

sub _create_group_dscl {

    my ( $self, $group, $gid ) = @_;

    my $niutil = $prov->find_bin( bin => "dscl" );
    $prov->syscmd( cmd => "$niutil . -create /groups/$group" );
    $prov->syscmd( cmd => "$niutil . -createprop /groups/$group gid $gid" )
        if $gid;

    $prov->syscmd( cmd => "$niutil . -createprop /groups/$group passwd '*'" );

## TODO  validate and return
}

sub _create_group_niutil {

    my ( $self, $group, $gid ) = @_;

    my $niutil = $prov->find_bin( bin => "niutil" );
    $prov->syscmd( cmd => "$niutil -create . /groups/$group" );
    $prov->syscmd( cmd => "$niutil -createprop . /groups/$group gid $gid" )
        if $gid;

    $prov->syscmd( cmd => "$niutil -createprop . /groups/$group passwd '*'" );
## TODO  validate and return
}

1;

__END__

=head1 NAME

Provision::Unix::User::Darwin - Provision Accounts on Darwin systems

=head1 VERSION

Version 0.10

=head1 SYNOPSIS

Handles provisioning operations (create, modify, destroy) for system users on UNIX based operating systems.

    use Provision::Unix::User::Darwin;

    my $prov_user = Provision::Unix::User::Darwin->new();
    ...

=head1 FUNCTIONS

=head2 new

Creates and returns a new Provision::Unix::User::Darwin object.


=head1 AUTHOR

Matt Simerson, C<< <matt at tnpi.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-unix-provision-user at rt.cpan.org>, or through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Provision-Unix>.  I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Provision::Unix::User::Darwin


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

