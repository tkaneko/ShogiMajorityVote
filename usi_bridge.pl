#!/usr/bin/perl -w
use strict;
use Getopt::Std;
use IPC::Open2;
use IO::Handle;
use IO::Socket;
use IO::Select;
my $options = {};
getopts("h:I:p:c:n:f:l:s:rv",$options);
### options
# -h hostname -p port number -c "command + args"
my $hostname = $options->{h} || "localhost";
my $port = $options->{p} || 4082;
my $command = $options->{c} || die "command not specified";
my $verbose = $options->{v};
my $name = $options->{n};
my $factor = $options->{f} || 1;
my $logfile = $options->{l};
my $stop_interval = $options->{s} || 0;
my $initialize_string = $options->{I} || undef; # string sent to client before isready
my $enable_resign = $options->{r};

sub init_client ($);
sub init_server ($$);
sub read_line ($@);
sub write_line ($$);
sub handle_server_message ($$);
sub handle_client_message ($$);
sub start_search ($);
sub unittest ();

&unittest();
die "factor is not a number" if ($factor !~ /^-?[0-9.]+$/);
die "stop_interval is not an integer" if ($stop_interval !~ /^[0-9]+$/);
my $log_handle = undef;
if ($logfile) {
  open($log_handle, "> $logfile") || die $!;
  $log_handle->autoflush(1);
  print $log_handle "log start\n";
}

$| = 1;
### initialize
sub connection_closed () { return ":connection closed:"; }
my $client = init_client($command);
print STDERR "client is $client->{id}\n";
my $client_name = $name || $client->{id};
$client_name =~ s/ /_/g;
$client_name .= " ".$factor." final";

CONNECT: while (1) {
  my $server = init_server($hostname, $port);
  write_line($server, $client_name);
  ### new game
  while (1) {
    my $status = { id=>0, server=>$server, client=>$client, moves=>[] };
    my $now = time;
    my ($sec,$min,$hour,$mday,$mon,$year) = localtime($now);
    printf STDERR "\nnew game %d-%02d-%02d %02d:%02d:%02d\n\n",
      1900+$year,$mon+1,$mday,$hour,$min,$sec;
    while (1) {
      my $line = read_line($server,90);
      unless ($line) {
	write_line($server, "");
	$now = time;
	next;
      }
      last if $line =~ /^new$/;
      if ($line eq connection_closed) {
	warn "server down while waiting new game";
	next CONNECT;
      }
    }
    write_line($client, "usinewgame");
    start_search($status);
    while (1) {
      if (my $line = read_line($server, 0.1)) {
	handle_server_message($line, $status);
	last if ($line =~ /^idle/);
	if ($line eq connection_closed) {
	  warn "server down in GAME";
	  next CONNECT;
	}
	next;
      }
      if (my $line = read_line($client, 0.1)) {
	handle_client_message($line, $status);
      }
    }
  }
}
write_line($client, "quit");
exit 0;

###
sub initialize_board ($) {
  my ($status) = @_;
  $status->{board} =
    [ "-KY", "-KE", "-GI", "-KI", "-OU", "-KI", "-GI", "-KE", "-KY",
      "   ", "-KA", "   ", "   ", "   ", "   ", "   ", "-HI", "   ",
      "-FU", "-FU", "-FU", "-FU", "-FU", "-FU", "-FU", "-FU", "-FU",
      "   ", "   ", "   ", "   ", "   ", "   ", "   ", "   ", "   ",
      "   ", "   ", "   ", "   ", "   ", "   ", "   ", "   ", "   ",
      "   ", "   ", "   ", "   ", "   ", "   ", "   ", "   ", "   ",
      "+FU", "+FU", "+FU", "+FU", "+FU", "+FU", "+FU", "+FU", "+FU",
      "   ", "+HI", "   ", "   ", "   ", "   ", "   ", "+KA", "   ",
      "+KY", "+KE", "+GI", "+KI", "+OU", "+KI", "+GI", "+KE", "+KY", "+" ];
  $status->{ptype} =
    { P=>"FU", L=>"KY", N=>"KE", S=>"GI", G=>"KI", B=>"KA", R=>"HI" };
  $status->{promotion} =
    { FU=>"TO", KY=>"NY", KE=>"NK", GI=>"NG", KA=>"UM", HI=>"RY" };
  foreach my $ptype (keys %{$status->{ptype}}) {
    $status->{usitype}->{$status->{ptype}->{$ptype}} = $ptype;
  }
}

sub board_index ($) {
  my ($square) = @_;
  die unless ($square =~ /^[1-9]{2}$/);
  my ($x, $y) = split(//, $square);
  return ($y-1)*9 + $x-1;
}

sub stop_and_wait_bestmove ($) {
  my ($status) = @_;
  return if (defined $status->{bestmove} && $status->{bestmove} == $status->{id});
  my $now = time;
  if ($status->{lastgo}+$stop_interval > $now) {
    warn "sleep $stop_interval before stop";
    sleep($status->{lastgo}+$stop_interval - $now);
  }
  write_line($status->{client}, "stop");
  my $stop_sent = time;
  while (my $line=read_line($status->{client})) {
    last if $line =~ /^bestmove/;
    if (time > $stop_sent + 10) {
      warn "try stop again";
      write_line($status->{client}, "stop");
      $stop_sent = time;
    }
  }
  $status->{bestmove} = $status->{id};
}

sub show ($) {
  my ($status) = @_;
  print "id = ".$status->{id}."\n";
  print "moves = ".join(' ', @{$status->{moves}})."\n" if ($status->{moves});
  foreach my $y (1..9) {
    foreach my $x (1..9) {
      print $status->{board}->[($y-1)*9+9-$x];
    }
    print "\n";
  }
}

sub usi2csa ($$) {
  my ($status, $usi_string) = @_;
  initialize_board($status) unless $status->{board};
  return '%TORYO' if ($usi_string =~ /^resign/ && $enable_resign);
  return undef if ($usi_string =~ /^resign/); # client must not resign
  my @usi_move = split(//, $usi_string);
  if ($usi_move[1] eq '*') {
    my $ptype = $status->{ptype}->{$usi_move[0]};
    my $to = $usi_move[2].(ord($usi_move[3])-ord('a')+1);
    die "drop on piece $usi_string"
      unless ($status->{board}->[board_index($to)] =~ /^\s+$/);
    return "00".$to.$ptype;
  }
  my $promote = ($#usi_move == 4) && $usi_move[4] eq '+';
  my ($from, $to) = ($usi_move[0].(ord($usi_move[1])-ord('a')+1),
		     $usi_move[2].(ord($usi_move[3])-ord('a')+1));
  my $turn = $status->{board}->[81];
  die "turn inconsistent $turn $from ".$status->{board}->[board_index($from)]
    unless ($turn eq substr($status->{board}->[board_index($from)],0,1));
  die "turn inconsistent $turn $to ".$status->{board}->[board_index($to)]
    if ($turn eq substr($status->{board}->[board_index($to)],0,1));
  my $ptype = substr($status->{board}->[board_index($from)], 1);
  die "invalid promotion $ptype"
    if ($promote && !defined $status->{promotion}->{$ptype});
  $ptype = $status->{promotion}->{$ptype} if ($promote);
  return $from.$to.$ptype;
}

sub csa2usi ($$$$) {
  my ($status, $from, $to, $ptype) = @_;
  my ($usi, $promote) = (undef, undef);
  if ($from eq "00") {
    $usi = $status->{usitype}->{$ptype} . "*";
    die "drop on piece $to".$status->{board}->[board_index($to)]
      if ($status->{board}->[board_index($to)] !~ /^\s+$/);
  }
  else {
    $usi = substr($from,0,1).chr(ord(substr($from,1,1))-ord('1')+ord('a'));
    my $old_ptype = substr($status->{board}->[board_index($from)],1);
    $promote = $old_ptype ne $ptype;
    die "board inconsistent $old_ptype $ptype"
      if ($old_ptype ne $ptype && $status->{promotion}->{$old_ptype} ne $ptype);
  }
  $usi .= substr($to,0,1).chr(ord(substr($to,1,1))-ord('1')+ord('a'));
  return $usi . ($promote ? '+' : '');
}
sub alt_turn ($) {
  my ($turn) = @_;
  die "turn? $turn" unless ($turn eq '+' || $turn eq '-');
  return $turn eq '+' ? '-' : '+';
}
sub make_move ($$$$) {
  my ($status, $from, $to, $ptype) = @_;
  $status->{board} = [ @{$status->{prev}} ];
  my $usi = csa2usi($status, $from, $to, $ptype);
  my $turn = $status->{board}->[81];
  $status->{board}->[81] = alt_turn($turn);
  die "inconsintent turn $turn $to"
    if (substr($status->{board}->[board_index($to)],0,1) eq $turn);
  $status->{board}->[board_index($to)] = $turn.$ptype;
  if ($from ne "00") {
    die "inconsintent turn $turn $from $to $ptype"
      if (substr($status->{board}->[board_index($from)],0,1) ne $turn);
    $status->{board}->[board_index($from)] = "   ";
  }
  push(@{$status->{moves}}, $usi);
}

sub start_search ($) {
  my ($status) = @_;
  my $position = "position startpos";
  $position .= " moves ".join(' ', @{$status->{moves}})
    if (@{$status->{moves}}+0);
  write_line($status->{client}, $position);
  write_line($status->{client}, "go infinite");
  $status->{lastgo} = time;
  $status->{lastnodes} = 1;
}

sub handle_server_message ($$) {
  my ($line, $status) = @_;
  initialize_board($status) unless $status->{board};
  if ($line =~ /(move|alter)\s+([0-9]{2})([0-9]{2})([A-Z]{2})\s+(\d+)/) {
    my ($command, $from, $to, $ptype, $new_id) = ($1, $2, $3, $4, $5);
    stop_and_wait_bestmove($status);
    print $log_handle ($status->{score} || 0).' '.join(' ',@{$status->{pv}})."\n"
      if (defined $status->{haspv} && $status->{haspv} == $status->{id}
	  && @{$status->{pv}} && $log_handle);
    $status->{prev} = [ @{$status->{board}} ] if ($command eq "move");
    pop(@{$status->{moves}}) if ($command eq "alter");
    make_move($status, $from, $to, $ptype);
    $status->{id} = $new_id;
    show($status);
    start_search($status);
    print $log_handle "$line\n" if ($log_handle);
    return;
  }
  if ($line =~ /^idle/ || $line eq connection_closed) {
    stop_and_wait_bestmove($status);
    return;
  }
  die "invalid server message ".$line;
}

sub valid_usi_move ($) {
  my ($move) = @_;
  $move =~ s/^(resign|pass)$//;
  $move =~ s/^[1-9][a-z][1-9][a-z]\+?//g;
  $move =~ s/^[PLNSGBR]\*[1-9][a-z]\+?//g;
  return $move =~ /^$/;
}

sub valid_usi_pv ($) {
  my ($pvstr) = @_;
  my @pv = split(/\s+/, $pvstr);
  foreach $_ (@pv) {
    return undef unless valid_usi_move($_);
  }
  return 1;
}

sub valid_usi ($) {
  my ($line) = @_;
  if ($line =~ /^info /) {
    $line =~ s/\s+score cp\s+-?[0-9]+(\s|$)/ /g;
    $line =~ s/\s+time\s+[0-9]+(\s|$)/ /g;
    $line =~ s/\s+seldepth\s+[0-9]+(\s|$)/ /g;
    $line =~ s/\s+depth\s+[0-9]+(\s|$)/ /g;
    $line =~ s/\s+nodes\s+[0-9]+(\s|$)/ /g;
    $line =~ s/\s+nps\s+-?[0-9.]+(\s|$)/ /g;
    $line =~ s/\s+hashfull\s+[0-9]+(\s|$)/ /g;
    $line =~ s/\s+currmove\s+(([0-9][a-z]|[PLNSGBR]\*)[0-9][a-z]\+?|resign)(\s|$)/ /g;
    $line =~ s/\s+string\s+.*$/ /g;
    return 0 if ($line =~ s/\s+pv\s+(.*)$// && ! valid_usi_pv($1));
    return ($line =~ /^info\s*$/);
  }
  return 1;
}

sub handle_client_message ($$) {
  my ($line, $status) = @_;
  if ($line =~ /^info /) {
    die "unknown syntax $line" unless (valid_usi($line));
    my $depth = ($line =~ /\s+depth\s+([0-9]+)/) && $1;
    my $score = ($line =~ /\s+score cp\s+(-?[0-9.]+)/) && $1;
    my $nodes = ($line =~ /\s+nodes\s+([0-9.]+)/) && $1;
    my ($move, @pv) = ($line =~ /\s+pv\s+(.+)/) && split(/\s+/, $1);
    $status->{haspv} = $status->{id} if ($move);
    $status->{pv} = [ $move, @pv ] if ($move);
    $status->{score} = $score if ($move && defined $score);
    $move = usi2csa($status, $move) if $move;
    $status->{lastnodes} = $nodes if $nodes;
    my $message = "";
    $message .= " move=".$move if ($move);
    # $message .= " v=".$score.'e' if $score;
    $message .= " n=".$status->{lastnodes} if $status->{lastnodes};
    write_line($status->{server}, "pid=".$status->{id}.$message) if $message;
    return;
  }
  elsif ($line =~ /^bestmove\s+(.+)/) {
    my $move = $1;
    die "unknown syntax $line" unless (valid_usi_move($move));
    $status->{bestmove} = $status->{id};
    my $csa = usi2csa($status, $move);
    write_line($status->{server}, "pid=".$status->{id}." move=".$csa
	       ." n=".$status->{lastnodes}." final") if $csa;
  }
  else {
    warn "unknown message $line";
  }
}

sub read_line ($@) {
  my ($object, $timeout) = @_;
  my $in = $object->{reader};
  if (defined $timeout) {
    my $selector = new IO::Select($in);
    return undef unless $selector->can_read($timeout);
  }
  my ($line, $char);
  return connection_closed unless $in->sysread($char, 1);
  $line = $char;
  if ($char ne "\n") {
    while ($in->sysread($char, 1) == 1) {
      $line .= $char;
      last if ($char eq "\n");
    }
  }
  $line =~ s/\r?\n$//;
  print STDERR substr($object->{type}, 0, 1), "< $line\n"
    if ($verbose || $object->{type} eq "Server" || $line !~ /^info/
	|| $line =~ /(pv|score|string)/);
  return $line;
}

sub write_line ($$) {
  my ($object, $message) = @_;
  my $writer = $object->{writer};
  print $writer $message, "\n";
  print STDERR substr($object->{type}, 0, 1), "> $message\n";
}

sub init_client ($)
{
  my ($command) = @_;
  my $client = { id=>"noname", type=>"client" };
  $client->{pid} = open2($client->{reader}, $client->{writer}, $command)
    || die "command execution failed";
  write_line($client, "usi");
  write_line($client, $initialize_string) if ($initialize_string);
  write_line($client, "isready");
  while (my $line = read_line($client)) {
    $line =~ s/\r?\n$//;
    $client->{id} = $1 if ($line =~ /^id name\s+(.*)/);
    last if ($line =~ /^readyok/);
  }
  return $client;
}

sub init_server ($$) {
  my ($hostname, $port) = @_;
  my $server = { type=>"Server" };
  print STDERR "connect to $hostname:$port\n";
  while (1) {
    eval {
      $server->{socket} = new IO::Socket::INET
	(PeerAddr=>$hostname, PeerPort=>$port, Proto=>'tcp');
      die "socket $!" unless $server->{socket};
    };
    last unless ($@);
    warn $@;
    print STDERR "try again in 10s.\n";
    sleep 10;
  }
  $server->{writer} = $server->{reader} = $server->{socket};
  return $server;
}

sub unittest () {
  valid_usi_move("resign") || die "unittest";
  valid_usi_move("7g7f") || die "unittest";
  valid_usi_move("7g7F") && die "unittest";

  my $status = { id=>0 };
  initialize_board($status) unless $status->{board};
  ($status->{board}->[81] eq '+') || die "unittest";
  (usi2csa($status, "7g7f")  eq "7776FU") || die "unittest";
  (usi2csa($status, "R*4e")  eq "0045HI") || die "unittest";
  (usi2csa($status, "8h2b+") eq "8822UM") || die "unittest";
  (csa2usi($status, "77","76","FU") eq "7g7f")  || die "unittest";
  (csa2usi($status, "88","22","UM") eq "8h2b+") || die "unittest";
  (csa2usi($status, "00","45","HI") eq "R*4e")  || die "unittest";
  $status->{prev} = [ @{$status->{board}} ];
  make_move($status, "77", "76", "FU");
  ($status->{board}->[81] eq '-') || die "unittest";
  # show($status);
}

