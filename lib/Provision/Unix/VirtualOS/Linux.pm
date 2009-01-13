package Provision::Unix::VirtualOS::Linux;

our $VERSION = '0.1';

use warnings;
use strict;

#use English qw( -no_match_vars );
#use Params::Validate qw(:all);

sub new {
}

sub get_distro {

  # credit to Max Vohra. Logic implemented here was taken from his Template.pm

    my ($fs_root) = @_;

    return -e "$fs_root/etc/debian_version"
        ? { distro => 'debian', pack_mgr => 'apt' }
        : -e "$fs_root/etc/redhat-release"
        ? { distro => 'redhat', pack_mgr => 'yum' }
        : -e "$fs_root/etc/SuSE-release"
        ? { distro => 'suse', pack_mgr => 'zypper' }
        : -e "$fs_root/etc/slackware-version"
        ? { distro => 'slackware', pack_mgr => 'unknown' }
        : -e "$fs_root/etc/gentoo-release"
        ? { distro => 'gentoo', pack_mgr => 'emerge' }
        : -e "$fs_root/etc/arch-release"
        ? { distro => 'arch', pack_mgr => 'packman' }
        : { distro => undef, pack_mgr => undef };
}

1;

