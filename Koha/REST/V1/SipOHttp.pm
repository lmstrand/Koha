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
use Socket qw(:crlf);
use IO::Socket::UNIX qw( SOCK_STREAM );
use IO::Socket::Timeout;
use IO::Socket qw(AF_INET AF_UNIX SOCK_STREAM SHUT_WR);
use Getopt::Long;
use lib("/home/koha/Koha");

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
		$c->render(
			text   => "Validation failed. Invalid Request. ",
			status => 400
		);
		return;
	}

	#process sip here
	my $sipmes = extractSip($xmlrequest);

	#TODO Error handling
	#get the proxy server socket params that matches login id in XML message from SIPconfig.xml
	
	my ( $proxyhost, $proxyport ) = extractProxy( $xmlrequest, $c );

	if ( $proxyhost eq '' or $proxyport eq '' ) {

		return $c->render(
			text   => "No config found for login device. ",
			status => 400
		);
	}

	#TODO Error handling, necessary?

	my $sipresponse = tradeSip( $proxyhost, $proxyport, $sipmes, $c );

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

	my ( $proxyhost, $proxyport, $command_message, $c ) = @_;

	#TODO error message to endpoint?

	my $client = IO::Socket::INET->new(
		PeerAddr => $proxyhost,
		PeerPort => $proxyport,
		Proto    => 'tcp'
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

	my @n = $xc->findnodes('//ns1:sip');
	for my $nod (@n) {
		my $login = $nod->getAttribute("login");

		return $login;

		#last;
	}
}

sub extractProxy {

	my $host = "";
	my $port = "";

	#Uses sipdevices.xml file for config.
	my ( $xmlmessage, $c ) = @_;
	my $term = getLogin($xmlmessage);

	my $dom =
	  XML::LibXML->load_xml(
		location => '/home/koha/Koha/koha-tmpl/sipdevices.xml' );
	my $acsconfig = $dom->documentElement;

	foreach my $config ( $acsconfig->findnodes( '//' . $term ) ) {
		$host = $config->findvalue('./proxyhost');
		$port = $config->findvalue('./proxyport');
	}

	#no config found
	if ( $host eq '' or $port eq '' ) {

		$c->app->log->warn(
			"Missing proxy server config parameters for $term in sipdevices.xml"
		);
		return 0;
	}
	else {
		return $host, $port;
	}

}

sub validateXml {

	#For validating the content of the XML SIP message
	my ( $c, $xmlbody ) = @_;
	my $parser = XML::LibXML->new();

	# parse and validate the xml against sipschema
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
