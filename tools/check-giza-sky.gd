extends SceneTree
const Giza = preload("res://scripts/presentation/giza_sky.gd")

func _initialize() -> void:
	# JPL Horizons airless topocentric azimuth and elevation at 31.1342 E, 29.9792 N.
	var reference := {
		"2026-01-15T06:00:00": [Vector2(123.286620, 12.083592), Vector2(162.266289, 29.227132)],
		"2026-03-20T10:00:00": [Vector2(178.541148, 59.933078), Vector2(140.088629, 64.653315)],
		"2026-06-21T16:00:00": [Vector2(290.876534, 10.917992), Vector2(188.288944, 58.294126)],
		"2026-09-22T22:00:00": [Vector2(5.961190, -59.853401), Vector2(228.590327, 24.455162)],
		"2026-12-21T00:00:00": [Vector2(84.586075, -61.053602), Vector2(283.908509, 19.211312)],
		"2026-11-09T07:00:00": [Vector2(135.281481, 29.441769), Vector2(139.864516, 25.802003)],
		"2026-11-24T15:00:00": [Vector2(246.990410, -1.589401), Vector2(63.305675, 3.903992)],
		"2026-11-14T18:00:00": [Vector2(269.943251, -38.989788), Vector2(233.695395, 9.836490)],
	}
	for date in reference:
		var utc := Time.get_unix_time_from_datetime_string(date)
		var sun := Giza.sun(utc)
		var moon := Giza.moon(utc)
		var light := Giza.lunar_light(moon, sun)
		print(date, " UTC: errors Sun %.4f°, Moon %.4f°" % [
			sun.distance_to(reference[date][0]), moon.distance_to(reference[date][1])])
		if sun.distance_to(reference[date][0]) > 0.02 \
				or moon.distance_to(reference[date][1]) > 0.25 \
				or not is_equal_approx(light.length(), 1.0):
			printerr("Ephemeris comparison failed at ", date)
			quit(1)
			return
	# At upper culmination, stars south of the zenith are due south.
	# Check Sirius and both sides of its transit independently of the sky renderer.
	const SIRIUS := Vector2(101.2872, -16.7161)
	var day_fraction := fposmod(SIRIUS.x - Giza.LONGITUDE - 280.46061837, 360.0) / 360.98564736629
	var transit := Giza.J2000_UNIX + day_fraction * 86400.0
	var before := Giza.equatorial_to_horizontal(transit - 3600.0, SIRIUS.x, SIRIUS.y)
	var at := Giza.equatorial_to_horizontal(transit, SIRIUS.x, SIRIUS.y)
	var after := Giza.equatorial_to_horizontal(transit + 3600.0, SIRIUS.x, SIRIUS.y)
	var expected_altitude := 90.0 - absf(Giza.LATITUDE - SIRIUS.y)
	if at.distance_to(Vector2(180.0, expected_altitude)) > 0.001 \
			or not (Giza.project(before).x < 0.5 and Giza.project(after).x > 0.5) \
			or absf(before.y - after.y) > 0.001:
		printerr("Sirius transit or east-to-west projection failed")
		quit(1)
		return
	print("Sirius transit: ", at, "; before: ", before, "; after: ", after)
	quit()

