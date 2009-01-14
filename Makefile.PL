#!perl

use strict;
use warnings;
use inc::Module::Install;

name            'Provision-Unix';
abstract_from   'lib/Provision/Unix.pm';
author          'msimerson@cpan.org';
license         'perl';
perl_version    '5.008';
version_from    'lib/Provision/Unix.pm';

requires        'Params::Validate'  => .8;
requires        'Config::Std'       => 0;
requires        'Getopt::Long'      => 2.37;

test_requires     'Test::More'      => 0;

# these are for the authors (mostly me), but listed here for Kwalitee
recommends        'Test::Pod'           => 0;
recommends        'Test::Pod::Coverage' => 0;
recommends        'Test::Perl::Critic'  => 0;

feature             'Email Notices',
                        -default          => 0,
                        'Mail::Send'      => 1;

feature             'Apache Configuration',
                        -default                => 0,
                        'Apache::Admin::Config' => .9;

feature             'Filesystem Quotas',
                        -default      => 0,
                        'Quota'       => 1;

feature             'NicTool API integration',
                        -default      => 0,
                       'NicTool'      => 0;

#feature         'tinydns data files'    # not used.
#                    DNS::TinyDNS'    => 1;

feature               'JSON Provisioning Agent',
                        -default           => 0,
                        'JSON::XS'         => 0;

feature               'self-update to latest CPAN version',
                        -default           => 0,
                        'LWP::UserAgent'   => 0;

clean_files           'Provision-Unix-*';
clean_files           'pod2htm*';
clean_files           't/trash';
clean_files           't/tinydns/root/data';
clean_files           't/tinydns/root/data.cdb';
clean_files           'MANIFEST.bak';
clean_files           'Makefile.old';

install_script        'bin/prov_dns';
install_script        'bin/prov_user';
install_script        'bin/prov_virtual';
install_script        'bin/prov_web';
install_script        'bin/remoteagent';

# inc and t are automatically not indexed
no_index              file      => 'bin/remoteagent';

WriteAll;
