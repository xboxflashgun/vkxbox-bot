#!/usr/bin/perl -w

use LWP::UserAgent;
use JSON::XS;
use Data::Dumper;
use Encode;
use DBI;

use utf8;

use lib '.';
use Xboxlive;

open F, "< vk-lp.apikey";
my $apikey = <F>;
chomp $apikey;
close F;

my $im;
my $up;		# json->updates
my $us;		# json->user

my $ua = LWP::UserAgent->new(
	timeout => 120,
	agent => "xboxstat.ru bot",
	keep_alive => 1,
);

my $dbh = DBI->connect("dbi:Pg:dbname=global;port=6432") || die;

my $xbl = Xboxlive->new(1, $dbh);
my $myxuid = $xbl->getmyxuid;

$ua->default_header('Authorization', "Bearer $apikey");

get_im_serv();

print "Bot started with ts=".$im->{'ts'}." xuid=$myxuid\n";

while(1)	{
	
	get_vk_msg();

	foreach $ev (@$up)	{

		next if($ev->[0] != 4);		# new message arrived

		my ($msgid, $minorid, $flags, $peerid, $timestamp, $text) = @$ev;

		print encode('utf-8', "$msgid: flg=$flags, minorid=$minorid: $peerid\n$text\n");

		next if($flags & 2);		# it's an outgoing message

		mark_as_read($msgid);
		get_user($peerid);
		send_msg($peerid, "got '$text'\n" . $us->{'first_name'});

	}

}


###############################

sub get_xbox_msg {

	my $msgs = decode_json($xbl->get("https://msg.xboxlive.com/users/xuid($myxuid)/inbox"));
	my $total = $msgs->{'pagingInfo'}->{'totalItems'};

	return if not $total;

	print "Got some xbox message(s):\n";
	foreach $msg (@{$msgs->{'results'}}) {

		my $text = $msg->{'messageSummary'};
		my $id   = $msg->{'header'}->{'id'};
		my $xuid = $msg->{'header'}->{'senderXuid'};
		my $gt   = $msg->{'header'}->{"sender"};

		if($text =~ /(\d{6})/m) {

			my $key = $1;
			print "    key: $key (id=$id) xuid=$xuid ($gt)\n";

		} else {

			print encode('utf-8', "   unknown '$text' received from $gt ($xuid)\n");

		}

		sleep 1;
		$xbl->delete("https://msg.xboxlive.com/users/xuid($myxuid)/inbox/$id");
		sleep 1;

	}

}	

sub get_user {

	my $userid = shift;
	my $url = "https://api.vk.com/method/users.get?user_ids=$userid&fields=first_name,last_name,city,country,domain,photo_50,sex&v=5.199";

	my $res = $ua->get($url);
	die $res->status_line if $res->code != 200;

	$us = (decode_json($res->decoded_content)->{'response'})->[0];
	return;

}

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


sub get_vk_msg {

	while(1)	{

		my $url = "https://".$im->{'server'}."?act=a_check&key=".$im->{'key'}."&ts=".$im->{'ts'}."&wait=25&mode=2&version=3";
		my $res = $ua->get($url);
		die $res->status_line if $res->code != 200;

		my $json = decode_json($res->decoded_content);
		$im->{'ts'} = $json->{'ts'};

		$up = $json->{'updates'};
		last if @$up;

		get_xbox_msg();

	}

}

sub get_im_serv {

	my $res = $ua->get("https://api.vk.com/method/messages.getLongPollServer?act=a_check&ts=0&wait=25&mode=2&v=5.199");
	die $res->status_line if $res->code != 200;

	$im = decode_json($res->decoded_content)->{'response'};

}

