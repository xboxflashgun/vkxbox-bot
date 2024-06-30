#!/usr/bin/perl -w

package Xboxlive;

use LWP;
use LWP::UserAgent;
use HTTP::Cookies;
use Cpanel::JSON::XS;
use DBI;
use POSIX;
use Try::Tiny;
use Sys::Hostname;
use Carp;
use Encode;

use Exporter qw(import);

use subs qw(new get post put delete getmyprog getrow);
use Class::Tiny qw(ua can_accept user pass warn header xuid gtg token uhs access_token new cookie_jar get put post delete errors getrow);
our @EXPORT = qw(dejson findprop getrow);

# fire_req('POST', 'https://...', 3.2, \$json_data);
#
sub fire_req	{
	my ($req, $self, $url, $contract, $body, $addedheaders) = @_;

	$contract = 2	if(!defined($contract));

	my $headers = {
		'Content-Type' => 'application/json',
		'Authorization' => $self->{header},
		'Accept', 'application/json',
		"Accept-Language" => 'en-us',
		'Accept-Encoding' => $self->{can_accept},
		'x-xbl-contract-version' => $contract,
		'User-Agent' => 'XboxRecord.Us Like SmartGlass/2.105.0415 CFNetwork/711.3.18 Darwin/14.0.0',
	};
	if(defined($addedheaders))	{
		%{$headers} = ( %{$headers}, %{$addedheaders} );
	}

	my $res;
	do	{{
		if($req eq 'POST')	{
			$res = $self->{ua}->post($url, %{$headers}, Content => $body);
		} elsif($req eq 'GET')	{
			$res = $self->{ua}->get($url, %{$headers});
		} elsif($req eq 'PUT')	{
			$res = $self->{ua}->put($url, %{$headers});
		} elsif($req eq 'DELETE')	{
			$res = $self->{ua}->delete($url, %{$headers});
		}
		if($res->is_success)	{
			$self{errors} = 0;
			return $res->decoded_content;
		}
		
		$self->{nr}++;	# count requests

		return ''  		if($res->code == 404);          # 'not found' не ошибка, просто вернём пусто
		if($res->code == 403)	{		# Forbidden
			# возвращается в progress.xboxlive.com для засекьюреных игроков (см. update_deco.pl)
			$self->{warn} = "Forbidden";
			return '';
		}
		my $st = strftime("%c", localtime);
		my $us = $self->{user};
		my $au = $self->{authid};
		print "$st * ", $res->status_line, " - $us($au)\n";
		if($res->code == 429)	{	# too many requests
			my $ra = $res->headers->header("Retry-After");
			if( ! defined($ra))	{
				
				my $nr = $self->{nr};
				my $el = time - $self->{st};

				sleep rand(30)+30;
				$self->{ta} += 1;
				print "$st *** pid=$$ nr=$nr in $el secs, number of '429' for $au ($us) is ", $self->{ta}, "\n";
				$self->{nr} = 0;
				$self->{st} = time;
				next;
			}
			$ra = 4	if($ra < 1);
			my $json = '';
			try {
				$json = decode_json($res->decoded_content);
			} catch	{
				$json = '';
			};
			if($json eq '')	{
				print "$st ($$) ".$self->{gtg}." Sleeping $ra s, 429 Too Many Requests for $url\n";
				sleep $ra;
				next;
			}
			my $cr = $json->{"currentRequests"};
			my $mr = $json->{"maxRequests"};
			my $pi = $json->{"periodInSeconds"};
			my $lt = $json->{"limitType"};
			my $gt = $self->{gtg};
			print "$st ($$) $us($gt): Sleeping $ra s, 429 Too Many Requests for $url, $cr of $mr reqs in $pi s, type: $lt\n";
			sleep $ra;
			next;
		}
		if($res->code == 500)	{	# internal error, попробовать после паузы (???) не факт - проверить, чтобы не зависло
			$self{errors} ++;
			if($self{errors} > 5)	{
				# print "More than 5 attempts for 500-error\n";
				sleep $self{errors} * 4;
				$self{errors} = 0;
				return '';
			}
			sleep $self{errors} * 4;
			next;
		}
		if($res->code == 503)	{
			my $ra = $res->headers->header("Retry-After");
			if(defined($ra))	{
				sleep $ra;
				print "$st ($$): Error 503 Retry-after $ra, for $url with $us ($au)\n";
				next;
			}
			return '';
		}
		if($self{errors} > 5)	{
			print "$st *** Error while auth $$: more than 5 attempts failed, mark $us ($au) as banned\n";
			$self->{dbh}->do("update auth set banned=true where authid=$au");
			sleep 30;
			die "after 5 attempts";
			return '';
		}
		$self->{warn} = $res->headers->header("WWW-Authenticate");
		if($res->code == 401)	{
			$self{errors} ++;
			sleep 5;	# wait before retry
			auth($self);
			return fire_req($req, $self, $url, $contract, $body);
		}
		print "$st $$\n   url:$url\nres: ", $res->status_line, "\n", $res->headers()->as_string;
		return $res->decoded_content;
	}} while(1);
}


sub get	{
	return fire_req('GET', @_);
}

sub put	{
	return fire_req('PUT', @_);
}

sub post	{
	return fire_req('POST', @_);
}

sub delete	{
	return fire_req('DELETE', @_);
}

###############################

sub do	{
	my ($self, $str) = @_;
	return $self->{dbh}->do($str);
}

sub dbh	{

	my $self = shift;
	return $self->{dbh};

}

sub quote	{
	my ($self, $str) = @_;
	return $self->{dbh}->quote($str);
}

sub getrow	{
	my ($self, $str) = @_;
	my @ret = $self->{dbh}->selectrow_array($str);
	if($self->{dbh}->err)	{
		print "error '", $self->{dbh}->errstr, "' here\n";
	}
	return @ret;
}

sub getcell	{
	my ($self, $str) = @_;
	my @ret = $self->{dbh}->selectrow_array($str);
	if($self->{dbh}->err)   {
		print "error '", $self->{dbh}->errstr, "' here\n";
		if($self->{$pname}->errstr =~ /deadlock detected/ && $self->{prog} eq 'presence')	{

			$self->{dbh}->do("commit");
			$self->{dbh}->do("begin");
		
		}
	}
	return $ret[0];
}

sub getall	{
	my ($self, $str) = @_;
	my $ret = $self->{dbh}->selectall_arrayref($str);
	if($self->{dbh}->err)   {
		print "error '", $self->{dbh}->errstr, "' here\n";
	}
	return $ret;
}

sub getmyxuid	{
	my $self = shift;
	return $self->{xuid};
}

# load credentials from DB
sub load_creds	{

	my $self = shift;
	($self->{pass}, $self->{xuid}, $self->{user}, $self->{gtg}) = $self->getrow("select pass,xuid,uname,gt from auth where authid=".$self->{authid});
	$self->{xuid} = 0	if(!defined($self->{xuid}));
	
	die "unable to find authid"	if(!defined($self->{pass}));
	
	$self->do("insert into credscache(authid) values(".$self->{authid}. ") on conflict do nothing");
	($self->{header}, $self->{access_token}) = 
		$self->getrow("select header,access_token from credscache where authid=" . $self->{authid});
	$self{errors} = 0;
}


sub closedbh	{
	my $self = shift;
	$self->{dbh}->disconnect;
}

#### Xboxlive->new($authid);
# нет проверки на banned
# запоминается в credscache
sub new {

	my ($self, $arg, $dbh) = @_;
	my (undef, $prog, undef) = caller;
	
	$prog =~ s/.*\/([^\/]+)$/$1/;
	$prog =~ s/\.[^.]+$//;
	
	$self->{ta} = 0;	# 30 seconds for 429 timeout w/o parameters
	$self->{nr} = 0;	# number of requests
	$self->{st} = time;	# start time of first request

	$self->{dbh} = $dbh;

	$self->{authid} = $arg;

	load_creds($self);

	$self->{cookie_jar} = HTTP::Cookies->new(
		file => "/tmp/xblive_$$.dat",		# authid as cookies jar
		autosave => 1,
	);

	$self->{ua} = LWP::UserAgent->new(keep_alive => 1);
	$self->{ua}->cookie_jar($self->{cookie_jar});
	$self->{ua}->agent("XboxRecord.Us Like SmartGlass/2.105.0415 CFNetwork/711.3.18 Darwin/14.0.0");
	$self->{ua}->timeout(180);

	$self->{can_accept} = HTTP::Message::decodable;

	# checking if already authenticated
	if(defined($self->{header}) && $self->{header} ne '')	{
		my $res = get($self, "https://profile.xboxlive.com/users/me/id");
		if(length($res) > 0)	{
			$self->{dbh}->do("update auth set banned=false where (banned or banned is null) and authid=" . $self->{authid});
			return $self;
		}
	}

	my $res = auth($self);
	return $res ? $self : undef ;
}

sub auth	{

	my $self = shift;

	# начинаем авторизацию
	$self->{dbh}->do("begin");	# lock for other's auth: other will wait for the transaction end
	$self->{dbh}->do("select 1 from credscache where authid=".$self->{authid}." for update");

	$self->{dbh}->do("insert into credscache(authid) values(".$self->{authid}.") on conflict do nothing");
	$self->{ua}->cookie_jar->clear;
	if(!defined($self->{access_token}) || $self->{access_token} eq '' || (defined($self->{warn}) && $self->{warn} =~ /token_expired/))	{
		my ($urlpost, $ppft_re) = pre_auth($self);
		fetch_init_token($self, $urlpost, $ppft_re);
	}
	# reauth goes here
	if( ! authenticate($self) or ! authorize($self) or $self->{gtg} eq '' ) {
		$self->{dbh}->do("commit");
		return 0;
	}
	$self->{dbh}->do("update credscache set lastauth=now(),
		header='".$self->{header}."',access_token='".$self->{access_token}."'       
		where authid=" . $self->{authid});
	$self->{dbh}->do("update auth set xuid=".$self->{xuid}." where (xuid is null or xuid < 1000) and authid=" . $self->{authid});
	# $self->{dbh}->do("update auth set banned=false where banned and authid=" . $self->{authid});
	$self->{dbh}->do("update auth set gt='".$self->{gtg}."' where authid=" . $self->{authid});
	$self->{dbh}->do("commit");

	my $res = get($self, "https://profile.xboxlive.com/users/me/id");
	return $self;
}

# Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/38.0.2125.104 Safari/537.36
# Mozilla/5.0 (games.directory/2.0; XboxLiveAuth/3.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/71.0.3578.98 Safari/537.36
# Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/54.0.2840.98 Safari/537.36
# Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Ubuntu Chromium/28.0.1500.71 Chrome/28.0.1500.71 Safari/537.36

sub gen_ua	{

	my @plat = ( 'X11', 'iPhone', 'iPad', 'Android 14', 'Windows NT 10.0', 'Macintosh', 'compatible', 'Linux', 'Android 13' );
	my @appl = ( 'Linux x86_64', 'Intel Mac OS X 10_11_6', 'Intel Mac OS X 10_15_7', 'Intel Mac OS X 10_13_5', 'Intel Mac OS X 10_12_6' );

	my $chrome = 'Chrome/' . int(28 + rand(95)) . ".0." . int(1000 + rand(7000)) . "." . int(10 + rand(80));
	my $safari = 'Safari/537.' . int(10 + rand(70));

	my $us =  "Mozilla/5.0 (" . $plat[rand(@plat)] . "; " . $appl[rand(@appl)] . ") AppleWebKit/537.36 (KHTML, like Gecko) "
		. "$chrome $safari";

	return $us;

}

sub pre_auth	{
	my $self = shift;

	my $client_id = '000000004C12AE6F';
	my $client_secret = 'FheDkMA9b49mh5sY9ChaqrMvdwds/ljM';
	my $client_agent = gen_ua();
	# 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/38.0.2125.104 Safari/537.36';
	my $URL = 'https://login.live.com/oauth20_authorize.srf';

	my @params = (
		"client_id=".$client_id,
		"scope=service::user.auth.xboxlive.com::MBI_SSL",
		"response_type=token",
		"redirect_uri=https://login.live.com/oauth20_desktop.srf"
	);

	my $URLFULL = $URL."?".join("&", @params);
	my $res = $self->{ua}->get($URLFULL);

	die "in pre-auth"	if(! $res->is_success );

	my $block = $res->as_string;
	$block =~ /urlPost:'([A-Za-z0-9:\?_\-\.&\/=]+)/;
	$urlPost = $1;
	$block =~ /sFTTag:'.*value=\"(.*)\"\/>'/;
	$ppft_re = $1;
	# print " ** urlPost: ", length($urlPost), "\n";
	# print " ** sFTTag: ", length($ppft_re), "\n";
	return ($urlPost, $ppft_re);
}

sub fetch_init_token	{
	my ($self, $urlPost, $ppft_re) = @_;

	%post_vals = (
		'login' => $self->{user},
		'passwd' => $self->{pass},
		'PPFT' => $ppft_re,
		'PPSX' => 'Passpor',
		'SI' => "Sign In",
		'type' => '11',
		'NewUser' => '1',
		'LoginOptions' => '1',
		'i3' => '36728',
		'm1' => '768',
		'm2' => '1184',
		'm3' => '0',
		'i12' => '1',
		'i17' => '0',
		'i18' => '__Login_Host|1'
	);

	$res = $self->{ua}->post($urlPost, \%post_vals);
	my $block = $res->as_string;

	$block =~ /Location: (.*)/;
	$self->{location} = $1;
	$block =~ /access_token=(.+?)&/;
	$self->{access_token} = $1;

	# print " ** Location: $location\n";
	# print " ** Access token: ", length($self->{access_token}), "\n";
	return $access_token;
}


sub authenticate	{
	my $self = shift;

	my $url = 'https://user.auth.xboxlive.com/user/authenticate';

	my $load = {
		'RelyingParty' => 'http://auth.xboxlive.com',
		'TokenType' => 'JWT',
		'Properties' => {
			'AuthMethod' => 'RPS',
			'SiteName' => 'user.auth.xboxlive.com',
			'RpsTicket' => $self->{access_token}
		}
	};

	my $json_payload = encode_json($load);

	my $headers = {
		'Content-Type' => 'application/json',
	};

	my $res = $self->{ua}->post($url, Content => $json_payload, %{$headers});
	my $st = strftime("%c", localtime);
	my $json;
	try {	
		$json = decode_json($res->content);
	} catch	{
		print "$st *** pid=$$: Error decoding JSON from authenticate for ", $self->{user}, " -- possibly banned authid=", $self->{authid},"\n";
		$self->{dbh}->do("update auth set banned=true where authid=".$self->{authid});
		$self->{dbh}->do("delete from credscache where authid=".$self->{authid});
		delete($self->{access_token});
		print " *** payload: ", $json_payload, "\n";
		print " *** reply: ", $res->content, "\n";
		print " *** headers:\n", $res->headers->as_string, "\n";
		sleep 30;
		die "Stop here";
	};

	$self->{token} = $json->{'Token'};
	$self->{auth_expires} = $json->{'NotAfter'};
	$self->{uhs} = $json->{'DisplayClaims'}->{'xui'}->[0]->{'uhs'};

	# print " ** token: ", length($self->{token}), "\n";
	# print " ** expires: ", $self->{auth_expires}, "\n";
	# print " ** uhs: ", $self->{uhs}, "\n";
	return 1;
}

sub authorize	{
	my $self = shift;

	my $url = 'https://xsts.auth.xboxlive.com/xsts/authorize';

	my $auth = {
		'RelyingParty' => 'http://xboxlive.com',
		'TokenType' => 'JWT',
		'Properties' => {
			'UserTokens' => [ $self->{token} ],
			'SandboxId' => 'RETAIL',
		}
	};

	my $json_payload = encode_json($auth);

	my $headers = {
		'Content-Type' => 'application/json',
	};

	$res = $self->{ua}->post($url, Content => $json_payload, %{$headers});
	try {
		$json = decode_json($res->content);
	} catch {
		print " *** $$: Error decoding json in authorize from ", $self->{user}, "\n";
		print " *** payload: ", $json_payload, "\n";
		$json = 0;
	};

	return 0 if not $json;
	# print Dumper($json);
	$self->{xuid} = $json->{'DisplayClaims'}->{'xui'}->[0]->{'xid'};
	# print " ** my xuid: ", $self->{xuid}, "\n";
	$self->{gtg}  = $json->{'DisplayClaims'}->{'xui'}->[0]->{'gtg'};
	$self->{token}= $json->{'Token'};
	$self->{header} = sprintf('XBL3.0 x=%s;%s', $self->{uhs}, $self->{token});
	$self->{auth_expires} = $json->{'NotAfter'};

	# print " ** xuid: ".$self->{xuid}."\n";
	# print " ** gtag: ".$self->{gtg}."\n";
	# print " ** header: ", length($self->{header}), "\n";
	# print " ** expires: ".$self->{auth_expires}."\n";
	return 1;
}

1;

