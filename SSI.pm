package CGI::SSI;

use vars qw( $allow_exec $VERSION @ISA @EXPORT_OK );

require Exporter;
use File::Basename;
use Date::Format;

$allow_exec = 0;
$VERSION = 0.01;
@ISA = qw( Exporter );
@EXPORT_OK = qw( get_content ssi );

my $TIME_FORMAT = "%A, %d-%b-%Y %T %Z";
my $SIZE_FORMAT = 'bytes';
my $ERROR = "[an error occurred while processing this directive]";

sub get_content
{
    my $path = shift;

    return undef unless open( FILE, $path );
    my $html = join( '', <FILE> );
    close( FILE );
    return $html;
}

my %ssi = (
    config => sub {
        my $attr = shift;
        my $value = shift;
        
        if ( $attr eq 'errmsg' )
        {
            $ERROR = $value;
        }
        elsif ( $attr eq 'sizefmt' )
        {
            return $ERROR unless $value =~ /^(bytes|abbrev)$/;
            $SIZE_FORMAT = $value;
        }
        elsif( $attr eq 'timefmt' )
        {
            $TIME_FORMAT = $value;
        }
        else
        {
            return $ERROR;
        }
        return '';
    },

    include => sub {
        my $attr = shift;
        my $value = shift;

        return $ERROR unless $attr =~ /^(virtual|file)$/;
        my $path = $attr eq 'virtual' ? 
            "$ENV{DOCUMENT_ROOT}/$value" :
            dirname( $0 ) . "/$value";
        ;
        my $content = get_content( $path );
        return defined( $content ) ? $content : $ERROR;
    },

    fsize => sub {
        my ( undef, $file ) = @_;
        my $path = "$ENV{DOCUMENT_ROOT}/$file";
        return $ERROR unless @stat = stat( $path );
        my $size = $stat[7];
        $size = int( ( $size / 1000 ) + 0.5 ) .'K' if $SIZE_FORMAT eq 'abbrev';
        return( $size );
    },

    flastmod => sub {
        my ( undef, $file ) = @_;
        my $path = "$ENV{DOCUMENT_ROOT}/$file";
        return $ERROR unless @stat = stat( $path );
        my $timestr = time2str( $TIME_FORMAT, $stat[9] );
        return( $timestr );
    },

    echo => sub {
        my ( undef, $var ) = @_;

        return basename( $0 ) if $var eq 'DOCUMENT_NAME';
        return $ENV{SCRIPT_NAME} if $var eq 'DOCUMENT_URL';
        return quotemeta( $ENV{QUERY_STRING} ) if $var eq 'QUERY_STRING_UNESCAPED';
        return time2str( $TIME_FORMAT, time ) if $var eq 'DATE_LOCAL';
        return time2str( $TIME_FORMAT, time, 'GMT' ) if $var eq 'DATE_GMT';
        return time2str( $TIME_FORMAT, ( stat( $0 ) )[9] ) 
            if $var eq 'LAST_MODIFIED'
        ;
        return $ERROR;
    },

    exec => sub {
        my ( $attr, $exec ) = @_;
        return $ERROR unless $allow_exec;
        return $ERROR unless $attr eq 'cmd';
        my $output = qx/$exec/;
        return $? ? $ERROR : $output;
        
    },
);

sub ssi
{
    my $html = shift;
    
    $html =~ s{
        <!--
        \s*
        \#(\S+)\s+
        (\S+)\s*
        =\s*
        "([^"]+)" # "
        \s*
        -->
    }{
        exists( $ssi{$1} ) ? $ssi{$1}($2,$3) : $ERROR
    }geix;
    return $html;
}

#------------------------------------------------------------------------------
#
# True
#
#------------------------------------------------------------------------------

1;

__END__

=head1 NAME

CGI::SSI - a perl module for doing SSI processing in CGIs.

=head1 SYNOPSIS

    use CGI::SSI qw( ssi get_content );

    CGI::SSI::allow_exec = 1;
    print ssi( $html );
    print ssi( get_content( $filename ) );
  
=head1 DESCRIPTION

CGI::SSI is a module which does standard SSI processing on HTML files. It is
intended to be used in CGIs, where the output of the CGI is HTML that included
SSI directives, but where SSI processing is not being done on this output by
the webserver. The standard directives are covered:

=over 4

=item <!--#echo var=(environment_variable)-->

=over 4

=item DOCUMENT_NAME

=item DOCUMENT_URL

=item QUERY_STRING_UNESCAPED

=item DATE_LOCAL

=item DATE_GMT

=item LAST_MODIFIED

=back

=item <!--#include (virtual|file)="..."-->

=item <!--#fsize file="..."-->

=item <!--#flastmod file="..."-->

=item <!--#exec (cmd|cgi)="..."-->

Note that <!--#exec cmd="..." --> is only supported if the package variable
CGI::SSI::allow_exec has been set to true (and will fail in any case if your
CGI is running in taint mode, as it should be!). Also, that <!--#exec
cgi="..."--> is not currently supported.

=item <!--#config (errmsg|timefmt|sizefmt)="..."-->

=back

=head1 AUTHOR

Ave Wrigley <Ave.Wrigley@itn.co.uk>

=head1 COPYRIGHT

Copyright (c) 2001 Ave Wrigley. All rights reserved. This program is free
software; you can redistribute it and/or modify it under the same terms as Perl
itself.

=cut
