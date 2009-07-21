package Provision::Unix::Utility;

our $VERSION = '5.19';

use strict;
use warnings;

use lib "lib";

use Cwd;
use Carp;
use English qw( -no_match_vars );
use File::Copy;
use Params::Validate qw(:all);
use Scalar::Util qw( openhandle );

use vars qw($fatal_err $err $prov);

sub new {

    my $class = shift;
    my %p     = validate(
        @_,
        {   prov  => { type => OBJECT, optional => 1 },
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
    return $self;
}

=for TODO

Go through this file and replace all the instances of carp and croak with calls
to $prov->error.

Replace all general logging with calls to $prov->status. 

This will conform with the coding standards of the rest of Provision Unix,
which uses those functions extensively for logging and error reporting.

=cut

sub ask {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'question' => { type => SCALAR,  optional => 0 },
            'password' => { type => BOOLEAN, optional => 1, default => 0 },
            'default'  => { type => SCALAR,  optional => 1 },
            'timeout'  => { type => SCALAR,  optional => 1 },
            'test_ok'  => { type => BOOLEAN, optional => 1 },
        }
    );

    # only prompt if we are running interactively
    unless ( $self->is_interactive() ) {
        warn "\tnot interactive, can not prompt!\n";
        return $p{default};
    }

    # basic input validation
    if ( $p{question} !~ m{\A \p{Any}* \z}xms ) {
        return $prov->error( "ask called with \'$p{question}\' which looks unsafe." );
    }

    my $response;

    return $p{test_ok} if defined $p{test_ok};

PROMPT:
    print "Please enter $p{question}";
    print " [$p{default}]" if ( $p{default} && !$p{password} );
    print ": ";

    system "stty -echo" if $p{password};

    if ( $p{timeout} ) {
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm $p{timeout};
            $response = <STDIN>;
            alarm 0;
        };
        if ($EVAL_ERROR) {
            $EVAL_ERROR eq "alarm\n" ? print "timed out!\n" : warn;
        }
    }
    else {
        $response = <STDIN>;
    }

    if ( $p{password} ) {
        print "Please enter $p{question} (confirm): ";
        my $response2 = <STDIN>;
        unless ( $response eq $response2 ) {
            print "\nPasswords don't match, try again.\n";
            goto PROMPT;
        }
        system "stty echo";
        print "\n";
    }

    chomp $response;

    # if they typed something, return it
    return $response if $response;

    # otherwise, return the default if available
    return $p{default} if $p{default};

    # and finally return empty handed
    return "";
}

sub archive_expand {

    my $self = shift;

    my %p = validate(
        @_,
        {   'archive' => { type => SCALAR,  optional => 0, },
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $archive = $p{archive};
    my $debug   = $p{debug};

    my $r;

    if ( !-e $archive ) {
        if    ( -e "$archive.tar.gz" )  { $archive = "$archive.tar.gz" }
        elsif ( -e "$archive.tgz" )     { $archive = "$archive.tgz" }
        elsif ( -e "$archive.tar.bz2" ) { $archive = "$archive.tar.bz2" }
        else {
            return $prov->error( "file $archive is missing!",
                fatal   => $p{fatal},
            );
        }
    }

    $prov->audit("archive_expand: found $archive");

    $ENV{PATH} = '/bin:/usr/bin'; # do this or taint checks will blow up on ``

    if ( $archive !~ /[bz2|gz]$/ ) {
        return $prov->error( "I don't know how to expand $archive!",
            fatal => $p{fatal},
        );
    }

    # find these binaries, we need them to inspect and expand the archive
    my $tar  = $self->find_bin( bin => 'tar',  debug => $debug );
    my $file = $self->find_bin( bin => 'file', debug => $debug );

    my %types = (
        gzip => {
            content => 'gzip',
            bin     => 'gunzip',
        },
        bzip => {
            content => 'b(un)?zip2',    # on BSD bunzip2, on Linux bzip2
            bin     => 'bunzip2',
        },
    );

    my $type
        = $archive =~ /bz2$/ ? 'bzip'
        : $archive =~ /gz$/  ? 'gzip'
        :                      die 'unknown archive type';

    # Check to make sure the archive contents match the file extension
    # this shouldn't be necessary but the world isn't perfect. Sigh.
    unless ( grep ( /$types{$type}{content}/, `$file $archive` ) ) {
        return $prov->error( "$archive not a $type compressed file",
            fatal   => $p{fatal},
        );
    }

    my $bin = $self->find_bin( bin => $types{$type}{bin}, debug => $debug );

    if ($self->syscmd(
            cmd   => "$bin -c $archive | $tar -xf -",
            debug => 0
        )
        )
    {
        print $self->_formatted( "archive_expand: extracting $archive", "ok" )
            if $debug;
        return 1;
    }

    return $prov->error( "error extracting $archive",
        fatal   => $p{fatal},
    );
}

sub chmod {

    my $self = shift;

    my %p = validate(
        @_,
        {   'file'        => { type => SCALAR,  optional => 1, },
            'file_or_dir' => { type => SCALAR,  optional => 1, },
            'dir'         => { type => SCALAR,  optional => 1, },
            'mode'        => { type => SCALAR,  optional => 0, },
            'sudo'        => { type => BOOLEAN, optional => 1, default => 0 },
            'fatal'       => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'       => { type => BOOLEAN, optional => 1, default => 1 },
            'test_ok'     => { type => BOOLEAN, optional => 1 },
        }
    );

    my ( $file, $mode, $debug ) = ( $p{file}, $p{mode}, $p{debug} );

    # look for file, but if missing, check file_or_dir and dir
    $file ||= $p{file_or_dir} ||= $p{dir};

    if ( !$file ) {
        return $prov->error( "invalid params, see perldoc Provision::Unix::Utility");
    }

    if ( $p{sudo} ) {
        my $chmod = $self->find_bin( bin => 'chmod', debug => $p{debug} );
        my $sudo  = $self->sudo();
        my $cmd   = "$sudo $chmod $mode $file";
        $prov->audit( "cmd: " . $cmd );
        if ( !$self->syscmd( cmd => $cmd, debug => 0 ) ) {
            return $prov->error( "couldn't chmod $file: $!",
                fatal   => $p{fatal},
                debug   => $p{debug},
            );
        }
    }

    $prov->audit("chmod: chmod $mode $file.");

    # note how we convert a string ($mode) to an octal value. Very Important!
    unless ( chmod oct($mode), $file ) {
        return $prov->error( "couldn't chmod $file: $!",
            fatal   => $p{fatal},
            debug   => $p{debug},
        );
    }
}

sub chown {

    my $self = shift;

    my %p = validate(
        @_,
        {   'file'        => { type => SCALAR, optional => 1, },
            'file_or_dir' => { type => SCALAR, optional => 1, },
            'dir'         => { type => SCALAR, optional => 1, },
            'uid'         => { type => SCALAR, optional => 0, },
            'gid'         => { type => SCALAR, optional => 1, default => -1 },
            'sudo' => { type => BOOLEAN, optional => 1, default => 0 },
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => 1 },
            'test_ok' => { type => BOOLEAN, optional => 1 },
        }
    );

    my ( $uid, $debug ) = ( $p{uid}, $p{debug} );

    # look for file, but if missing, check file_or_dir and dir
    my $file = $p{file} || $p{file_or_dir} || $p{dir};

    if ( !$file ) {
        return $prov->error( "you did not set a required parameter!",
            fatal   => $p{fatal},
        );
    }

    $prov->audit("chown: preparing to chown $uid $file");

    if ( ! -e $file ) {
        return $prov->error( "file $file does not exist!",
            fatal   => $p{fatal},
        );
    }

    # sudo forces us to use the system chown instead of the perl builtin
    if ( $p{sudo} ) {
        return $self->chown_system(
            dir   => $file,
            user  => $uid,
            group => $p{gid},
            fatal => $p{fatal},
            debug => $debug,
        );
    }

    # if uid or gid is not numeric, convert it
    my ( $nuid, $ngid );

    if ( $uid =~ /\A[0-9]+\z/ ) {
        $nuid = int($uid);
        $prov->audit("using $nuid from int($uid)");
    }
    else {
        $nuid = getpwnam($uid);
        if ( !defined $nuid ) {
            return $prov->error( "failed to get uid for $uid. FATAL!",
                fatal   => $p{fatal},
                debug   => $debug,
            );
        }
        $prov->audit("converting $uid to a number: $nuid");
    }

    if ( $p{gid} =~ /\A[0-9\-]+\z/ ) {
        $ngid = int( $p{gid} );
        $prov->audit("using $ngid from int($p{gid})");
    }
    else {
        $ngid = getgrnam( $p{gid} );
        if ( !defined $ngid ) {
            return $prov->error( "failed to get gid for $p{gid}. FATAL!",
                fatal   => $p{fatal},
                debug   => $p{debug},
            );
        }
        $prov->audit("converting $p{gid} to a number: $ngid");
    }

    if ( !chown $nuid, $ngid, $file ) {
        return $prov->error( "couldn't chown $file: $!",
            fatal   => $p{fatal},
            debug   => $p{debug},
        );
    }

    return 1;
}

sub chown_system {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'file'        => { type => SCALAR,  optional => 1, },
            'file_or_dir' => { type => SCALAR,  optional => 1, },
            'dir'         => { type => SCALAR,  optional => 1, },
            'user'        => { type => SCALAR,  optional => 0, },
            'group'       => { type => SCALAR,  optional => 1, },
            'recurse'     => { type => BOOLEAN, optional => 1, },
            'fatal'       => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'       => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $dir, $user, $group, $recurse, $fatal, $debug )
        = ( $p{dir}, $p{user}, $p{group}, $p{recurse}, $p{fatal}, $p{debug} );

    # look for file, but if missing, check file_or_dir and dir
    $dir ||= $p{file_or_dir} ||= $p{file};

    if ( !$dir ) {
        print "\tchown_system was passed an invalid argument(s).\n" if $debug;
        croak if $p{fatal};
    }

    my $chown = $self->find_bin(
        bin   => 'chown',
        fatal => $fatal,
        debug => $debug,
    );

    my $cmd = $chown;
    $cmd .= " -R"     if $recurse;
    $cmd .= " $user";
    $cmd .= ":$group" if $group;
    $cmd .= " $dir";

    print "chown_system: cmd: $cmd\n" if $debug;

    if ( !$self->syscmd( cmd => $cmd, fatal => 0, debug => 0 ) ) {
        return $prov->error( "couldn't chown with $cmd: $!",
            fatal   => $p{fatal},
        );
    }

    if ($debug) {
        print "Recursively " if $recurse;
        print "changed $dir to be owned by $user\n\n";
    }
    return 1;
}

sub clean_tmp_dir {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'dir'   => { type => SCALAR,  optional => 0, },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $dir = $p{dir};

    # remember where we started
    my $before = cwd;

    if ( !chdir $dir ) {
        return $prov->error( "couldn't chdir to $dir: $!",
            fatal => $p{fatal},
        );
    }

    foreach ( $self->get_dir_files( dir => $dir ) ) {
        next unless $_;

        my ($file) = $_ =~ /^(.*)$/;

        print "\tdeleting file: $file\n" if $p{debug};

        if ( -f $file ) {
            unless ( unlink $file ) {
                $self->file_delete( file => $file, debug => $p{debug} );
            }
        }
        elsif ( -d $file ) {
            use File::Path;
            rmtree $file or croak "clean_tmp_dir: couldn't delete $file\n";
        }
        else {
            print "Cannot delete unknown entity: $file?\n";
        }
    }

    chdir($before);
    return 1;
}

sub cwd_source_dir {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'dir'   => { type => SCALAR,  optional => 0, },
            'src'   => { type => SCALAR,  optional => 1, },
            'sudo'  => { type => BOOLEAN, optional => 1, },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $dir, $src, $sudo, $fatal, $debug )
        = ( $p{dir}, $p{src}, $p{sudo}, $p{fatal}, $p{debug} );

    if ( -e $dir && !-d $dir ) {
        croak
            "Something (other than a directory) is at $dir and that's my build directory. Please remove it and try again!\n";
    }

    if ( !-d $dir ) {

        # use the perl builtin mkdir
        _try_mkdir( $dir, $debug );

        if ( !-d $dir ) {
            print "cwd_source_dir: trying again with system mkdir...\n";
            $self->mkdir_system( dir => $dir, debug => $debug );

            if ( !-d $dir ) {
                print
                    "cwd_source_dir: trying one last time with $sudo mkdir -p....\n";
                $self->mkdir_system(
                    dir   => $dir,
                    sudo  => 1,
                    debug => $debug
                );
                croak "Couldn't create $dir.\n";
            }
        }
    }

    chdir($dir) or croak "cwd_source_dir: FAILED to cd to $dir: $!\n";
    return 1;
}

sub _try_mkdir {
    my ( $foo, $debug ) = @_;
    print "_try_mkdir: trying to create $foo\n" if $debug;
    mkdir( $foo, oct("0755") )
        or warn "cwd_source_dir: mkdir $foo failed: $!";
}

sub file_archive {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'file'  => { type => SCALAR },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            'sudo'  => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $file = $p{file};

    my $date = time;

    if ( !-e $file ) {
        return $prov->error( "file ($file) is missing!",
            debug   => $p{debug},
            fatal   => $p{fatal},
        );
    }

    # see if we can write to both files (new & archive) with current user
    if ($self->is_writable(
            file  => $file,
            debug => $p{debug},
            fatal => $p{fatal},
        )
        && $self->is_writable(
            file  => "$file.$date",
            debug => $p{debug},
            fatal => $p{fatal},
        )
        )
    {

        # we have permission, use perl's native copy
        if ( copy( $file, "$file.$date" ) ) {
            $prov->audit("file_archive: $file backed up to $file.$date");
            return "$file.$date" if -e "$file.$date";
        }
    }

    # we failed with existing permissions, try to escalate
    if ( $< != 0 )    # we're not root
    {
        if ( $p{sudo} ) {
            my $sudo = $self->sudo( debug => $p{debug}, fatal => $p{fatal} );
            my $cp = $self->find_bin(
                bin   => 'cp',
                debug => $p{debug},
                fatal => $p{fatal},
            );

            if ( $sudo && $cp && -x $cp ) {
                $self->syscmd(
                    cmd   => "$sudo $cp $file $file.$date",
                    debug => $p{debug},
                    fatal => $p{fatal},
                );
            }
            else {
                $prov->audit(
                    "file_archive: sudo or cp was missing, could not escalate."
                );
            }
        }
    }

    if ( -e "$file.$date" ) {
        $prov->audit("file_archive: $file backed up to $file.$date");
        return "$file.$date";
    }

    return $prov->error( "backup of $file to $file.$date failed: $!",
        fatal   => $p{fatal},
        debug   => $p{debug},
    );
}

sub file_delete {

    my $self = shift;

    my %p = validate(
        @_,
        {   'file'  => { type => SCALAR },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
            'sudo'  => { type => BOOLEAN, optional => 1, default => 0 },
        }
    );

    my ( $file, $fatal, $debug ) = ( $p{file}, $p{fatal}, $p{debug} );

    if ( !-e $file ) {
        return $prov->error(  "checking $file existence", fatal => $p{fatal} );
    }
    $self->_formatted( $err, "ok" ) if $debug;

    $err = "file_delete: checking write permissions";
    if ( !-w $file ) {
        $self->_formatted( $err, "NO" ) if $debug;
    }
    else {
        $self->_formatted( $err, "ok" ) if $debug;

        $err = "file_delete: deleting file $file";
        if ( unlink $file ) {
            $self->_formatted( $err, "ok" ) if $debug;
            return 1;
        }

        $self->_formatted( $err, "FAILED" ) if $debug;
        croak "\t\t $!" if $fatal;
        warn "\t\t $!";
    }

    if ( !$p{sudo} ) {    # all done
        return -e $file ? undef : 1;
    }

    $err = "file_delete: trying with system rm";
    my $rm = $self->find_bin( bin => "rm", debug => $debug );

    my $rm_command = "$rm -f $file";

    if ( $< != 0 ) {      # we're not running as root
        my $sudo = $self->sudo( debug => $debug );
        $rm_command = "$sudo $rm_command";
        $err .= " (sudo)";
    }

    if ($self->syscmd(
            cmd   => $rm_command,
            fatal => $fatal,
            debug => $debug,
        )
        )
    {
        $self->_formatted( $err, "ok" ) if $debug;
    }
    else {
        $self->_formatted( $err, "FAILED" ) if $debug;
        croak "\t\t $!" if $fatal;
        warn "\t\t $!";
    }

    return -e $file ? undef : 1;
}

sub file_get {

    my $self = shift;

    my %p = validate(
        @_,
        {   'url'     => { type => SCALAR },
            'timeout' => { type => SCALAR, optional => 1, },
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $url, $debug ) = ( $p{url}, $p{debug} );

    my $found;

    print "file_get: fetching $url\n" if $debug;

    my ($ua, $response);
    eval "require LWP::Simple";
    if ( ! $EVAL_ERROR ) {
#        $response = LWP::Simple::getstore($url);
    };

    my $fetchbin;
    if ( $OSNAME eq "freebsd" ) {
        $fetchbin = $self->find_bin(
            bin   => 'fetch',
            debug => $debug,
            fatal => 0,
        );
        if ( $fetchbin && -x $fetchbin ) {
            $found = $fetchbin;
            $found .= " -q" unless $debug;
        }
    }
    elsif ( $OSNAME eq "darwin" ) {
        $fetchbin = $self->find_bin(
            bin   => 'curl',
            debug => $debug,
            fatal => 0
        );
        if ( $fetchbin && -x $fetchbin ) {
            $found = "$fetchbin -O";
            $found .= " -s " if !$debug;
        }
    }

    if ( !$found ) {
        $fetchbin = $self->find_bin(
            bin   => 'wget',
            debug => $debug,
            fatal => $p{fatal},
        );
        if ( $fetchbin && -x $fetchbin ) { $found = $fetchbin; }
    }

    if ( !$found ) {

        # TODO: should use LWP here if available
        return $prov->error( "couldn't find wget. Please install it.",
            fatal => $p{fatal},
        );
    }

    my $fetchcmd = "$found $url";
    print "fetchcmd: $fetchcmd\n" if $debug;

    my $r;

    # timeout stuff goes here.
    if ( $p{timeout} ) {
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm $p{timeout};
            $r = $self->syscmd( cmd => $fetchcmd, debug => $debug );
            alarm 0;
        };
    }
    else {
        $r = $self->syscmd( cmd => $fetchcmd, debug => $debug );
    }

    if ($EVAL_ERROR) {    # propagate unexpected errors
        print "timed out!\n" if $EVAL_ERROR eq "alarm\n";
        $prov->error( $EVAL_ERROR, fatal => $p{fatal} );
    }

    if ( !$r ) {
        return $prov->error( "error executing $fetchcmd", fatal => $p{fatal} );
    }

    return 1;
}

sub file_is_newer {

    my $self = shift;

    my %p = validate(
        @_,
        {   f1    => { type => SCALAR },
            f2    => { type => SCALAR },
            debug => { type => SCALAR, optional => 1, default => 1 },
        }
    );

    my ( $file1, $file2 ) = ( $p{f1}, $p{f2} );

    # get file attributes via stat
    # (dev,ino,mode,nlink,uid,gid,rdev,size,atime,mtime,ctime,blksize,blocks)

    print "file_is_newer: checking age of $file1 and $file2\n" if $p{debug};

    use File::stat;
    my $stat1 = stat($file1)->mtime;
    my $stat2 = stat($file2)->mtime;

    print "\t timestamps are $stat1 and $stat2\n" if $p{debug};

    return 1 if ( $stat2 > $stat1 );
    return;

    # I could just:
    #
    # if ( stat($f1)[9] > stat($f2)[9] )
    #
    # but that forces the reader to read the man page for stat
    # to see what's happening
}

sub file_read {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'file'       => { type => SCALAR },
            'max_lines'  => { type => SCALAR, optional => 1 },
            'max_length' => { type => SCALAR, optional => 1 },
            'fatal'      => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'      => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $filename, $max_lines, $max_length, $debug )
        = ( $p{file}, $p{max_lines}, $p{max_length}, $p{debug} );

    if ( !-e $filename ) {
        return $prov->error( "$filename does not exist!",
            fatal   => $p{fatal},
            debug   => $p{debug},
        );
    }

    if ( !-r $filename ) {
        $err = "file_read: $filename is not readable!";
        croak $err if $p{fatal};
        carp $err  if $p{debug};
        return;
    }

    open my $FILE, '<', $filename or $fatal_err++;

    if ($fatal_err) {
        $err = "file_read: could not open $filename: $OS_ERROR";
        croak $err if $p{fatal};
        carp $err  if $p{debug};
        return;
    }

    my ( $line, @lines );

    if ($max_lines) {
        while ( my $i < $max_lines ) {
            if ($max_length) {
                $line = substr <$FILE>, 0, $max_length;
            }
            else {
                $line = <$FILE>;
            }
            push @lines, $line;
            $i++;
        }
        chomp @lines;
        close $FILE;
        return @lines;
    }

#TODO, make max_length work with slurp mode, without doing something ugly like
# reading in the entire line and then truncating it.

    chomp( @lines = <$FILE> );
    close $FILE;

    return @lines;
}

sub file_mode {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'file'  => { type => SCALAR },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 0 },
        }
    );

    if ( !-e $p{file} ) {
        $err = "argument file to sub file_mode does not exist!\n";
        die $err if $p{fatal};
        warn $err;
    }

    my $file = $p{file};
    warn "file is: $file \n" if $p{debug};

    # one way to get file mode
    #    my $raw_mode = stat($file)->[2];
    ## no critic
    my $mode = sprintf "%04o", stat($file)->[2] & 07777;

    # another way to get it
    #    my $st = stat($file);
    #    my $mode = sprintf "%lo", $st->mode & 07777;

    warn "file $file has mode: $mode \n" if $p{debug};

    return $mode;
}

sub file_write {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'file'   => { type => SCALAR },
            'lines'  => { type => ARRAYREF },
            'append' => { type => BOOLEAN, optional => 1, default => 0 },
            'mode'  => { type => SCALAR,  optional => 1 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $file = $p{file};

    if ( -d $file ) {
        carp "file_write FAILURE: $file is a directory!" if $p{debug};
        croak if $p{fatal};
        return;
    }

    if (-f $file
        && !$self->is_writable(
            file  => $file,
            debug => $p{debug},
            fatal => 0,
        )
        )
    {
        $err = "file_write FAILURE: $file is not writable!";
        croak $err if $p{fatal};
        carp $err  if $p{debug};
        return;
    }

    my $write_mode = '>';    # (over)write
    $write_mode = '>>' if $p{append};

    open my $HANDLE, $write_mode, $file or $fatal_err++;

    if ($fatal_err) {
        carp "file_write: couldn't open $file: $!";
        croak if $p{fatal};
        return;
    }

    my $m = "writing";
    $m = "appending" if $p{append};
    $self->_formatted( "file_write: opened $file for $m", "ok" ) if $p{debug};

    my $c = 0;
    for ( @{ $p{lines} } ) { chomp; print $HANDLE "$_\n"; $c++ }
    close $HANDLE or return;

    $self->_formatted( "file_write: wrote $c lines to $file", "ok" )
        if $p{debug};

    # set file permissions mode if requested
    if ( $p{mode} ) {
        $self->chmod(
            file  => $file,
            mode  => $p{mode},
            debug => $p{debug},
        );
    }

    return 1;
}

sub files_diff {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'f1'    => { type => SCALAR },
            'f2'    => { type => SCALAR },
            'type'  => { type => SCALAR, optional => 1, default => 'text' },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $f1, $f2, $type, $debug ) = ( $p{f1}, $p{f2}, $p{type}, $p{debug} );

    if ( !-e $f1 || !-e $f2 ) {
        print "files_diff: $f1 or $f2 does not exist!\n";
        croak if $p{fatal};
        return -1;
    }

    my $FILE;

    if ( $type eq "text" ) {
### TODO
        # use file here to make sure files are ASCII
        #
        $self->_formatted("files_diff: comparing $f1 and $f2 using diff")
            if $debug;

        my $diff = $self->find_bin( bin => 'diff', debug => $debug );

        my $r = `$diff $f1 $f2`;
        chomp $r;
        return $r;
    }

    $self->_formatted("files_diff: comparing $f1 and $f2 using md5")
        if $debug;

    eval { require Digest::MD5 };
    if ($EVAL_ERROR) {
        carp "couldn't load Digest::MD5!";
        croak if $p{fatal};
        return;
    }

    $self->_formatted( "\t Digest::MD5 loaded", "ok" ) if $debug;

    my @md5sums;

FILE: foreach my $f ( $f1, $f2 ) {
        my ( $sum, $changed );

        $self->_formatted("$f: checking md5") if $debug;

        # if the file is already there, read it in.
        if ( -f "$f.md5" ) {
            $sum = $self->file_read( file => "$f.md5" );
            $self->_formatted( "\t md5 file exists", "ok" ) if $debug;
        }

   # if the md5 file is missing, invalid, or older than the file, recompute it
        if (   !-f "$f.md5"
            or $sum !~ /[0-9a-f]+/i
            or
            $self->file_is_newer( f1 => "$f.md5", f2 => $f, debug => $debug )
            )
        {
            my $ctx = Digest::MD5->new;
            open $FILE, '<', $f;
            $ctx->addfile(*$FILE);
            $sum = $ctx->hexdigest;
            close($FILE);
            $changed++;
            $self->_formatted("\t created md5: $sum") if $debug;
        }

        push( @md5sums, $sum );

        # update the md5 file
        if ($changed) {
            $self->file_write(
                file  => "$f.md5",
                lines => [$sum],
                debug => $debug
            );
        }
    }

    # compare the two md5 sums
    return if ( $md5sums[0] eq $md5sums[1] );
    return 1;
}

sub find_bin {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'bin'   => { type => SCALAR, },
            'dir'   => { type => SCALAR, optional => 1, },
            'fatal' => { type => SCALAR, optional => 1, default => 1 },
            'debug' => { type => SCALAR, optional => 1, default => 1 },
        },
    );

    my ( $bin, $debug ) = ( $p{bin}, $p{debug} );

    print "find_bin: searching for $bin\n" if $debug;

    my $prefix = "/usr/local";

    if ( $p{dir} && -x "$p{dir}/$bin" ) { return "$p{dir}/$bin"; }
    if ( $bin =~ /^\// && -x $bin ) { return $bin }
    ;    # we got a full path

    my $found
        = -x "$prefix/bin/$bin"       ? "/usr/local/bin/$bin"
        : -x "$prefix/sbin/$bin"      ? "/usr/local/sbin/$bin"
        : -x "$prefix/mysql/bin/$bin" ? "$prefix/mysql/bin/$bin"
        : -x "/bin/$bin"              ? "/bin/$bin"
        : -x "/usr/bin/$bin"          ? "/usr/bin/$bin"
        : -x "/sbin/$bin"             ? "/sbin/$bin"
        : -x "/usr/sbin/$bin"         ? "/usr/sbin/$bin"
        : -x "/opt/local/bin/$bin"    ? "/opt/local/bin/$bin"
        : -x "/opt/local/sbin/$bin"   ? "/opt/local/sbin/$bin"
        : -x cwd . "/$bin"            ? cwd "/$bin"
        :                               undef;

    if ($found) {
        print "find_bin: found $found\n" if $debug;
        return $found;
    }

    $err = "find_bin: WARNING: could not find $bin";
    croak $err if $p{fatal};
    carp $err  if $debug;
    return;
}

sub fstab_list {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    if ( $OSNAME eq "darwin" ) {
        return ['fstab not used on Darwin!'];
    }

    my $fstab = "/etc/fstab";
    if ( !-e $fstab ) {
        print "fstab_list: FAILURE: $fstab does not exist!\n" if $p{debug};
        return;
    }

    my $grep = $self->find_bin( bin => "grep", debug => 0 );
    my @fstabs = `$grep -v cdr $fstab`;

    #	foreach my $fstab (@fstabs)
    #	{}
    #		my @fields = split(" ", $fstab);
    #		#print "device: $fields[0]  mount: $fields[1]\n";
    #	{};
    #	print "\n\n END of fstabs\n\n";

    return \@fstabs;
}

sub get_cpan_config {

    my $ftp = `which ftp`; chomp $ftp;
    my $gzip = `which gzip`; chomp $gzip;
    my $unzip = `which unzip`; chomp $unzip;
    my $tar  = `which tar`; chomp $tar;
    my $make = `which make`; chomp $make;
    my $wget = `which wget`; chomp $wget;

    return 
{
  'build_cache' => q[10],
  'build_dir' => qq[$ENV{HOME}/.cpan/build],
  'cache_metadata' => q[1],
  'cpan_home' => qq[$ENV{HOME}/.cpan],
  'ftp' => $ftp,
  'ftp_proxy' => q[],
  'getcwd' => q[cwd],
  'gpg' => q[],
  'gzip' => $gzip,
  'histfile' => qq[$ENV{HOME}/.cpan/histfile],
  'histsize' => q[100],
  'http_proxy' => q[],
  'inactivity_timeout' => q[5],
  'index_expire' => q[1],
  'inhibit_startup_message' => q[1],
  'keep_source_where' => qq[$ENV{HOME}/.cpan/sources],
  'lynx' => q[],
  'make' => $make,
  'make_arg' => q[],
  'make_install_arg' => q[],
  'makepl_arg' => q[],
  'ncftp' => q[],
  'ncftpget' => q[],
  'no_proxy' => q[],
  'pager' => q[less],
  'prerequisites_policy' => q[follow],
  'scan_cache' => q[atstart],
  'shell' => q[/bin/csh],
  'tar' => $tar,
  'term_is_latin' => q[1],
  'unzip' => $unzip,
  'urllist' => [ 'http://www.perl.com/CPAN/', 'ftp://cpan.cs.utah.edu/pub/CPAN/', 'ftp://mirrors.kernel.org/pub/CPAN', 'ftp://osl.uoregon.edu/CPAN/', 'http://cpan.yahoo.com/' ],
  'wget' => $wget, 
};

}

sub get_dir_files {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'dir'   => { type => SCALAR,  optional => 0, },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $dir, $fatal, $debug ) = ( $p{dir}, $p{fatal}, $p{debug} );

    my @files;

    unless ( -d $dir ) {
        carp "get_dir_files: dir $dir is not a directory!";
        return;
    }

    unless ( opendir D, $dir ) {
        $err = "get_dir_files: couldn't open $dir: $!";
        croak $err if $fatal;
        carp $err  if $debug;
        return;
    }

    while ( defined( my $f = readdir(D) ) ) {
        next if $f =~ /^\.\.?$/;
        push @files, "$dir/$f";
    }

    closedir(D);

    return @files;
}

sub get_my_ips {

    ############################################
    # Usage      : @list_of_ips_ref = $utility->get_my_ips();
    # Purpose    : get a list of IP addresses on local interfaces
    # Returns    : an arrayref of IP addresses
    # Parameters : only - can be one of: first, last
    #            : exclude_locahost  (all 127.0 addresses)
    #            : exclude_internals (192.168, 10., 169., 172.)
    #            : exclude_ipv6
    # Comments   : exclude options are boolean and enabled by default.
    #              tested on Mac OS X and FreeBSD

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'only' => { type => SCALAR, optional => 1, default => 0 },
            'exclude_localhost' =>
                { type => BOOLEAN, optional => 1, default => 1 },
            'exclude_internals' =>
                { type => BOOLEAN, optional => 1, default => 1 },
            'exclude_ipv6' =>
                { type => BOOLEAN, optional => 1, default => 1 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $debug = $p{debug};

    my $ifconfig = $self->find_bin( bin => "ifconfig", debug => 0 );
    my $grep     = $self->find_bin( bin => "grep",     debug => 0 );
    my $cut      = $self->find_bin( bin => "cut",      debug => 0 );

    my $once = 0;

TRY:
    my $cmd = "$ifconfig | $grep inet ";

    if ( $p{exclude_ipv6} ) {
        $cmd .= "| $grep -v inet6 ";
    }

    $cmd .= "| $cut -d' ' -f2 ";

    if ( $p{exclude_localhost} ) {
        $cmd .= "| $grep -v '^127.0.0' ";
    }

    if ( $p{exclude_internals} ) {
        $cmd .= "| $grep -v '^192.168.' | $grep -v '^10.' "
            . "| $grep -v '^172.16.'  | $grep -v '^169.254.' ";
    }

    if ( $p{only} eq "first" ) {
        my $head = $self->find_bin( bin => "head", debug => 0 );
        $cmd .= "| $head -n1 ";
    }
    elsif ( $p{only} eq "last" ) {
        my $tail = $self->find_bin( bin => "tail", debug => 0 );
        $cmd .= "| $tail -n1 ";
    }

    #carp "get_my_ips command: $cmd" if $debug;
    my @ips = `$cmd`;
    chomp @ips;

    # this keeps us from failing if the box has only internal IP space
    if ( @ips < 1 || $ips[0] eq "" ) {
        carp "yikes, you really don't have any public IPs?!" if $debug;
        $p{exclude_internals} = 0;
        $once++;
        goto TRY if ( $once < 2 );
    }

    return \@ips;
}

sub get_the_date {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'bump'  => { type => SCALAR,  optional => 1, },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $bump, $fatal, $debug ) = ( $p{bump}, $p{fatal}, $p{debug} );

    my $time = time;
    print "time: " . time . "\n" if $debug;

    $bump = $bump ? $bump * 86400 : 0;
    my $offset_time = time - $bump;
    print "selected time: $offset_time\n" if $debug;

    # load Date::Format to get the time2str function
    eval { require Date::Format };
    if ( !$EVAL_ERROR ) {

        my $ss = Date::Format::time2str( "%S", ($offset_time) );
        my $mn = Date::Format::time2str( "%M", ($offset_time) );
        my $hh = Date::Format::time2str( "%H", ($offset_time) );
        my $dd = Date::Format::time2str( "%d", ($offset_time) );
        my $mm = Date::Format::time2str( "%m", ($offset_time) );
        my $yy = Date::Format::time2str( "%Y", ($offset_time) );
        my $lm = Date::Format::time2str( "%m", ( $offset_time - 2592000 ) );

        print "get_the_date: $yy/$mm/$dd $hh:$mn\n" if $debug;
        return $dd, $mm, $yy, $lm, $hh, $mn, $ss;
    }

    #  0    1    2     3     4    5     6     7     8
    # ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
    #                    localtime(time);
    # 4 = month + 1   ( see perldoc localtime)
    # 5 = year + 1900     ""

    my @fields = localtime($offset_time);

    my $ss = sprintf( "%02i", $fields[0] );    # seconds
    my $mn = sprintf( "%02i", $fields[1] );    # minutes
    my $hh = sprintf( "%02i", $fields[2] );    # hours (24 hour clock)

    my $dd = sprintf( "%02i", $fields[3] );        # day of month
    my $mm = sprintf( "%02i", $fields[4] + 1 );    # month
    my $yy = ( $fields[5] + 1900 );                # year

    print "get_the_date: $yy/$mm/$dd $hh:$mn\n" if $debug;
    return $dd, $mm, $yy, undef, $hh, $mn, $ss;
}

sub get_mounted_drives {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $mount = $self->find_bin(
        bin   => 'mount',
        debug => $p{debug},
        fatal => 0
    );

    unless ( -x $mount ) {
        carp "get_mounted_drives: I couldn't find mount!";
        croak if $p{fatal};
        return 0;
    }

    $ENV{PATH} = "";
    my %hash;
    foreach (`$mount`) {
        my ( $d, $m ) = $_ =~ /^(.*) on (.*) \(/;

        #		if ( $m =~ /^\// && $d =~ /^\// )  # mount drives that begin with /
        if ( $m && $m =~ /^\// )    # only mounts that begin with /
        {
            print "adding: $m \t $d\n" if $p{debug};
            $hash{$m} = $d;
        }
    }
    return \%hash;
}

sub install_if_changed {

    my $self = shift;

    # parameter validation here

    my %p = validate(
        @_,
        {   'newfile'  => { type => SCALAR, optional => 0, },
            'existing' => { type => SCALAR, optional => 0, },
            'mode'     => { type => SCALAR, optional => 1, },
            'uid'      => { type => SCALAR, optional => 1, },
            'gid'      => { type => SCALAR, optional => 1, },
            'sudo'     => { type => SCALAR, optional => 1, default => 0 },
            'notify'   => { type => SCALAR, optional => 1, },
            'email' =>
                { type => SCALAR, optional => 1, default => 'postmaster' },
            'clean'   => { type => SCALAR, optional => 1, default => 1 },
            'archive' => { type => SCALAR, optional => 1, default => 0 },
            'fatal'   => { type => SCALAR, optional => 1, default => 1 },
            'debug'   => { type => SCALAR, optional => 1, default => 1 },
        },
    );

    my ( $newfile, $existing, $mode, $uid, $gid, $email, $debug ) = (
        $p{newfile}, $p{existing}, $p{mode}, $p{uid}, $p{gid}, $p{email},
        $p{debug}
    );

    if ( $newfile !~ /\// ) {

        # relative filename given
        carp "relative filename given, use complete paths "
            . "for more predicatable results!";

        carp "working directory is " . cwd();
    }

    # make sure the new file exists
    if ( !-e $newfile ) {
        $err = "the file to install ($newfile) does not exist, ERROR!\n";
        croak $err if $p{fatal};
        carp $err  if $debug;
        return;
    }

    # make sure new file is a normal file
    if ( !-f $newfile ) {
        $err = "the file to install ($newfile) is not a file, ERROR!\n";
        croak $err if $p{fatal};
        carp $err  if $debug;
        return;
    }

    my $sudo = $p{sudo};

    # make sure existing and new are writable
    if (!$self->is_writable(
            file  => $existing,
            debug => $debug,
            fatal => 0,
        )
        || !$self->is_writable(
            file  => $newfile,
            debug => $debug,
            fatal => 0,
        )
        )
    {

        # if we are root and did not have permissions
        if ( $UID == 0 ) {

            # sudo won't do us any good!
            croak if $p{fatal};
            return;
        }

        if ( $p{sudo} ) {
            $sudo = $self->find_bin(
                bin   => 'sudo',
                fatal => 0,
                debug => 0
            );
            if ( !-x $sudo ) {
                carp "FAILED: you are not root, sudo is not installed,"
                    . " and you don't have permission to write to "
                    . " $newfile and $existing. Sorry, I can't go on!\n";
                croak if $p{fatal};
                return;
            }
        }
    }

    my $diffie = $self->files_diff(
        f1    => $newfile,
        f2    => $existing,
        type  => "text",
        debug => $debug
    );

    # if the target file exists, get the differences
    if ( -e $existing ) {
        if ( !$diffie ) {
            print "install_if_changed: $existing is already up-to-date.\n"
                if $debug;
            unlink $newfile if $p{clean};
            return 2;
        }
    }

    $self->_formatted("install_if_changed: checking $existing") if $debug;

    # set file ownership on the new file
    if ( $uid && $gid ) {
        $self->chown(
            file_or_dir => $newfile,
            uid         => $uid,
            gid         => $gid,
            sudo        => $sudo,
            debug       => $debug,
        );
    }

    # set file permissions on the new file
    if ( $mode && -e $existing ) {
        $self->chmod(
            file_or_dir => $existing,
            mode        => $mode,
            sudo        => $sudo,
            debug       => $debug,
        );
    }

    # email diffs to admin
    if ( $p{notify} && -f $existing ) {

        eval { require Mail::Send; };

        if ($EVAL_ERROR) {
            carp "ERROR: could not send notice, Mail::Send is not installed!";
            goto EMAIL_SKIPPED;
        }

        my $msg = Mail::Send->new;
        $msg->subject("$existing updated by $0");
        $msg->to($email);
        my $email_message = $msg->open;

        print $email_message
            "This message is to notify you that $existing has been altered. The difference between the new file and the old one is:\n\n";

        print $email_message $diffie;
        $email_message->close;

    EMAIL_SKIPPED:
    }

    # archive the existing file
    if ( -e $existing && $p{archive} ) {
        $self->file_archive( file => $existing, debug => $debug );
    }

    # install the new file
    if ($sudo) {
        my $cp = $self->find_bin( bin => 'cp', debug => $debug );

        # make a backup of the existing file
        $self->syscmd(
            cmd   => "$sudo $cp $existing $existing.bak",
            debug => $debug
        ) if ( -e $existing );

        # install the new one
        if ( $p{clean} ) {
            $self->syscmd(
                cmd   => "$sudo  mv $newfile $existing",
                debug => $debug
            );
        }
        else {
            $self->syscmd(
                cmd   => "$sudo $cp $newfile $existing",
                debug => $debug
            );
        }
    }
    else {

        # back up the existing file
        if ( -e $existing ) {
            copy( $existing, "$existing.bak" );
        }

        if ( $p{clean} ) {
            unless ( move( $newfile, $existing ) ) {
                $err = "install_if_changed: copy $newfile to $existing";
                $self->_formatted( $err, "FAILED" );
                croak "$err: $!" if $p{fatal};
                carp "$err: $!";
                return;
            }
        }
        else {
            unless ( copy( $newfile, $existing ) ) {
                $err = "install_if_changed: copy $newfile to $existing";
                $self->_formatted( $err, "FAILED" );
                croak "$err: $!" if $p{fatal};
                carp "$err: $!";
                return;
            }
        }
    }

    # set ownership on the existing file
    if ( $uid && $gid ) {
        $self->chown(
            file_or_dir => $existing,
            uid         => $uid,
            gid         => $gid,
            sudo        => $sudo,
            debug       => 0
        );
    }

    # set file permissions (paranoid)
    if ($mode) {
        $self->chmod(
            file_or_dir => $existing,
            mode        => $mode,
            sudo        => $sudo,
            debug       => 0
        );
    }

    $self->_formatted( "install_if_changed: updating $existing", "ok" );
    return 1;
}

sub install_from_source {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'conf'           => { type => HASHREF,  optional => 1, },
            'site'           => { type => SCALAR,   optional => 0, },
            'url'            => { type => SCALAR,   optional => 0, },
            'package'        => { type => SCALAR,   optional => 0, },
            'targets'        => { type => ARRAYREF, optional => 1, },
            'patches'        => { type => ARRAYREF, optional => 1, },
            'patch_url'      => { type => SCALAR,   optional => 1, },
            'patch_args'     => { type => SCALAR,   optional => 1, },
            'source_sub_dir' => { type => SCALAR,   optional => 1, },
            'bintest'        => { type => SCALAR,   optional => 1, },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => 1 },
            'test_ok' => { type => BOOLEAN, optional => 1, },
        },
    );

    my ( $conf, $site, $url, $package, $targets, $patches, $debug ) = (
        $p{conf},    $p{site},    $p{url}, $p{package},
        $p{targets}, $p{patches}, $p{debug}
    );

    if ( defined $p{test_ok} ) { return $p{test_ok}; }

    my $original_directory = cwd;

    my $src = $conf->{toaster_src_dir} || "/usr/local/src";
    $src .= "/$p{source_sub_dir}" if $p{source_sub_dir};

    $self->cwd_source_dir( dir => $src, debug => $debug );

    if ( $p{bintest} ) {
        if ( $self->find_bin( bin => $p{bintest}, fatal => 0, debug => 0 ) ) {
            return
                if (
                !$self->yes_or_no(
                    timeout  => 60,
                    question => "$p{bintest} exists, suggesting that"
                        . "$package is installed. Do you want to reinstall?",
                )
                );
        }
    }

    print "install_from_source: building $package in $src\n" if $debug;

    # make sure there are no previous sources in the way
    if ( -d $package ) {
        if (!$self->source_warning(
                package => $package,
                clean   => 1,
                src     => $src,
                debug   => $debug,
            )
            )
        {
            carp "\nOK then, skipping install.";
            return;
        }

        print "install_from_source: removing previous build sources.\n";
        $self->syscmd( cmd => "rm -rf $package-*", debug => $debug );
    }

    #print "install_from_source: looking for existing sources...";
    $self->sources_get(
        conf    => $conf,
        package => $package,
        site    => $site,
        url     => $url,
        debug   => $debug,
    );

    if ( $patches && @$patches[0] ) {

        print "install_from_source: fetching patches...\n";

    PATCH:
        foreach my $patch (@$patches) {
            next PATCH if ( -e $patch );

            unless (
                $self->file_get(
                    url   => "$p{patch_url}/$patch",
                    debug => $debug,
                )
                )
            {
                croak
                    "install_from_source: could not fetch $p{patch_url}/$patch\n";
            }
        }
    }
    else {
        print "install_from_source: no patches to fetch.\n" if $debug;
    }

    # expand the tarball
    $self->archive_expand( archive => $package, debug => $debug )
        or croak "Couldn't expand $package: $!\n";

    # cd into the package directory
    my $sub_path;
    if ( -d $package ) {
        unless ( chdir $package ) {
            $err = "FAILED to chdir $package!";
            croak $err if $p{fatal};
            carp $err;
            return;
        }
    }
    else {

       # some packages (like daemontools) unpack within an enclosing directory
        $sub_path = `find ./ -name $package`;    # tainted data
        chomp $sub_path;

        # untaint it
        ($sub_path) = $sub_path =~ /^([-\w\/.]+)$/;

        print "found sources in $sub_path\n" if $sub_path;
        unless ( -d $sub_path && chdir($sub_path) ) {
            print "FAILED to find $package sources!\n";
            return 0;
        }
    }

    if ( $patches && @$patches[0] ) {
        print "should be patching here!\n" if $debug;

        foreach my $patch (@$patches) {

            my $patchbin = $self->find_bin( bin => "patch", debug => $debug );
            unless ( -x $patchbin ) {
                print "install_from_sources: FAILED, could not find patch!\n";
                return 0;
            }

            croak "install_from_source: patch failed: $!\n"
                if (
                !$self->syscmd(
                    cmd   => "$patchbin $p{patch_args} < $src/$patch",
                    debug => $debug,
                )
                );
        }
    }

    # set default targets if none are provided
    if ( !@$targets[0] ) {
        print "\tusing default targets (./configure, make, make install).\n";
        @$targets = ( "./configure", "make", "make install" );
    }

    if ($debug) {
        print "install_from_source: using targets \n";
        foreach (@$targets) { print "\t$_\n " }
        print "\n";
    }

    # build the program
TARGET:
    foreach my $target (@$targets) {

        print "\t pwd: " . cwd . "\n";
        if ( $target =~ /^cd (.*)$/ ) {
            chdir($1) or croak "couldn't chdir $1: $!\n";
            next TARGET;
        }

        if ( !$self->syscmd( cmd => $target, debug => $debug ) ) {
            print "\t pwd: " . cwd . "\n";
            croak "install_from_source: $target failed: $!\n" if $p{fatal};
            return;
        }
    }

    # clean up the build sources
    chdir($src);
    if ( -d $package ) {
        $self->syscmd( cmd => "rm -rf $package", debug => $debug );
    }

    if ( defined $sub_path && -d "$package/$sub_path" ) {
        $self->syscmd(
            cmd   => "rm -rf $package/$sub_path",
            debug => $debug
        );
    }

    chdir($original_directory);
    return 1;
}

sub install_package {
    my ($self, $app, $info) = @_;

    if ( lc($OSNAME) eq 'freebsd' ) {

        my $portname = $info->{port}
            or warn "skipping install of $app b/c port dir not set.";

        if ( $portname ) {
            if (`/usr/sbin/pkg_info | /usr/bin/grep $app`) {
                return print "$app is installed.\n";
            }

            print "installing $app\n";
            my $portdir = </usr/ports/*/$portname>;

            if ( -d $portdir && chdir $portdir ) {
                system "make install clean"
                    or warn "'make install clean' failed for port $app\n";
            }
            else {
                print "oops, couldn't find port $app at ($portname)\n";
            }
        };
    };

    if ( lc($OSNAME) eq 'linux' ) {
        my $rpm = $info->{rpm} or return;
        my $yum = '/usr/bin/yum';
        if ( ! -x $yum ) {
            print "couldn't find yum, skipping install.\n";
            return;
        };
        system "$yum install $rpm";
    };
}

sub install_module {

    my ($self, $module, $info) = @_;

    if ( lc($OSNAME) eq 'darwin' ) {
        my $dport = '/opt/local/bin/port';
        if ( ! -x $dport ) {
            print "Darwin ports is not installed!\n";
        } 
        else {
            my $port = "p5-$module";
            $port =~ s/::/-/g;
            my $cmd = "sudo $dport install $port";
            $self->syscmd( cmd => $cmd, debug => 0 );
        }
    }

    if ( lc($OSNAME) eq 'freebsd' ) {

        my $portname = "p5-$module";
        $portname =~ s/::/-/g;

        if (`/usr/sbin/pkg_info | /usr/bin/grep $portname`) {
            return print "$module is installed.\n";
        }

        print "installing $module";

        my $portdir = </usr/ports/*/$portname>;

        if ( $portdir && -d $portdir && chdir $portdir ) {
            print " from ports ($portdir)\n";
            system "make clean && make install clean";
        }
    }

    if ( lc($OSNAME) eq 'linux' ) {

        my $rpm = $info->{rpm};
        if ( $rpm ) {
            my $portname = "perl-$rpm";
            $portname =~ s/::/-/g;
            my $yum = '/usr/bin/yum';
            if ( -x $yum ) {
                system "$yum -y install $portname";
            };
        }
    };

    print " from CPAN...";
    require CPAN;

    # some Linux distros break CPAN by auto/preconfiguring it with no URL mirrors.
    # this works around that annoying little habit
    no warnings;
    $CPAN::Config = $self->get_cpan_config();
    use warnings;

    CPAN::Shell->install($module);
}

sub is_interactive {

    ## no critic
    # borrowed from IO::Interactive
    my $self = shift;
    my ($out_handle) = ( @_, select );    # Default to default output handle

    # Not interactive if output is not to terminal...
    return if not -t $out_handle;

    # If *ARGV is opened, we're interactive if...
    if ( openhandle * ARGV ) {

        # ...it's currently opened to the magic '-' file
        return -t *STDIN if defined $ARGV && $ARGV eq '-';

        # ...it's at end-of-file and the next file is the magic '-' file
        return @ARGV > 0 && $ARGV[0] eq '-' && -t *STDIN if eof *ARGV;

        # ...it's directly attached to the terminal
        return -t *ARGV;
    }

   # If *ARGV isn't opened, it will be interactive if *STDIN is attached
   # to a terminal and either there are no files specified on the command line
   # or if there are files and the first is the magic '-' file
    else {
        return -t *STDIN && ( @ARGV == 0 || $ARGV[0] eq '-' );
    }
}

sub is_process_running {

    my ( $self, $process ) = @_;

    eval "require Proc::ProcessTable";
    if ( ! $EVAL_ERROR ) {
        my $i = 0;
        my $t = Proc::ProcessTable->new();
        if ( scalar @{ $t->table } ) {
            foreach my $p ( @{ $t->table } ) {
                $i++ if ( $p->cmndline =~ m/$process/i );
            };
            return $i;
        };
    };

    my $ps   = $self->find_bin( bin => 'ps',   debug => 0 );
    my $grep = $self->find_bin( bin => 'grep', debug => 0 );

    if ( lc($OSNAME) =~ /solaris/i ) {
        $ps .= " -ef";
    }
    elsif ( lc($OSNAME) =~ /linux/i ) {
        $ps .= " -efw";
    }
    else {
        $ps .= " axw";
    };

    my $is_running = `$ps | $grep $process | $grep -v grep` ? 1 : 0;
    if ( ! $is_running ) {
        #warn "$ps | $grep $process | $grep -v grep\n";
    };
    return $is_running;
}

sub is_readable {

    my $self = shift;

    my %p = validate(
        @_,
        {   'file'  => { type => SCALAR },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $file, $fatal, $debug ) = ( $p{file}, $p{fatal}, $p{debug} );

    unless ( -e $file ) {
        $err = "\nis_readable: ERROR: The file $file does not exist.";
        croak $err if $fatal;
        carp $err  if $debug;
        return 0;
    }

    unless ( -r $file ) {
        carp "\nis_readable: ERROR: The file $file is not readable by you ("
            . getpwuid($>)
            . "). You need to fix this, using chown or chmod.\n";
        croak if $fatal;
        return;
    }

    return 1;
}

sub is_writable {

    my $self = shift;

    my %p = validate(
        @_,
        {   'file'  => SCALAR,
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $file, $fatal, $debug ) = ( $p{file}, $p{fatal}, $p{debug} );

    my $nl = "\n";
    $nl = "<br>" if ( $ENV{GATEWAY_INTERFACE} );

    #print "is_writable: checking $file..." if $debug;

    if ( !-e $file ) {

        use File::Basename;
        my ( $base, $path, $suffix ) = fileparse($file);

        if ( !-w $path ) {

            $err
                = "\nWARNING: is_writable: $path not writable by "
                . getpwuid($>)
                . "!$nl$nl";
            croak $err if $fatal;
            carp $err  if $debug;
            return 0;
        }
        return 1;
    }

    # if we get this far, the file exists
    unless ( -f $file ) {
        $err = "is_writable: $file is not a file!\n";
        croak $err if $fatal;
        carp $err  if $debug;
        return 0;
    }

    unless ( -w $file ) {
        $err
            = "is_writable: WARNING: $file not writable by "
            . getpwuid($>)
            . "!$nl$nl>";

        croak $err if $fatal;
        carp $err  if $debug;
        return 0;
    }

    $self->_formatted( "is_writable: checking $file.", "ok" ) if $debug;
    return 1;
}

sub logfile_append {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'file'  => { type => SCALAR,   optional => 0, },
            'lines' => { type => ARRAYREF, optional => 0, },
            'prog'  => { type => BOOLEAN,  optional => 1, default => 0, },
            'fatal' => { type => BOOLEAN,  optional => 1, default => 1 },
            'debug' => { type => BOOLEAN,  optional => 1, default => 1 },
        },
    );

    my ( $file, $lines ) = ( $p{file}, $p{lines} );

    my ( $dd, $mm, $yy, $lm, $hh, $mn, $ss )
        = $self->get_the_date( debug => $p{debug} );

    open my $LOG_FILE, '>>', $file or $fatal_err++;

    if ($fatal_err) {
        carp "logfile_append: couldn't open $file: $OS_ERROR";
        croak if $p{fatal};
        return;
    }

    $self->_formatted( "logfile_append: opened $file for writing", "ok" )
        if $p{debug};

    print $LOG_FILE "$yy-$mm-$dd $hh:$mn:$ss $p{prog} ";

    my $i;
    foreach (@$lines) { print $LOG_FILE "$_ "; $i++ }

    print $LOG_FILE "\n";
    close $LOG_FILE;

    $self->_formatted( "    wrote $i lines", "ok" ) if $p{debug};
    return 1;
}

sub provision_unix {

    my ( $self, $debug ) = @_;
    my ( $conf, $ver );

    my $perlbin = $self->find_bin( bin => "perl", debug => 0 );

    if ( -e "/usr/local/etc/provision.conf" ) {

        $conf = $self->parse_config(
            file   => "provision.conf",
            debug  => 0,
            etcdir => "/usr/local/etc",
        );
    }

    $self->install_module( 'Provision::Unix' );
}

sub mkdir_system {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'dir'   => { type => SCALAR,  optional => 0, },
            'mode'  => { type => SCALAR,  optional => 1, },
            'sudo'  => { type => BOOLEAN, optional => 1, default => 0 },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my ( $dir, $mode, $debug ) = ( $p{dir}, $p{mode}, $p{debug} );

    if ( -d $dir ) {
        print "mkdir_system: $dir already exists.\n" if $debug;
        return 1;
    }

    # can't do anything without mkdir
    my $mkdir = $self->find_bin( bin => 'mkdir', debug => $debug );

    # if we are root, just do it (no sudo nonsense)
    if ( $< == 0 ) {

        print "mkdir_system: trying mkdir -p $dir..\n" if $debug;
        $self->syscmd( cmd => "$mkdir -p $dir", debug => $debug );

        if ($mode) {
            $self->chmod( dir => $dir, mode => $mode, debug => $debug );
        }

        return 1 if -d $dir;
        croak "failed to create $dir" if $p{fatal};
        return;
    }

    if ( $p{sudo} ) {

        my $sudo = $self->sudo();

        print "mkdir_system: trying $sudo mkdir -p....\n" if $debug;
        $mkdir = $self->find_bin( bin => 'mkdir', debug => $debug );
        $self->syscmd( cmd => "$sudo $mkdir -p $dir", debug => $debug );

        print "mkdir_system: setting ownership to $<.\n" if $debug;
        my $chown = $self->find_bin( bin => 'chown', debug => $debug );
        $self->syscmd( cmd => "$sudo $chown $< $dir", debug => $debug );

        if ($mode) {
            $self->chmod(
                dir   => $dir,
                mode  => $mode,
                sudo  => $sudo,
                debug => $debug
            );
        }

        return -d $dir ? 1 : 0;
    }

    print "mkdir_system: trying mkdir -p $dir....." if $debug;

    # no root and no sudo, just try and see what happens
    $self->syscmd( cmd => "$mkdir -p $dir", debug => 0 );

    if ($mode) {
        $self->chmod( dir => $dir, mode => $mode, debug => $debug );
    }

    if ( -d $dir ) {
        print "done... (ok)\n" if $debug;
        return 1;
    }

    croak if $p{fatal};
    return;
}

sub path_parse {

    # code left her for reference, use File::Basename instead
    my ( $self, $dir ) = @_;

    # if it ends with a /, chop if off
    if ( $dir =~ q{/$} ) { chop $dir }

    # get the position of the last / in the path
    my $rindex = rindex( $dir, "/" );

    # grabs everything up to the last /
    my $updir = substr( $dir, 0, $rindex );
    $rindex++;

    # matches from the last / char +1 to the end of string
    my $curdir = substr( $dir, $rindex );

    return $updir, $curdir;
}

sub pidfile_check {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'pidfile' => { type => SCALAR },
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    my ( $pidfile, $debug ) = ( $p{pidfile}, $p{debug} );

    # if $pidfile exists, verify that it is a file
    if ( -e $pidfile && !-f $pidfile ) {
        $err = "pidfile_check: $pidfile is not a regular file!";
        croak $err if $p{fatal};
        carp $err  if $debug;
        return;
    }

    # test if file & enclosing directory is writable, revert to /tmp if not
    if (!$self->is_writable(
            file  => $pidfile,
            debug => $debug,
            fatal => $p{fatal}
        )
        )
    {
        use File::Basename;
        my ( $base, $path, $suffix ) = fileparse($pidfile);
        carp "NOTICE: using /tmp for pidfile, $path is not writable!"
            if $debug;
        $pidfile = "/tmp/$base";
    }

    # if it does not exist
    if ( !-e $pidfile ) {
        print "pidfile_check: writing process id ", $PROCESS_ID,
            " to $pidfile..."
            if $debug;

        if ($self->file_write(
                file  => $pidfile,
                lines => [$PROCESS_ID],
                debug => $debug,
            )
            )
        {
            print "done.\n" if $debug;
            return $pidfile;
        }
    }

    use File::stat;
    my $age = time() - stat($pidfile)->mtime;

    if ( $age < 1200 ) {    # less than 20 minutes old
        carp "\nWARNING! pidfile_check: $pidfile is "
            . $age / 60
            . " minutes old and might still be running. If it is not running,"
            . " please remove the pidfile (rm $pidfile). \n"
            if $debug;
        return;
    }
    elsif ( $age < 3600 ) {    # 1 hour
        carp "\nWARNING! pidfile_check: $pidfile is "
            . $age / 60
            . " minutes old and might still be running. If it is not running,"
            . " please remove the pidfile. (rm $pidfile)\n";    #if $debug;

        return;
    }
    else {
        print
            "\nWARNING: pidfile_check: $pidfile is $age seconds old, ignoring.\n\n"
            if $debug;
    }

    return $pidfile;
}

sub regexp_test {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'exp'    => { type => SCALAR },
            'string' => { type => SCALAR },
            'pbp'    => { type => BOOLEAN, optional => 1, default => 0 },
            'debug'  => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    my ( $exp, $string, $pbp, $debug )
        = ( $p{exp}, $p{string}, $p{pbp}, $p{debug} );

    if ($pbp) {
        if ( $string =~ m{($exp)}xms ) {
            print "\t Matched pbp: |$`<$&>$'|\n" if $debug;
            return $1;
        }
        else {
            print "\t No match.\n" if $debug;
            return;
        }
    }

    if ( $string =~ m{($exp)} ) {
        print "\t Matched: |$`<$&>$'|\n" if $debug;
        return $1;
    }

    print "\t No match.\n" if $debug;
    return;
}

sub sources_get {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'package' => { type => SCALAR,  optional => 0 },
            'site'    => { type => SCALAR,  optional => 0 },
            'url'     => { type => SCALAR,  optional => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    my ( $conf, $package, $site, $url, $debug )
        = ( $p{conf}, $p{package}, $p{site}, $p{url}, $p{debug} );

    print "sources_get: fetching $package from site $site\n" if $debug;
    print "\t url: $url\n"                                   if $debug;

    my @extensions = qw/ tar.gz tgz tar.bz2 tbz2 /;

    my $filet = $self->find_bin( bin => 'file', debug => $debug );
    my $grep  = $self->find_bin( bin => 'grep', debug => $debug );

    foreach my $ext (@extensions) {

        my $tarball = "$package.$ext";
        next if !-e $tarball;
        print "\t found $tarball!\n" if -e $tarball;

        if (`$filet $tarball | $grep compress`) {
            if ($self->yes_or_no(
                    question => "$tarball exists, shall I use it?: "
                )
                )
            {
                print "\n\t ok, using existing archive: $tarball\n";
                return 1;
            }
        }

        $self->file_delete( file => $tarball, debug => $debug );
    }

    foreach my $ext (@extensions) {
        my $tarball = "$package.$ext";

        print "sources_get: fetching $site$url/$tarball...";

        if ($self->file_get(
                url   => "$site$url/$tarball",
                debug => 0,
                fatal => 0
            )
            )
        {
            print "done.\n";
        }
        else {
            carp "sources_get: couldn't fetch $site$url/$tarball";
        }

        if ( -e $tarball ) {
            print "sources_get: testing $tarball ...";

            if (`$filet $tarball | $grep zip`) {
                print "sources_get: looks good!\n";
                return 1;
            }
            else {
                print "YUCK, is not [b|g]zipped data!\n";
                $self->file_delete( file => $tarball, debug => $debug );
            }
        }
    }

    print "sources_get: FAILED, I am giving up!\n";
    return;
}

sub source_warning {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'package' => { type => SCALAR, },
            'clean'   => { type => BOOLEAN, optional => 1, default => 1 },
            'src' => {
                type     => SCALAR,
                optional => 1,
                default  => "/usr/local/src"
            },
            'timeout' => { type => SCALAR,  optional => 1, default => 60 },
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    my ( $package, $src, $debug ) = ( $p{package}, $p{src}, $p{debug} );

    if ( !-d $package ) {
        print "source_warning: $package sources not present.\n" if $debug;
        return 1;
    }

    if ( -e $package ) {
        print "
	$package sources are already present, indicating that you've already
	installed $package. If you want to reinstall it, remove the existing
	sources (rm -r $src/$package) and re-run this script\n\n";
        return if !$p{clean};
    }

    return
        if (
        !$self->yes_or_no(
            question => "\n\tMay I remove the sources for you?",
            timeout  => $p{timeout},
        )
        );

    print "wd: " . cwd . "\n";
    print "Deleting $src/$package...";

    if ( !rmtree "$src/$package" ) {
        print "FAILED to delete $package: $OS_ERROR";
        croak if $p{fatal};
        return;
    }
    print "done.\n";

    return 1;
}

sub sudo {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    my $debug = $p{debug};

    # if we are running as root via $<
    if ( $REAL_USER_ID == 0 ) {
        print "sudo: you are root, sudo isn't necessary.\n" if $debug;
        return "";    # return an empty string for $sudo
    }

    my $sudo;
    my $path_to_sudo = $self->find_bin(
        bin   => 'sudo',
        debug => $debug,
        fatal => 0,
    );

    # sudo is installed
    if ( $path_to_sudo && -x $path_to_sudo ) {
        print "sudo: sudo is set using $path_to_sudo.\n" if $debug;
        return "$path_to_sudo -p 'Password for %u@%h:'";
    }

    print
        "\n\n\tWARNING: Couldn't find sudo. This may not be a problem but some features require root permissions and will not work without them. Having sudo can allow legitimate and limited root permission to non-root users. Some features of Provision::Unix may not work as expected without it.\n\n";

    # try installing sudo
    if ( !$self->yes_or_no( question => "may I try to install sudo?" ) ) {
        print "very well then, skipping along.\n";
        return "";
    }

    if ( !-x $self->find_bin( bin => "sudo", debug => $debug, fatal => 0 ) ) {
        $self->install_from_source(
            package => 'sudo-1.6.9p17',
            site    => 'http://www.courtesan.com',
            url     => '/sudo/',
            targets => [ './configure', 'make', 'make install' ],
            patches => '',
            debug   => 1,
        );
    }

    # can we find it now?
    $path_to_sudo = $self->find_bin( bin => "sudo", debug => $debug );

    if ( !-x $path_to_sudo ) {
        carp "sudo install failed!";
        return "";
    }

    return "$path_to_sudo -p 'Password for %u@%h:'";
}

sub syscmd {

    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'cmd'     => { type => SCALAR },
            'timeout' => { type => SCALAR, optional => 1 },
            'fatal'   => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'   => { type => BOOLEAN, optional => 1, default => 1 },
        },
    );

    my $cmd_request = $p{cmd};
    my $debug       = $p{debug};

    $prov->audit("syscmd is preparing: $cmd_request") if ($prov && $debug);

    my ( $is_safe, $tainted, $bin, @args );

    # separate the program from its arguments
    if ( $cmd_request =~ m/\s+/xm ) {
        @args = split /\s+/, $cmd_request;  # split on whitespace
        $bin = shift @args;
        $is_safe++;
        my $arg_string = join ' ', @args;
        $prov->audit("\tprogram is: $bin, args are: $arg_string") if $debug;
    }
    else {
        # make sure it does not not contain a ./ pattern
        if ( $cmd_request !~ m{\./} ) {
            $bin = $cmd_request;
            $is_safe++;
        }
    }

    my $status_message;
    $status_message .= "syscmd: bin is <$bin>" if $bin;
    $status_message .= " (safe)" if $is_safe;

    $self->_formatted($status_message) if $debug;

    if ( $is_safe && !$bin ) {
        $self->_formatted("\tcommand is not safe! BAILING OUT!");
        return;
    }

    if ( $bin && !-e $bin ) {  # $bin is set, but we have not found it

        # check the normal places
        my $found_bin = $self->find_bin( bin => $bin, fatal => 0, debug => 0 );
        if ( $found_bin && -x $found_bin ) {
            $bin = $found_bin;
        }

        if ( !-x $bin ) {
            return $prov->error( "cmd: $cmd_request \t bin: $bin is not found",
                fatal => $p{fatal},
                debug => $p{debug},
            );
        }
    }
    unshift @args, $bin;

    $status_message = "checking for tainted data in string";
    require Scalar::Util;
    if ( Scalar::Util::tainted($cmd_request) ) {
        $tainted++;
    }

    my $before_path = $ENV{PATH};

    if ( $tainted && !$is_safe ) {

        # instead of croaking, maybe try setting a
        # very restrictive PATH?  I'll err on the side of
        # safety for now.
        # $ENV{PATH} = '';

        return $prov->error( "$status_message ...TAINTED!",
            fatal   => $p{fatal},
            debug   => $p{debug},
        );
    }

    if ($is_safe) {
        # restrict the path
        my $prefix = "/usr/local";
        if ( -d "/opt/local" ) { $prefix = "/opt/local"; }
        $ENV{PATH} = "/bin:/sbin:/usr/bin:/usr/sbin:$prefix/bin:$prefix/sbin";
    }

    $prov->audit("syscmd: $cmd_request") if $prov;

    my $r;
    if ( $p{timeout} ) {
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm $p{timeout};
            #$r = system $cmd_request;
            $r = `$cmd_request 2>&1`;
            alarm 0;
        };

        if ($EVAL_ERROR) {
            if ( $EVAL_ERROR eq "alarm\n" ) {
                $prov->audit("timed out '$cmd_request'");
            }
            else {
                return $prov->error( "unknown error '$EVAL_ERROR'",
                    fatal => $p{fatal},
                    debug => $p{fatal},
                );
            }
        }
    }
    else {
        $r = `$cmd_request 2>&1`;
        #$r = system $cmd_request;
    }

    my $exit_code = sprintf ("%d", $CHILD_ERROR >> 8);

    $ENV{PATH} = $before_path;   # set PATH back to original value

    if ( $exit_code != 0 ) {     # an error of some kind
        #print 'error # ' . $ERRNO . "\n";   # $! == $ERRNO
        warn "error $CHILD_ERROR: $r \n" if $debug;

        if ( $CHILD_ERROR == -1 ) {     # check $? for "normal" errors
            warn "$cmd_request \nfailed to execute: $ERRNO" if $debug;
        }
        elsif ( $CHILD_ERROR & 127 ) {  # check for core dump
            if ($debug) {
                warn "syscmd: $cmd_request";
                printf "child died with signal %d, %s coredump\n", ( $? & 127 ),
                    ( $? & 128 ) ? 'with' : 'without';
            }
        }

        return $prov->error( "syscmd tried to run $cmd_request but received the following error ($CHILD_ERROR): $r",
            location => join( ", ", caller ),
            fatal    => $p{fatal},
            debug    => $p{debug},
        );
    }

    return 1;
}

sub yes_or_no {
    my $self = shift;

    # parameter validation here
    my %p = validate(
        @_,
        {   'question' => { type => SCALAR,  optional => 0 },
            'timeout'  => { type => SCALAR,  optional => 1 },
            'debug'    => { type => BOOLEAN, optional => 1, default => 1 },
            'force'    => { type => BOOLEAN, optional => 1, default => 0 },
        },
    );

    my $question = $p{question};

    # for 'make test' testing
    return 1 if $question eq "test";

    # force if interactivity testing is not working properly.
    if ( !$p{force} && !$self->is_interactive ) {
        carp "not running interactively, can't prompt!";
        return;
    }

    my $response;

    print "\nYou have $p{timeout} seconds to respond.\n" if $p{timeout};
    print "\n\t\t$question";

    # I wish I knew why this is not working correctly
    #	eval { local $SIG{__DIE__}; require Term::ReadKey };
    #	if ($@) { #
    #		require Term::ReadKey;
    #		Term::ReadKey->import();
    #		print "yay, Term::ReadKey is present! Are you pleased? (y/n):\n";
    #		use Term::Readkey;
    #		ReadMode 4;
    #		while ( not defined ($key = ReadKey(-1)))
    #		{ # no key yet }
    #		print "Got key $key\n";
    #		ReadMode 0;
    #	};

    if ( $p{timeout} ) {
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm $p{timeout};
            do {
                print "(y/n): ";
                $response = lc(<STDIN>);
                chomp($response);
            } until ( $response eq "n" || $response eq "y" );
            alarm 0;
        };

        if ($@) {
            $@ eq "alarm\n" ? print "timed out!\n" : carp;
        }

        return ($response && $response eq "y") ? 1 : 0;
    }

    do {
        print "(y/n): ";
        $response = lc(<STDIN>);
        chomp($response);
    } until ( $response eq "n" || $response eq "y" );

    return ($response eq "y") ? 1 : 0;
}

sub _formatted {

    ############################################
    # Usage      : $utility->_formatted( "tried this", "ok");
    # Purpose    : print nicely formatted status messages
    # Returns    : tried this...............................ok
    # Parameters : message - what your are reporting on
    #              result  - the status to report
    # See Also   : n/a

    my ( $self, $mess, $result ) = @_;

    my $dots           = '...';
    my $length_of_mess = length($mess);

    if ( $length_of_mess < 65 ) {
        until ( $length_of_mess == 65 ) { $dots .= "."; $length_of_mess++ }
    }

    print $mess if $mess;
    if ($result) {
        print $dots . $result;
    }
    print "\n";

    #print "$mess $dots $result\n";
}

sub _progress {
    my ( $self, $mess ) = @_;
    print {*STDERR} "$mess.\n";
    return;
}

sub _progress_begin {
    my ( $self, $phase ) = @_;
    print {*STDERR} "$phase...";
    return;
}

sub _progress_continue {
    print {*STDERR} '.';
    return;
}

sub _progress_end {
    my ( $self, $mess ) = @_;
    if ($mess) {
        print {*STDERR} "$mess\n";
    }
    else {
        print {*STDERR} "done\n";
    }
    return;
}

1;
__END__


=head1 NAME

Provision::Unix::Utility - utility subroutines for sysadmin tasks


=head1 SYNOPSIS

  use Provision::Unix::Utility;
  my $utility = Provision::Unix::Utility->new;

  $utility->file_write($file, @lines);

This is just one of the many handy little methods I have amassed here. Rather than try to remember all of the best ways to code certain functions and then attempt to remember them, I have consolidated years of experience and countless references from Learning Perl, Programming Perl, Perl Best Practices, and many other sources into these subroutines.


=head1 DESCRIPTION

This Provision::Unix::Utility package is my most frequently used one. Each method has its own documentation but in general, all methods accept as input a hashref with at least one required argument and a number of optional arguments. 


=head1 DIAGNOSTICS

All methods set and return error codes (0 = fail, 1 = success) unless otherwise stated. 

Unless otherwise mentioned, all methods accept two additional parameters:

  debug - to print status and verbose error messages, set debug=>1.
  fatal - die on errors. This is the default, set fatal=>0 to override.


=head1 DEPENDENCIES

  Perl.
  Scalar::Util -  built-in as of perl 5.8

Almost nothing else. A few of the methods do require certian things, like archive_expand requires tar and file. But in general, this package (Provision::Unix::Utility) should run flawlessly on any UNIX-like system. Because I recycle this package in other places (not just Provision::Unix), I avoid creating dependencies here.

=head1 METHODS

=over


=item new

To use any of the methods below, you must first create a utility object. The methods can be accessed via the utility object.

  ############################################
  # Usage      : use Provision::Unix::Utility;
  #            : my $utility = Provision::Unix::Utility->new;
  # Purpose    : create a new Provision::Unix::Utility object
  # Returns    : a bona fide object
  # Parameters : none
  ############################################


=item ask


Get a response from the user. If the user responds, their response is returned. If not, then the default response is returned. If no default was supplied, 0 is returned.

  ############################################
  # Usage      :  my $ask = $utility->ask(
  #  		           question => "Would you like fries with that",
  #  		           default  => "SuperSized!",
  #  		           timeout  => 30  
  #               );
  # Purpose    : prompt the user for information
  #
  # Returns    : S - the users response (if not empty) or
  #            : S - the default ask or
  #            : S - an empty string
  #
  # Parameters
  #   Required : S - question - what to ask
  #   Optional : S - default  - a default answer
  #            : I - timeout  - how long to wait for a response
  # Throws     : no exceptions
  # See Also   : yes_or_no


=item archive_expand


Decompresses a variety of archive formats using your systems built in tools.

  ############### archive_expand ##################
  # Usage      : $utility->archive_expand(
  #            :     archive => 'example.tar.bz2' );
  # Purpose    : test the archiver, determine its contents, and then
  #              use the best available means to expand it.
  # Returns    : 0 - failure, 1 - success
  # Parameters : S - archive - a bz2, gz, or tgz file to decompress


=item cwd_source_dir


Changes the current working directory to the supplied one. Creates it if it does not exist. Tries to create the directory using perl's builtin mkdir, then the system mkdir, and finally the system mkdir with sudo. 

  ############ cwd_source_dir ###################
  # Usage      : $utility->cwd_source_dir( dir=>"/usr/local/src" );
  # Purpose    : prepare a location to build source files in
  # Returns    : 0 - failure,  1 - success
  # Parameters : S - dir - a directory to build programs in


=item check_homedir_ownership 

Checks the ownership on all home directories to see if they are owned by their respective users in /etc/password. Offers to repair the permissions on incorrectly owned directories. This is useful when someone that knows better does something like "chown -R user /home /user" and fouls things up.

  ######### check_homedir_ownership ############
  # Usage      : $utility->check_homedir_ownership();
  # Purpose    : repair user homedir ownership
  # Returns    : 0 - failure,  1 - success
  # Parameters :
  #   Optional : I - auto - no prompts, just fix everything
  # See Also   : sysadmin

Comments: Auto mode should be run with great caution. Run it first to see the results and then, if everything looks good, run in auto mode to do the actual repairs. 


=item check_pidfile

see pidfile_check

=item chown_system

The advantage this sub has over a Pure Perl implementation is that it can utilize sudo to gain elevated permissions that we might not otherwise have.


  ############### chown_system #################
  # Usage      : $utility->chown_system( dir=>"/tmp/example", user=>'matt' );
  # Purpose    : change the ownership of a file or directory
  # Returns    : 0 - failure,  1 - success
  # Parameters : S - dir    - the directory to chown
  #            : S - user   - a system username
  #   Optional : S - group  - a sytem group name
  #            : I - recurse - include all files/folders in directory?
  # Comments   : Uses the system chown binary
  # See Also   : n/a


=item clean_tmp_dir


  ############## clean_tmp_dir ################
  # Usage      : $utility->clean_tmp_dir( dir=>$dir );
  # Purpose    : clean up old build stuff before rebuilding
  # Returns    : 0 - failure,  1 - success
  # Parameters : S - $dir - a directory or file. 
  # Throws     : die on failure
  # Comments   : Running this will delete its contents. Be careful!


=item get_mounted_drives

  ############# get_mounted_drives ############
  # Usage      : my $mounts = $utility->get_mounted_drives();
  # Purpose    : Uses mount to fetch a list of mounted drive/partitions
  # Returns    : a hashref of mounted slices and their mount points.


=item file_archive


  ############### file_archive #################
  # Purpose    : Make a backup copy of a file by copying the file to $file.timestamp.
  # Usage      : my $archived_file = $utility->file_archive( file=>$file );
  # Returns    : the filename of the backup file, or 0 on failure.
  # Parameters : S - file - the filname to be backed up
  # Comments   : none


=item chmod

Set the permissions (ugo-rwx) of a file. Will use the native perl methods (by default) but can also use system calls and prepend sudo if additional permissions are needed.

  $utility->chmod(
		file_or_dir => '/etc/resolv.conf',
		mode => '0755',
		sudo => $sudo
  )

 arguments required:
   file_or_dir - a file or directory to alter permission on
   mode   - the permissions (numeric)

 arguments optional:
   sudo  - the output of $utility->sudo
   fatal - die on errors? (default: on)
   debug

 result:
   0 - failure
   1 - success


=item chown

Set the ownership (user and group) of a file. Will use the native perl methods (by default) but can also use system calls and prepend sudo if additional permissions are needed.

  $utility->chown(
		file_or_dir => '/etc/resolv.conf',
		uid => 'root',
		gid => 'wheel',
		sudo => 1
  );

 arguments required:
   file_or_dir - a file or directory to alter permission on
   uid   - the uid or user name
   gid   - the gid or group name

 arguments optional:
   file  - alias for file_or_dir
   dir   - alias for file_or_dir
   sudo  - the output of $utility->sudo
   fatal - die on errors? (default: on)
   debug

 result:
   0 - failure
   1 - success


=item file_delete

  ############################################
  # Usage      : $utility->file_delete( file=>$file );
  # Purpose    : Deletes a file.
  # Returns    : 0 - failure, 1 - success
  # Parameters 
  #   Required : file - a file path
  # Comments   : none
  # See Also   : 

 Uses unlink if we have appropriate permissions, otherwise uses a system rm call, using sudo if it is not being run as root. This sub will try very hard to delete the file!


=item file_get

   $utility->file_get( url=>$url, debug=>1 );

Use the standard URL fetching utility (fetch, curl, wget) for your OS to download a file from the $url handed to us.

 arguments required:
   url - the fully qualified URL

 arguments optional:
   timeout - the maximum amount of time to try
   fatal
   debug

 result:
   1 - success
   0 - failure


=item file_is_newer

compares the mtime on two files to determine if one is newer than another. 


=item file_mode

 usage:
   my @lines = "1", "2", "3";  # named array
   $utility->file_write ( file=>"/tmp/foo", lines=>\@lines );   
        or
   $utility->file_write ( file=>"/tmp/foo", lines=>['1','2','3'] );  # anon arrayref

 required arguments:
   mode - the files permissions mode

 arguments optional:
   fatal
   debug

 result:
   0 - failure
   1 - success


=item file_read

Reads in a file, and returns it in an array. All lines in the array are chomped.

   my @lines = $utility->file_read( file=>$file, max_lines=>100 )

 arguments required:
   file - the file to read in

 arguments optional:
   max_lines  - integer - max number of lines
   max_length - integer - maximum length of a line
   fatal
   debug

 result:
   0 - failure
   success - returns an array with the files contents, one line per array element


=item file_write

 usage:
   my @lines = "1", "2", "3";  # named array
   $utility->file_write ( file=>"/tmp/foo", lines=>\@lines );   
        or
   $utility->file_write ( file=>"/tmp/foo", lines=>['1','2','3'] );  # anon arrayref

 required arguments:
   file - the file path you want to write to
   lines - an arrayref. Each array element will be a line in the file

 arguments optional:
   fatal
   debug

 result:
   0 - failure
   1 - success


=item files_diff

Determine if the files are different. $type is assumed to be text unless you set it otherwise. For anthing but text files, we do a MD5 checksum on the files to determine if they are different or not.

   $utility->files_diff( f1=>$file1,f2=>$file2,type=>'text',debug=>1 );

   if ( $utility->files_diff( f1=>"foo", f2=>"bar" ) )
   {
       print "different!\n";
   };

 required arguments:
   f1 - the first file to compare
   f2 - the second file to compare

 arguments optional:
   type - the type of file (text or binary)
   fatal
   debug

 result:
   0 - files are the same
   1 - files are different
  -1 - error.


=item find_config

This sub is called by several others to determine which configuration file to use. The general logic is as follows:

  If the etc dir and file name are provided and the file exists, use it.

If that fails, then go prowling around the drive and look in all the usual places, in order of preference:

  /opt/local/etc/
  /usr/local/etc/
  /etc

Finally, if none of those work, then check the working directory for the named .conf file, or a .conf-dist. 

Example:
  my $twconf = $utility->find_config (
	  file   => 'toaster-watcher.conf', 
	  etcdir => '/usr/local/etc',
	)

 arguments required:
   file - the .conf file to read in

 arguments optional:
   etcdir - the etc directory to prefer
   debug
   fatal

 result:
   0 - failure
   the path to $file  


=item find_bin

Check all the "normal" locations for a binary that should be on the system and returns the full path to the binary.

   $utility->find_bin( bin=>'dos2unix', dir=>'/opt/local/bin' );

Example: 

   my $apachectl = $utility->find_bin( bin=>"apachectl", dir=>"/usr/local/sbin" );


 arguments required:
   bin - the name of the program (its filename)

 arguments optional:
   dir - a directory to check first
   fatal
   debug

 results:
   0 - failure
   success will return the full path to the binary.


=item get_file

an alias for file_get for legacy purposes. Do not use.

=item get_my_ips

returns an arrayref of IP addresses on local interfaces. 

=item is_process_running

Verify if a process is running or not.

   $utility->is_process_running($process) ? print "yes" : print "no";

$process is the name as it would appear in the process table.



=item is_readable


  ############################################
  # Usage      : $utility->is_readable( file=>$file );
  # Purpose    : ????
  # Returns    : 0 = no (not reabable), 1 = yes
  # Parameters : S - file - a path name to a file
  # Throws     : no exceptions
  # Comments   : none
  # See Also   : n/a

  result:
     0 - no (file is not readable)
     1 - yes (file is readable)



=item is_writable

If the file exists, it checks to see if it is writable. If the file does not exist, it checks to see if the enclosing directory is writable. 

  ############################################
  # Usage      : $utility->is_writable(file =>"/tmp/boogers");
  # Purpose    : make sure a file is writable
  # Returns    : 0 - no (not writable), 1 - yes (is writeable)
  # Parameters : S - file - a path name to a file
  # Throws     : no exceptions


=item fstab_list


  ############ fstab_list ###################
  # Usage      : $utility->fstab_list;
  # Purpose    : Fetch a list of drives that are mountable from /etc/fstab.
  # Returns    : an arrayref
  # Comments   : used in backup.pl
  # See Also   : n/a


=item get_dir_files

   $utility->get_dir_files( dir=>$dir, debug=>1 )

 required arguments:
   dir - a directory

 optional arguments:
   fatal
   debug

 result:
   an array of files names contained in that directory.
   0 - failure


=item get_the_date

Returns the date split into a easy to work with set of strings. 

   $utility->get_the_date( bump=>$bump, debug=>$debug )

 required arguments:
   none

 optional arguments:
   bump - the offset (in days) to subtract from the date.
   debug

 result: (array with the following elements)
	$dd = day
	$mm = month
	$yy = year
	$lm = last month
	$hh = hours
	$mn = minutes
	$ss = seconds

	my ($dd, $mm, $yy, $lm, $hh, $mn, $ss) = $utility->get_the_date();


=item install_from_source

  usage:

	$utility->install_from_source(
		package => 'simscan-1.07',
   	    site    => 'http://www.inter7.com',
		url     => '/simscan/',
		targets => ['./configure', 'make', 'make install'],
		patches => '',
		debug   => 1,
	);

Downloads and installs a program from sources.

 required arguments:
    conf    - hashref - mail-toaster.conf settings.
    site    - 
    url     - 
    package - 

 optional arguments:
    targets - arrayref - defaults to [./configure, make, make install].
    patches - arrayref - patch(es) to apply to the sources before compiling
    patch_args - 
    source_sub_dir - a subdirectory within the sources build directory
    bintest - check the usual places for an executable binary. If found, it will assume the software is already installed and require confirmation before re-installing.
    debug
    fatal

 result:
   1 - success
   0 - failure


=item install_from_source_php

Downloads a PHP program and installs it. This function is not completed due to lack o interest.


=item is_interactive

tests to determine if the running process is attached to a terminal.


=item logfile_append

   $utility->logfile_append( file=>$file, lines=>\@lines )

Pass a filename and an array ref and it will append a timestamp and the array contents to the file. Here's a working example:

   $utility->logfile_append( file=>$file, prog=>"proggy", lines=>["Starting up", "Shutting down"] )

That will append a line like this to the log file:

   2004-11-12 23:20:06 proggy Starting up
   2004-11-12 23:20:06 proggy Shutting down

 arguments required:
   file  - the log file to append to
   prog  - the name of the application
   lines - arrayref - elements are events to log.

 arguments optional:
   fatal
   debug

 result:
   1 - success
   0 - failure


=item mailtoaster

   $utility->mailtoaster();

Downloads and installs Provision::Unix.


=item mkdir_system

   $utility->mkdir_system( dir => $dir, debug=>$debug );

creates a directory using the system mkdir binary. Can also make levels of directories (-p) and utilize sudo if necessary to escalate.


=item pidfile_check

pidfile_check is a process management method. It will check to make sure an existing pidfile does not exist and if not, it will create the pidfile.

   $pidfile = $utility->pidfile_check( pidfile=>"/var/run/program.pid" );

The above example is all you need to do to add process checking (avoiding multiple daemons running at the same time) to a program or script. This is used in toaster-watcher.pl and rrdutil. toaster-watcher normally completes a run in a few seconds and is run every 5 minutes. 

However, toaster-watcher can be configured to do things like expire old messages from maildirs and feed spam through a processor like sa-learn. This can take a long time on a large mail system so we don't want multiple instances of toaster-watcher running.

 result:
   the path to the pidfile (on success).

Example:

	my $pidfile = $utility->pidfile_check( pidfile=>"/var/run/changeme.pid" );
	unless ($pidfile) {
		warn "WARNING: couldn't create a process id file!: $!\n";
		exit 0;
	};

	do_a_bunch_of_cool_stuff;
	unlink $pidfile;


=item regexp_test

Prints out a string with the regexp match bracketed. Credit to Damien Conway from Perl Best Practices.

 Example:
    $utility->regexp_test( 
		exp    => 'toast', 
		string => 'mailtoaster rocks',
	);

 arguments required:
   exp    - the regular expression
   string - the string you are applying the regexp to

 result:
   printed string highlighting the regexp match


=item source_warning

Checks to see if the old build sources are present. If they are, offer to remove them.

 Usage:

   $utility->source_warning( 
		package => "Mail-Toaster-4.10", 
		clean   => 1, 
		src     => "/usr/local/src" 
   );

 arguments required:
   package - the name of the packages directory

 arguments optional:
   src     - the source directory to build in (/usr/local/src)
   clean   - do we try removing the existing sources? (enabled)
   timeout - how long to wait for an answer (60 seconds)

 result:
   1 - removed
   0 - failure, package exists and needs to be removed.


=item sources_get

Tries to download a set of sources files from the site and url provided. It will try first fetching a gzipped tarball and if that files, a bzipped tarball. As new formats are introduced, I will expand the support for them here.

  usage:
	$self->sources_get( 
		conf    => $conf, 
		package => 'simscan-1.07', 
		site    => 'http://www.inter7.com',
		url     => '/simscan/',
	)

 arguments required:
   package - the software package name
   site    - the host to fetch it from
   url     - the path to the package on $site

 arguments optional:
   conf    - hashref - values from toaster-watcher.conf
   debug

This sub proved quite useful during 2005 as many packages began to be distributed in bzip format instead of the traditional gzip.


=item sudo

   my $sudo = $utility->sudo();

   $utility->syscmd( cmd=>"$sudo rm /etc/root-owned-file" );

Often you want to run a script as an unprivileged user. However, the script may need elevated privileges for a plethora of reasons. Rather than running the script suid, or as root, configure sudo allowing the script to run system commands with appropriate permissions.

If sudo is not installed and you're running as root, it'll offer to install sudo for you. This is recommended, as is properly configuring sudo.

 arguments required:

 arguments optional:
   debug

 result:
   0 - failure
   on success, the full path to the sudo binary


=item syscmd

   Just a little wrapper around system calls, that returns any failure codes and prints out the error(s) if present. A bit of sanity testing is also done to make sure the command to execute is safe. 

      my $r = $utility->syscmd( cmd=>"gzip /tmp/example.txt" );
      $r ? print "ok!\n" : print "not ok.\n";

    arguments required:
      cmd     - the command to execute

    arguments optional:
      debug
      fatal

    result
      the exit status of the program you called.


=item _try_mkdir

try creating a directory using perl's builtin mkdir.


=item yes_or_no

  my $r = $utility->yes_or_no( 
      question => "Would you like fries with that?",
      timeout  => 30
  );

	$r ? print "fries are in the bag\n" : print "no fries!\n";

 arguments required:
   none.

 arguments optional:
   question - the question to ask
   timeout  - how long to wait for an answer (in seconds)

 result:
   0 - negative (or null)
   1 - success (affirmative)


=back

=head1 AUTHOR

Matt Simerson (matt@tnpi.net)


=head1 BUGS

None known. Report any to author.


=head1 TODO

  make all errors raise exceptions
  write test cases for every method
  comments. always needs more comments.


=head1 SEE ALSO

The following are all man/perldoc pages: 

 Provision::Unix 


=head1 COPYRIGHT

Copyright (c) 2003-2008, The Network People, Inc. All Rights Reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

Neither the name of the The Network People, Inc. nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
