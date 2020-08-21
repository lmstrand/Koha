package Koha::REST::V1::SIPoHTTP::SIPoHTTP;

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
use XML::LibXML;
use IO::Socket::INET;
use IO::Socket qw(AF_INET AF_UNIX SOCK_STREAM SHUT_WR);
use Socket qw(:crlf);
use Try::Tiny;
use File::Slurp;
use Mojo::Log;

use strict;
use warnings qw( all );

# Customize log file location and minimum log level
my $log = Mojo::Log->new(path => '/home/koha/koha-dev/var/log/SIPoHTTP.log', level => 'info');

#This gets called from REST api
sub process {
	
	my $c = shift->openapi->valid_input or return;

	my $body = $c->req->body;
	my $xmlrequestesc = $body;
	
	$log->info("Request received.");
	
	#unescape
	$xmlrequestesc =~ s/\\//g;
	$xmlrequestesc =~ s/^"(.*)"$/$1/;
	
	my $xmlrequest = $xmlrequestesc;

	#TODO validate only if there's stuff in body?
	my $validation = validateXml( $c, $xmlrequest );

	if ( $validation != 1 ) {
		
		$c->render(
			text   => "Validation failed. Invalid Request. ",
			status => 400
		);
		
		return;
	}

	#process sip here
	my ($login, $password) = getLogin($xmlrequest);
	my $sipmes = extractSip($xmlrequest, $c);
	
	if ($sipmes eq ""){
		
			$c->render(
			text   => "Missing SIP Request in XML. ",
			status => 400
		);
		return;
	}

	#TODO Error handling
	#get the proxy server socket params that matches login id in XML message from SIPconfig.xml
	
	my ( $siphost, $sipport ) = extractServer( $xmlrequest, $c );

	if ( $siphost eq '' or $sipport eq '' ) {
		
		$log->error("No config found for login device. ");

		return $c->render(
			text   => "No config found for login device. ",
			status => 400
		);
		
	}

	my $sipresponse = tradeSip($login, $password, $siphost, $sipport, $sipmes, $c );

	#remove carriage return from response (\r)
	$sipresponse =~ s/\r//g;

	my $xmlresponse = buildXml($sipresponse);

	return try {
		$c->render( status => 200, text => $xmlresponse );
		$log->info("XML response passed to endpoint.");
		
	}
	catch {
		Koha::Exceptions::rethrow_exception($_);
	}
}

sub tradeSip {

	my ( $login, $password, $host, $port, $command_message, $c ) = @_;

	my $sipsock = IO::Socket::INET->new(
		PeerAddr => $host,
		PeerPort => $port,
		Proto    => 'tcp'
	) or die $log->error("Can't connect to sipserver at $host:$port.");

	$sipsock->autoflush(1);
	
	my $loginsip = buildLogin ($login, $password);

	my $terminator = q{};
	$terminator = ( $terminator eq 'CR' ) ? $CR : $CRLF;

	# Set perl to expect the same record terminator it is sending
	$/ = $terminator;

	$log->info("Trying login: $loginsip");
		
	my $respdata = "";
	
	print $sipsock $loginsip . $terminator;
	
	$sipsock->recv( $respdata, 1024 );
	$sipsock->flush;
	
	if ($respdata == "941") {

		$log->info("Login OK. Sending: $command_message");
		
		print $sipsock $command_message . $terminator;

		$sipsock->recv( $respdata, 1024 );
		$sipsock->flush;
		
		#end writing to socket
		$sipsock->shutdown(SHUT_WR);
		$sipsock->shutdown(SHUT_RDWR);  # we stopped using this socket
		$sipsock->close;
		
		my $respmes = $respdata;
		$respmes =~ s/.{1}$//;
			
		$log->info("Received: $respmes");	
	
		return $respdata;
	}
	
	chomp $respdata;
	$log->error("Unauthorized login for $login: $respdata. Can't process attached SIP message.");
	
	return $respdata;
}

sub buildLogin {
	
	my ( $login, $password) = @_;
	my $siptempl = "9300CN<SIPDEVICE>|CO<SIPDEVICEPASS>|CPSIPLOCATION|";
    $siptempl =~ s|<SIPDEVICE>|$login|;
	$siptempl =~ s|<SIPDEVICEPASS>|$password|;
	
	return $siptempl;
}

sub buildXml {
	
	my $responsemessage = shift;

	# open the html template
	
	my $respxml = read_file("/home/koha/Koha/Koha/REST/V1/SIPoHTTP/Templates/siprespxml.tmpl");
	$respxml =~ s|<TMPL_VAR NAME=MESSAGE>|$responsemessage|;

	return $respxml;
}

sub extractSip {

	my ($xmlmessage, $c) = @_;
	
	
		
	my $parser     = XML::LibXML->new();
	my $xmldoc     = $parser->load_xml( string => $xmlmessage );

	# for finding all stuff inside <request></request>
	my $messageparam = 'request';

	for my $sample ( $xmldoc->findnodes( './/' . $messageparam ) )

	{

		#remove <request></request> headers
		$sample = $sample->to_literal();
		
		if ($sample eq ""){
			$log->error("Missing SIP message inside XML.");
			return;
		}
		$log->info("SIP message found in XML: $sample");

		return $sample;
	}
}

sub getLogin {

	#Retrieve the self check machine login info from XML
	my $xmlmessage = shift;
	
	my ($login, $passw) = "";

	#my $dom = XML::LibXML->load_xml( string => $xmlmessage );
	my $parser = XML::LibXML->new();
	my $doc    = $parser->load_xml( string => $xmlmessage );
	my $xc     = XML::LibXML::XPathContext->new( $doc->documentElement() );

	#$xc->registerNs( 'ns', 'sip' );

	my @n = $xc->findnodes('//ns1:sip');
	for my $nod (@n) {
		$login = $nod->getAttribute("login");
		#last;
	}
	
	my @n = $xc->findnodes('//ns1:sip');
	for my $nod (@n) {
		$passw = $nod->getAttribute("password");
		#last;
	}
	
	return $login, $passw;
	
}

sub extractServer {

	my $host = "";
	my $port = "";

	#Uses sipdevices.xml file for config.
	my ( $xmlmessage, $c ) = @_;
	my ($term, $pass) = getLogin($xmlmessage);
	
	my $dom =
	  XML::LibXML->load_xml(
		location => '/home/koha/Koha/koha-tmpl/sipdevices.xml' );
	my $acsconfig = $dom->documentElement;

	foreach my $config ( $acsconfig->findnodes( '//' . $term ) ) {
		$host = $config->findvalue('./host');
		$port = $config->findvalue('./port');
	}

	#no config found
	if ( $host eq '' or $port eq '' ) {

		$log->error("Missing server config parameters for $term in sipdevices.xml");
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
	# https://koha-suomi.fi/sipschema.xsd

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
			$log->error("Could not validate XML - @_\n");
			return 0;
		}
		else {
			$log->info("XML Validated OK.");
			return 1;
		}
	};

}

1;
