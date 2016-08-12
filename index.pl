#!/usr/bin/env perl
use Mojolicious::Lite;
use Cache::File;
use File::Slurp qw(read_file write_file);
use List::MoreUtils qw();
use Travel::Status::DE::HAFAS;
use Travel::Status::DE::HAFAS::StopFinder;
use Travel::Status::DE::IRIS;
use Travel::Status::DE::IRIS::Stations;
use 5.014;
use utf8;

no if $] >= 5.018, warnings => 'experimental::smartmatch';

our $VERSION = qx{git describe --dirty} || '0.05';

my %default = (
	backend => 'iris',
	mode    => 'clean',
	admode  => 'deparr',
);

sub log_api_access {
	my $counter = 1;
	if ( -r $ENV{DBFAKEDISPLAY_STATS} ) {
		$counter = read_file( $ENV{DBFAKEDISPLAY_STATS} ) + 1;
	}
	write_file( $ENV{DBFAKEDISPLAY_STATS}, $counter );
	return;
}

sub get_results_for {
	my ( $backend, $station, %opt ) = @_;
	my $data;

	my $cache_hafas = Cache::File->new(
		cache_root => $ENV{DBFAKEDISPLAY_HAFAS_CACHE} // '/tmp/dbf-hafas',
		default_expires => '180 seconds',
		lock_level      => Cache::File::LOCK_LOCAL(),
	);

	my $cache_iris_main = Cache::File->new(
		cache_root => $ENV{DBFAKEDISPLAY_IRIS_CACHE} // '/tmp/dbf-iris-main',
		default_expires => '2 hours',
		lock_level      => Cache::File::LOCK_LOCAL(),
	);

	my $cache_iris_rt = Cache::File->new(
		cache_root => $ENV{DBFAKEDISPLAY_IRISRT_CACHE}
		  // '/tmp/dbf-iris-realtime',
		default_expires => '50 seconds',
		lock_level      => Cache::File::LOCK_LOCAL(),
	);

	# Cache::File has UTF-8 problems, so strip it (and any other potentially
	# problematic chars).
	my $cache_str = $station;
	$cache_str =~ tr{[0-9a-zA-Z -]}{}cd;

	if ( $backend eq 'iris' ) {

		if ( $ENV{DBFAKEDISPLAY_STATS} ) {
			log_api_access();
		}

		# requests with DS100 codes should be preferred (they avoid
		# encoding problems on the IRIS server). However, only use them
		# if we have an exact match. Ask the backend otherwise.
		my @station_matches
		  = Travel::Status::DE::IRIS::Stations::get_station($station);
		if ( @station_matches == 1 ) {
			$station = $station_matches[0][0];
			my $status = Travel::Status::DE::IRIS->new(
				station        => $station,
				main_cache     => $cache_iris_main,
				realtime_cache => $cache_iris_rt,
				%opt
			);
			$data = {
				results => [ $status->results ],
				errstr  => $status->errstr,
				station_name =>
				  ( $status->station ? $status->station->{name} : $station ),
			};
		}
		elsif ( @station_matches > 1 ) {
			$data = {
				results => [],
				errstr  => 'Ambiguous station name',
			};
		}
		else {
			$data = {
				results => [],
				errstr  => 'Unknown station name',
			};
		}
	}
	elsif ( $backend eq 'ris' ) {
		$data = $cache_hafas->thaw($cache_str);
		if ( not $data ) {
			if ( $ENV{DBFAKEDISPLAY_STATS} ) {
				log_api_access();
			}
			my $status = Travel::Status::DE::HAFAS->new(
				station       => $station,
				excluded_mots => [qw[bus ferry ondemand tram u]],
				%opt
			);
			$data = {
				results => [ $status->results ],
				errstr  => $status->errstr,
			};
			$cache_hafas->freeze( $cache_str, $data );
		}
	}
	else {
		$data = {
			results => [],
			errstr  => "Backend '$backend' not supported",
		};
	}

	return $data;
}

helper 'handle_no_results' => sub {
	my ( $self, $backend, $station, $errstr ) = @_;

	if ( $backend eq 'ris' ) {
		my $db_service = Travel::Status::DE::HAFAS::get_service('DB');
		my $sf         = Travel::Status::DE::HAFAS::StopFinder->new(
			url   => $db_service->{stopfinder},
			input => $station,
		);
		my @candidates
		  = map { [ $_->{name}, $_->{id} ] } $sf->results;
		if ( @candidates > 1
			or ( @candidates == 1 and $candidates[0][1] ne $station ) )
		{
			$self->render(
				'landingpage',
				stationlist => \@candidates,
				hide_opts   => 0
			);
			return;
		}
	}
	if ( $backend eq 'iris' ) {
		my @candidates = map { [ $_->[1], $_->[0] ] }
		  Travel::Status::DE::IRIS::Stations::get_station($station);
		if ( @candidates > 1
			or ( @candidates == 1 and $candidates[0][1] ne $station ) )
		{
			$self->render(
				'landingpage',
				stationlist => \@candidates,
				hide_opts   => 0
			);
			return;
		}
	}
	$self->render(
		'landingpage',
		error => ( $errstr // "Got no results for '$station'" ),
		hide_opts => 0
	);
	return;
};

helper 'handle_no_results_json' => sub {
	my ( $self, $backend, $station, $errstr, $api_version, $callback ) = @_;

	$self->res->headers->access_control_allow_origin(q{*});
	my $json;
	if ($errstr) {
		$json = $self->render_to_string(
			json => {
				api_version => $api_version,
				version     => $VERSION,
				error       => $errstr,
			}
		);
	}
	elsif ( $backend eq 'iris' ) {
		my @candidates = map { { code => $_->[0], name => $_->[1] } }
		  Travel::Status::DE::IRIS::Stations::get_station($station);
		if ( @candidates > 1
			or ( @candidates == 1 and $candidates[0]{code} ne $station ) )
		{
			$json = $self->render_to_string(
				json => {
					api_version => $api_version,
					version     => $VERSION,
					error       => 'ambiguous station code/name',
					candidates  => \@candidates,
				}
			);
		}
		else {
			$json = $self->render_to_string(
				json => {
					api_version => $api_version,
					version     => $VERSION,
					error => ( $errstr // "Got no results for '$station'" )
				}
			);
		}
	}
	else {
		$json = $self->render_to_string(
			json => {
				api_version => $api_version,
				version     => $VERSION,
				error       => ( $errstr // 'unknown station code/name' )
			}
		);
	}
	if ($callback) {
		$self->render(
			data   => "$callback($json);",
			format => 'json'
		);
	}
	else {
		$self->render(
			data   => $json,
			format => 'json'
		);
	}
	return;
};

helper 'is_important' => sub {
	my ( $self, $stop ) = @_;

	if ( $stop =~ m{ Hbf | Flughafen }ox ) {
		return 1;
	}
	return;
};

helper 'json_route_diff' => sub {
	my ( $self, $route, $sched_route ) = @_;
	my @json_route;
	my @route       = @{$route};
	my @sched_route = @{$sched_route};

	my $route_idx = 0;
	my $sched_idx = 0;

	while ( $route_idx <= $#route and $sched_idx <= $#sched_route ) {
		if ( $route[$route_idx] eq $sched_route[$sched_idx] ) {
			push( @json_route, { name => $route[$route_idx] } );
			$route_idx++;
			$sched_idx++;
		}

		# this branch is inefficient, but won't be taken frequently
		elsif ( not( $route[$route_idx] ~~ \@sched_route ) ) {
			push(
				@json_route,
				{
					name         => $route[$route_idx],
					isAdditional => 1
				}
			);
			$route_idx++;
		}
		else {
			push(
				@json_route,
				{
					name        => $sched_route[$sched_idx],
					isCancelled => 1
				}
			);
			$sched_idx++;
		}
	}
	while ( $route_idx < $#route ) {
		push(
			@json_route,
			{
				name         => $route[$route_idx],
				isAdditional => 1,
				isCancelled  => 0
			}
		);
		$route_idx++;
	}
	while ( $sched_idx < $#sched_route ) {
		push(
			@json_route,
			{
				name         => $sched_route[$sched_idx],
				isAdditional => 0,
				isCancelled  => 1
			}
		);
		$sched_idx++;
	}
	return @json_route;
};

sub handle_request {
	my $self    = shift;
	my $station = $self->stash('station');
	my $via     = $self->stash('via');

	my @platforms = split( /,/, $self->param('platforms') // q{} );
	my @lines     = split( /,/, $self->param('lines')     // q{} );
	my $template       = $self->param('mode')          // 'clean';
	my $hide_low_delay = $self->param('hidelowdelay')  // 0;
	my $hide_opts      = $self->param('hide_opts')     // 0;
	my $show_realtime  = $self->param('show_realtime') // 0;
	my $backend        = $self->param('backend')       // 'iris';
	my $admode         = $self->param('admode')        // 'deparr';
	my $with_related   = $self->param('recursive')     // 0;
	my $callback       = $self->param('callback');
	my $apiver         = $self->param('version')       // 0;
	my @train_types     = split( /,/, $self->param('train_types')     // q{} );
	my %opt;

	my $api_version
	  = $backend eq 'iris'
	  ? $Travel::Status::DE::IRIS::VERSION
	  : $Travel::Status::DE::HAFAS::VERSION;

	$self->stash( departures => [] );
	$self->stash( title      => 'db-infoscreen' );
	$self->stash( version    => $VERSION );

	if ( not( $template ~~ [qw[clean json marudor multi single]] ) ) {
		$template = 'clean';
	}

	if ( not $station ) {
		$self->render(
			'landingpage',
			hide_opts  => 0,
			show_intro => 1
		);
		return;
	}

	if ( $template eq 'marudor' ) {
		$backend = 'iris';
		$opt{lookahead} = 120;
	}

	if ($with_related) {
		$opt{with_related} = 1;
	}

	my @departures;
	my $data        = get_results_for( $backend, $station, %opt );
	my $results_ref = $data->{results};
	my $errstr      = $data->{errstr};
	my @results     = @{$results_ref};

	if ( not @results and $template ~~ [qw[json marudor]] ) {
		$self->handle_no_results_json( $backend, $station, $errstr,
			$api_version, $callback );
		return;
	}

	if ( not @results ) {
		$self->handle_no_results( $backend, $station, $errstr );
		return;
	}

	if ( $template eq 'single' ) {
		if ( not @platforms ) {
			for my $result (@results) {
				if ( not( $result->platform ~~ \@platforms ) ) {
					push( @platforms, $result->platform );
				}
			}
			@platforms = sort { $a <=> $b } @platforms;
		}
		my %pcnt;
		@results = grep { $pcnt{ $_->platform }++ < 1 } @results;
		@results = sort { $a->platform <=> $b->platform } @results;
	}

	if ( $backend eq 'iris' and $show_realtime ) {
		if ( $admode eq 'arr' ) {
			@results = sort {
				( $a->arrival // $a->departure )
				  <=> ( $b->arrival // $b->departure )
			} @results;
		}
		else {
			@results = sort {
				( $a->departure // $a->arrival )
				  <=> ( $b->departure // $b->arrival )
			} @results;
		}
	}

	for my $result (@results) {
		my $platform = ( split( / /, $result->platform ) )[0];
		my $line     = $result->line;
		my $train_type     = $result->type;
		my $delay    = $result->delay;
		if ( $via and $result->can('route_post') ) {
			$via =~ s{ , \s* }{|}gx;
			my @route = $result->route_post;
			if ( not( List::MoreUtils::any { m{$via}i } @route ) ) {
				next;
			}
		}
		if ( @platforms
			and not( List::MoreUtils::any { $_ eq $platform } @platforms ) )
		{
			next;
		}
		if ( @lines and not( List::MoreUtils::any { $line =~ m{^$_} } @lines ) )
		{
			next;
		}
		if ( @train_types and not ( List::MoreUtils::any { $train_type =~ m{^$_} } @train_types ))
		{
			next;
		}
		if ( $backend eq 'iris' and $admode eq 'arr' and not $result->arrival )
		{
			next;
		}
		if (    $backend eq 'iris'
			and $admode eq 'dep'
			and not $result->departure )
		{
			next;
		}
		my ( $info, $moreinfo );
		if ( $backend eq 'iris' ) {
			my $delaymsg
			  = join( ', ', map { $_->[1] } $result->delay_messages );
			my $qosmsg = join( ' +++ ', map { $_->[1] } $result->qos_messages );
			if ( $result->is_cancelled ) {
				$info = "Fahrt fällt aus: ${delaymsg}";
			}
			elsif ( $result->delay and $result->delay > 0 ) {
				if ( $template eq 'clean' ) {
					$info = $delaymsg;
				}
				else {
					$info = sprintf( 'ca. +%d%s%s',
						$result->delay, $delaymsg ? q{: } : q{}, $delaymsg );
				}
			}
			if ( $result->replacement_for and $template ne 'clean' ) {
				for my $rep ( $result->replacement_for ) {
					$info = sprintf(
						'Ersatzzug für %s %s %s%s',
						$rep->type, $rep->train_no,
						$info ? '+++ ' : q{}, $info // q{}
					);
				}
			}
			if ( $info and $qosmsg ) {
				$info .= ' +++ ';
			}
			$info .= $qosmsg;

			if ( $result->additional_stops and not $result->is_cancelled ) {
				my $additional_line = join( q{, }, $result->additional_stops );
				$info
				  = 'Zusätzliche Halte: '
				  . $additional_line
				  . ( $info ? ' +++ ' : q{} )
				  . $info;
				if ( $template ne 'marudor' ) {
					push(
						@{$moreinfo},
						[ 'Zusätzliche Halte', $additional_line ]
					);
				}
			}

			if ( $result->canceled_stops and not $result->is_cancelled ) {
				my $cancel_line = join( q{, }, $result->canceled_stops );
				$info
				  = 'Ohne Halt in: '
				  . $cancel_line
				  . ( $info ? ' +++ ' : q{} )
				  . $info;
				if ( $template ne 'marudor' ) {
					push( @{$moreinfo}, [ 'Ohne Halt in', $cancel_line ] );
				}
			}

			push( @{$moreinfo}, $result->messages );
		}
		else {
			$info = $result->info;
			if ($info) {
				$moreinfo = [ [ 'HAFAS', $info ] ];
			}
			if ( $result->delay and $result->delay > 0 ) {
				if ($info) {
					$info = 'ca. +' . $result->delay . ': ' . $info;
				}
				else {
					$info = 'ca. +' . $result->delay;
				}
			}
			push( @{$moreinfo}, map { [ 'HAFAS', $_ ] } $result->messages );
		}

		my $time = $result->time;

		if ( $backend eq 'iris' ) {

			# ->time defaults to dep, so we only need to overwrite $time
			# if we want arrival times
			if ( $admode eq 'arr' ) {
				$time = $result->sched_arrival->strftime('%H:%M');
			}

			if ($show_realtime) {
				if ( ( $admode eq 'arr' and $result->arrival )
					or not $result->departure )
				{
					$time = $result->arrival->strftime('%H:%M');
				}
				else {
					$time = $result->departure->strftime('%H:%M');
				}
			}
		}

		if ($hide_low_delay) {
			if ($info) {
				$info =~ s{ (?: ca [.] \s* )? [+] [ 1 2 3 4 ] $ }{}x;
			}
			if ( $delay and $delay < 5 ) {
				$delay = undef;
			}
		}
		if ($info) {
			$info =~ s{ (?: ca [.] \s* )? [+] (\d+) }{Verspätung ca $1 Min.}x;
		}

		if ( $template eq 'marudor' ) {
			my @json_route = $self->json_route_diff( [ $result->route ],
				[ $result->sched_route ] );

			if ( $apiver == 1 ) {
				push(
					@departures,
					{
						delay       => $delay,
						destination => $result->destination,
						isCancelled => $result->can('is_cancelled')
						? $result->is_cancelled
						: undef,
						messages => {
							delay => [
								map {
									{
										timestamp => $_->[0],
										text      => $_->[1]
									}
								} $result->delay_messages
							],
							qos => [
								map {
									{
										timestamp => $_->[0],
										text      => $_->[1]
									}
								} $result->qos_messages
							],
						},
						platform          => $result->platform,
						route             => \@json_route,
						scheduledPlatform => $result->sched_platform,
						time              => $time,
						train             => $result->train,
						via               => [ $result->route_interesting(3) ],
					}
				);
			}
			elsif ( $apiver == 2 ) {
				my ( $delay_arr, $delay_dep, $sched_arr, $sched_dep );
				if ( $result->arrival ) {
					$delay_arr = $result->arrival->subtract_datetime(
						$result->sched_arrival )->in_units('minutes');
				}
				if ( $result->departure ) {
					$delay_dep = $result->departure->subtract_datetime(
						$result->sched_departure )->in_units('minutes');
				}
				if ( $result->sched_arrival ) {
					$sched_arr = $result->sched_arrival->strftime('%H:%M');
				}
				if ( $result->sched_departure ) {
					$sched_dep = $result->sched_departure->strftime('%H:%M');
				}
				push(
					@departures,
					{
						delayArrival   => $delay_arr,
						delayDeparture => $delay_dep,
						destination    => $result->destination,
						isCancelled    => $result->can('is_cancelled')
						? $result->is_cancelled
						: undef,
						messages => {
							delay => [
								map {
									{
										timestamp => $_->[0],
										text      => $_->[1]
									}
								} $result->delay_messages
							],
							qos => [
								map {
									{
										timestamp => $_->[0],
										text      => $_->[1]
									}
								} $result->qos_messages
							],
						},
						platform           => $result->platform,
						route              => \@json_route,
						scheduledPlatform  => $result->sched_platform,
						scheduledArrival   => $sched_arr,
						scheduledDeparture => $sched_dep,
						train              => $result->train,
						via                => [ $result->route_interesting(3) ],
					}
				);
			}
			else {    # apiver == 3
				my ( $delay_arr, $delay_dep, $sched_arr, $sched_dep );
				if ( $result->arrival ) {
					$delay_arr = $result->arrival->subtract_datetime(
						$result->sched_arrival )->in_units('minutes');
				}
				if ( $result->departure ) {
					$delay_dep = $result->departure->subtract_datetime(
						$result->sched_departure )->in_units('minutes');
				}
				if ( $result->sched_arrival ) {
					$sched_arr = $result->sched_arrival->strftime('%H:%M');
				}
				if ( $result->sched_departure ) {
					$sched_dep = $result->sched_departure->strftime('%H:%M');
				}
				push(
					@departures,
					{
						delayArrival   => $delay_arr,
						delayDeparture => $delay_dep,
						destination    => $result->destination,
						isCancelled    => $result->can('is_cancelled')
						? $result->is_cancelled
						: undef,
						messages => {
							delay => [
								map {
									{
										timestamp => $_->[0],
										text      => $_->[1]
									}
								} $result->delay_messages
							],
							qos => [
								map {
									{
										timestamp => $_->[0],
										text      => $_->[1]
									}
								} $result->qos_messages
							],
						},
						platform           => $result->platform,
						route              => \@json_route,
						scheduledPlatform  => $result->sched_platform,
						scheduledArrival   => $sched_arr,
						scheduledDeparture => $sched_dep,
						train              => $result->train,
						trainClasses       => [ $result->classes ],
						trainNumber        => $result->train_no,
						via                => [ $result->route_interesting(3) ],
					}
				);
			}
		}
		elsif ( $backend eq 'iris' ) {
			push(
				@departures,
				{
					time          => $time,
					sched_arrival => $result->sched_arrival
					? $result->sched_arrival->strftime('%H:%M')
					: undef,
					sched_departure => $result->sched_departure
					? $result->sched_departure->strftime('%H:%M')
					: undef,
					arrival => $result->arrival
					? $result->arrival->strftime('%H:%M')
					: undef,
					departure => $result->departure
					? $result->departure->strftime('%H:%M')
					: undef,
					train           => $result->train,
					train_type      => $result->type,
					train_line      => $result->line_no,
					train_no        => $result->train_no,
					via             => [ $result->route_interesting(3) ],
					scheduled_route => [ $result->sched_route ],
					route_post      => [ $result->route_post ],
					route_post_diff => [
						$self->json_route_diff(
							[ $result->route_post ],
							[ $result->sched_route_post ]
						)
					],
					destination        => $result->destination,
					origin             => $result->origin,
					platform           => $result->platform,
					scheduled_platform => $result->sched_platform,
					info               => $info,
					is_cancelled       => $result->is_cancelled,
					messages           => {
						delay => [
							map { { timestamp => $_->[0], text => $_->[1] } }
							  $result->delay_messages
						],
						qos => [
							map { { timestamp => $_->[0], text => $_->[1] } }
							  $result->qos_messages
						],
					},
					moreinfo         => $moreinfo,
					delay            => $delay,
					additional_stops => [ $result->additional_stops ],
					canceled_stops   => [ $result->canceled_stops ],
					replaced_by      => [
						map { $_->type . q{ } . $_->train_no }
						  $result->replaced_by
					],
					replacement_for => [
						map { $_->type . q{ } . $_->train_no }
						  $result->replacement_for
					],
				}
			);
		}
		else {
			push(
				@departures,
				{
					time             => $time,
					train            => $result->train,
					train_type       => $result->type,
					destination      => $result->destination,
					platform         => $platform,
					changed_platform => $result->is_changed_platform,
					info             => $info,
					is_cancelled     => $result->can('is_cancelled')
					? $result->is_cancelled
					: undef,
					messages => {
						delay => [],
						qos   => [],
					},
					moreinfo         => $moreinfo,
					delay            => $delay,
					additional_stops => [],
					canceled_stops   => [],
					replaced_by      => [],
					replacement_for  => [],
				}
			);
		}
	}

	if ( $template eq 'json' ) {
		$self->res->headers->access_control_allow_origin(q{*});
		my $json = $self->render_to_string(
			json => {
				api_version  => $api_version,
				preformatted => \@departures,
				version      => $VERSION,
				raw          => \@results,
			}
		);
		if ($callback) {
			$self->render(
				data   => "$callback($json);",
				format => 'json'
			);
		}
		else {
			$self->render(
				data   => $json,
				format => 'json'
			);
		}
	}
	elsif ( $template eq 'marudor' ) {
		$self->res->headers->access_control_allow_origin(q{*});
		my $json = $self->render_to_string(
			json => {
				departures => \@departures,
			}
		);
		if ($callback) {
			$self->render(
				data   => "$callback($json);",
				format => 'json'
			);
		}
		else {
			$self->render(
				data   => $json,
				format => 'json'
			);
		}
	}
	else {
		my $station_name = $data->{station_name} // $station;
		$self->render(
			$template,
			departures       => \@departures,
			version          => $VERSION,
			title            => "Abfahrtsmonitor $station_name",
			refresh_interval => 120,
			hide_opts        => $hide_opts,
			hide_low_delay   => $hide_low_delay,
			show_realtime    => $show_realtime,
		);
	}
	return;
}

get '/_redirect' => sub {
	my $self    = shift;
	my $station = $self->param('station');
	my $via     = $self->param('via');
	my $params  = $self->req->params;

	$params->remove('station');
	$params->remove('via');

	for my $param (qw(platforms backend mode admode)) {
		if (
			not $params->param($param)
			or ( exists $default{$param}
				and $params->param($param) eq $default{$param} )
		  )
		{
			$params->remove($param);
		}
	}

	$params = $params->to_string;

	if ($via) {
		$self->redirect_to("/${station}/${via}?${params}");
	}
	else {
		$self->redirect_to("/${station}?${params}");
	}
};

get '/_auto' => sub {
	my $self = shift;

	$self->render(
		'geolocation',
		with_geolocation => 1,
		hide_opts        => 1
	);
};

post '/_geolocation' => sub {
	my $self = shift;

	my $lon = $self->param('lon');
	my $lat = $self->param('lat');

	if ( not $lon or not $lat ) {
		$self->render( json => { error => 'Invalid lon/lat received' } );
	}
	else {
		my @candidates = map {
			{
				ds100    => $_->[0][0],
				name     => $_->[0][1],
				eva      => $_->[0][2],
				lon      => $_->[0][3],
				lat      => $_->[0][4],
				distance => $_->[1],
			}
		  } Travel::Status::DE::IRIS::Stations::get_station_by_location( $lon,
			$lat, 10 );
		$self->render(
			json => {
				candidates => [@candidates],
			}
		);
	}
};

app->defaults( layout => 'default' );

get '/'               => \&handle_request;
get '/#station'       => \&handle_request;
get '/#station/#via'  => \&handle_request;
get '/multi/#station' => \&handle_request;

app->config(
	hypnotoad => {
		accepts  => 10,
		listen   => [ $ENV{DBFAKEDISPLAY_LISTEN} // 'http://*:8092' ],
		pid_file => '/tmp/db-fakedisplay.pid',
		workers  => $ENV{DBFAKEDISPLAY_WORKERS} // 2,
	},
);

app->types->type( json => 'application/json; charset=utf-8' );
app->plugin('browser_detect');
app->start();
