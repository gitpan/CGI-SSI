use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'		=> 'CGI::SSI',
    'VERSION_FROM'	=> 'SSI.pm', # finds $VERSION
    'PREREQ_PM'		=> {
        File::Basename  => undef,
        Date::Format    => undef,
    }, # e.g., Module::Name => 1.1
);
