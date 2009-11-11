package Provision::Unix;

our $VERSION = '0.78';

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
        {   file  => { type => SCALAR, optional => 1, },
            fatal => { type => SCALAR, optional => 1, default => 1 },
            debug => { type => SCALAR, optional => 1, default => 1 },
        }
    );

    my $file = $p{file} || 'provision.conf';
    my $debug = $p{debug};
    my $ts = get_datetime_from_epoch();
    my $self = {
        debug  => $debug,
        fatal  => $p{fatal},
        config => undef,
        errors => [],  # errors get appended here
        audit  => [    # status messages accumulate here
                "launched at $ts",
                $class . sprintf( " loaded by %s, %s, %s", caller ),
            ], 
        last_audit => 0,
        last_error => 0,
    };

    bless( $self, $class );
    my $config = $self->find_config( file => $file, debug => $debug, fatal => 0 );
    if ( $config ) {
        $self->{config} = Config::Tiny->read( $config );
    }
    else {
        warn "could not find provision.conf. Consider installing it in your local etc directory.\n";
    };

    return $self;
}

sub audit {
    my $self = shift;
    my $mess = shift;

    if ($mess) {
        push @{ $self->{audit} }, $mess;
        warn "$mess\n" if $self->{debug};
    }

    return $self->{audit};
}

sub dump_audit {
    my $self = shift;
    my $last_line = $self->{last_audit};

    # we already dumped everything
    return if $last_line == scalar @{ $self->{audit} };

    print STDERR "\n\t\t\tAudit History Report \n\n";
    my $i = 0;
    foreach ( @{ $self->{audit} } ) {
        $i++;
        next if $i < $last_line;
        print STDERR "\t$_\n";
    };
    $self->{last_audit} = $i;
    return;
};

sub dump_errors {
    my $self = shift;
    my $last_line = $self->{last_error};

    return if $last_line == scalar @{ $self->{errors} }; # everything dumped

    print STDERR "\n\t\t\t Error History Report \n\n";
    my $i = 0;
    foreach ( @{ $self->{errors} } ) {
        $i++;
        next if $i < $last_line;
        print STDERR "ERROR: '$_->{errmsg}' \t\t at $_->{errloc}\n";
    };
    $self->{last_error} = $i;
    return;
};

sub error {
    my $self = shift;
    my $message = shift;
    my %p = validate(
        @_,
        {   'location' => { type => SCALAR,  optional => 1, },
            'fatal'    => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'    => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    my $debug = $p{debug};
    my $fatal = $p{fatal};
    my $location = $p{location};

    if ( $message ) {
        my @caller = caller;
        push @{ $self->{audit} }, $message;

        # append message to $self->error stack
        push @{ $self->{errors} },
            {
            errmsg => $message,
            errloc => $location || join( ", ", $caller[0], $caller[2] ),
            };
    }
    else {
        $message = $self->get_last_error();
    }

    # print audit and error results to stderr
    if ( $debug ) {
        $self->dump_audit();
        $self->dump_errors();
    }

    if ( $fatal ) {
        if ( ! $debug ) {
            $self->dump_audit();  # dump if err is fatal and debug is not set
            $self->dump_errors();
        };
        croak "FATAL ERROR";
    };
    return;
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

    my $file = $p{file};
    my $etcdir = $p{etcdir};
    my $fatal = $self->{fatal} = $p{fatal};
    my $debug = $self->{debug} = $p{debug};

    $self->audit("searching for config $file");

    return $self->_find_readable( $file, $etcdir ) if $etcdir;

    my @etc_dirs = qw{ /opt/local/etc /usr/local/etc /etc etc };

    my $working_directory = cwd;
    push @etc_dirs, $working_directory;

    my $r = $self->_find_readable( $file, @etc_dirs );
    return $r if $r;

    # try $file-dist in the working dir
    if ( -r "./$file-dist" ) {
        $self->audit("\tfound $file-dist in ./");
        return "$working_directory/$file-dist";
    }

    return $self->error( "could not find $file",
        fatal   => $fatal,
        debug   => $debug,
    );
}

sub get_datetime_from_epoch {
    my ( $self, $time ) = @_;
    my @lt = localtime( $time || time() );
    return sprintf '%04d-%02d-%02d %02d:%02d:%02d', $lt[5] + 1900, $lt[4] + 1,
           $lt[3], $lt[2], $lt[1], $lt[0];
}

sub get_errors {
    my $self = shift;
    return $self->{errors};
}

sub get_last_error {
    my $self = shift;
    return $self->{errors}[-1]->{errmsg} if scalar @{ $self->{errors} };
    return;
}

sub get_version {
    print "Provision::Unix version $VERSION\n";
    return $VERSION;
};

sub progress {
    my $self = shift;
    my %p = validate(
        @_,
        {   'num'  => { type => SCALAR },
            'desc' => { type => SCALAR, optional => 1 },
            'err'  => { type => SCALAR, optional => 1 },
        },
    );

    my $num  = $p{num};
    my $desc = $p{desc};
    my $err  = $p{err};

    my $msg_length = length $desc;
    my $to_print   = 10;
    my $max_print  = 70 - $msg_length;

    # if err, print and return
    if ( $err ) {
        if ( length( $err ) == 1 ) {
            foreach my $error ( @{ $self->{errors} } ) {
                print {*STDERR} "\n$error->{errloc}\t$error->{errmsg}\n";
            }
        }
        else {
            print {*STDERR} "\n\t$err\n";
        }
        return $self->error( $err, fatal => 0, debug => 0 );
    }

    if ( $msg_length > 54 ) {
        die "max message length is 55 chars\n";
    }

    print {*STDERR} "\r[";
    foreach ( 1 .. $num ) {
        print {*STDERR} "=";
        $to_print--;
        $max_print--;
    }

    while ($to_print) {
        print {*STDERR} ".";
        $to_print--;
        $max_print--;
    }

    print {*STDERR} "] $desc";
    while ($max_print) {
        print {*STDERR} " ";
        $max_print--;
    }

    if ( $num == 10 ) { print {*STDERR} "\n" }

    return 1;
}

sub _find_readable {
    my $self = shift;
    my $file = shift;
    my $dir  = shift or return;    # breaks recursion at end of @_

    #$self->audit("looking for $file in $dir") if $self->{debug};

    if ( -r "$dir/$file" ) {
        no warnings;
        $self->audit("\tfound in $dir");
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

Each class (DNS, User, VirtualOS, Web) has a general module that 
contains the logic for selecting and dispatching requests to sub-classes which
are implementation specific. Selecting and dispatching is done based on the
environment and configuration file settings at run time.

For example, Provision::Unix::DNS contains all the general logic for dns
operations (create a zone, record, alias, etc). Subclasses contain 
specific information such as how to provision a DNS record for nictool,
BIND, or tinydns.

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

