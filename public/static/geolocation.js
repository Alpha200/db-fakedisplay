$(document).ready(function() {
	var removeStatus = function() {
		$('div.candidatestatus').remove();
	};
	var showError = function(header, message, code) {
		var errnode = $(document.createElement('div'));
		errnode.attr('class', 'error');
		errnode.text(message);

		var headnode = $(document.createElement('strong'));
		headnode.text(header);
		errnode.prepend(headnode);

		if (code) {
			var shortnode = $(document.createElement('div'));
			shortnode.attr('class', 'errcode');
			shortnode.text(code);
			errnode.append(shortnode);
		}

		$('div.candidatelist').append(errnode);
	};

	var processResult = function(data) {
		removeStatus();
		if (data.error) {
			showError('Backend-Fehler:', data.error, null);
		} else if (data.candidates.length == 0) {
			showError('Keine Bahnhöfe in 70km Umkreis gefunden', '', null);
		} else {
			$.each(data.candidates, function(i, candidate) {

				var ds100 = candidate.ds100,
					name = candidate.name,
					distance = candidate.distance;
				distance = distance.toFixed(1);

				var stationlink = $(document.createElement('a'));
				stationlink.attr('href', ds100);
				stationlink.text(name);

				var distancenode = $(document.createElement('div'));
				distancenode.attr('class', 'distance');
				distancenode.text(distance);

				stationlink.append(distancenode);
				$('div.candidatelist').append(stationlink);
			});
		}
	};

	var processLocation = function(loc) {
		$.post('/_geolocation', {lon: loc.coords.longitude, lat: loc.coords.latitude}, processResult);
		$('div.candidatestatus').text('Suche Bahnhöfe…');
	};

	var processError = function(error) {
		removeStatus();
		if (error.code == error.PERMISSION_DENIED) {
			showError('Standortanfrage nicht möglich.', 'Vermutlich fehlen die Rechte im Browser oder der Android Location Service ist deaktiviert.', 'geolocation.error.PERMISSION_DENIED');
		} else if (error.code == error.POSITION_UNAVAILABLE) {
			showError('Standort konnte nicht ermittelt werden', '(Service nicht verfügbar)', 'geolocation.error.POSITION_UNAVAILABLE');
		} else if (error.code == error.TIMEOUT) {
			showError('Standort konnte nicht ermittelt werden', '(Timeout)', 'geolocation.error.TIMEOUT');
		} else {
			showError('Standort konnte nicht ermittelt werden', '(unbekannter Fehler)', 'unknown geolocation.error code');
		}
	};

	if (navigator.geolocation) {
		navigator.geolocation.getCurrentPosition(processLocation, processError);
		$('div.candidatestatus').text('Position wird bestimmt…');
	} else {
		removeStatus();
		showError('Standortanfragen werden von diesem Browser nicht unterstützt', '', null);
	}
});
