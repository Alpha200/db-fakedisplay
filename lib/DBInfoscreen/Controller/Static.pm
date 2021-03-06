package DBInfoscreen::Controller::Static;
use Mojo::Base 'Mojolicious::Controller';

# Copyright (C) 2011-2019 Daniel Friesel <derf+dbf@finalrewind.org>
# License: 2-Clause BSD

my %default = (
	backend => 'iris',
	mode    => 'app',
	admode  => 'deparr',
);

sub redirect {
	my ($self)  = @_;
	my $station = $self->param('station');
	my $params  = $self->req->params;

	$params->remove('station');

	for my $param (qw(platforms backend mode admode via)) {
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

	$self->redirect_to("/${station}?${params}");
}

sub geolocation {
	my ($self) = @_;

	$self->render(
		'geolocation',
		with_geolocation => 1,
		hide_opts        => 1
	);
}

sub privacy {
	my ($self) = @_;

	$self->render( 'privacy', hide_opts => 1 );
}

sub imprint {
	my ($self) = @_;

	$self->render( 'imprint', hide_opts => 1 );
}

1;
