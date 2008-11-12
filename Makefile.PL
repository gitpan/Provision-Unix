use strict;
use warnings;
use ExtUtils::MakeMaker;

BEGIN {
    if ( ! eval "require Params::Validate" ) {
        print "\n\tParams::Validate is not installed!\n\n";
        print "\trun 'make deps' to install dependencies.\n";
    }
}

WriteMakefile(
    NAME                => 'Provision::Unix',
    AUTHOR              => 'Matt Simerson <matt@tnpi.net>',
    VERSION_FROM        => 'lib/Provision/Unix.pm',
    ABSTRACT_FROM       => 'lib/Provision/Unix.pm',
    PL_FILES            => {},
    LICENSE             => 'perl',
    PREREQ_PM => {
        'Test::More' => 0,
        'Params::Validate' => .8,
        'Apache::Admin::Config' => .9,
        'NicTool'       => 0,
        'Config::Std'   => 0,
#        'DNS::TinyDNS'    => 1,  # doesn't support SOA or SRV records

    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { 
            FILES => [  
                        'Provision-Unix-*',
                        "pod2htm*",
                        "t/trash",
                        "t/tinydns/root/data",
                        "t/tinydns/root/data.cdb",
                    ],
    },
);


sub MY::postamble {
'
deps:
	perl bin/install_deps.pl
';
}
