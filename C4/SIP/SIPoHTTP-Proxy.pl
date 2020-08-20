#!/usr/bin/perl
use strict;
use warnings;
use IO::Socket::INET;
use IO::Socket qw(AF_INET AF_UNIX SOCK_STREAM SHUT_WR);
use Socket qw(:crlf);
use XML::LibXML;
use autodie;
use lib 'lib';
use POSIX qw(strftime);

binmode STDERR, ':utf8';

#This is a self service proxy server for communication between the Koha REST "sipmessages" endpoint
#and between a sipserver via Socket::INET sockets.

#Sipserver's service parameter must be set: client_timeout="0" in SIPconfig.xml for this script to work properly!
#Self check device handles timeouts.

#While we attempt to write things to read-side through socket, if the socket of read-side already closed,
#the write-side would got a signal SIGPIPE, that causes write-side killed by SIGPIPE.
#????Prevents server from shutting down
$SIG{PIPE} = 'IGNORE';

$SIG{'TSTP'} = 'IGNORE';    # Ctrl-Z disabled

#Get command line argument (the sipdevice name = xml login parameter)
my $device = shift or die "Usage: $0 SIPDEVICELOGINNAME\n";

print STDERR getTime() . "Starting proxy server for: $device \n"
  if ( $ENV{'DEBUG'} && $ENV{'DEBUG'} == 2 );

my ( $proxyhost, $proxyport, $siphost, $sipport ) = getConfig($device);

#TODO change into var/spool/ in sipdevices.xml

$| = 1;                     # Autoflush

#Needs to be a plain IO::Socket so we can use $client_socket->shutdown(SHUT_RD) and (SHUT_WR)to end
#reading/writing to sipserver without problems and preserving socket connection

my $server = IO::Socket->new(
	Domain    => AF_INET,
	Type      => SOCK_STREAM,
	Proto     => 'tcp',
	LocalHost => $proxyhost,
	LocalPort => $proxyport,
	ReusePort => 1,
	KeepAlive => 0,
	Listen    => 5
) || die getTime() . "Can't open proxy socket for $device: $@";

#handle signals
#TODO CTRL+C sends an emtpy message to sipserver
$SIG{TERM} = $SIG{INT} = $SIG{HUP} = sub {
	print STDERR getTime()
	  . "SIGTERM - External termination request. Leaving...\n"
	  if ( $ENV{'DEBUG'} && $ENV{'DEBUG'} == 2 );
	if ($server) {
		print STDERR getTime() . "Closing server socket. \n"
		  if ( $ENV{'DEBUG'} && $ENV{'DEBUG'} == 2 );
		$server->shutdown(SHUT_RDWR);
		$server->close;
		exit;
	}
	else {
		exit;
	}
};

#Socket:INET to sipserver
my $sipsocket = IO::Socket::INET->new(

	PeerHost  => $siphost,
	PeerPort  => $sipport,
	Proto     => 'tcp',
	KeepAlive => 1,
	Reuse     => 1

  )
  or die getTime()
  . "Couldn't be a tcp server for sipsocket on $siphost:$sipport : $@\n";

print STDERR getTime() . "Waiting for tcp to connect to $proxyport\n"
  if ( $ENV{'DEBUG'} && $ENV{'DEBUG'} == 2 );

while (1) {

	my $client_socket = $server->accept();

	#?
	#my $sip_socket = $sipsocket->accept();

	print STDERR getTime() . "Socket has connected.\n"
	  if ( $ENV{'DEBUG'} && $ENV{'DEBUG'} == 2 );

	connection( $client_socket, $sipsocket );

}

$server->close;

sub connection {

	my $client_socket = shift;
	$client_socket->autoflush(1);
	my $sipsock = shift;
	$sipsock->autoflush(1);

	if ( $sipsock->connected ) {
		print STDERR getTime() . "Connection to SIP socket OK. \n"
		  if ( $ENV{'DEBUG'} && $ENV{'DEBUG'} == 2 );
	}

	else {
		die getTime() . "Can't connect to SIP socket. : $@\n";
	}

	while (1) {

		if ( $sipsock->connected ) {

			#Still connected to SIP socket

			my $data     = "";
			my $respdata = "";

			$data = <$client_socket>;

			#end reading from socket. $CR etc do not work.
			$client_socket->shutdown(SHUT_RD);
			$client_socket->flush;

			if ( $data eq "" ) {
				print STDERR getTime() . "Empty request!" if $ENV{'DEBUG'};

				#return;
			}

			print STDERR getTime() . ">>>>>> Sending: $data\n"
			  if ( $ENV{'DEBUG'} && $ENV{'DEBUG'} == 2 );

			print $sipsock $data;

			$sipsock->recv( $respdata, 1024 );
			$sipsock->flush;

			print STDERR getTime()
			  . "<<<<<< Received from SIPserver: $respdata\n\n"
			  if ( $ENV{'DEBUG'} && $ENV{'DEBUG'} == 2 );

			######Handle empty message ---_> next message needs a fresh connection
			######Is this a failsafe in sipserver?
			if ( $respdata eq "" ) {
				print STDERR getTime()
				  . "Sip server returned no data (bad device login mes/sipserver down?) $data\n"
				  if $ENV{'DEBUG'};
				my $errordata = "Bad device login.";

				#Send disconnect info to REST
				print $client_socket $errordata . $CR;

				#end writing to socket
				#$client_socket->shutdown(SHUT_WR);

				#?
				#$client_socket->shutdown(SHUT_RDWR)
				;    # we stopped using this socket
				     #$client_socket->close;
				print STDERR getTime()
				  . "Sipserver disconnected. Reconnecting...\n"
				  if $ENV{'DEBUG'};

				#Socket:INET to sipserver
				$sipsocket = IO::Socket::INET->new(

					PeerHost  => $siphost,
					PeerPort  => $sipport,
					Proto     => 'tcp',
					KeepAlive => 1,
					Reuse     => 1
				  )
				  
				  or die getTime()
				  . "Couldn't be a tcp server for sipsocket on $siphost:$sipport : $@\n";

				if ( $sipsock->connected ) {
					print STDERR getTime() . "Connection to SIP socket OK. \n"
					  if ( $ENV{'DEBUG'} && $ENV{'DEBUG'} == 2 );
				}

			}
			else {
				print $client_socket $respdata . $CR;
			}

			######Handle empty message -> next message needs a fresh connection -> restart proxy server

			#end writing to socket
			$client_socket->shutdown(SHUT_WR);
			$client_socket->shutdown(SHUT_RDWR);  # we stopped using this socket
			$client_socket->close;

			print STDERR getTime()
			  . "Response message passed to REST endpoint. Done. Listening...  \n\n"
			  if ( $ENV{'DEBUG'} && $ENV{'DEBUG'} == 2 );
			return;
		}

		else {
			print STDERR getTime() . "Sipserver socket Disconnected\n"
			  if $ENV{'DEBUG'};

			#Try to establish a new fresh connection or die?
			exit;

		}
	}

}

sub getTime {
	my $time = ( strftime "[%Y/%m/%d %H:%M:%S] ", localtime );
	return $time;
}

sub getConfig {

	#reads sip server info from config file and returns socket setup parameters

	my $device = shift;

	my ( $proxyhost, $proxyport, $host, $port );

	my $dom =
	  XML::LibXML->load_xml(
		location => "/home/koha/Koha/koha-tmpl/sipdevices.xml" );

	foreach my $sipserver ( $dom->findnodes( '//' . $device ) ) {

		$proxyhost = $sipserver->findvalue('./proxyhost');

		$proxyport = $sipserver->findvalue('./proxyport');

		$host = $sipserver->findvalue('./host');

		$port = $sipserver->findvalue('./port');

	}
	if (    length $host
		and length $port
		and length $proxyhost
		and length $proxyport )
	{
		print STDERR getTime()
		  . "Found config: '$host' '$port'  in sipdevices.xml. \n"
		  if ( $ENV{'DEBUG'} && $ENV{'DEBUG'} == 2 );
		return $proxyhost, $proxyport, $host, $port;

	}
	else {
		die getTime() . "Missing parameters for '$device' in sipdevices.xml \n"
		  if $ENV{'DEBUG'};
	}

}

