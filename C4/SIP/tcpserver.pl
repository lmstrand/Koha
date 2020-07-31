#!/usr/bin/perl
use strict;
use warnings;

use IO::Socket::INET;
use IO::Socket qw(AF_INET AF_UNIX SOCK_STREAM SHUT_WR);
use threads;
use Socket qw(:crlf);
use IO::Select;
use IO::Socket::UNIX qw( SOCK_STREAM SOMAXCONN );
use XML::Simple;
use XML::LibXML;
use Data::Dump qw(dump);
use Data::Dumper;
use autodie;
use DateTime;

use lib 'lib';

#This is a self service proxy server for communication between the Koha REST "sipmessages" endpoint
#via a UNIX socket and between the sipserver via a Socket::INET socket.

#Sipserver's service parameter must be set: client_timeout="0" in SIPconfig.xml for this script to work properly!
#Self check device handles timeouts.

#TODO pass sip server parameters in @ARGV

#While we attempt to write things to read-side through socket, if the socket of read-side already closed,
#the write-side would got a signal SIGPIPE, that causes write-side killed by SIGPIPE.
#????Prevents server from shutting down
$SIG{PIPE} = 'IGNORE';

$SIG{'TSTP'} = 'IGNORE';    # Ctrl-Z disabled

#Exit server program with CTRL+C, Zombies with Z

my $port_listen = 2836;

my $device = shift or die "Usage: $0 SIPDEVICELOGINNAME\n";

print "Starting proxy server for device $device: \n";

my ( $socket, $siphost, $sipport ) = getConfig($device);

#TODO change into var/spool/ in sipdevices.xml
my $SOCK_PATH = $socket;
unlink($SOCK_PATH) if -e $SOCK_PATH;

$| = 1;    # Autoflush

#Needs to be a plain IO::Socket so we can use $client_socket->shutdown(SHUT_RD) and (SHUT_WR)to end
#reading/writing to sipserver without problems and preserving socket connection

#    my $server = IO::Socket->new(
#        Domain => AF_INET,
#        Type => SOCK_STREAM,
#        Proto => 'tcp',
#        LocalHost => '0.0.0.0',
#        LocalPort => $port_listen,
#        ReusePort => 1,
#        KeepAlive => 0,
#        Listen => 5
#
#    ) || die "Can't open socket: $@";

#UNIX Socket for REST endpoint (SipOHttp)
my $server = IO::Socket::UNIX->new(
	Type   => SOCK_STREAM(),
	Local  => $SOCK_PATH,
	Listen => SOMAXCONN,
) or die("Can't create server socket: $!\n");

#Change socketfile permissions for client, needs to be 777
chmod 0777, $SOCK_PATH;

#Socket:INET to sipserver
my $sipsocket = IO::Socket::INET->new(

	PeerHost  => $siphost,
	PeerPort  => $sipport,
	Proto     => 'tcp',
	KeepAlive => 1,
	Reuse     => 1

) or die "Couldn't be a tcp server on port '$sipport' : $@\n";

print "Waiting for tcp to connect to $SOCK_PATH\n";

while (1) {

	my $client_socket = $server->accept();

	#?
	#my $sip_socket = $server->accept();

	#non-UNIX socket params for print

	#my $client_address = $client_socket->peerhost;
	#my $client_port    = $client_socket->peerport;
	#my $sip_addr = $sip_socket->peerhost;
	#my $sip_port = $sip_socket->peerport;

	#my $datetime = DateTime->now;

	print "Unix Socket has connected\n";

	#If using threads:
	#threads->create( \&connection, $client_socket, $sipsocket );

	#No threads:
	connection( $client_socket, $sipsocket );

}

$server->close;

sub connection {

	my $client_socket = shift;
	$client_socket->autoflush(1);
	my $sipsock = shift;
	$sipsock->autoflush(1);

	if ( $sipsock->connected ) {
		print "Connection to SIP socket OK. \n";
	}

	else {
		#???????????????????????
		#How to test if sipserver socket has disconnected
		print "Sip socket closed!";
		my $sipsocket = IO::Socket::INET->new(

			PeerHost  => '10.0.3.217',
			PeerPort  => 6009,
			Proto     => 'tcp',
			KeepAlive => 1,
			Reuse     => 1

		) or die "Couldn't be a tcp server on port 6009 : $@\n";
	}

	#	my $select = IO::Select->new();
	#	#my $sock   = IO::Socket->new(...);
	#	$select->add($sipsock);
	#	if ( my @sockets = $select->can_read() ) {
	#		...;
	#	}
	#}

	#print "Sipsocket has timed out, trying to reconnect...";
	#$sipsock = IO::Socket::INET->new(
	#
	#	PeerHost  => '10.0.3.217',
	#	PeerPort  => 6009,
	#	Proto     => 'tcp',
	#	KeepAlive => 1,
	#	Reuse     => 1
	#
	#) or die "Couldn't be a tcp server on port 6009 : $@\n";
	#}

	while (1) {

		if ( $sipsock->connected ) {

			#print "Still connected to SIP socket. \n";

			my $data     = "";
			my $respdata = "";

			#my $terminator = q{};
			#$terminator = ( $terminator eq 'CR' ) ? $CR : $CRLF;

			$data = <$client_socket>;

			#end reading from socket. $CR etc do not work.
			$client_socket->shutdown(SHUT_RD);
			$client_socket->flush;

			#Should only happen when sipserver closed socket.
			if ( $data eq "" ) {
				print "Empty request!"

				  #return;
			}

			#my $datetime = DateTime->now;
			print ">>>>>> Sending: $data\n";

			print $sipsock $data;

			$sipsock->recv( $respdata, 1024 );
			$sipsock->flush;

			#$datetime = DateTime->now;
			print "<<<<<< Received from SIPserver: $respdata\n\n";

			######Handle empty message ---_> next message need a fresh connection
			######Is this a failsafe in sipserver? Prevent sipserver from disconnecting?
			if ( $respdata eq "" ) {
				print
"Sip server returned no data (bad device login mes/sipserver down?) $data\n";
				my $errordata = "Disconnected!";

				#Send disconnect info to REST
				print $client_socket $errordata . $CR;

				#end writing to socket
				$client_socket->shutdown(SHUT_WR);

				#?
				$client_socket->shutdown(SHUT_RDWR)
				  ;    # we stopped using this socket
				$client_socket->close;
				print "Sipserver disconnected. Exiting...\n";
				exit;
			}
			else {
				print $client_socket $respdata . $CR;
			}

			######Handle empty message ---_> next message nned a fresh connection

			#end writing to socket
			$client_socket->shutdown(SHUT_WR);

			#?
			$client_socket->shutdown(SHUT_RDWR);  # we stopped using this socket
			$client_socket->close;

			#$datetime = DateTime->now;
			print
"Sipserver response message passed to REST endpoint. Done. Listening...  \n\n";
			return;
		}

		else {
			print "Sipserver socket Disconnected\n";

			#Try to establish a new fresh connection or die?
			#connection( $client_socket, $sipsock );
			exit;

		}
	}

}

sub getConfig {

	#reads sip server info from config file and returns setup parameters
	#TODO read info from SIPdevices.xml????

	my $device = shift;

	my ( $servsocket, $host, $port );

	my $dom =
	  XML::LibXML->load_xml(
		location => "/home/koha/Koha/koha-tmpl/sipdevices.xml" );

	foreach my $sipserver ( $dom->findnodes( '//' . $device ) ) {

		$host = $sipserver->findvalue('./host');

		#print "$host:";
		$port = $sipserver->findvalue('./port');

		#print "$port\n";
		$servsocket = $sipserver->findvalue('./socket');

		#print "$name";

		if ($host && $port &&  $servsocket) {
			print "Found config: '$servsocket' '$host' '$port'  in sipdevices.xml. \n";
		}
		else {
			die "Missing parameters for '$device' in sipconfig.xml \n";
		}

	}

	return $servsocket, $host, $port;

	#	my $host = $config->{sipdevice}->{$term}->{host};
	#	my $port = $config->{sipdevice}->{$term}->{port};

}

