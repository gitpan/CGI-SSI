use strict;
use warnings FATAL => 'all';

use Test::More tests => 21;

use_ok('CGI::SSI');

# set and echo

{
    my $ssi = CGI::SSI->new();
    $ssi->set(var => 'value');
    my $value = $ssi->echo('var');
    ok($value eq 'value','set/echo 1');
}

# other ways to call set and echo

{
    my $ssi = CGI::SSI->new();
    $ssi->set(var => "var2", value => "value2");
    my $value = $ssi->echo(var => 'var2');
    ok($value eq 'value2','set/echo 2');
}

# objects don't crush each other's vars.

{
    my $ssi = CGI::SSI->new();
    my $ssi2 = CGI::SSI->new();

    $ssi->set(var => "value");
    $ssi2->set(var => "value2");

    my $value  = $ssi->echo("var");
    my $value2 = $ssi2->echo("var");

    ok($value eq "value" && $value2 eq "value2",'data encapsulation');
}

# args to new()

{
    my $ssi = CGI::SSI->new(
			    DOCUMENT_URI  => "doc_uri",
			    DOCUMENT_NAME => "doc_name",
			    DOCUMENT_ROOT => "/",
			    errmsg        => "[ERROR!]",
			    sizefmt       => "bytes",
                            timefmt       => "%B",
			    );
    ok(   ($ssi->echo("DOCUMENT_URI")  eq "doc_uri"
       and $ssi->echo("DOCUMENT_NAME") eq "doc_name"
       and $ssi->echo("DOCUMENT_ROOT") eq "/"),'new()');
}

# config

{
    my %months = map { ($_,1) } qw(January February March April May June 
                                   July August September October November December);

        # create a tmp file for testing.
    use IO::File;
    use POSIX qw(tmpnam);
    
    my($filename,$fh); # Thanks, Perl Cookbook!
    do { $filename = tmpnam() } until $fh = IO::File->new($filename, O_RDWR|O_CREAT|O_EXCL);
#   select( ( select($fh), $| = 1 )[0] );
    print $fh ' ' x 10;
    close $fh;

    my $ssi = CGI::SSI->new();
    $ssi->config(timefmt => "%B");
    ok($months{ $ssi->flastmod(file => $filename) },'config 1');

    $ssi->config(sizefmt => "bytes"); # TODO: combine these calls to config.

    my $size = $ssi->fsize(file => $filename);
    ok($size eq int $size,'config 2');

    $ssi->config(errmsg => "error"); # TODO combine config calls
    ok($ssi->flastmod("") eq "error",'config 3');

    unlink $filename;
}

    # tough to do these well, without more info...
# include file - with many types of input
# include virtual - with different types of input

{
    my $ssi = CGI::SSI->new();
    my $html = $ssi->process(q[<!--#include virtual="http://www.yahoo.com" -->]);
    ok($html =~ /yahoo/i,'include virtual');
}

# exec cgi - with different input

{
    my $ssi = CGI::SSI->new();
    my $html = $ssi->process(q[<!--#exec cgi="http://www.yahoo.com/" -->]);
    ok($html =~ /yahoo/i,'exec cgi');
}

# exec cmd - with different input

{
    my $ssi = CGI::SSI->new();
    my $perl = $^X;
    $perl =~ s|\\|/|g;
    my $html = $ssi->process(qq[<!--#exec cmd="$perl -v" -->]);
    ok($html =~ /perl/i,'exec cmd');
}

# flastmod - different input
# fsize - different input

# if/else

{
    my $ssi = CGI::SSI->new();
    $ssi->set(varname => "test");
    my $html = $ssi->process(qq[<!--#if expr="'\$varname' =~ /^TEST\$/i" -->if<!--#else -->else<!--#endif --->]);
    ok($html eq "if",'if/else');
}

# if/elif

{
    my $ssi = CGI::SSI->new();
    my $html = $ssi->process(q[<!--#if expr="my \$i = 2; \$i eq 3;" -->if<!--#elif expr="my \$j = 4; \$j == 4" -->elif<!--#endif -->]);
    ok($html eq "elif",'if/elif');
}

# if/elif/else

{
    my $ssi = CGI::SSI->new();
    my $html = $ssi->process(q[<!--#if expr="0" -->if<!--#elif expr="'$DATE_LOCAL' !~ /\\\\S/" -->elif<!--#else -->else<!--#endif -->]);
    ok($html eq "else",'if/elif/else');
}

## nested ifs:

# if false -> if true/else

{
    my $ssi = CGI::SSI->new();
    my $html = $ssi->process(q[<!--#if expr="0" -->if1<!--#if expr="1" -->if2<!--#else -->else<!--#endif --><!--#endif -->]);
    ok(!$html,'if 1');
}


# if true -> if false/else

{
    my $ssi = CGI::SSI->new();
    my $html = $ssi->process(q[<!--#if expr="1" -->if1<!--#if expr="0" -->if2<!--#else -->else<!--#endif --><!--#endif -->]);
    ok($html eq "if1else",'if 2');
}

# if true -> if true/else

{
    my $ssi = CGI::SSI->new();
    my $html = $ssi->process(q[<!--#if expr="1" -->if1<!--#if expr="1" -->if2<!--#else -->else<!--#endif --><!--#endif -->]);
    ok($html eq "if1if2",'if 3');
}

# one bigger test: if true -> if false/elif true/else -> if false/*elif true*/else

{
    my $ssi = CGI::SSI->new();
    my $html = $ssi->process(q[<!--#if expr="1" -->if1<!--#if expr="0" -->if2<!--#elif expr="1" -->elif1<!--#if expr="0" -->if3<!--#elif expr="1" -->elif2<!--#else -->else1<!--#endif --><!--#else -->else2<!--#endif --><!--#endif -->]);
    ok($html eq "if1elif1elif2",'if/elif/else');
}

# derive a class, and do something simple (empty class)

{
    package CGI::SSI::Empty;
    @CGI::SSI::Empty::ISA = qw(CGI::SSI);

    package main;

    my $empty = CGI::SSI::Empty->new();
    my $html = $empty->process(q[<!--#set var="varname" value="foo" --><!--#echo var="varname" -->]);
    ok($html eq "foo",'inherit 1');
}

# derive a class, and do something simple (altered class)

{
    package CGI::SSI::UCEcho;
    @CGI::SSI::UCEcho::ISA = qw(CGI::SSI);

    sub echo {
	return uc shift->SUPER::echo(@_);
    }

    package main;

    my $echo = CGI::SSI::UCEcho->new();
    my $html = $echo->process(q[<!--#set var="varname" value="foo" --><!--#echo var="varname" -->]);
    ok($html eq "FOO",'inherit 2');
}

# DATE_LOCAL/DATE_GMT with config{timefmt}
{
    my $ssi = new CGI::SSI (timefmt => '%Y');
    ok($ssi->echo('DATE_LOCAL') =~ /^\d{4}$/,'config{timefmt}');
}


# autotie ?
# tie by hand


__END__
