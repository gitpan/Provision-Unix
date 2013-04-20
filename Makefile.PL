
use strict;
use warnings;

use 5.006001;

use ExtUtils::MakeMaker 6.30;



my %WriteMakefileArgs = (
  "ABSTRACT" => "provision hosting accounts on unix systems",
  "AUTHOR" => "Matt Simerson <msimerson\@cpan.org>",
  "BUILD_REQUIRES" => {
    "Config" => 0,
    "Dist::Zilla" => 1,
    "Dist::Zilla::Plugin::MinimumPerl" => "0.1",
    "Pod::Coverage::TrustPod" => "0.1",
    "Test::More" => "0.1",
    "Test::Perl::Critic" => "0.1",
    "Test::Pod" => "0.1",
    "Test::Pod::Coverage" => "0.1"
  },
  "CONFIGURE_REQUIRES" => {
    "ExtUtils::MakeMaker" => "6.30"
  },
  "DISTNAME" => "Provision-Unix",
  "EXE_FILES" => [],
  "LICENSE" => "perl",
  "NAME" => "Provision::Unix",
  "PREREQ_PM" => {
    "Apache::Admin::Config" => 1,
    "Apache::ConfigFile" => 1,
    "CPAN" => 0,
    "Config::Tiny" => 2,
    "Cwd" => 0,
    "Data::Dumper" => 0,
    "Date::Format" => 0,
    "Digest::MD5" => 1,
    "English" => 0,
    "File::Basename" => 0,
    "File::Copy" => 0,
    "File::Path" => "2.08",
    "File::Spec" => 0,
    "File::stat" => 0,
    "Getopt::Long" => "2.37",
    "LWP::Simple" => 0,
    "LWP::UserAgent" => 0,
    "Mail::Send" => 1,
    "Params::Validate" => "0.8",
    "Scalar::Util" => 0,
    "Time::Local" => 0,
    "URI" => 1,
    "base" => 0,
    "strict" => 0,
    "utf8" => 1,
    "vars" => 0,
    "warnings" => 0
  },
  "VERSION" => "1.06",
  "test" => {
    "TESTS" => "t/*.t"
  }
);


unless ( eval { ExtUtils::MakeMaker->VERSION(6.56) } ) {
  my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
  my $pp = $WriteMakefileArgs{PREREQ_PM};
  for my $mod ( keys %$br ) {
    if ( exists $pp->{$mod} ) {
      $pp->{$mod} = $br->{$mod} if $br->{$mod} > $pp->{$mod};
    }
    else {
      $pp->{$mod} = $br->{$mod};
    }
  }
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);



