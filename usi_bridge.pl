#!/usr/bin/perl -w
use strict;
use Getopt::Std;
use IPC::Open2;
use IO::Handle;
use IO::Socket;
use IO::Select;
my $options = {};
getopts("h:p:c:n:f:l:v",$options);
### options
# -h hostname -p port number -c "command + args"
my $hostname = $options->{h} || "localhost";
my $port = $options->{p} || 4082;
my $command = $options->{c} || die "command not specified";
my $verbose = $options->{v};
my $name = $options->{n};
my $factor = $options->{f};
my $logfile = $options->{l};

sub init_client ($);
sub init_server ($$);
sub read_line ($@);
sub write_line ($$);
sub handle_server_message ($$);
sub handle_client_message ($$);
sub start_search ($);
sub unittest ();

&unittest();
die "factor is not a number" if (defined $factor && $factor !~ /^-?[0-9.]+$/);
my $log_handle = undef;
if ($logfile) {
  open($log_handle, "> $logfile") || die $!;
  $log_handle->autoflush(1);
  print $log_handle "log start\n";
}

$| = 1;
### initialize
my $client = init_client($command);
my $server = init_server($hostname, $port);
print STDERR "client is $client->{id}\n";
my $client_name = $name || $client->{id};
$client_name =~ s/ /_/g;
$client_name .= " ".$factor if (defined $factor && $factor =~ /^[0-9.-]+$/);
write_line($server, $client_name);

### new game
while (1) {
  my $status = { id=>0, server=>$server, client=>$client, moves=>[] };
  my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time);
  printf STDERR "\nnew game %d-%02d-%02d %02d:%02d:%02d\n\n",
    $year,$mon,$mday,$hour,$min,$sec;
  while (my $line = read_line($server) || die "server closed") {
    last if $line =~ /^new$/;
  }
  write_line($client, "usinewgame");
  start_search($status);
  while (1) {
    if (my $line = read_line($server, 0.1)) {
      handle_server_message($line, $status);
      last if ($line =~ /^idle/);
      next;
    }
    if (my $line = read_line($client, 0.1)) {
      handle_client_message($line, $status);
    }
  }
}
write_line($client, "quit");
exit 0;

###
sub initilize_board ($) {
  my ($status) = @_;
  $status->{board} =
    [ "KY", "KE", "GI", "KI", "OU", "KI", "GI", "KE", "KY",
      "  ", "KA", "  ", "  ", "  ", "  ", "  ", "HI", "  ",
      "FU", "FU", "FU", "FU", "FU", "FU", "FU", "FU", "FU",
      "  ", "  ", "  ", "  ", "  ", "  ", "  ", "  ", "  ",
      "  ", "  ", "  ", "  ", "  ", "  ", "  ", "  ", "  ",
      "  ", "  ", "  ", "  ", "  ", "  ", "  ", "  ", "  ",
      "FU", "FU", "FU", "FU", "FU", "FU", "FU", "FU", "FU",
      "  ", "HI", "  ", "  ", "  ", "  ", "  ", "KA", "  ",
      "KY", "KE", "GI", "KI", "OU", "KI", "GI", "KE", "KY", ];
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
  write_line($status->{client}, "stop");
  while (my $line=read_line($status->{client})) {
    last if $line =~ /^bestmove/;
  }
  $status->{bestmove} = $status->{id};
}

sub show ($) {
  my ($status) = @_;
  print "id = ".$status->{id}."\n";
  print "moves = ".join(' ', @{$status->{moves}})."\n";
  foreach my $y (1..9) {
    foreach my $x (1..9) {
      print ' '.$status->{board}->[($y-1)*9+9-$x];
    }
    print "\n";
  }
}

sub usi2csa ($$) {
  my ($status, $usi_string) = @_;
  initilize_board($status) unless $status->{board};
  return undef if ($usi_string =~ /^resign/); # client must not resign
  my @usi_move = split(//, $usi_string);
  if ($usi_move[1] eq '*') {
    my $ptype = $status->{ptype}->{$usi_move[0]};
    return "00".$usi_move[2].(ord($usi_move[3])-ord('a')+1).$ptype;
  }
  my $promote = ($#usi_move == 4) && $usi_move[4] eq '+';
  my $fromto = $usi_move[0].(ord($usi_move[1])-ord('a')+1)
    .$usi_move[2].(ord($usi_move[3])-ord('a')+1);
  my $ptype = $status->{board}->[$usi_move[0]-1+(ord($usi_move[1])-ord('a'))*9];
  $ptype = $status->{promotion}->{$ptype} if ($promote);
  return $fromto.$ptype;
}

sub csa2usi ($$$$) {
  my ($status, $from, $to, $ptype) = @_;
  my ($usi, $promote) = (undef, undef);
  if ($from eq "00") {
    $usi = $status->{usitype}->{$ptype} . "*";
  }
  else {
    $usi = substr($from,0,1).chr(ord(substr($from,1,1))-ord('1')+ord('a'));
    $promote = $status->{board}->[board_index($from)] ne $ptype;
  }
  $usi .= substr($to,0,1).chr(ord(substr($to,1,1))-ord('1')+ord('a'));
  return $usi . ($promote ? '+' : '');
}

sub make_move ($$$$) {
  my ($status, $from, $to, $ptype) = @_;
  $status->{board} = [ @{$status->{prev}} ];
  my $usi = csa2usi($status, $from, $to, $ptype);
  $status->{board}->[board_index($to)] = $ptype;
  $status->{board}->[board_index($from)] = "  " if ($from ne "00");
  push(@{$status->{moves}}, $usi);
}

sub start_search ($) {
  my ($status) = @_;
  my $position = "position startpos";
  $position .= " moves ".join(' ', @{$status->{moves}})
    if (@{$status->{moves}}+0);
  write_line($status->{client}, $position);
  write_line($status->{client}, "go infinite");
}

sub handle_server_message ($$) {
  my ($line, $status) = @_;
  initilize_board($status) unless $status->{board};
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
  if ($line =~ /^idle/) {
    stop_and_wait_bestmove($status);
    return;
  }
  die $line;
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
    my $message = "";
    $message .= " move=".$move if $move;
    # $message .= " v=".$score.'e' if $score;
    $message .= " n=".$nodes if $nodes;
    write_line($status->{server}, "pid=".$status->{id}.$message) if $message;
    return;
  }
  elsif ($line =~ /^bestmove\s+(.+)/) {
    my $move = $1;
    die "unknown syntax $line" unless (valid_usi_move($move));
    $status->{bestmove} = $status->{id};
    if (defined $status->{haspv} && $status->{haspv} == $status->{id}) {
	warn "a client should not return bestmove until the server sent stop\n";
    } else {
	my $csa = usi2csa($status, $move);
	write_line($status->{server}, "pid=".$status->{id}." move=".$csa." book") if $move;
    }
  }
  else {
    warn "unknown message\n";
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
  while ($in->sysread($char, 1) == 1) {
    $line .= $char;
    last if ($char eq "\n");
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
  $server->{socket} = new IO::Socket::INET
    (PeerAddr=>$hostname, PeerPort=>$port, Proto=>'tcp') || die "socket $!";
  $server->{writer} = $server->{reader} = $server->{socket};
  return $server;
}

sub unittest () {
  valid_usi_move("resign") || die "unittest";
  valid_usi_move("7g7f") || die "unittest";
  valid_usi_move("7g7F") && die "unittest";

  my $status = { id=>0 };
  initilize_board($status) unless $status->{board};
  usi2csa($status, "7g7f")  eq "7776FU" || die "unittest";
  usi2csa($status, "R*4c")  eq "0043HI" || die "unittest";
  usi2csa($status, "8h2b+") eq "8822UM" || die "unittest";
  csa2usi($status, "77","76","FU") eq "7g7f"  || die "unittest";
  csa2usi($status, "88","22","UM") eq "8h2b+" || die "unittest";
  csa2usi($status, "00","43","HI") eq "R*4c"  || die "unittest";
  $status->{prev} = [ @{$status->{board}} ];
  make_move($status, "77", "76", "FU");
  # show($status);
}

