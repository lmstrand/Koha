package Koha::REST::V1::SipOHttp;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

use FindBin qw($Bin);
use lib "$Bin";
use Koha::Exceptions;
use Koha::Logger;
use Data::Dumper;
use XML::LibXML;
use XML::Simple;
use Socket qw(:crlf);
use IO::Socket::UNIX qw( SOCK_STREAM );
use IO::Socket::Timeout;
use IO::Socket qw(AF_INET AF_UNIX SOCK_STREAM SHUT_WR);
use Getopt::Long;
use lib("/home/koha/Koha");
#use Errno qw( EAGAIN EINTR );

use HTML::Template;
use Try::Tiny;

#This gets called from REST api
sub process {
	my $c = shift->openapi->valid_input or return;

	my $body       = $c->req->json;
	my $xmlrequest = $body->{request_xml};

	#TODO validate only if there's stuff in body
	my $validation = validateXml( $c, $xmlrequest );

	if ( $validation != 1 ) {
		$c->render( text => "Invalid Request. '$xmlrequest'", status => 400 );
		return;
	}

	#process sip here

	my $sipmes = extractSip($xmlrequest);

	#get terminal info in XML login:"
	#TODO Error handling

#get the proxy server UNIX socket location that matches login id in XML message from SIPconfig.xml
	my $proxyloc = getProxy( $xmlrequest, $c );

	#TODO Error handling
	
	#UNIX socket
	my $sipresponse = tradeSip( $proxyloc, $sipmes, $c );

	#remove carriage return from response (\r)
	$sipresponse =~ s/\r//g;

	my $xmlresponse = buildXml($sipresponse);

	return try {
		$c->render( status => 200, text => $xmlresponse );
	}
	catch {
		Koha::Exceptions::rethrow_exception($_);
	}
}

sub tradeSip {

	#For UNIX socket
	my ( $SOCK_PATH, $sipmes, $c ) = @_;

	my $command_message = $sipmes;
	
	#TODO error message to endpoint?
	my $client    = IO::Socket::UNIX->new(
		Type => SOCK_STREAM(),
		Peer => $SOCK_PATH,
	) or die("Can't connect to proxy server: $!\n");

	$client->autoflush(1);

	my $terminator = q{};
	$terminator = ( $terminator eq 'CR' ) ? $CR : $CRLF;

	# Set perl to expect the same record terminator it is sending
	$/ = $terminator;

	print $client $command_message . $terminator;

	my $data = $client->getline();

	$client->close();

	return $data;
}

sub buildXml {

	my $responsemessage = shift;

	# open the html template

	my $template = HTML::Template->new(
		filename => 'sipresp.tmpl',
		path     => ['/home/koha/Koha/koha-tmpl/'],
	);

	# fill in MESSAGE param in template
	$template->param( MESSAGE => $responsemessage );

	# send the obligatory Content-Type and return the template output
	
	my $respxml = $template->output();

	return $respxml;
}

sub extractSip {

	my $xmlmessage = shift;
	my $parser     = XML::LibXML->new();
	my $xmldoc     = $parser->load_xml( string => $xmlmessage );

	# for finding all stuff inside <request></request>
	my $messageparam = 'request';

	for my $sample ( $xmldoc->findnodes( './/' . $messageparam ) )

	{

		#remove <request></request> headers
		$sample = $sample->to_literal();

		#die "Sipmessage inside XML request empty" unless $sample;
		return $sample;
	}
}

sub getLogin {

	#Retrieve the self check machine name or "login:" from XML
	my $xmlmessage = shift;

	#my $dom = XML::LibXML->load_xml( string => $xmlmessage );
	my $parser = XML::LibXML->new();
	my $doc    = $parser->load_xml( string => $xmlmessage );
	my $xc     = XML::LibXML::XPathContext->new( $doc->documentElement() );

	#$xc->registerNs( 'ns', 'sip' );

	#use for loop?
	my @n = $xc->findnodes('//ns1:sip');
	for my $nod (@n) {
		my $login = $nod->getAttribute("login");

		return $login;

		#last;
	}
}

sub getProxy {

	#For reading the terminal's proxy socket path for "login" in xml message.

	my ( $xmlmessage, $c ) = @_;

	my $loginid = getLogin($xmlmessage);

	#
	# Read configuration from SIPconfig.xml
	#
	# Throws a Plack error
	#
	#my $config = C4::SIP::Sip::Configuration->new( $ARGV[0] );
	#my @logins;
	#my @proxies;

	#	#
	#	# Ports to bind
	#	#
	#	foreach my $svc ( keys %{ $config->{listeners} } ) {
	#		push @logins, "login=" . $svc;
	#	}
	#	foreach my $svc ( keys %{ $config->{listeners} } ) {
	#		push @proxies, "proxy_socket=" . $svc;
	#	}
	#
	#	my %hash;
	#	@hash{@logins} = @proxies;

	
	#these parameters are hard coded to match proxy config in      
	#the systemd service file /etc/systemd/system/sipproxy.service
 	
	# key/value
	# key = sip device name (the "login" parameter in XML)
	# value = location of the unix socket file
	
	#TODO read from config file? Can systemd services file use the same file to read and pass parameters?
	
	my %hash = (
		'sipdevice1', '/home/koha/Koha/koha-tmpl/test.sock',
		'sipdevice2', '/home/koha/Koha/koha-tmpl/test2.sock'
	);
	
	#Return socket path matching the "login" parameter in request XML
	if ( exists( $hash{$loginid} ) ) {

		$c->app->log->warn(
			"Proxy socket location found for '$loginid': '$hash{$loginid}'\n");
		return $hash{$loginid};
	}
	else {
		$c->app->log->warn("Proxy socket for '$hash{$loginid}' not defined!\n");
		return 1;
	}

}

sub validateXml {

	#For validating the content of the XML SIP message
	my ( $c, $xmlbody ) = @_;
	my $parser = XML::LibXML->new();

	# parse and validate the xml against sipchema
	# http://biblstandard.dk/rfid/dk/rfid_sip2_over_https.htm
	#Todo make a Koha specific version

	my $schema =
	  XML::LibXML::Schema->new(
		location => '/home/koha/Koha/koha-tmpl/sipschema.xsd' );

	try {
		my $xmldoc = $parser->load_xml( string => $xmlbody );
		$schema->validate($xmldoc);
		return 1;
	}
	catch {
		# ...code run in case of error
		return 0;
	}
	finally {
		if (@_) {
			$c->app->log->warn("Could not validate '$xmlbody' - @_\n");
			return 0;
		}
		else {
			#$c->app->log->warn("XML validated OK.");
			return 1;
		}
	};

}

1;
