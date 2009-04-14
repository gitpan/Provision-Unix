package Provision::Unix::User::Linux;

our $VERSION = '0.08';

use warnings;
use strict;

use English qw( -no_match_vars );
use Carp;
use Params::Validate qw( :all );

use lib 'lib';
use Provision::Unix;
my $provision = Provision::Unix->new();
my ( $prov, $user, $util );

sub new {

    my $class = shift;

    my %p = validate(
        @_,
        {   prov  => { type => OBJECT },
            user  => { type => OBJECT },
            debug => { type => BOOLEAN, optional => 1, default => 1 },
            fatal => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    $prov = $p{prov};
    $user = $p{user};

    my $self = {
        prov  => $prov,
        user  => $user,
        debug => $p{debug},
        fatal => $p{fatal},
    };
    bless( $self, $class );

    $prov->audit("loaded User/Linux");

    require Provision::Unix::Utility;
    $util = Provision::Unix::Utility->new( prov => $prov );
    return $self;
}

sub create {

    my $self = shift;

    my %p = validate(
        @_,
        {   'username' => { type => SCALAR },
            'uid'      => { type => SCALAR },
            'gid'      => { type => SCALAR },
            'shell'    => { type => SCALAR | UNDEF, optional => 1 },
            'password' => { type => SCALAR | UNDEF, optional => 1 },
            'homedir'  => { type => SCALAR | UNDEF, optional => 1 },
            'gecos'    => { type => SCALAR | UNDEF, optional => 1 },
            'domain'   => { type => SCALAR | UNDEF, optional => 1 },
            'expire'   => { type => SCALAR | UNDEF, optional => 1 },
            'quota'    => { type => SCALAR | UNDEF, optional => 1 },
            'debug'    => { type => SCALAR, optional => 1, default => 1 },
            'test_mode' => { type => SCALAR, optional => 1 },
        }
    );

    my $debug = $p{'debug'};
    $prov->audit("creating user '$p{username}' on $OSNAME");

    $user->_is_valid_username( $p{username} ) or return;

    my $cmd = $util->find_bin( bin => 'useradd', debug => $p{debug} );
    $cmd .= " -c $p{gecos}"   if $p{gecos};
    $cmd .= " -d $p{homedir}" if $p{homedir};
    $cmd .= " -e $p{expire}"  if $p{expire};
    $cmd .= " -u $p{uid}"     if $p{uid};
    $cmd .= " -s $p{shell}"   if $p{shell};
    $cmd .= " -g $p{gid}"     if $p{gid};

    $cmd .= " -m $p{username}";

    $prov->audit("\tcmd: $cmd");
    return $prov->audit("\ttest mode early exit") if $p{test_mode};
    $util->syscmd( cmd => $cmd, debug => 0 );

    if ( $p{password} ) {
        my $passwd = $util->find_bin( bin => 'passwd', debug => $p{debug} );
        ## no critic
        my $FH;
        unless ( open $FH, "| $passwd --stdin" ) {
            return $prov->error( "opening passwd failed for $p{username}" );
        }
        print $FH "$p{password}\n";
        close $FH;
        ## use critic
    }

    return $self->exists()
        ? $prov->progress(
        num  => 10,
        desc => "created user $p{username} successfully"
        )
        : $prov->error( "create user $p{username} failed" );
}

sub create_group {

    my $self = shift;

    my %p = validate(
        @_,
        {   'group' => { type => SCALAR },
            'gid'   => { type => SCALAR, optional => 1, },
            'debug' => { type => SCALAR, optional => 1, default => 1 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    # see if the group exists
    if ( $self->exists_group( $p{group} ) ) {
        $prov->audit("create_group: '$p{group}', already exists");
        return 2;
    }

    $prov->audit("create_group: installing $p{group} on $OSNAME");

    my $cmd = $util->find_bin( bin => 'groupadd', debug => $p{debug} );
    $cmd .= " -g $p{gid}" if $p{gid};
    $cmd .= " $p{group}";

    return $util->syscmd( cmd => $cmd, debug => $p{debug} );
}

sub destroy {

    my $self = shift;

    my %p = validate(
        @_,
        {   'username'  => { type => SCALAR, },
            'homedir'   => { type => SCALAR, optional => 1, },
            'archive'   => { type => BOOLEAN, optional => 1, default => 0 },
            'prompt'    => { type => BOOLEAN, optional => 1, default => 0 },
            'test_mode' => { type => BOOLEAN, optional => 1, default => 0 },
            'fatal'     => { type => SCALAR, optional => 1, default => 1 },
            'debug'     => { type => SCALAR, optional => 1, default => 1 },
        },
    );

    $prov->audit("removing user $p{username} on $OSNAME");

    $user->_is_valid_username( $p{username} ) or return;

    return $prov->audit("\ttest mode early exit") if $p{test_mode};

    # make sure user exists
    if ( !$self->exists() ) {
        return $prov->progress(
            num  => 10,
            desc => 'error',
            err  => "\tno such user '$p{username}'",
        );
    }

    my $cmd = $util->find_bin( bin => 'userdel', debug => $p{debug} );
    $cmd .= " -r $p{username}";

    my $r = $util->syscmd( cmd => $cmd, debug => 0, fatal => $p{fatal} );

    # validate that the user was removed
    if ( !$self->exists() ) {
        return $prov->progress(
            num  => 10,
            desc => "\tdeleted user $p{username}"
        );
    }

    return $prov->progress(
        num   => 10,
        desc  => 'error',
        'err' => "\tfailed to remove user '$p{username}'",
    );
}

sub destroy_group {

    my $self = shift;

    my %p = validate(
        @_,
        {   'group'     => { type => SCALAR, },
            'gid'       => { type => SCALAR, optional => 1 },
            'test_mode' => { type => BOOLEAN, optional => 1, default => 0 },
            'fatal'     => { type => SCALAR, optional => 1, default => 1 },
            'debug'     => { type => SCALAR, optional => 1, default => 1 },
        },
    );

    $prov->audit("destroy group $p{group} on $OSNAME");

    $prov->progress( num => 1, desc => 'validating' );

    # make sure group exists
    if ( !$self->exists_group( $p{group} ) ) {
        return $prov->progress(
            num   => 10,
            desc  => 'error',
            'err' => "group $p{group} does not exist",
        );
    }

    my $cmd = $util->find_bin( bin => 'groupdel', debug => 0 );
    $cmd .= " $p{group}";

    return 1 if $p{test_mode};
    $prov->audit("destroy group cmd: $cmd");

    $util->syscmd( cmd => $cmd, debug => $p{debug} )
        or return $prov->progress(
        num   => 10,
        desc  => 'error',
        'err' => $prov->{errors}->[-1]->{errmsg},
        );

    # validate that the group was removed
    if ( !$self->exists_group( $p{group} ) ) {
        return $prov->progress( num => 10, desc => 'completed' );
    }

    return;
}

sub exists {
    my $self = shift;
    my $username = shift || $user->{username};

    $user->_is_valid_username($username)
        or return $prov->error( "missing/invalid username param in request",
            fatal => $user->{fatal},
        );

    $username = lc $username;

    # double check
    if ( -f '/etc/passwd' ) {
        my $exists = `grep '^$username:' /etc/passwd`;
        if ($exists) {
            $prov->audit("\t'$username' exists (passwd: $exists)");
            return $exists;
        }
        return;
    }

    my $uid = getpwnam $username;
    $prov->audit("\t'$username' exists (uid: $uid)");
    $self->{uid} = $uid;
    return $uid;
}

sub exists_group {

    my ( $self, $group ) = @_;
    $group ||= $user->{group} || $prov->error( "missing group" );

    if ( -f '/etc/group' ) {
        my $exists = `grep '^$group:' /etc/group`;
        return $exists ? 1 : 0;
    }

    my $gid = getgrnam($group);
    return $gid ? 1 : 0;
}

sub modify {
    my $self = shift;
    my %p = validate(
        @_,
        {   'username'  => { type => SCALAR },
            'shell'     => { type => SCALAR, optional => 1 },
            'password'  => { type => SCALAR, optional => 1 },
            'ssh_key'   => { type => SCALAR, optional => 1 },
            'gecos'     => { type => SCALAR, optional => 1 },
            'expire'    => { type => SCALAR, optional => 1 },
            'quota'     => { type => SCALAR, optional => 1 },
            'debug'     => { type => SCALAR, optional => 1, default => 1 },
            'test_mode' => { type => SCALAR, optional => 1 },
        }
    );

    if ( $p{password} ) {
        $self->set_password( 
            username => $p{username}, 
            password => $p{password}, 
            ssh_key  => $p{ssh_key},
        );
    };
};

sub set_password {

    my $self = shift;
    my %p = validate(
        @_,
        {   'username'  => { type => SCALAR },
            'password'  => { type => SCALAR, optional => 1 },
            'ssh_key'   => { type => SCALAR, optional => 1 },
            'debug'     => { type => SCALAR, optional => 1, default => 1 },
            'fatal'     => { type => SCALAR, optional => 1, default => 1 },
            'test_mode' => { type => SCALAR, optional => 1 },
        }
    );

    my $username = $p{username};
    $prov->error( "user '$username' not found", fatal => $p{fatal} ) 
        if ! $self->exists( $username );

    my $pass_file = "/etc/shadow";  # SYS 5
    if ( ! -f $pass_file ) {
        $pass_file = "/etc/passwd";
        -f $pass_file or die "could not find password file\n";
    };

    my @lines = $util->file_read( file => $pass_file );
    my $entry = grep { /^$username:/ } @lines;
    $entry or die "could not find $username entry in $pass_file!";

    my $crypted = $user->get_crypted_password( $p{password} );

    foreach ( @lines ) {
        s/$username\:.*?\:/$username\:$crypted\:/ if m/^$username\:/;
    };
    $util->file_write( file => $pass_file, lines => \@lines, debug => $user->{debug} );

    if ( $p{ssh_key} ) {
        my $homedir = (split(':', $entry))[7];
        $user->install_ssh_key( homedir => $homedir, ssh_key => $p{ssh_key} );
    };
    return 1;
};

1;

__END__

=head1 NAME

Provision::Unix::User::Linux - Provision Accounts on Linux systems

=head1 SYNOPSIS

Handles provisioning operations (create, modify, destroy) for system users on UNIX based operating systems.

    use Provision::Unix::User::Linux;

    my $provision_user = Provision::Unix::User::Linux->new();
    ...

=head1 FUNCTIONS

=head2 new

Creates and returns a new Provision::Unix::User::Linux object.

=head1 AUTHOR

Matt Simerson, C<< <matt at tnpi.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-unix-provision-user at rt.cpan.org>, or through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Provision-Unix>.  I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.



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
