# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'

######################### We start with some black magic to print on failure.

# Change 1..1 below to 1..last_test_to_print .
# (It may become useful if the test is moved to ./t subdirectory.)

BEGIN { $| = 1; print "1..18\n"; }
END {print "not ok 1\n" unless $loaded;}

#use CGI::SSI;
require "./SSI.pm";
CGI::SSI->import;

$loaded = 1;
print "ok 1\n";

######################### End of black magic.

# Insert your test code below (better if it prints "ok 13"
# (correspondingly "not ok 13") depending on the success of chunk 13
# of the test code):


# set and echo

{
    my $ssi = CGI::SSI->new();
    $ssi->set(var => 'value');
    my $value = $ssi->echo('var');
    print 'not ' unless $value eq 'value';
    print "ok 2\n";
}

# other ways to call set and echo

{
    my $ssi = CGI::SSI->new();
    $ssi->set(var => "var2", value => "value2");
    my $value = $ssi->echo(var => 'var2');
    print 'not ' unless $value eq 'value2';
    print "ok 3\n";
}

# objects don't crush each other's vars.

{
    my $ssi = CGI::SSI->new();
    my $ssi2 = CGI::SSI->new();

    $ssi->set(var => "value");
    $ssi2->set(var => "value2");

    my $value  = $ssi->echo("var");
    my $value2 = $ssi2->echo("var");

    print "not " if($value ne "value" or $value2 ne "value2");
    print "ok 4\n";
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
    print "not " if(   $ssi->echo("DOCUMENT_URI")  ne "doc_uri"
		    or $ssi->echo("DOCUMENT_NAME") ne "doc_name"
		    or $ssi->echo("DOCUMENT_ROOT") ne "/");
    print "ok 5\n";
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
    print "not " unless $months{ $ssi->flastmod(file => $filename) };
    print "ok 6\n";

    $ssi->config(sizefmt => "bytes"); # TODO: combine these calls to config.

    my $size = $ssi->fsize(file => $filename);
    print "not " unless $size eq int $size;
    print "ok 7\n";

    $ssi->config(errmsg => "error"); # TODO combine config calls
    print "not " unless $ssi->flastmod("") eq "error";
    print "ok 8\n";

    unlink $filename;
}

    # tough to do these well, without more info...
# include file - with many types of input
# include virtual - with different types of input

{
    my $ssi = CGI::SSI->new();
    my $html = $ssi->process(q[<!--#include virtual="http://www.yahoo.com" -->]);
    print "not " unless $html =~ /yahoo/smi;
    print "ok 9\n";
}

# exec cgi - with different input

{
    my $ssi = CGI::SSI->new();
    my $html = $ssi->process(q[<!--#exec cgi="http://www.yahoo.com?foo=bar" -->]);
    print "not " unless $html =~ /yahoo/smi;
    print "ok 10\n";
}

# exec cmd - with different input

{
    if(-e '/usr/bin/perl') {
	my $ssi = CGI::SSI->new();
	my $html = $ssi->process(q[<!--#exec cmd="/usr/bin/perl -v" -->]);
        print "not " unless $html =~ /perl/smi;
        print "ok 11\n";
    } else {
	print "skipping test on this platform.\n";
    }
}

# flastmod - different input
# fsize - different input

# if/else

{
    my $ssi = CGI::SSI->new();
    $ssi->set(varname => "test");
    my $html = $ssi->process(qq[<!--#if expr="'\$varname' =~ /^TEST\$/i" -->if<!--#else -->else<!--#endif --->]);
    print "not " unless $html eq "if";
    print "ok 12\n";
}

# if/elif

{
    my $ssi = CGI::SSI->new();
    my $html = $ssi->process(q[<!--#if expr="my \$i = 2; \$i eq 3;" -->if<!--#elif expr="my \$j = 4; \$j == 4" -->elif<!--#endif -->]);
    print "not " unless $html eq "elif";
    print "ok 13\n";
}

# if/elif/else

{
    my $ssi = CGI::SSI->new();
    my $html = $ssi->process(q[<!--#if expr="0" -->if<!--#elif expr="'$DATE_LOCAL' !~ /\\\\S/" -->elif<!--#else -->else<!--#endif -->]);
    print "not " unless $html eq "else";
    print "ok 14\n";
}

## nested ifs:

# if false -> if true/else

{
    my $ssi = CGI::SSI->new();
    my $html = $ssi->process(q[<!--#if expr="0" -->if1<!--#if expr="1" -->if2<!--#else -->else<!--#endif --><!--#endif -->]);
    print "not " if $html;
    print "ok 15\n";
}

# if true -> if false/else

{
    my $ssi = CGI::SSI->new();
    my $html = $ssi->process(q[<!--#if expr="1" -->if1<!--#if expr="0" -->if2<!--#else -->else<!--#endif --><!--#endif -->]);
    print "not " unless $html eq "if1else";
    print "ok 16\n";
}

# if true -> if true/else

{
    my $ssi = CGI::SSI->new();
    my $html = $ssi->process(q[<!--#if expr="1" -->if1<!--#if expr="1" -->if2<!--#else -->else<!--#endif --><!--#endif -->]);
    print "not " unless $html eq "if1if2";
    print "ok 17\n";
}

# one bigger test: if true -> if false/elif true/else -> if false/*elif true*/else

{
    my $ssi = CGI::SSI->new();
    my $html = $ssi->process(q[<!--#if expr="1" -->if1<!--#if expr="0" -->if2<!--#elif expr="1" -->elif1<!--#if expr="0" -->if3<!--#elif expr="1" -->elif2<!--#else -->else1<!--#endif --><!--#else -->else2<!--#endif --><!--#endif -->]);
    print "not " unless $html eq "if1elif1elif2";
    print "ok 18\n";
}

## end nested ifs tests

__END__

# derive a class, and do something simple (empty class)

{
    package CGI::SSI::Empty;
    @CGI::SSI::Empty::ISA = qw(CGI::SSI);

    package main;

    my $empty = CGI::SSI::Empty->new();
    my $html = $empty->process(q[<!--#set var="varname" value="foo" --><!--#echo var="varname" -->]);
    print "not " unless $html eq "foo";
    print "ok 19\n";
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
    print "not " unless $html eq "FOO";
    print "ok 20\n";
}

# autotie ?
# tie by hand

