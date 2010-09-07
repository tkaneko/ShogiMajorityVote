#!/usr/bin/perl -w

# load perl modules
use strict;
use IO::Socket;
use IO::Select;
use IO::Handle;
use IO::File;
use Time::HiRes qw( time );
use File::Spec;
use Getopt::Long;

# autoflush STDOUT
$| = 1;

# subroutines
sub get_game_summary ($$$);
sub play_a_game      ($$$$$);
sub parse_smsg       ($$$$);
sub parse_cmsg       ($$$$);
sub print_opinions   ($$$);
sub set_times        ($$);
sub clean_up_moves   ($$);
sub move_selection   ($$$$);
sub get_line         ($);
sub make_dir         ();
sub open_record      ($$);
sub open_log         ($);
sub open_clients     ($);
sub open_server      ($);
sub in_csa_clients   ($$$);
sub in_csa_block     ($$$);
sub out_csa          ($$$$);
sub out_record       ($$) { print { $_[0] } "$_[1]\n"; }
sub out_log          ($$) { print { $_[0] } "$_[1]\n"; }
sub out_client       ($$) { print { $_[0] } "$_[1]\n"; }
sub out_clients      ($$$);

# constants
sub phase_thinking  () { 0 }
sub phase_puzzling  () { 1 }
sub phase_pondering () { 2 }
sub tc_nmove        () { 29 }
sub sec_margin      () { 15 }
sub min_timeout     () { 0.05 }
sub max_timeout     () { 1.0 }
sub keep_alive      () { 180.0 }

{
    # defaults of command-line options
    my ( %status ) = ( client_port      => 4082,
		       client_num       => 3,
		       csa_host         => 'localhost',
		       csa_port         => 4081,
		       csa_id           => 'majority_vote',
		       csa_pw           => 'majority_vote',
		       sec_limit        => 0,
		       sec_limit_up     => 3,
		       time_response    => 0.2,
		       time_stable_min  => 2.0,
		       buf_csa          => "",
		       resign_threshold => -1500 );

    # parse the command-line options
    GetOptions( \%status,
		'client_port=i',
		'client_num=i',
		'csa_host=s',
		'csa_port=i',
		'csa_id=s',
		'csa_pw=s',
		'sec_limit=i',
		'sec_limit_up=i',
		'time_response=f' ) or die "$!";

    my $ref_sckt_clients = open_clients \%status;
    while ( 1 ) {
	my $sckt_csa = open_server \%status;
	my $basename = make_dir;
	my $fh_log   = open_log $basename;

	unless ( get_game_summary \%status, $sckt_csa, $fh_log ) {
	    $sckt_csa->close;
	    close $fh_log or die "$!";
	    next;
	}

	my $fh_record = open_record \%status, $basename;


	play_a_game( \%status, $ref_sckt_clients, $sckt_csa, $fh_record,
		     $fh_log );
	
	close $fh_record or die "$!";
	close $fh_log    or die "$!";
	$sckt_csa->close;
    }

    foreach my $sckt ( @$ref_sckt_clients ) { $sckt->close; }
}


sub play_a_game ($$$$$) {
    my ( $ref_status, $ref_sckt_clients, $sckt_csa, $fh_record, $fh_log ) = @_;
    my ( $line );

    # initialization of variables
    clean_up_moves $ref_status, $ref_sckt_clients;

    $$ref_status{sec_mytime}     = 0;
    $$ref_status{sec_optime}     = 0;
    $$ref_status{timeout}        = max_timeout;
    $$ref_status{pid}            = 0;
    $$ref_status{move_ponder}    = "";

    # initialize the Shogi board of clients 
    out_clients $ref_sckt_clients, $fh_log, "new";

    $$ref_status{time}           = time;
    $$ref_status{start_turn}     = $$ref_status{time};
    $$ref_status{start_think}    = $$ref_status{time};
    $$ref_status{time_printed}   = $$ref_status{time};
    $$ref_status{time_last_send} = $$ref_status{time};
    set_times $ref_status, $fh_log;

    if ( $$ref_status{phase} == phase_thinking ) {
	$$ref_status{timeout} = min_timeout;
    }

    while ( 1 ) {

      # block until handles are ready to be read, or timeout
      my $sckt = in_csa_clients $sckt_csa, $ref_status, $ref_sckt_clients;
  
      # set current time
      $$ref_status{time} = time;

      # keep alive
      if ( keep_alive > 0
	   and $$ref_status{time} > ( keep_alive
				      + $$ref_status{time_last_send} ) ) {
	  out_csa $ref_status, $sckt_csa, $fh_log, "";
      }

      if ( defined $sckt ) {
	  if ( $sckt == $sckt_csa ) {
	  
	      # received a message from the server
	      last unless parse_smsg( $ref_status, $ref_sckt_clients,
				      $fh_record, $fh_log );
	      
	  } else {

	      # received a message from one of the clients
	      parse_cmsg $ref_status, $sckt, $ref_sckt_clients, $fh_log;
	  }
      }

      # confer with client's opinions to make a move or pondering-move
      move_selection $ref_status, $ref_sckt_clients, $sckt_csa, $fh_log;
  }

    # the game ends. now all of clients should idle away.
    out_clients $ref_sckt_clients, $fh_log, "idle";
}


sub parse_smsg ($$$$) {
    my ( $ref_status, $ref_sckt_clients, $fh_record, $fh_log ) = @_;

    my $line = get_line \$$ref_status{buf_csa};

    out_log $fh_log, "csa> $line";

    if ( $line =~ /^\#WIN/ )  { return 0; }
    if ( $line =~ /^\#LOSE/ ) { return 0; }
    if ( $line =~ /^\#DRAW/ ) { return 0; }

    if ( $line =~ /^\#\w/ )   { return 1; }
    if ( $line =~ /^\s*$/ )   { return 1; }
    if ( $line =~ /^\%\w/ ) {
	out_record $fh_record, $line;
	return 1;
    }

    unless ( $line =~ /^([+-])(\d\d\d\d\w\w),T(\d+)/ ) { die "$!"; }

    my ( $color, $move, $sec ) = ( $1, $2, $3 );

    if ( $$ref_status{phase} == phase_thinking ) { die "$!"; }
    elsif ( $color eq $$ref_status{color} ) {

	# received time information from the server, continue puzzling.
	$$ref_status{sec_mytime} += $sec;
	$$ref_status{timeout}     = min_timeout;
	out_record $fh_record, $line;
	out_log $fh_log, "Time: ${sec}s / $$ref_status{sec_mytime}s.\n";
	out_log $fh_log, "Opponent's turn started.";
	set_times $ref_status, $fh_log;

    } elsif ( $$ref_status{phase} == phase_pondering
	      and $$ref_status{move_ponder} eq $move ) {
	    
	# received opp's move, pondering hit and my turn started.
	my $time_think = $$ref_status{time}-$$ref_status{start_think};

	$$ref_status{sec_optime} += $sec;
	out_record $fh_record, $line;
	out_log $fh_log, "Opponent made a move $line.";
	out_log $fh_log, "Time: ${sec}s / $$ref_status{sec_optime}s.";
	out_log $fh_log, sprintf( "Pondering hit! (%.2fs)\n", $time_think );
	out_log $fh_log, "My turn started.";

	$$ref_status{start_turn}  = $$ref_status{time};
	$$ref_status{phase}       = phase_thinking;
	$$ref_status{move_ponder} = "";
	$$ref_status{timeout}     = min_timeout;
	set_times $ref_status, $fh_log;

    } elsif ( $$ref_status{phase} == phase_pondering ) {
	    
	# received opp's move, pondering failed, my turn started.
	$$ref_status{pid} += 1;
	out_clients( $ref_sckt_clients, $fh_log,
		     "alter $move $$ref_status{pid}" );

	$$ref_status{sec_optime} += $sec;
	out_record $fh_record, $line;
	out_log $fh_log, "pid is set to $$ref_status{pid}.";
	out_log $fh_log, "Opponent made an unexpected move $line.";
	out_log $fh_log, "Time: ${sec}s / $$ref_status{sec_optime}s.\n";
	out_log $fh_log, "My turn started.";

	$$ref_status{start_turn}   = $$ref_status{time};
	$$ref_status{start_think}  = $$ref_status{time};
	$$ref_status{time_printed} = $$ref_status{time};
	$$ref_status{phase}        = phase_thinking;
	$$ref_status{move_ponder}  = "";
	$$ref_status{timeout}      = min_timeout;
	clean_up_moves $ref_status, $ref_sckt_clients;
	set_times $ref_status, $fh_log;

    } else {

	# received opp's move while puzzling, my turn started.
	$$ref_status{pid} += 1;
	out_clients( $ref_sckt_clients, $fh_log,
		     "move $move $$ref_status{pid}" );

	$$ref_status{sec_optime} += $sec;
	out_record $fh_record, $line;
	out_log $fh_log, "pid is set to $$ref_status{pid}.";
	out_log $fh_log, "Opponent made a move $line while puzzling.";
	out_log $fh_log, "Time: ${sec}s / $$ref_status{sec_optime}s.\n";
	out_log $fh_log, "My turn started.";
	
	$$ref_status{start_turn}   = $$ref_status{time};
	$$ref_status{start_think}  = $$ref_status{time};
	$$ref_status{time_printed} = $$ref_status{time};
	$$ref_status{phase}        = phase_thinking;
	$$ref_status{move_ponder}  = "";
	$$ref_status{timeout}      = min_timeout;
	clean_up_moves $ref_status, $ref_sckt_clients;
	set_times $ref_status, $fh_log;
    }

    return 1;
}


sub parse_cmsg ($$$$) {
    my ( $ref_status, $sckt, $ref_sckt_clients, $fh_log ) = @_;
    my $ref        = $$ref_status{$sckt};
    my $line       = get_line \$$ref{buf};
    my $time_think = $$ref_status{time}-$$ref_status{start_think};

#    print "$$ref{id}> $line";

    # keep alive
    if ( $line =~ /^\s*$/ ) {
	out_client $sckt, "";
	out_log $fh_log, "$$ref{id}< ";
	return;
    }

    unless ( $line =~ /pid=(\d+)/ ) {
	warn "pid from $$ref{id} is no match: $line\n";
	return;
    }

    if ( $1 != $$ref_status{pid} ) { return; }
    
    my $move      = undef;
    my $book      = undef;
    my $nodes     = undef;
    my $stable    = undef;
    my $final     = undef;
    my $confident = undef;

    if ( $line =~ /book/ )                   { $book      = 1; }
    if ( $line =~ /move=(\d\d\d\d\w\w)/ )    { $move      = $1; }
    if ( $line =~ /move=(%TORYO)/
	 and $$ref_status{phase} != phase_puzzling ) { $move = $1; }
    if ( $line =~ /n=(\d+)/ )                { $nodes     = $1; }
    if ( $line =~ /stable/ ) {
	if ( defined $$ref{have_stable} )    { $stable    = 1; }
	else { warn "Invalid message 'stable' from $$ref{id}: $line\n";	}
    }
    if ( $line =~ /final/ ) {
	if ( defined $$ref{have_final} )     { $final     = 1; }
	else { warn "Invalid message 'final' from $$ref{id}: $line\n";	}
    }
    if ( $line =~ /confident/ ) {
	if ( defined $$ref{have_confident} ) { $confident = 1; }
	else { warn "Invalid message 'confident' from $$ref{id}: $line\n"; }
    }
    
    
    if ( defined $move and defined $book ) {

	$$ref{book}      = $book;
	$$ref{move}      = $move;
	$$ref{nodes}     = 0.0;
	$$ref{spent}     = $time_think;
	
    } elsif ( defined $move and defined $nodes ) {

	$$ref{final}     = $final;
	$$ref{stable}    = $stable;
	$$ref{confident} = $confident;
	$$ref{move}      = $move;
	$$ref{nodes}     = $nodes;
	$$ref{spent}     = $time_think;

    } elsif ( defined $final and defined $$ref{move} ) {

	$$ref{final}     = $final;
	$$ref{spent}     = $time_think;

    } elsif ( defined $stable and defined $$ref{move} ) {

	$$ref{stable}    = $stable;
	$$ref{spent}     = $time_think;

    } elsif ( defined $confident and defined $$ref{move} ) {

	$$ref{confident} = $confident;
	$$ref{spent}     = $time_think;

    } elsif ( defined $nodes and defined $$ref{move} ) {

	$$ref{nodes}     = $nodes;
	$$ref{spent}     = $time_think;

    } else { warn "Invalid message from $$ref{id}: $line\n"; }

    my ( @boxes );
    my $nvalid = 0;

    # Organize all opinions into the ballot boxes.
    # Each box contains the same move-opinions.
    foreach my $sckt ( @$ref_sckt_clients ) {
	my $i;
	my $ref = $$ref_status{$sckt};

	unless ( defined $$ref{move} ) { next; }

	if ( defined $book and not defined $$ref{book} ) { next; }

	$nvalid += 1;
	for ( $i = 0; $i < @boxes; $i++ ) {
	    my $op = ${$boxes[$i]}[1];
	    if ( $$op{move} eq $$ref{move} ) { last; }
	}
	
	${$boxes[$i]}[0] += $$ref{factor};
	push @{$boxes[$i]}, $ref;
    }
    
    # Sort opinions by factor
    @boxes = sort { $$b[0] <=> $$a[0] } @boxes;

    my $box_name = ( defined $book ) ? 'boxes_book' : 'boxes';
    $$ref_status{$box_name} = \@boxes;
    $$ref_status{nvalid}    = $nvalid;
}


sub move_selection ($$$$) {
    my ( $ref_status, $ref_sckt_clients, $sckt_csa, $fh_log ) = @_;
    my ( $move_ready );
	  
    if ( $$ref_status{phase} == phase_pondering ) { return; }


    my $time_turn  = $$ref_status{time} - $$ref_status{start_turn};
    my $time_think = $$ref_status{time} - $$ref_status{start_think};

    # see if there are any confident decisions or not.
    foreach my $sckt ( @$ref_sckt_clients ) {
	    
	my $ref = $$ref_status{$sckt};
	    
	if ( defined $$ref{confident} ) {
		
	    out_log $fh_log, "$$ref{id} is confident in $$ref{move}.";
	    $move_ready = $$ref{move};
	    last;
	}
    }

    # Find the best move from the ballot box of book.
    if ( not $move_ready
	 and 2.0 < $time_think + $$ref_status{time_response}
	 and defined $$ref_status{boxes_book}
	 and defined ${${$$ref_status{boxes_book}}[0]}[0] ) {
	
	my $ref_boxes = $$ref_status{boxes_book};
	my $ops       = $$ref_boxes[0];
	my $op        = $$ops[1];
	my $nop       = @$ops;
	
	out_log $fh_log, "Book Move";
	out_log $fh_log, "The best move is ${$op}{move}.";
	print_opinions $$ref_status{boxes_book}, undef, $fh_log;
	
	$move_ready = ${$op}{move};
    }


    # Find the best move from the ballot box.
    if ( not $move_ready
	 and defined $$ref_status{boxes}
	 and defined ${${$$ref_status{boxes}}[0]}[0] ) {

	my $ref_boxes   = $$ref_status{boxes};
	my $ops         = $$ref_boxes[0];
	my $op          = $$ops[1];
	my $nop         = @$ops;
	my $nvalid      = $$ref_status{nvalid};
	my $condition   = 0;
	my $sec_elapsed;

	# check time
	if ( $$ref_status{phase} == phase_thinking
	     and ( $$ref_status{sec_mytime}
		   + int( $$ref_status{sec_fine} ) + 1.0
		   >= $$ref_status{sec_limit} ) ) {
	    # in byo-yomi
	    $sec_elapsed = $time_turn;

	} else {

	    $sec_elapsed = ( $time_turn + int( $time_think - $time_turn ) );
	}

	if ( $$ref_status{time_printed} + 60 < $$ref_status{time} ) {

	    $$ref_status{time_printed} = $$ref_status{time};
	    print_opinions $$ref_status{boxes}, $$ref_status{nvalid}, $fh_log;
	    out_log $fh_log, "";
	}

	if ( $nvalid > 2 and $nop > $nvalid * 0.90
	     and $sec_elapsed > $$ref_status{sec_easy} ) {

	    out_log $fh_log, "Easy Move";
	    $condition = 1;

	} elsif ( $nop > $nvalid * 0.70
		  and $sec_elapsed > $$ref_status{sec_fine} ) {
	    
	    out_log $fh_log, "Normal Move";
	    $condition = 1;

	} elsif ( $sec_elapsed > $$ref_status{sec_max} ) {

	    out_log $fh_log, "Difficult Move";
	    $condition = 1;
	}

	# check stable
	if ( not $condition
	     and $$ref_status{time_stable_min} < $time_think + $$ref_status{time_response} ) {

	    my $nhave_stable = 0;
	    my $nstable      = 0;

	    foreach my $sckt ( @$ref_sckt_clients ) {
	    
		my $ref = $$ref_status{$sckt};

		unless ( defined $$ref{have_stable} ) { next; }
		
		$nhave_stable += $$ref{factor};
		if ( defined $$ref{stable} ) { $nstable += $$ref{factor}; }
	    }

	    if ( $nhave_stable < $nstable * 2 ) { $condition = 1; }
	}

	# see if there is any final decisions or not.
	unless ( $condition ) {

	    my %nfinal;
	    my $nhave_final = 0;

	    foreach my $sckt ( @$ref_sckt_clients ) {

		my $ref = $$ref_status{$sckt};

		unless ( defined $$ref{have_final} ) { next; }

		$nhave_final += $$ref{factor};

		if ( defined $$ref{final} ) { $nfinal{$$ref{move}} += $$ref{factor}; }
	    }

	    my $max = ( sort { $b <=> $a } values %nfinal )[0];

	    if ( defined $max and $nhave_final < $max * 2 ) { $condition = 1; }
	}
	
	if ( $condition ) {
	    
	    out_log $fh_log, "The best move is ${$op}{move}.";
	    print_opinions $$ref_status{boxes}, $$ref_status{nvalid}, $fh_log;
	    
	    $move_ready = ${$op}{move};
	}
    }
    
    unless ( $move_ready ) { return; }


    # A move is found.
    if ( $$ref_status{phase} == phase_puzzling ) {
	      
	# Make a move, and ponering start.
	$$ref_status{pid} += 1;
	out_clients( $ref_sckt_clients, $fh_log,
		     "move $move_ready $$ref_status{pid}" );
	    
	out_log $fh_log, "pid is set to $$ref_status{pid}.";
	out_log $fh_log, "Ponder on $$ref_status{color}$move_ready.";
	    
	clean_up_moves $ref_status, $ref_sckt_clients;
	$$ref_status{move_ponder}  = $move_ready;
	$$ref_status{start_think}  = $$ref_status{time};
	$$ref_status{time_printed} = $$ref_status{time};
	$$ref_status{timeout}      = max_timeout;
	$$ref_status{phase}        = phase_pondering;
	return;
    }
	
    # Make a move, and start puzzling.
    $$ref_status{pid} += 1;
    my $csa_move = (($move_ready !~ /^%/) ? $$ref_status{color} : "").$move_ready;
    out_csa $ref_status, $sckt_csa, $fh_log, $csa_move;
    if ( $move_ready !~ /^%/ ) {
      out_clients( $ref_sckt_clients, $fh_log,
		   "move $move_ready $$ref_status{pid}" );
    }
    out_log $fh_log, "pid is set to $$ref_status{pid}.";
    out_log $fh_log, sprintf( "time-searched: %7.2fs", $time_think );
    out_log $fh_log, sprintf( "time-elapsed:  %7.2fs", $time_turn );
	
    clean_up_moves $ref_status, $ref_sckt_clients;
    $$ref_status{start_turn}   = $$ref_status{time};
    $$ref_status{start_think}  = $$ref_status{time};
    $$ref_status{time_printed} = $$ref_status{time};
    $$ref_status{phase}        = phase_puzzling;
    $$ref_status{timeout}      = max_timeout;
}


# input
#   $$ref_status{sec_mytime}
#   $$ref_status{sec_limit}
#   $$ref_status{sec_limit_up}
#   $$ref_status{time_response}
#   $$ref_status{start_turn}
#   $$ref_status{start_think}
#   $$ref_status{phase}
#   tc_nmove
#   sec_margin
#
# output
#   $$ref_status{sec_max}
#   $$ref_status{sec_fine}
#   $$ref_status{sec_easy}
#
sub set_times ($$) {
    my ( $ref_status, $fh_log ) = @_;
    my ( $sec_left, $sec_fine, $sec_max, $sec_easy, $max, $min );
    my $sec_ponder = int $$ref_status{start_turn} - $$ref_status{start_think};

    # set $sec_max and $sec_fine
    #    $sec_max  - maximum allowed time-consumption to think
    #    $sec_fine - fine time-consumption to think
    #    $sec_easy - time-consumption to think an easy move
    if ( $$ref_status{sec_limit_up} ) {

	# have byo-yomi
	$sec_left = $$ref_status{sec_limit} - $$ref_status{sec_mytime};
	if ( $sec_left < 0 ) { $sec_left = 0; }

	$sec_fine = int( $sec_left / tc_nmove + 0.5 ) - $sec_ponder;
	if ( $sec_fine < 0 ) { $sec_fine = 0; }

	# t = 2s is not beneficial since 2.8s are almost the same as 1.8s.
        # So that, we rather want to use up the ordinary time.
	if ( $sec_fine < 3 ) { $sec_fine = 3; }

	# 'byo-yomi' is so long that the ordinary time-limit is negligible.
	if ( $sec_fine < $$ref_status{sec_limit_up} * 1.0 ) {
	    $sec_fine = int( $$ref_status{sec_limit_up} * 1.0 );
	}

	$sec_max  = $sec_fine * 3;
	$sec_easy = int( $sec_fine / 3 + 0.5 );

    } else {

	# no byo-yomi
	if ( $$ref_status{sec_mytime}+sec_margin < $$ref_status{sec_limit} ) {
	    $sec_left = $$ref_status{sec_limit} - $$ref_status{sec_mytime};
	    $sec_fine = int( $sec_left / tc_nmove + 0.5 ) - $sec_ponder;
	    if ( $sec_fine < 0 ) { $sec_fine = 0; }
	    
	    # t = 2s is not beneficial since 2.8s are almost the same as 1.8s.
	    # So that, we rather want to save the time.
	    if ( $sec_fine < 3 ) { $sec_fine = 1; }
	    $sec_max  = $sec_fine * 3;
	    $sec_easy = int( $sec_fine / 3 + 0.5 );

	} else { $sec_fine = $sec_max = 1; }
    }

    $max = $sec_left + $$ref_status{sec_limit_up};
    $min = 1;

    if ( $max < $sec_easy ) { $sec_easy = $max; }
    if ( $max < $sec_fine ) { $sec_fine = $max; }
    if ( $max < $sec_max )  { $sec_max  = $max; }
    if ( $min > $sec_easy ) { $sec_easy = $min; }
    if ( $min > $sec_fine ) { $sec_fine = $min; }
    if ( $min > $sec_max )  { $sec_max  = $min; }
    
    $$ref_status{sec_max}  = ( 1.0 - $$ref_status{time_response} + $sec_max );
    $$ref_status{sec_fine} = ( 1.0 - $$ref_status{time_response} + $sec_fine );
    $$ref_status{sec_easy} = ( 1.0 - $$ref_status{time_response} + $sec_easy );

    if ( $$ref_status{phase} == phase_puzzling ) {

	$$ref_status{sec_max}  /= 5.0;
	$$ref_status{sec_fine} /= 5.0;
	$$ref_status{sec_easy} /= 5.0;
    }

    out_log $fh_log, sprintf( "Time limits: max=%.2f fine=%.2f easy=%.2fs",
			      $$ref_status{sec_max}, $$ref_status{sec_fine},
			      $$ref_status{sec_easy} );
}


sub clean_up_moves ($$) {
    my ( $ref_status, $ref_sckt_clients ) = @_;

    delete $$ref_status{boxes};
    delete $$ref_status{boxes_book};
    foreach my $sckt ( @$ref_sckt_clients ) {
	my $ref = $$ref_status{$sckt};
	delete @$ref{ qw(move book stable final confident) };
    }
}


sub make_dir () {
    my ( $sec, $min, $hour, $mday, $mon, $year ) = localtime( time );

    $year -= 100;
    $mon  += 1;
    my $dirname = sprintf "%02s%02s", $year, $mon;
    unless ( -d $dirname ) { mkdir $dirname or die "$!"; }

    my $basename  = sprintf "%02s%02s%02s%02s", $mday, $hour, $min, $sec;

    return File::Spec->catfile( $dirname, $basename );
}


sub print_opinions ($$$) {
    my ( $ref_boxes, $nvalid, $fh_log ) = @_;

    if ( defined $nvalid ) {
	out_log $fh_log, "$nvalid valid ballots are found.";
    }

    foreach my $ops ( @$ref_boxes ) {
	my ( $sum, @ops_ ) = @$ops;

	out_log $fh_log, "sum = $sum";
	foreach my $op ( @ops_ ) {
	    my $nps = $$op{nodes} / $$op{spent} / 1000.0;
	    my $str = sprintf( "  %.2f %s nps=%6.1fK %6.1fs %s",
			       $$op{factor}, $$op{move}, $nps,
			       $$op{spent}, $$op{id} );

	    if ( defined $$op{stable} ) { $str .= " stable"; }
	    if ( defined $$op{final} )  { $str .= " final"; }
	    out_log $fh_log, $str;
	}
    }
}


sub open_record ($$) {
    my ( $ref_status, $basename ) = @_;
    my ( $fh_record );

    open $fh_record, ">${basename}.csa" or die "$!";
    $fh_record->autoflush(1);

    out_record $fh_record, "N+$$ref_status{name1}";
    out_record $fh_record, "N-$$ref_status{name2}";
    out_record $fh_record, "PI";
    out_record $fh_record, "+";

    return $fh_record;
}


sub open_log ($) {
    my ( $basename ) = @_;
    my ( $fh_log );

    open $fh_log, ">${basename}.log" or die "$!";
    $fh_log->autoflush(1);

    return $fh_log;
}


sub open_clients ($) {
    my ( $ref_status ) = @_;
    my ( $selector, $sckt_listen, @sckt_clients );


    # creates a listening socket for my clients.
    $sckt_listen = new IO::Socket::INET( LocalPort=> $$ref_status{client_port},
					 Listen   => SOMAXCONN,
					 Proto    => 'tcp',
					 ReuseAddr=> 1 )
	or die "Can't create a listening socket: $!\n";


    # wait for a certain number of clients connects to me.
    print "Wait for $$ref_status{client_num} clients connect to me ...\n";
    $selector = new IO::Select $sckt_listen;
    
    for ( my $n = 0; $n < $$ref_status{client_num}; $n++ ) {

	$selector->can_read;

	my $sckt = $sckt_listen->accept or die "acception failure: $!\n";
	push @sckt_clients, $sckt;

	my $line = <$sckt>;
	out_client $sckt, "idle";

	$line =~ s/\r?\n$//;
	
	my ( $id, $factor ) = split " ", "$line 1.0";
	$$ref_status{$sckt} = { id => $id, factor => $factor, buf => "" };

	$line =~ /stable/    and ${$$ref_status{$sckt}}{have_stable}    = 1;
	$line =~ /final/     and ${$$ref_status{$sckt}}{have_final}     = 1;
	$line =~ /confident/ and ${$$ref_status{$sckt}}{have_confident} = 1;


	print "  $line is accepted\n";
    }

    $sckt_listen->close;

    return \@sckt_clients;
}


sub get_game_summary ($$$) {
    my ( $ref_status, $sckt_csa, $fh_log ) = @_;
    my ( $line, @game_summary );

    while ( 1 ) {
	$line = in_csa_block $ref_status, $sckt_csa, $fh_log;
	push @game_summary, $line;
	if ( $line =~ /^END Game_Summary$/ ) { last; }
    }

    out_csa $ref_status, $sckt_csa, $fh_log, "AGREE";
    $line = in_csa_block $ref_status, $sckt_csa, $fh_log;
    
    unless ( $line =~ /^START/ ) {
	print "The game disagreed.\n";
	return 0;
    }

    # parse massages of the game summary from the CSA Shogi server
    $$ref_status{name1} = "";
    $$ref_status{name2} = "";
    $$ref_status{color} = '+';
    $$ref_status{phase} = phase_puzzling;

    foreach $line ( @game_summary ) {

	if ( $line =~ /^Your_Turn\:([+-])\s*$/ ) {

	    $$ref_status{color} = $1;
	    if ( $1 eq '+' ) { $$ref_status{phase} = phase_thinking; }
	}
	elsif ( $line =~ /^Name\+\:(\w+)/ ) { $$ref_status{name1} = $1; }
	elsif ( $line =~ /^Name\-\:(\w+)/ ) { $$ref_status{name2} = $1; }
    }

    return 1;
}


sub open_server ($) {
    my ( $ref_status ) = @_;
    my $sckt_csa;

    while ( 1 ) {

	eval {
	    my $line;

	    $sckt_csa
		= new IO::Socket::INET( PeerAddr => $$ref_status{csa_host},
					PeerPort => $$ref_status{csa_port},
					Proto    => 'tcp' );
	    die "$!" unless $sckt_csa;
	    
	    out_csa( $ref_status, $sckt_csa, *STDOUT,
		     "LOGIN $$ref_status{csa_id} $$ref_status{csa_pw}" );
	    
	    $line = in_csa_block $ref_status, $sckt_csa, *STDOUT;
	    $line =~ /^LOGIN:$$ref_status{csa_id} OK$/
		or die "Login failed \n";
	};

	if ( $@ ) {

	    warn $@;
	    print "try connect() again in 10s...\n";
	    sleep 10;

	} else { last; }
    }

    return $sckt_csa;
}


sub out_csa ($$$$) {
    my ( $ref_status, $sckt_csa, $fh_log, $line ) = @_;

    $$ref_status{time_last_send} = $$ref_status{time};
    print $sckt_csa "$line\n";   # '\n' is assumed to be represented by 0x0a.
    out_log $fh_log, "csa< $line";
}


sub in_csa_block ($$$) {
    my ( $ref_status, $sckt_csa, $fh_log ) = @_;
    my $selector = new IO::Select $sckt_csa;
    my ( $line, $input );

    for ( ;; ) {
	
	# The buffer already has one line.
	if ( index( $$ref_status{buf_csa}, "\n" ) != -1 ) {

	    $line = get_line \$$ref_status{buf_csa};
	    out_log $fh_log, "csa> $line";
	    unless ( $line =~ /^\s*$/ ) { last; }
	    next;
	}


	# The socket is ready to recv().
	if ( keep_alive < 0 or $selector->can_read( keep_alive ) ) {

	    $sckt_csa->recv( $input, 65536 );
	    $input or die "connection to CSA Shogi server is down: $!\n";
	    $$ref_status{buf_csa} .= $input;
	    next;
	}

	# keep alive
	out_csa $ref_status, $sckt_csa, $fh_log, "";
    }

    return $line;
}


sub out_clients ($$$) {
    my ( $ref_fh, $fh_log, $line ) = @_;

    foreach my $fh ( @$ref_fh ) { print $fh "$line\n"; }
    out_log $fh_log, "all< $line";
}


sub in_csa_clients ($$$) {
    my ( $sckt_csa, $ref_status, $ref_sckt_clients ) = @_;

    # check if any buffers had already read one line
    if ( index( $$ref_status{buf_csa}, "\n" ) != -1 ) { return $sckt_csa; }

    foreach my $sckt ( @$ref_sckt_clients ) {
	my $ref = $$ref_status{$sckt};
	if ( index( $$ref{buf}, "\n" ) != -1 ) { return $sckt; }
    }


    # get messages from all sockets
    my $selector = new IO::Select $sckt_csa, @$ref_sckt_clients;

    foreach my $sckt ( $selector->can_read( $$ref_status{timeout} ) ) {
	my $ref = $$ref_status{$sckt};
	my $input;
	
	if ( $sckt == $sckt_csa ) {

	    # message arrived from CSA Shogi server
	    $sckt->recv( $input, 65536 );
	    $input or die "connection to CSA Shogi server is down: $!\n";

	    $$ref_status{buf_csa} .= $input;
	    next;
	}

	# message arrived from a client
	$sckt->recv( $input, 65536 );
	unless ( $input ) {
	    # One client is down
	    my $nclient = $selector->count - 2;
	    my $i;

	    warn "\nWARNING: connection to $$ref{id} is down. "
		. "$nclient clients left.\n\n";
	    unless ( $nclient ) { die "$!"; }

	    for ( $i = 0; $i < $nclient; $i++ ) {
		if ( $$ref_sckt_clients[$i] == $sckt ) {
		    $$ref_sckt_clients[$i] = $$ref_sckt_clients[-1];
		}
	    }
	    pop @$ref_sckt_clients;

	    delete $$ref_status{$sckt};
	    $selector->remove( $sckt );
	    $sckt->close;
	    next;
	}

	$$ref{buf} .= $input;
    }

    # check if any buffers received one line now
    if ( index( $$ref_status{buf_csa}, "\n" ) != -1 ) { return $sckt_csa; }

    foreach my $sckt ( @$ref_sckt_clients ) {
	my $ref = $$ref_status{$sckt};
	if ( index( $$ref{buf}, "\n" ) != -1 ) { return $sckt; }
    }


    return undef;
}


sub get_line ($) {
    my ( $ref_buf ) = @_;
    my ( $pos, $line );

    $pos = index $$ref_buf, "\n";
    if ( $pos == -1 ) { die "$!"; }

    $line     = substr $$ref_buf, 0, 1+$pos;
    $$ref_buf = substr $$ref_buf, 1+$pos;
    $line     =~ s/\r?\n$//;

    return $line;
}
