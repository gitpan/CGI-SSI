use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'	   => 'CGI::SSI',
    'VERSION_FROM' => 'SSI.pm', # finds $VERSION
    'PREREQ_PM'    => {
                         HTML::SimpleParse => 0,
                         FindBin           => 0,
                         File::Spec        => 0,
                         LWP::Simple       => 0,
                         URI               => 0,
                         Date::Parse       => 0,
                      },
);
