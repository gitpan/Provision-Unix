package Provision::Unix::User;
use strict;
use warnings;

our $VERSION = '0.13';

use English qw( -no_match_vars );
use Params::Validate qw( :all );

use lib 'lib';
use Provision::Unix::Utility;

my ($util, $prov);

sub new {
    my $class = shift;

    my %p = validate(
        @_,
        {   prov  => { type => HASHREF },
            debug => { type => BOOLEAN, optional => 1, default => 1 },
            fatal => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $self = {
        prov  => $p{prov},
        debug => $p{debug},
        fatal => $p{fatal},
    };
    bless( $self, $class );

    $prov = $p{prov};
    $prov->audit("loaded User");
    $self->{os} = $self->_get_os();

    $util = Provision::Unix::Utility->new( prov=> $prov );
    return $self;
}

sub create {

    ############################################
    # Usage      : $user->create( username=>'bob',uid=>501} );
    # Purpose    : creates a new system user
    # Returns    : uid of new user or undef on failure
    # Parameters :
    #   Required : username
    #            : uid
    #            : guid
    #   Optional : password,
    #            : shell
    #            : homedir
    #            : gecos, quota, uid, gid, expire,
    #            : domain  - if set, account homedir is $HOME/$domain
    # Throws     : exceptions

    my $self = shift;
    return $self->{os}->create(@_);
}

sub modify {

    my $self = shift;

    my %p = validate(
        @_,
        {   'request'   => { type => HASHREF, optional => 1, },
            'prompt'    => { type => BOOLEAN, optional => 1, default => 0 },
            'test_mode' => { type => BOOLEAN, optional => 1, default => 0 },
            'fatal'     => { type => SCALAR,  optional => 1, default => 1 },
            'debug'     => { type => SCALAR,  optional => 1, default => 1 },
        },
    );

    my $request = $p{request};

    $prov->progress( num => 1, desc => 'validating' );

    $self->{os}->modify( $self->{request} );

## TODO

}

sub destroy {

    my $self = shift;
    return $self->{os}->destroy(@_);
}

sub destroy_group {

    my $self = shift;
    return $self->{os}->destroy_group(@_);
}

sub exists {

    ############################################
    # Usage      : $user->exists('builder_bob')
    # Purpose    : Check if a user account exists
    # Returns    : the uid of the user or undef
    # Parameters :
    # Throws     : no exceptions
    # Comments   : Use this before adding a new user (error trapping)
    #               and also after adding a user to verify success.

    my $self = shift;
    my $username = lc(shift) || $self->{username} || die "missing user";

    my $uid = getpwnam($username);
    $self->{uid} = $uid;

    ( $uid && $uid > 0 ) ? return $uid : return;
}

sub exists_group {

    ############################################
    # Usage      : $user->exists_group('builder_bob')
    # Purpose    : Check if a group exists
    # Returns    : the gid of the group or undef
    # Parameters :
    # Throws     : no exceptions
    # Comments   : Use this before adding a new group (error trapping)
    #               and also after adding to verify success.

    my $self  = shift;
    my $group = lc(shift) or die "missing user";

    my $gid = getgrnam($group);

    ( $gid && $gid > 0 ) ? return $gid : return;
}

sub user_quota {

    # Quota::setqlim($dev, $uid, $bs, $bh, $is, $ih, $tlo, $isgrp);
    # $dev     - filesystem mount or device
    # $bs, $is - soft limits for blocks and inodes
    # $bh, $ih - hard limits for blocks and inodes
    # $tlo     - time limits (0 = first user write, 1 = 7 days)
    # $isgrp   - 1 means that uid = gid, group limits set

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'conf'  => { type => HASHREF, optional => 1, },
            'username'  => { type => SCALAR,  optional => 0, },
            'quota' => { type => SCALAR,  optional => 1, default => 100 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    my ( $conf, $username, $quota, $fatal, $debug )
        = ( $p{conf}, $p{username}, $p{quota}, $p{fatal}, $p{debug} );

    require Quota;

    my $dev = $conf->{quota_filesystem} || "/home";
    my $uid = getpwnam($username);

    # set the soft limit a few megs higher than the hard limit
    my $quotabump = $quota + 5;

    print "quota_set: setting $quota MB quota for $username ($uid) on $dev\n"
        if $debug;

    # convert from megs to 1K blocks
    my $bh = $quota * 1024;
    my $bs = $quotabump * 1024;

    my $is = $conf->{quota_inodes_soft} || 0;
    my $ih = $conf->{quota_inodes_hard} || 0;

    Quota::setqlim( $dev, $uid, $bs, $bh, $is, $ih, 1, 0 );

    print "user: end.\n" if $debug;

    # we should test the quota here and then return an appropriate result code
    return 1;
}

sub show {

=head2 show

Show user attributes. Right now it only shows quota info.

   $pass->show( {user=>"matt"} );

returns a hashref with error_code and error_desc

=cut

    my ( $self, $user ) = @_;

    unless ($user) {
        return { 'error_code' => 500, 'error_desc' => 'invalid user' };
    }

    print "user_show: $user show function...\n" if $self->{debug};
    $prov->syscmd( cmd => "quota $user" );
    return { 'error_code' => 100, 'error_desc' => 'all is well' };
}

sub disable {

=head2 disable

Disable an /etc/passwd user by expiring their account.

  $pass->disable( "matt" );

=cut

    my ( $self, $user ) = @_;

    my $r;

    my $pw = $util->find_bin( bin => "pw" ) || '/usr/sbin/pw';

    if ( getpwnam($user) && getpwnam($user) > 0 )    # Make sure user exists
    {
        my $cmd = "$pw usermod -n $user -e -1m";

         if ( $util->syscmd( cmd => $cmd ) ) {
             return {
                 'error_code' => 200,
                 'error_desc' => "disable: success. $user has been disabled."
             };
         }
         else {
            return {
                'error_code' => 500,
                'error_desc' => "disable: FAILED. $user not disabled."
            };
        }
    }
    else {
        return {
            'error_code' => 100,
            'error_desc' => "disable: $user does not exist."
        };
    }
}

sub enable {

=head2 enable

Enable an /etc/passwd user by removing the expiration date.

  $pass->enable( {user=>"matt"} );

input is a hashref

returns a hashref with error_code and error_desc

=cut

    my ( $self, $vals ) = @_;

    my $r;

    my $user = $vals->{user};
    my $pw   = '/usr/sbin/pw';

    if ( $self->exists($user) )    # Make sure user exists
    {
        my $cmd = "$pw usermod -n $user -e ''";

   #        if ( $prov->syscmd( cmd => $cmd ) ) {
   #            $r = {
   #                'error_code' => 200,
   #                'error_desc' => "enable: success. $user has been enabled."
   #            };
   #            return $r;
   #        }
   #        else {
        $r = {
            'error_code' => 500,
            'error_desc' => "enable: FAILED. $user not enabled."
        };
        return $r;

        #        }
    }
    else {
        return {
            'error_code' => 100,
            'error_desc' => "disable: $user does not exist."
        };
    }
}

sub encrypt {

=head2 encrypt

	$pass->encrypt ($pass, $debug)

encrypt (MD5) the plain text password that arrives at $pass.

=cut

    my ( $self, $pass, $debug ) = @_;

    #    $perl->module_load(
    #            module     => "Crypt::PasswdMD5",
    #            port_name  => "p5-Crypt-PasswdMD5",
    #            port_group => "security"
    #    );

    my $salt = rand;
    my $pass_e = Crypt::PasswdMD5::unix_md5_crypt( $pass, $salt );

    print "encrypt: pass_e = $pass_e\n" if $debug;
    return $pass_e;
}

sub is_valid_password {

=head2 is_valid_password

Check a password for sanity.

    $r =  $user->is_valid_password($password, $username);


$password  is the password the user is attempting to use.

$username is the username the user has selected. 

Checks: 

    Passwords must have at least 6 characters.
    Passwords must have no more than 128 characters.
    Passwords must not be the same as the username
    Passwords must not be purely alpha or purely numeric
    Passwords must not be in reserved list 
       (/usr/local/etc/passwd.badpass)

$r is a hashref that gets returned.

$r->{error_code} will contain a result code of 100 (success) or (4-500) (failure)

$r->{error_desc} will contain a string with a description of which test failed.

=cut

    my ( $self, $pass, $user ) = @_;
    my %r = ( error_code => 400 );

    # min 6 characters
    if ( length($pass) < 6 ) {
        $r{error_desc}
            = "Passwords must have at least six characters. $pass is too short.";
        return \%r;
    }

    # max 128 characters
    if ( length($pass) > 128 ) {
        $r{error_desc}
            = "Passwords must have no more than 128 characters. $pass is too long.";
        return \%r;
    }

    # not purely alpha or numeric
    if ( $pass =~ /a-z/ or $pass =~ /A-Z/ or $pass =~ /0-9/ ) {
        $r{error_desc} = "Passwords must contain both letters and numbers!";
        return \%r;
    }

    # does not match username
    if ( $pass eq $user ) {
        $r{error_desc} = "The username and password must not match!";
        return \%r;
    }

    if ( -r "/usr/local/etc/passwd.badpass" ) {

        my @lines =
            $util->file_read( file => "/usr/local/etc/passwd.badpass" );
        foreach my $line (@lines) {
            chomp $line;
            if ( $pass eq $line ) {
                $r{error_desc} =
                    "$pass is a weak password. Please select another.";
                return \%r;
            }
        }
    }

    $r{error_code} = 100;
    return \%r;
}

sub create_group {

    my $self = shift;
    return $self->{os}->create_group(@_);
}

sub archive {

}

sub _get_os {

    my $self = shift;
    my $prov = $self->{prov};

    my $os = lc($OSNAME);

    if ( $os eq 'darwin' ) {
        require Provision::Unix::User::Darwin;
        return Provision::Unix::User::Darwin->new(
            prov => $prov,
            user => $self
        );
    }
    elsif ( lc($OSNAME) eq 'freebsd' ) {
        require Provision::Unix::User::FreeBSD;
        return Provision::Unix::User::FreeBSD->new(
            prov => $prov,
            user => $self
        );
    }
#    elsif ( lc($OSNAME) eq 'linux' ) {
#        require Provision::Unix::User::Linux;
#        return Provision::Unix::User::Linux->new( 
#            prov => $prov,
#            user => $self );
#    }
    else {
        return $prov->error( message => "create: "
                . $self->{request}{username}
                . " FAILED! There is no support for $OSNAME yet. Consider submitting a patch."
        );
    }
}

sub _is_valid_request {

    my $self = shift;

    $self->{prov}->progress( num => 2, desc => 'validating input' );

    # check for missing username
    if ( !$self->{username} ) {
        return $prov->progress(
            num  => 10,
            desc => 'error',
            err  => 'invalid request, missing a value for username',
        );
    }

    # make sure username is valid
    if ( !$self->_is_valid_username() ) {
        return $prov->progress(
            num  => 10,
            desc => 'error',
            err  => $prov->{errors}->[-1]->{errmsg}
        );
    }

    # make sure uid is set
    if ( !$self->{uid} ) {
        return $prov->progress(
            num  => 10,
            desc => 'error',
            err  => "missing uid in request"
        );
    }
    return 1;
}

sub _is_valid_username {

    my $self = shift;

    # set this to fully define your username restrictions. It will
    # get returned every time an invalid username is submitted.

    my $username = $self->{username};

    if ( !$username ) {
        return $self->{prov}->error(
            message  => "username missing",
            location => join( '\t', caller ),
            fatal    => 0,
            debug    => 0,
        );
    }

    # min 2 characters
    if ( length($username) < 2 ) {
        return $prov->error(
            {   message  => "username $username is too short",
                location => join( '\t', caller ),
                fatal    => 0,
                debug    => 0,
            }
        );
    }

    # max 16 characters
    if ( length($username) > 16 ) {
        return $prov->error(
            {   message  => "username $username is too long",
                location => join( '\t', caller ),
                fatal    => 0,
                debug    => 0,
            }
        );
    }

    # only lower case letters and numbers
    # begins with an alpha character
    if ( $username !~ /^[a-z][a-z0-9]+$/ ) {
        return $prov->error(
            {   message  => "username $username has invalid characters",
                location => join( '\t', caller ),
                fatal    => 0,
                debug    => 0,
            }
        );
    }

    my $reserved = "/usr/local/etc/passwd.reserved";
    if ( -r $reserved ) {
        foreach my $line (
            $util->file_read( file => $reserved, fatal => 0, debug => 0 ) )
        {
            if ( $username eq $line ) {
                return $prov->error(
                    {   message  => "$username is reserved.",
                        location => join( '\t', caller ),
                        fatal    => 0,
                        debug    => 1,
                    }
                );
            }
        }
    }

    return 1;
}

1;

__END__

=head1 NAME

Provision::Unix::User - Provision Unix Accounts on Unix(like) systems!

=head1 VERSION

Version 0.13

=head1 SYNOPSIS

Handles provisioning operations (create, modify, destroy) for system users on UNIX based operating systems.

    use Provision::Unix::User;

    my $prov = Provision::Unix::User->new();
    ...

=head1 FUNCTIONS

=head2 new

Creates and returns a new Provision::Unix::User object.

=head2 is_valid_username

   $user->is_valid_username($username, $denylist);

$username is the username. Pass it along as a scalar (string).

$denylist is a optional hashref. Define all usernames you want reserved (denied) and it will check to make sure $username is not in the hashref.

Checks:

   * Usernames must be between 2 and 16 characters.
   * Usernames must have only lower alpha and numeric chars
   * Usernames must begin with an alpha character
   * Usernames must not be defined in $denylist or reserved list

The format of $local/etc/passwd.reserved is one username per line.


=head2 archive

Create's a tarball of the users home directory. Typically done right before you rm -rf their home directory as part of a de-provisioning step.

    if ( $user->archive("user") ) 
    {
        print "user archived";
    };

returns a boolean.

=head2 create_group

Installs a system group. 

    $r = $pass->create_group($group, $gid)

    $r->{error_code} == 200 ? print "success" : print $r->{error_desc}; 



=head1 AUTHOR

Matt Simerson, C<< <matt at tnpi.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-unix-provision-user at rt.cpan.org>, or through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Provision-Unix>.  I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Provision::Unix::User


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
