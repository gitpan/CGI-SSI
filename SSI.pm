package CGI::SSI;
use strict;

use HTML::SimpleParse;
use File::Spec;
use FindBin;
use LWP::Simple;
use URI;
use Date::Format;

$CGI::SSI::VERSION = '0.10';

my $debug = 0;

######### tie some vars for ease and precision
my($gmt,$loc);
tie $gmt,'CGI::SSI::Gmt';
tie $loc,'CGI::SSI::Local';
#########

sub import {
    my($class,%args) = @_;
    return unless defined $args{'autotie'};
    $args{'filehandle'} = $args{'autotie'} =~ /::/ ? $args{'autotie'} : caller().'::'.$args{'autotie'};
    no strict 'refs';
    my $self = tie(*{$args{'filehandle'}},$class,%args);
    return $self;
}

sub new {
    my($class,%args) = @_;
    my $self = bless {}, $class;

    $self->{'_handle'}        = undef;

    my $script_name = '';
    if(exists $ENV{'SCRIPT_NAME'}) {
	($script_name) = $ENV{'SCRIPT_NAME'} =~ /([^\/]+)$/;
    }

    $self->{'_variables'}     = {
        DOCUMENT_URI    =>  ($args{'DOCUMENT_URI'} || $ENV{'SCRIPT_NAME'}),
        DATE_GMT        =>  $gmt,
        DATE_LOCAL      =>  $loc,
        LAST_MODIFIED   =>  $self->flastmod('file', $ENV{'SCRIPT_FILENAME'} || $ENV{'PATH_TRANSLATED'} || ''),
        DOCUMENT_NAME   =>  ($args{'DOCUMENT_NAME'} || $script_name),
                                };

    $self->{'_config'}        = {
        errmsg  =>  '[an error occurred while processing this directive]',
        sizefmt =>  'abbrev',
        timefmt =>  undef,
                                };

    $self->{'_in_if'}     = 0;
    $self->{'_suspend'}   = [0];
    $self->{'_seen_true'} = [1];

    return $self;
}

sub TIEHANDLE {
    my($class,%args) = @_;
    my $self = $class->new(%args);
    $self->{'_handle'} = do { local *STDOUT };
    my $handle_to_tie = '';
    if($args{'filehandle'} !~ /::/) {
	$handle_to_tie = caller().'::'.$args{'filehandle'};
    } else {
	$handle_to_tie = $args{'filehandle'};
    }
    open($self->{'_handle'},'>&'.$handle_to_tie) or die "Failed to copy the filehandle ($handle_to_tie): $!";
    return $self;
}

sub PRINT {
    my($self,@shtml) = @_;
    print {$self->{'_handle'}} map { $self->process($_) } @shtml;
}

sub process {
    my($self,@shtml) = @_;
    print main::STDERR "###processing:\n",join("\n",@shtml),"\n" if $debug;
    my $processed = '';
    @shtml = split(/(<!--#.+?-->)/,join '',@shtml);
    for my $token (@shtml) {
	next unless(defined $token and length $token);
        if($token =~ /^<!--#(.+?)\s*-->$/) {
	    $processed .= $self->_process_ssi_text($self->_interp_vars($1));
	} else {
	    next if $self->_suspended;
	    $processed .= $token;
	}
    }
    return $processed;
}

sub _process_ssi_text {
    my($self,$text) = @_;
    return '' if($self->_suspended and $text !~ /^(?:if|else|elif|endif)\b/);
    return $self->{'_config'}->{'errmsg'} unless $text =~ s/^(\S+)\s*//;
    my $method = $1;
    print main::STDERR "###calling $method($text)\n" if $debug;
    return $self->$method( HTML::SimpleParse->parse_args($text) );
}

# many thanks to Apache::SSI
sub _interp_vars {
    local $^W = 0;
    my($self,$text) = @_;
    my($a,$b,$c) = ('','','');
    $text =~ s{ (^|[^\\]) (\\\\)* \$(?:\{)?(\w+)(?:\})? }
              {($a,$b,$c)=($1,$2,$3); $a . substr($b,length($b)/2) . $self->_echo($c) }exg;
    return $text;
}

# for internal use only
sub _echo {
    my($self,$key,$var) = @_;
    $var = $key if @_ == 2;
    return $self->{'_variables'}->{$var} if exists $self->{'_variables'}->{$var};
    return $ENV{$var} if exists $ENV{$var};
    return $var;
}

#
# ssi directive methods
#

sub config {
    my($self,%args) = @_;
    if(exists $args{'timefmt'}) {
	$self->{'_config'}->{'timefmt'} = $args{'timefmt'};
    } elsif(exists $args{'sizefmt'}) {
	if($args{'sizefmt'} eq 'abbrev') {
	    $self->{'_config'}->{'sizefmt'} = 'abbrev';
	} elsif($args{'sizefmt'} eq 'bytes') {
	    $self->{'_config'}->{'sizefmt'} = 'bytes';
	} else {
	    return $self->{'_config'}->{'errmsg'};
	}
    } elsif(exists $args{'errmsg'}) {
	$self->{'_config'}->{'errmsg'} = $args{'errmsg'};
    } else {
	return $self->{'_config'}->{'errmsg'};
    }
    return '';
}

sub set {
    my($self,%args) = @_;
    if(scalar keys %args > 1) {
	$self->{'_variables'}->{$args{'var'}} = $args{'value'};
    } else { # var => value notation
	$self->{'_variables'}->{(keys %args)[0]} = (values %args)[0];
    }
    return '';
}

sub echo {
    my($self,$key,$var) = @_;
    $var = $key if @_ == 2;
    return $self->{'_variables'}->{$var} if exists $self->{'_variables'}->{$var};
    return $ENV{$var} if exists $ENV{$var};
    return '';
}

sub printenv {
    #my $self = shift;
    return join "\n",map {"$_=$ENV{$_}"} keys %ENV; 
}

sub include {
    my($self,$type,$filename) = @_;
    if($type eq 'file') {
	return $self->_include_file($filename);
    } elsif($type eq 'virtual') {
	return $self->_include_virtual($filename);
    } else {
	return $self->{'_config'}->{'errmsg'};
    }
}

sub _include_file {
    my($self,$filename) = @_;
    $filename = File::Spec->catfile($FindBin::Bin,$filename) unless -e $filename;
    my $fh = do { local *STDIN };
    open($fh,$filename) or return $self->{'_config'}->{'errmsg'};
    return join '',<$fh>;
}

sub _include_virtual {
    my($self,$filename) = @_;
    my $response = undef;
    eval {
	my $uri = URI->new($filename);
	$uri->scheme($uri->scheme || 'http'); # ??
	$uri->host($uri->host || $ENV{'HTTP_HOST'} || $ENV{'SERVER_NAME'});
	$response = get $uri->canonical;
    };
    return $self->{'_config'}->{'errmsg'} if $@;
    return $self->{'_config'}->{'errmsg'} unless defined $response;
    return $response;
}

sub exec {
    my($self,$type,$filename) = @_;
    if($type eq 'cmd') {
	return $self->_exec_cmd($filename);
    } elsif($type eq 'cgi') {
	return $self->_exec_cgi($filename);
    } else {
	return $self->{'_config'}->{'errmsg'};
    }
}

sub _exec_cmd {
    my($self,$filename) = @_;
    my $output = `$filename`; # security here is mighty bad.
    return $self->{'_config'}->{'errmsg'} if $?;
    return $output;
}

sub _exec_cgi { # no relative $filename allowed.
    my($self,$filename) = @_;
    my $response = undef;
    eval {
	my $uri = URI->new($filename);
	$uri->scheme($uri->scheme || 'http');
	$uri->host($uri->host || $ENV{'HTTP_HOST'} || $ENV{'SERVER_NAME'});
	$uri->query($uri->query || $ENV{'QUERY_STRING'});
	$response = get $uri->canonical;
    };
    return $self->{'_config'}->{'errmsg'} if $@;
    return $self->{'_config'}->{'errmsg'} unless defined $response;
    return $response;
}

sub flastmod {
    my($self,$type,$filename) = @_;

    if($type eq 'file') {
	$filename = File::Spec->catfile($FindBin::Bin,$filename) unless -e $filename;
    } elsif($type eq 'virtual') {
	$filename = File::Spec->catfile($ENV{'DOCUMENT_ROOT'},$filename) unless $filename =~ /$ENV{'DOCUMENT_ROOT'}/;
    } else {
	return $self->{'_config'}->{'errmsg'};
    }
    return $self->{'_config'}->{'errmsg'} unless -e $filename;

    my $flastmod = (stat $filename)[9];
    
    if($self->{'_config'}->{'timefmt'}) {
	my @localtime = localtime($flastmod); # need this??
	return Date::Format::strftime($self->{'_config'}->{'timefmt'},@localtime);
    } else {
	return scalar localtime($flastmod);
    }
}

sub fsize {
    my($self,$type,$filename) = @_;

    if($type eq 'file') {
	$filename = File::Spec->catfile($FindBin::Bin,$filename) unless -e $filename;
    } elsif($type eq 'virtual') {
	$ENV{'DOCUMENT_ROOT'} ||= '';
	$filename = File::Spec->catfile($ENV{'DOCUMENT_ROOT'},$filename) unless $filename =~ /$ENV{'DOCUMENT_ROOT'}/;
    } else {
	return $self->{'_config'}->{'errmsg'};
    }
    return $self->{'_config'}->{'errmsg'} unless -e $filename;

    my $fsize = (stat $filename)[7];
    
    if($self->{'_config'}->{'sizefmt'} eq 'bytes') {
	1 while $fsize =~ s/^(\d+)(\d{3})/$1,$2/g;
	return $fsize;
    } else { # abbrev
	# gratefully lifted from Apache::SSI
	return "   0k" unless $fsize;
	return "   1k" if $fsize < 1024;
	return sprintf("%4dk", ($fsize + 512)/1024) if $fsize < 1048576;
	return sprintf("%4.1fM", $fsize/1048576.0) if $fsize < 103809024;
	return sprintf("%4dM", ($fsize + 524288)/1048576) if $fsize < 1048576;
    }
}

#
# if/elsif/else/endif and related methods
#

sub _test {
    my($self,$test) = @_;
    my $retval = eval($test);
    print main::STDERR "###the test ($test) was true.\n"  if $debug and $retval;
    print main::STDERR "###the test ($test) was false.\n" if $debug and not $retval;
    return undef if $@;
    return defined $retval ? $retval : 0;
}

sub _entering_if {
    my $self = shift;
    $self->{'_in_if'}++;
    $self->{'_suspend'}->[$self->{'_in_if'}] = $self->{'_suspend'}->[$self->{'_in_if'} - 1];
    $self->{'_seen_true'}->[$self->{'_in_if'}] = 0;
}

sub _seen_true {
    my $self = shift;
    return $self->{'_seen_true'}->[$self->{'_in_if'}];
}

sub _suspended {
    my $self = shift;
    return $self->{'_suspend'}->[$self->{'_in_if'}];
}

sub _leaving_if {
    my $self = shift;
    $self->{'_in_if'}-- if $self->{'_in_if'};
}

sub _true {
    my $self = shift;
    return $self->{'_seen_true'}->[$self->{'_in_if'}]++;
}

sub _suspend {
    my $self = shift;
    $self->{'_suspend'}->[$self->{'_in_if'}]++;
}

sub _resume {
    my $self = shift;
    $self->{'_suspend'}->[$self->{'_in_if'}]--
	if $self->{'_suspend'}->[$self->{'_in_if'}];
}

sub _in_if {
    my $self = shift;
    return $self->{'_in_if'};
}

sub if {
    my($self,$expr,$test) = @_;
    print main::STDERR "###entering if()\n" if $debug;
    $expr = $test if @_ == 3;
    $self->_entering_if();
    if($self->_test($expr)) {
	$self->_true();
    } else {
	$self->_suspend();
    }
    print main::STDERR "###leaving if(), and we're ".($self->_suspended() ? "":"not ")."suspended.\n" if $debug;
    return '';
}

sub elif {
    my($self,$expr,$test) = @_;
    die "Incorrect use of elif ssi directive: no preceeding 'if'." unless $self->_in_if();
    print main::STDERR "###entering elif()\n" if $debug;
    $expr = $test if @_ == 3;
    if(! $self->_seen_true() and $self->_test($expr)) {
	$self->_true();
	$self->_resume();
    } else {
	$self->_suspend() unless $self->_suspended();
    }
    print main::STDERR "###leaving elif(), and we're ".($self->_suspended() ? "":"not ")."suspended.\n" if $debug;
    return '';
}

sub else {
    my $self = shift;
    die "Incorrect use of else ssi directive: no preceeding 'if'." unless $self->_in_if();
    print main::STDERR "###entering else()\n" if $debug;
    unless($self->_seen_true()) {
	$self->_resume();
    } else {
	$self->_suspend();
    }
    print main::STDERR "###leaving else(), and we're ".($self->_suspended() ? "":"not ")."suspended.\n" if $debug;
    return '';
}

sub endif {
    my $self = shift;
    die "Incorrect use of endif ssi directive: no preceeding 'if'." unless $self->_in_if();
    print main::STDERR "###entering endif()\n" if $debug;
    $self->_leaving_if();
    $self->_resume() if $self->_suspended();
    print main::STDERR "###leaving endif(), and we're ".($self->_suspended() ? "":"not ")."suspended.\n" if $debug;
    return '';
}

#
# packages for tie()
#

package CGI::SSI::Gmt;

sub TIESCALAR { bless {},$_[0] }
sub FETCH { gmtime() }

package CGI::SSI::Local;

sub TIESCALAR { bless {},$_[0] }
sub FETCH { localtime() }


1;
__END__


=head1 NAME

 CGI::SSI - Use SSI from CGI scripts

=head1 SYNOPSIS

 #autotie STDOUT or any other open filehandle

   use CGI::SSI (autotie => STDOUT);

   print $shtml; # browser sees resulting HTML

 # or tie it yourself to any filehandle

   use CGI::SSI;

   open(FILE,'+>'.$html_file) or die $!;
   $ssi = tie(*FILE, 'CGI::SSI', filehandle => 'FILE');
   print FILE $shtml; # HTML arrives in the file

 # or use the object-oriented interface

   use CGI::SSI;

   $ssi = CGI::SSI->new();

   $ssi->if('"$varname" =~ /^foo/');
      $html .= $ssi->process($shtml);
   $ssi->else();
      $html .= $ssi->include(file => $filename);
   $ssi->endif();

   print $ssi->exec(cgi => $url);
   print $ssi->flastmod(file => $filename);

 #
 # or roll your own favorite flavor of SSI
 #

   package CGI::SSI::MySSI;
   use CGI::SSI;
   @CGI::SSI::MySSI::ISA = qw(CGI::SSI);

   sub include {
      my($self,$type,$file_or_url) = @_; 
      # my idea of include goes something like this...
      return $html;
   }
   1;
   __END__

=head1 DESCRIPTION

CGI::SSI is meant to be used as an easy way to filter shtml 
through cgi scripts in a loose imitation of Apache's mod_include. 
If you're using Apache, you may want to use either mod_include or 
the Apache::SSI module instead. Due to limitations in a CGI 
script's knowledge of how the server behaves makes some SSI
directives impossible to imitate from a CGI script.

Most of the time, you'll simply want to filter shtml through STDOUT 
or some other open filehandle. C<autotie> is available for STDOUT, 
but in general, you'll want to tie other filehandles yourself:

    $ssi = tie *FH, 'CGI::SSI', filehandle => 'FH';
    print FH $shtml;

Note that you'll need to pass the name of the filehandle to C<tie()> as 
a named parameter. Other named parameters are possible, as detailed 
below. These parameters are the same as those passed to the C<new()> 
method. However, C<new()> will not tie a filehandle.

CGI::SSI has it's own flavor of SSI. Test expressions are Perlish. 
You may create and use multiple CGI::SSI objects; they will not 
step on each others' variables.

Object-Oriented methods use the same general format so as to imitate 
SSI directives:

    <!--#include virtual="/foo/bar.footer" -->

  would be

    $ssi->include(virtual => '/foo/bar.footer');

likewise,

    <!--#exec cgi="/cgi-bin/foo.cgi" -->

  would be

    $ssi->exec(cgi => '/cgi-bin/foo.cgi');

Usually, if there's no chance for ambiguity, the first argument may 
be left out:

    <!--#echo var="var_name" -->

  could be either

    $ssi->echo(var => 'var_name');

  or

    $ssi->echo('var_name');

Likewise,

    $ssi->set(var => $varname, value => $value)

  is the same as 

    $ssi->set($varname => $value)

=over 4

=item $ssi->new([%args])

Creates a new CGI::SSI object. The following are valid (optional) arguments: 

 DOCUMENT_URI    => $doc_uri,
 DOCUMENT_NAME   => $doc_name,
 errmsg          => $oops,
 sizefmt         => ('bytes' || 'abbrev'),
 timefmt         => $time_fmt,

=item $ssi->config($type, $arg)

$type is either 'sizefmt', 'timefmt', or 'errmsg'. $arg is similar to 
those of the SSI C<spec>, referenced below.

=item $ssi->set($varname => $value)

Sets variables internal to the CGI::SSI object. (Not to be confused 
with the normal variables your script uses.) These variables may be used 
in test expressions, and retreived using $ssi->echo($varname).

=item $ssi->echo($varname)

Returns the value of the variable named $varname. Such variables may 
be set manually using the C<set()> method. There are also several built-in 
variables:

 DOCUMENT_URI  - the URI of this document
 DOCUMENT_NAME - the name of the current document
 DATE_GMT      - the same as 'gmtime'
 DATE_LOCAL    - the same as 'localtime'
 FLASTMOD      - the last time this script was modified

=item $ssi->exec($type, $arg)

$type is either 'cmd' or 'cgi'. $arg is similar to the SSI C<spec> 
(see below).

=item $ssi->include($type, $arg)

Same as C<exec>.

=item $ssi->flastmod($type, $filename)

$type is either 'file' or 'virtual'. $arg is similar to the SSI C<spec> 
(see below).

=item $ssi->fsize($type, $filename)

Same as C<flastmod>.

=item $ssi->printenv

Returns the environment similar to Apache's mod_include.

=back

=back

=head2 FLOW-CONTROL METHODS

The following methods may be used to test expressions. During a C<block> 
where the test $expr is false, nothing will be returned (or printed, 
if tied).

=over 4

=item $ssi->if($expr)

=item $ssi->elif($expr)

=item $ssi->else

=item $ssi->endif

=back

=head1 SEE ALSO

C<Apache::SSI> and the SSI C<spec> at
http://www.apache.org/docs/mod/mod_include.html

=head1 COPYRIGHT

Copyright 2000 James Tolley   All Rights Reserved.

This is free software. You may copy and/or modify it under
the same terms as perl itself.

=head1 AUTHOR

James Tolley <james@jamestolley.com>
