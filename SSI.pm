package CGI::SSI;
use strict;

$CGI::SSI::VERSION = '0.01';

#use Socket;
#use URI::Escape;
#use Date::Format;
#use FindBin;
#use File::Spec;

#
# Note: this module uses the above modules to process certain ssi directives.
# These modules are not use'd here because they are not always needed; we
# will only load them if necessary. If any of these modules are unavailable, 
# the relevant directives will fail, returning the current config errmsg.
# The rest of the module will work fine.
#

########### tie some vars for accuracy and ease.
my $gmt;
my $loc;

tie $gmt,'CGI::SSI::Gmt';
tie $loc,'CGI::SSI::Local';
###########

sub import {
    my($class, %args) = @_;
    return unless $args{'autotie'};
    my $filehandle = $args{'autotie'} =~ /::/ ? $args{'autotie'} : (caller())[0].'::'.$args{'autotie'};
    no strict 'refs';
    my $self = tie(*{$filehandle},$class,%args, filehandle => $filehandle);
    return $self;
}

sub new {
    my($class,%args) = @_;
    my $self = bless {}, $class;

    $self->{'_handle'}          = undef;
    $self->{'_variables'}       = {
        DOCUMENT_URI    =>  $args{'DOCUMENT_URI'}  || $ENV{'SCRIPT_NAME'},
        DATE_GMT        =>  $gmt,
        DATE_LOCAL      =>  $loc,
        LAST_MODIFIED   =>  $self->flastmod('file', $ENV{'SCRIPT_FILENAME'} || $ENV{'PATH_TRANSLATED'}),
        DOCUMENT_NAME   =>  $args{'DOCUMENT_NAME'} || ($ENV{'SCRIPT_NAME'} =~ /([^\/]+)$/)[0],
                                  };
    $self->{'_config'}          = {
        errmsg  =>  '[an error occurred while processing this directive]',
        sizefmt =>  'abbrev',
        timefmt =>  undef, # the current locale's default
                                  };
    $self->{'_in_if'}           = 0;
    $self->{'_seen_true'}       = 0;
    $self->{'_suspend'}         = [];
    $self->{'_seen_true'}       = [];
    $self->{'_cache'}           = '';

    return $self;
}

sub TIEHANDLE {
    my($class,%args) = @_;
    my $self = $class->new(%args);

    $self->{'_handle'} = do { local *FH };
    my $handle_to_copy;
    if($args{'filehandle'}) {
        $handle_to_copy = $args{'filehandle'} =~ /::/ ? $args{'filehandle'} : (caller())[0].'::'.$args{'filehandle'};
    } else {
        $handle_to_copy = 'main::STDOUT';
    }
    open($self->{'_handle'},">&$handle_to_copy") or die "Could not copy the filehandle $handle_to_copy: $!";
    return $self;
}

sub PRINT { # TODO return value.
    my($self,@shtml) = @_;
    for my $shtml (@shtml) {
        print {$self->{'_handle'}} $self->process($shtml);
    }
}

sub process {
    local $^W = 0; # ?? TODO
    my($self,@shtml) = @_;
    my $processed = '';
        # TODO - do we want/need this complexity/feature?
    @shtml = split(/((?:<!--#\S+(?:\s*[^=\s]+="(?:\\"|[^"])*")*\s*-->)|(?:<!--#\S+(?:\s*[^=\s]+='(?:\\'|[^'])*')*\s*-->))/,
        $self->_get_cache().join('',@shtml));
    while(@shtml) {
        my $html = shift(@shtml);
        if(@shtml) { # there's more left.
            $processed .= $html;
        } else { # this is the last one, so let's see if there's anything to cache.
            if($html =~ /^(.*)(<[^>]*)$/) { # TODO - is this accurate?
                $processed .= $1;
                $self->_set_cache($2);
            } else {
                $processed .= $html;
            }
        }
        $processed .= $self->_process_ssi_token(shift(@shtml)) if @shtml; # there's nothing uninitialized here, is there?
    }
    return $processed;
}

sub _process_ssi_token {
    my($self,$token) = @_;

    $token =~ /^<!--#\s*(\S+)\s*(.*?)\s*-->$/sm;
    my $method = lc $1;
    my $argument_string = $2; # could be empty.

    my %arguments = ();
    # parse the arguments.
    while($argument_string) {
        if($argument_string =~ s/^\s*(\S+?)="((?:\\"|[^"])*)"//sm) { # double quotes
            my $name = $1;
            $arguments{$name} = $2;
            $arguments{$name} =~ s/\\"/"/g;
        } elsif($argument_string =~ s/^\s*(\S+?)='((?:\\'|[^'])*)'//sm) { # single quotes
            my $name = $1;
            $arguments{$name} = $2;
            $arguments{$name} =~ s/\\'/'/g;
        } else {
            return $self->{'_config'}->{'errmsg'}; # there's a problem - this should not happen.
        }
    }
    %arguments = $self->_interpolate_variables(%arguments);
    my $retval = eval { $self->$method(%arguments) }; # TODO - replace this eval with AUTOLOAD.
    return $self->{'_config'}->{'errmsg'} if $@;
    return $retval;
}

sub _interpolate_variables { # done.
    my($self,%args) = @_;
    my %interpolated = ();
    for my $key (keys %args) {
        $interpolated{$key} = $args{$key} and next if $key eq 'var'; # only do the values.
        my $value = $args{$key};
        my $new_value = '';
        if($self->echo(var => $value) ne '(none)') { # but then you can't have '(none)' as a valid value(?). TODO
            $new_value = $self->echo(var => $value);
        } elsif($value =~ /^\${(?:\\}|[^}])+}$/) { # don't interpolate "${DATE_LOCAL}"(?)
            $new_value = $value;
        } else {
            while($value) {
                if($value =~ s/^\$([^{]\S*)//) { # var without {}
                    my $tmp = $self->echo(var => $1);
                    if($tmp ne '(none)') {
                        $new_value .= $tmp;
                    }
                } elsif($value =~ s/^\${((?:\\}|[^}])+)}//) { # var with {}
                    my $tmp = $self->echo(var => $1);
                    if($tmp ne '(none)') {
                        $new_value .= $tmp;
                    }
                } elsif($value =~ s/^((?:\\\$|\\[^\$]|[^\\\$]|\$$)+)//) { # everything but the start of a variable.
                    # the above regex: one or more of the following: '\$' or '\[^$]' or [^\\] or [^\$] or \\end or $end.
                    $new_value .= $1; # get the rest - no more vars here.
                }
            }
        }
        $interpolated{$key} = $new_value;
    }
    return %interpolated;
}

################ expression test methods.

sub _test {
    my($self,$expr) = @_;
    my $retval = eval($expr); # possibly poor security. TODO
    return $self->{'_config'}->{'errmsg'} if $@;
    return $retval;
}

################ if/elif/else/endif/etc methods.

sub _entering_if {
    my $self = shift();
    $self->{'_in_if'}++;
    $self->{'_suspend'}->[$self->{'_in_if'}] = $self->{'_suspend'}->[$self->{'_in_if'} - 1];
    $self->{'_seen_true'}->[$self->{'_in_if'}] = 0;
}

sub _seen_true {
    my $self = shift();
    return $self->{'_seen_true'}->[$self->{'_in_if'}];
}

sub _suspended {
    my $self = shift();
    return $self->{'_suspend'}->[$self->{'_in_if'}];
}

sub _leaving_if {
    $_[0]->{'_in_if'}--;
}

sub _true {
    my $self = shift();
    $self->{'_seen_true'}->[$self->{'_in_if'}]++;
}

sub _suspend {
    my $self = shift();
    $self->{'_suspend'}->[$self->{'_in_if'}]++;
}

sub _resume {
    my $self = shift();
    $self->{'_suspend'}->[$self->{'_in_if'}]--;
}

sub _in_if {
    return $_[0]->{'_in_if'};
}

sub if {
    my($self,$key,$expr) = @_;
    $expr = $key if @_ == 2; # flexible interface.
    $self->_entering_if();
    if($self->_test($expr)) {
        $self->_true();
    } else {
        $self->_suspend();
    }
    return;
}

sub elif {
    my($self,$key,$expr) = @_;
    die "incorrect use of 'elif' ssi directive: no preceding 'if'." unless $self->_in_if();
    $expr = $key if @_ == 2 ; # flexible interface.
    if(! $self->_seen_true() and $self->_test($expr)) {
        $self->_true();
        $self->_resume();
    } else {
        $self->_suspend() unless $self->_suspended();
    }
    return;
}

sub else {
    my $self = shift();
    die "incorrect use of 'else' ssi directive: no preceding 'if'." unless $self->_in_if();
    unless($self->_seen_true()) {
        $self->_resume();
    } else {
        $self->_suspend() unless $self->_suspended();
    }
    return;
}

sub endif {
    my($self) = shift;
    die "incorrect use of 'endif' ssi directive: no preceding 'if'." unless $self->_in_if();
    $self->_leaving_if();
    $self->_resume() if $self->_suspended();
    return;
}

##################### cache methods.

sub _set_cache { # done.
    my($self,$cache) = @_;
    $self->{'_cache'} = $cache;
}

sub _get_cache { # done.
    my($self) = @_;
    my $tmp = $self->{'_cache'};
    $self->{'_cache'} = '';
    return $tmp;
}

######################### following are the ssi directive routines.

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
    } elsif(exists $args{'errmsg'}) { # errmsg
        $self->{'_config'}->{'errmsg'} = $args{'errmsg'};
    } else {
        return $self->{'_config'}->{'errmsg'};
    }
    return;
}

sub set {
    my($self, %args) = @_;
    if(scalar keys %args > 1) {
        $self->{'_variables'}->{$args{'var'}} = $args{'value'};
    } else { # there's one key, so it must be var => value notation.
        $self->{'_variables'}->{(keys %args)[0]} = (values %args)[0];
    }
    return;
}

sub echo {
    my($self, @args) = @_;
    if(@args > 1) {
        my %args = @args;
        return $self->{'_variables'}->{$args{'var'}} if exists $self->{'_variables'}->{$args{'var'}};
        return $ENV{$args{'var'}} if exists $ENV{$args{'var'}};
    } else { # $args[0] is the name of the var to echo.
        return $self->{'_variables'}->{$args[0]} if exists $self->{'_variables'}->{$args[0]};
        return $ENV{$args[0]} if exists $ENV{$args[0]};
    }
    return '(none)'; # default.
}

sub printenv {
    my $self = shift();
    my $str = '';
    for my $key (keys %ENV) {
        $str .= $key."=".$ENV{$key}."<br>\n";
    }
    return $str;
}

sub _include_virtual {
    my($self,$filename) = @_;
    $filename =~ s/^$ENV{'DOCUMENT_ROOT'}\///i;

    my $host = '';
    my $port = 0;

    if($filename !~ m|^http://|) { # use this host
        $host = lc($ENV{'HTTP_HOST'} || $ENV{'SERVER_NAME'});
        $host =~ /^(.+)$/; # untaint. TODO. make sure this is the localhost?
        $host = $1;
    } else { # other host - parse the host info.
        $filename =~ s|^http://([^:/]+):?(\d+)?||;
        $host = $1;
        $port = $2;
    }

    eval{ require LWP::Simple };
    unless($@) {
        return LWP::Simple::get('http://'.$host.$filename);
    }
        #
        # no LWP, so use Socket.
        #
    eval { require Socket };
    return $self->{'_config'}->{'errmsg'} if $@;

    $port = getservbyname('http','tcp') unless $port;

    my $iaddr = Socket::inet_aton($host)               or return $self->{'_config'}->{'errmsg'};
    my $paddr = Socket::sockaddr_in($port, $iaddr);
    my $proto = getprotobyname('tcp');

    my $h = do { local *FH };

    socket($h, Socket::PF_INET(), Socket::SOCK_STREAM(), $proto)   
                                                       or return $self->{'_config'}->{'errmsg'};
    connect($h, $paddr)                                or return $self->{'_config'}->{'errmsg'};

    select((select($h),$|++)[0]);

    binmode($h);

    print $h join("\015\012" =>
            "GET $filename HTTP/1.0",
            "Host: $host",
            "User-Agent: CGI-SSI/$CGI::SSI::VERSION",
            "","");

    my $return_text = '';
    my $bytes_read = 0;
    1 while $bytes_read = sysread($h, $return_text, 8*1024, length($return_text));
    #return $self->{'_config'}->{'errmsg'} unless defined($bytes_read);

    close($h); # should probably check this, but do I really want to return an error here? TODO

    $return_text =~ /^HTTP\/\d\.\d\s+2/ or return $self->{'_config'}->{'errmsg'};
    $return_text =~ s/.+?\015?\012\015?\012//s;

    return $return_text;
}

sub include {
    my($self,$type,$filename) = @_;
    if($type eq 'file') {
        $filename = $self->_get_absolute($filename) unless(-e $filename);
        return $self->_include_file($filename);
    } else { # virtual
        return $self->_include_virtual($filename);
    }
}

sub _include_file {
    my($self,$filename) = @_;
    return $self->{'_config'}->{'errmsg'} unless(-e $filename);

    my $file = do { local *FH };
    open($file,$filename) or return $self->{'_config'}->{'errmsg'};
    return join('',<$file>);
}

sub exec {
    my($self,$type,$filename) = @_;
    if($type eq 'cgi') {
        my $resource = $self->_get_virtual($filename).$ENV{'PATH_INFO'};
        $resource .= '?'.$ENV{'QUERY_STRING'} if $ENV{'QUERY_STRING'};
        return $self->_include_virtual($resource);
    } else { # cmd
        ($ENV{'PATH'}) = $ENV{'PATH'} =~ /^(.*)$/;
        my $output = `$filename`; # security here is mighty bad. TODO?
        if(! $?) {
            return $output;
        } else {
            return $self->{'_config'}->{'errmsg'};
        }
    }
}

sub fsize {
    my($self,$type,$filename) = @_;

    if($type eq 'file') {
        $filename = $self->_get_absolute($filename);
    } else {
        $filename = $self->_get_absolute_from_virtual($self->_get_virtual($filename));
    }
    return $self->{'_config'}->{'errmsg'} unless(-e $filename);

    my $fsize = (stat($filename))[7];
    if($self->{'_config'}->{'sizefmt'} eq 'bytes') {
        1 while $fsize =~ s/^(\d+)(\d{3})/$1,$2/g;		
        return $fsize;
    } else {
        # gratefully lifted from Apache::SSI.
        return "   0k" unless $fsize;
        return "   1k" if $fsize < 1024;
        return sprintf("%4dk", ($fsize + 512)/1024) if $fsize < 1048576;
        return sprintf("%4.1fM", $fsize/1048576.0)  if $fsize < 103809024;
        return sprintf("%4dM", ($fsize + 524288)/1048576);
    }
}

sub flastmod {
    my($self,$type,$filename) = @_;

    if($type eq 'file') {
        $filename = $self->_get_absolute($filename);
    } else { # virtual
        $filename = $self->_get_absolute_from_virtual($self->_get_virtual($filename));
    }
    return $self->{'_config'}->{'errmsg'} unless(-e $filename);

    my $flastmod = (stat($filename))[9];
    if(! $self->{'_config'}->{'timefmt'}) { # undef by default
        return scalar localtime($flastmod);
    } else {
        eval { require Date::Format };
        return $self->{'_config'}->{'errmsg'} if $@;
        my @localt = localtime($flastmod); # is this really necessary? TODO
        return Date::Format::strftime($self->{'_config'}->{'timefmt'},\@localt);
    }
}

sub _get_absolute_from_virtual {
    my($self,$filename) = @_;
    my $absolute = '';
    $filename =~ s|^\/||;
    my $path = $ENV{'DOCUMENT_ROOT'};

    eval { require File::Spec };
    return if $@;

    eval { require File::Basename };
    return if $@;
    $absolute = File::Spec->catfile($path,$filename);
    return $absolute if -e $absolute;

    $absolute = File::Spec->catfile(File::Basename::dirname($path),$filename);
    return $absolute if -e $absolute;

    return;
}

sub _get_virtual { # filename
    my($self,$filename) = @_;
    my $return_filename = '';

    return $filename if(-e $filename); # do we need this? TODO

    eval { require File::Spec };
    return $self->{'_config'}->{'errmsg'} if $@;

    $return_filename = File::Spec->catfile($ENV{'DOCUMENT_ROOT'}, $filename);
    return $return_filename if(-e $return_filename);

    eval { require FindBin };
    return $self->{'_config'}->{'errmsg'} if $@;

    $return_filename = File::Spec->catfile($FindBin::Bin, $filename);
    return $return_filename if(-e $return_filename);

    return $filename;
}

sub _get_absolute { # filename
    my($self,$filename) = @_; # $type is 'file'

    return $filename if(-e $filename);

    eval { require File::Spec };
    return if $@;

    eval { require FindBin };
    return if $@;

    $filename = File::Spec->catfile($FindBin::Bin, $filename);
    return $filename;
}

sub DESTROY {
    my $self = shift;
    print {$self->{'_handle'}} $self->_get_cache() if $self->{'_handle'};
}

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

    # autotie STDOUT or any other open filehandle

    use CGI::SSI (autotie => 'STDOUT');

    print $shtml; # browser sees resulting HTML

    # or tie it yourself to any filehandle.

    use CGI::SSI;

    open(FILE,"$html_file")    or die $!;
    my $ssi = tie(*FILE,'CGI::SSI', filehandle => 'FILE')
            or die 'no tie';
    print FILE $shtml; # HTML arrives in the file

    # or use the Object-Oriented interface:

    my $ssi = CGI::SSI->new();

    $ssi->if($expr);
        $html .= $ssi->process($shtml);
    $ssi->else();
        $html .= $ssi->process($shtml2);
    $ssi->endif();

    print $ssi->include($type, $path);
    print $ssi->flastmod($filename);

    # or roll your own favorite flavor of SSI:

    package CGI::SSI::MySSI;
    use CGI::SSI;
    @CGI::SSI::MySSI::ISA = qw(CGI::SSI);

    sub include {
        my($self,$type,$arg) = @_; # $type is 'file' or 'virtual'
        # my idea of include goes something like this...
        return $html;
    }
    1;

=head1 DESCRIPTION

C<CGI::SSI> has it's own flavor of SSI. Test expressions are Perlish.
You may create and use multiple CGI::SSI objects. They will not step on
each other's variables.

You can either tie (or autotie) a filehandle, or use the following
interface methods. When STDOUT is tied, printing shtml will result in
the browser seeing the result of ssi processing.

If you are going to tie a filehandle manually, you need to pass the name
of the filehandle to C<CGI::SSI> like so:

tie(*FH,'CGI::SSI', filehandle => 'FH');

=over 4

=item $ssi = CGI::SSI->new()

Creates a new CGI::SSI object.

=item $ssi->config($type, $argument) 

$type is either 'errmsg','timefmt', or 'sizefmt'. Valid values for 
$argument depend on $type:

errmsg - Any string. Defaults to '[an error occurred while 
            processing this directive]'.

timefmt - A valid first argument to 
            Date::Format::strftime(). Defaults to 
            'scalar localtime()'.

sizefmt - 'bytes' or 'abbrev'. Default is 'abbrev'.

=item $ssi->echo($varname)

Returns the value of $varname.

=item $ssi->exec($type, $resource) 

$type may be 'cmd' or 'cgi'. $resource is either an absolute or 
relative filename.

=item $ssi->flastmod($type, $resource)

$type is either 'file' or 'virtual'. $resource is either a relative
or absolute filename.

=item $ssi->fsize($type, $resource)

Arguments are identical to those of flastmod().

=item $ssi->include($type, $resource)

Arguments are identical to those of exec().

=item $ssi->printenv()

Returns a listing of the environment variable names and their values.

=item $ssi->set($varname, $value)

Associate a value with a variable.

=back

=head2 FLOW CONTROL METHODS

The following methods may be used for flow-control. During a `block' where
the test $expr was false, nothing will be returned (or printed, if tied).

=over 4

=item $ssi->if($expr)

If $expr is excluded, it's considered to be false.

=item $ssi->elif($expr)

If $expr is excluded, it's considered to be false.

=item $ssi->else()

=item $ssi->endif()

=back

=head1 SEE ALSO

Apache::SSI and the SSI 'spec' at: 
http://www.apache.org/docs/mod/mod_include.html

=head1 COPYRIGHT

Copyright 1999 James Tolley   All Rights Reserved.

This is free software. You may copy and/or modify it under 
the same terms as perl itself.

=head1 AUTHOR

James Tolley <james@jamestolley.com>
