#!/usr/bin/perl -w

use LWP::UserAgent;
use JSON::XS;
use Data::Dumper;

open F, "< vk-lp.apikey";
my $apikey = <F>;
chomp $apikey;
close F;

my $im;
my $up;		# json->updates

my $ua = LWP::UserAgent->new(
	timeout => 120,
	agent => "xboxstat.ru bot",
	keep_alive => 1,
);

$ua->default_header('Authorization', "Bearer $apikey");

get_im_serv();

print "Bot started with ts=".$im->{'ts'}."\n";

while(1)	{
	
	get_msg();

	foreach $ev (@$up)	{

		next if($ev->[0] != 4);		# new message arrived

		my ($msgid, $minorid, $flags, $peerid, $timestamp, $text) = @$ev;

		print "$msgid: flg=$flags, minorid=$minorid: $peerid\n$text\n";
		mark_as_read($msgid);

		next if($flags & 2);		# it's an outgoing message

		send_msg($peerid, "got '$text'");

	}

}


###############################

sub send_msg {

	my ($peerid, $msg) = @_;
	my $url = "https://api.vk.com/method/messages.send?user_id=$peerid&message=$msg&random_id=0&v=5.199";

	my $res = $ua->get($url);
	die $res->status_line if $res->code != 200;

}

sub mark_as_read {

	my $peerid = shift;
	my $url = "https://api.vk.com/method/messages.markAsRead?peer_id=$peerid&v=5.199&mark_conversation_as_read=1";

	my $res = $ua->get($url);
	die $res->status_line if $res->code != 200;

}


sub get_msg {

	while(1)	{

		my $url = "https://".$im->{'server'}."?act=a_check&key=".$im->{'key'}."&ts=".$im->{'ts'}."&wait=25&mode=2&version=3";
		my $res = $ua->get($url);
		die $res->status_line if $res->code != 200;

		my $json = decode_json($res->decoded_content);
		$im->{'ts'} = $json->{'ts'};

		$up = $json->{'updates'};
		last if @$up;

	}

}

sub get_im_serv {

	my $res = $ua->get("https://api.vk.com/method/messages.getLongPollServer?act=a_check&ts=0&wait=25&mode=2&v=5.199");
	die $res->status_line if $res->code != 200;

	$im = decode_json($res->decoded_content)->{'response'};

}

