package Provision::Unix;

our $VERSION = '0.52';

use warnings;
use strict;

use Carp;
use Config::Tiny;
use Cwd;
use Data::Dumper;
use English qw( -no_match_vars );
use Params::Validate qw(:all);
use Scalar::Util qw( openhandle );

sub new {
    my $class = shift;
    my %p     = validate(
        @_,
        {   'file' => {
                type     => SCALAR,
                optional => 1,
                default  => 'provision.conf'
            },
            'fatal' => { type => SCALAR, optional => 1, default => 1 },
            'debug' => { type => SCALAR, optional => 1, default => 1 },
        }
    );

    my $self = {
        debug  => $p{debug},
        fatal  => $p{fatal},
        config => undef,
        errors => [],          # runtime errors will get added to this array
        audit  => [],          # status messages accumulate here
        last_audit => 0,
    };

    bless( $self, $class );
    my $config_file
        = $self->find_config( file => $p{file}, debug => $p{debug}, fatal => 0 );
    if ( $config_file ) {
        $self->{config} = Config::Tiny->read( $config_file );
    }
    else {
        warn "could not find provision.conf. Consider installing it in your local etc directory.\n";
    };
    return $self;
}

sub find_config {

    my $self = shift;

    my %p = validate(
        @_,
        {   'file'   => { type => SCALAR, },
            'etcdir' => { type => SCALAR | UNDEF, optional => 1, },
            'fatal'  => { type => SCALAR, optional => 1, default => 1 },
            'debug'  => { type => SCALAR, optional => 1, default => 1 },
        }
    );

    my $file = $p{'file'};
    $self->{debug} = $p{debug};

    $self->audit("find_config: searching for $file");

    return $self->_find_readable( $file, $p{etcdir} ) if $p{etcdir};

    my @etc_dirs = qw{ /opt/local/etc /usr/local/etc /etc etc };

    my $working_directory = cwd;
    push @etc_dirs, $working_directory;

    my $r = $self->_find_readable( $file, @etc_dirs );
    return $r if $r;

    # try $file-dist in the working dir
    if ( -r "./$file-dist" ) {
        $self->audit("\tfound $file in ./");
        return "$working_directory/$file-dist";
    }

    return $self->error( "could not find $file",
        fatal   => $p{fatal},
        debug   => $p{debug},
    );
}

sub get_errors {
    my $self = shift;
    return $self->{errors};
}

sub get_last_error_message {
    my $self = shift;
    return $self->{errors}[-1]->{errmsg};
}

sub progress {
    my $self = shift;

    my %p = validate(
        @_,
        {   'num'  => { type => SCALAR },
            'desc' => { type => SCALAR, optional => 1 },
            'err'  => { type => SCALAR, optional => 1 },
        },
    );

    my $msg_length = length $p{desc};
    my $to_print   = 10;
    my $max_print  = 70 - $msg_length;

    # if err, print and return
    if ( $p{err} ) {
        if ( length( $p{err} ) == 1 ) {
            foreach my $error ( @{ $self->{errors} } ) {
                print {*STDERR} "\n$error->{errloc}\t$error->{errmsg}\n";
            }
        }
        else {
            print {*STDERR} "\n\t$p{err}\n";
        }
        return $self->error( $p{err}, fatal => 0, debug => 0 );
    }

    if ( $msg_length > 54 ) {
        die "max message length is 55 chars\n";
    }

    print {*STDERR} "\r[";
    foreach ( 1 .. $p{num} ) {
        print {*STDERR} "=";
        $to_print--;
        $max_print--;
    }

    while ($to_print) {
        print {*STDERR} ".";
        $to_print--;
        $max_print--;
    }

    print {*STDERR} "] $p{desc}";
    while ($max_print) {
        print {*STDERR} " ";
        $max_print--;
    }

    if ( $p{num} == 10 ) { print {*STDERR} "\n" }

    return 1;
}

sub error {

    my $self = shift;
    my $message = shift;
    my %p = validate(
        @_,
        {   'location' => { type => SCALAR, optional => 1, },
            'fatal'    => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'    => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    if ( $message ) {
        push @{ $self->{audit} }, $message;

        # append message to $self->error stack
        push @{ $self->{errors} },
            {
            errmsg => "ERROR: $message",
            errloc => $p{location} || join( ", ", caller ),
            };
    }
    else {
        $message = $self->get_last_error_message();
    }

    # print audit and error results to stderr
    if ( $p{fatal} ) {
        warn "\n\t\t\tAudit & Error history Report \n\n";
        $self->dump_audit() if $p{debug};
        warn Dumper( $self->{errors}[-1] ) if $p{debug};
        croak "FATAL ERROR";
    }

    if ( $p{debug} ) {
        $self->dump_audit();
    }

    return;
}

sub dump_audit {
    my $self = shift;
    my $last_line = $self->{last_audit};
    my $i;
    foreach ( @{ $self->{audit} } ) {
        $i++;
        next if $i < $last_line;
        print "\t$_\n";
    };
    $self->{last_audit} = $i;
    return;
};

sub audit {
    my $self = shift;
    my $mess = shift;

    if ($mess) {
        push @{ $self->{audit} }, $mess;
        warn "$mess\n" if $self->{debug};
    }

    return $self->{audit};
}

sub _find_readable {
    my $self = shift;
    my $file = shift;
    my $dir  = shift or return;    # breaks recursion at end of @_

    $self->audit("looking for $file in $dir");

    if ( -r "$dir/$file" ) {
        no warnings;
        $self->audit("\tfound $file in $dir");
        return "$dir/$file";       # we have succeeded
    }

    if ( -d $dir ) {

        # warn about directories we don't have read access to
        if ( !-r $dir ) {
            $self->error( "$dir is not readable", fatal => 0 );
        }
        else {

            # warn about files that exist but aren't readable
            if ( -e "$dir/$file" ) {
                $self->error( "$dir/$file is not readable",
                    fatal   => 0
                );
            }
        }
    }

    return $self->_find_readable( $file, @_ );
}

sub _begin {
    my ( $self, $phase ) = @_;
    print {*STDERR} "$phase...";
    return;
}

sub _continue {
    print {*STDERR} '.';
    return;
}

sub _end {
    print {*STDERR} "done\n";
    return;
}


1;

__END__

=head1 NAME

Provision::Unix - provision accounts on unix systems

=head1 SYNOPSIS

Provision::Unix is an application to create, modify, and destroy accounts
on Unix systems in a reliable and consistent manner. 

    prov_user.pl --action=create --username=matt --pass='neat0app!'
    prov_dns.pl  --action=create --zone=example.com
    prov_web.pl  --action=create --vhost=www.example.com

The types of accounts that can be provisioned are organized by class with each
class including a standard set of operations. All classes support at least
create and destroy operations.  Additional common operations are: modify, 
enable, and disable.

Each class (DNS, Mail, User, VirtualOS, Web) has a general module that 
contains the logic for selecting and dispatching requests to sub-classes which
are implementation specific. Selecting and dispatching is done based on the
environment and configuration file settings at run time.

For example, Provision::Unix::Mail contains all the general logic for email
operations (create a vhost, mailbox, alias, etc). Subclasses contain 
specific information such as how to provision a mailbox for sendmail,
postfix, qmail, ezmlm, or vpopmail.

Browse the perl modules to see which modules are available.

    use Provision::Unix;

    my $foo = Provision::Unix->new();
    ...


=head1 Programming Conventions

All functions/methods adhere to the following:

=head2 Exception Handling

Errors throw exceptions. This can be overridden by calling the method with fatal=>0. If you do so, you must write code to handle the errors. 

This call will throw an exception since it cannot find the file. 

  $util->file_read(file=>'/etc/oopsie_a_typo');

Setting fatal will cause it to return undef instead:

  $util->file_read(file=>'/etc/oopsie_a_typo', fatal=>0);

=head2 Warnings and Messages

Methods have an optional debug parameter that defaults to enabled. Often, that means methods spit out more messages than you want to see. You can supress them by setting debug=>0.

Supressed messages are not lost! All error messages are stored in $prov->errors and all status messages are in $prov->audit. You can dump those arrays any time to to inspect the status or error messages. A handy way to do so is:

  $prov->error('test breakpoint');

That will dump the contents of $prov->audit and $prov->errors and then terminate your program. If you want your program to continue after calling $prov->error, just set fatal=>0. 


=head1 FUNCTIONS

=head2 new

Creates and returns a new Provision::Unix object. 

As part of initialization, new() finds and reads in provision.conf from /[opt/usr]/local/etc, /etc, and the current working directory. 

=head2 find_config

Searches in common etc directories for a named configuration file.

  my $config = $self->find_config( file => 'provision.conf', debug=>0 );


=head2 error

Whenever a method runs into an unexpected condition, it should call $prov->error with a human intelligible error message. It should also specify whether the error is merely a warning or a fatal condition. Errors are considered fatal unless otherwise specified.

Examples:

 $prov->error( 'could not write to file /etc/passwd' );

This error is fatal and will throw an exception, after dumping the contents of $prov->audit and the last error message from $prov->errors to stderr. 

A very helpful thing to do is call error with a location as well:

 $prov->error( 'could not write to file /etc/passwd',
    location => join( ", ", caller ),
 );

Doing so will tell you where the error message was encountered as well as what called the method. The latter is more likely where the error exists, making location a very beneficial thing to pass along.

=head2 audit

audit is a method that appends messages to an internal audit log. Rather than spewing messages to stdout or stderr, they all get appended to an array. They can then be inspected whenever desired by calling $prov->audit and examining the result. I expect to add additional support to that method for logging the messages to a file or SQL table.

returns an arrayref of audit messages.

=head1 AUTHOR

Matt Simerson, <msimerson@cpan.org>

=head1 BUGS

Please report any bugs or feature requests to C<bug-unix-provision at rt.cpan.org>, or through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Provision-Unix>.  I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.


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

=head1 COPYRIGHT & LICENSE

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

