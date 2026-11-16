extends RefCounted
## Approximate horizontal coordinates. The default observer is in Giza.

const LATITUDE := 29.9792
const LONGITUDE := 31.1342
const GIZA := Vector2(LATITUDE, LONGITUDE)
const TOMSK := Vector2(56.4977, 84.9744)
const J2000_UNIX := 946728000.0
const CENTER_AZIMUTH := 180.0
const AZIMUTH_SPAN := 360.0
const ALTITUDE_SPAN := 90.0


static func project(horizontal: Vector2) -> Vector2:
	var azimuth := wrapf(horizontal.x - CENTER_AZIMUTH, -180.0, 180.0)
	return Vector2(0.5 + azimuth / AZIMUTH_SPAN, 1.0 - horizontal.y / ALTITUDE_SPAN)


static func equatorial_to_horizontal(unix_utc: float, ra_degrees: float,
		declination_degrees: float, observer: Vector2 = GIZA) -> Vector2:
	var days := (unix_utc - J2000_UNIX) / 86400.0
	var sidereal := 280.46061837 + 360.98564736629 * days + observer.y
	var hour := deg_to_rad(wrapf(sidereal - ra_degrees, -180.0, 180.0))
	var latitude := deg_to_rad(observer.x)
	var declination := deg_to_rad(declination_degrees)
	var east := -cos(declination) * sin(hour)
	var north := sin(declination) * cos(latitude) - cos(declination) * cos(hour) * sin(latitude)
	var up := sin(declination) * sin(latitude) + cos(declination) * cos(hour) * cos(latitude)
	return Vector2(fposmod(rad_to_deg(atan2(east, north)), 360.0),
		rad_to_deg(atan2(up, Vector2(east, north).length())))


static func sun(unix_utc: float, observer: Vector2 = GIZA) -> Vector2:
	var days := (unix_utc - J2000_UNIX) / 86400.0
	var anomaly := deg_to_rad(fposmod(357.529 + 0.98560028 * days, 360.0))
	var longitude := deg_to_rad(fposmod(280.459 + 0.98564736 * days
		+ 1.915 * sin(anomaly) + 0.020 * sin(2.0 * anomaly), 360.0))
	var tilt := deg_to_rad(23.439 - 0.00000036 * days)
	var ra := atan2(cos(tilt) * sin(longitude), cos(longitude))
	var declination := asin(sin(tilt) * sin(longitude))
	return equatorial_to_horizontal(unix_utc, rad_to_deg(ra), rad_to_deg(declination), observer)


# Low-precision lunar elements and dominant perturbations from Paul Schlyter.
# https://stjarnhimlen.se/comp/tutorial.html?level=1
static func moon(unix_utc: float, observer: Vector2 = GIZA) -> Vector2:
	var days := (unix_utc - J2000_UNIX) / 86400.0 + 1.5
	var node := deg_to_rad(fposmod(125.1228 - 0.0529538083 * days, 360.0))
	var perigee := deg_to_rad(fposmod(318.0634 + 0.1643573223 * days, 360.0))
	var anomaly := deg_to_rad(fposmod(115.3654 + 13.0649929509 * days, 360.0))
	var inclination := deg_to_rad(5.1454)
	const ECCENTRICITY := 0.0549
	var eccentric := anomaly + ECCENTRICITY * sin(anomaly)
	for iteration in range(3):
		eccentric -= (eccentric - ECCENTRICITY * sin(eccentric) - anomaly) \
			/ (1.0 - ECCENTRICITY * cos(eccentric))
	var distance := 60.2666 * (1.0 - ECCENTRICITY * cos(eccentric))
	var orbital_angle := perigee + atan2(sqrt(1.0 - ECCENTRICITY ** 2) * sin(eccentric),
		cos(eccentric) - ECCENTRICITY)
	var latitude := asin(sin(inclination) * sin(orbital_angle))
	var longitude := node + atan2(cos(inclination) * sin(orbital_angle), cos(orbital_angle))
	var solar_anomaly := deg_to_rad(fposmod(356.0470 + 0.9856002585 * days, 360.0))
	var solar_mean := solar_anomaly + deg_to_rad(282.9404 + 0.0000470935 * days)
	var mean_longitude := node + perigee + anomaly
	var elongation := mean_longitude - solar_mean
	var latitude_argument := mean_longitude - node
	longitude += deg_to_rad(-1.274 * sin(anomaly - 2.0 * elongation)
		+ 0.658 * sin(2.0 * elongation) - 0.186 * sin(solar_anomaly)
		- 0.059 * sin(2.0 * anomaly - 2.0 * elongation))
	latitude += deg_to_rad(-0.173 * sin(latitude_argument - 2.0 * elongation)
		- 0.055 * sin(anomaly - latitude_argument - 2.0 * elongation))
	var ecliptic := Vector3(cos(latitude) * cos(longitude),
		cos(latitude) * sin(longitude), sin(latitude))
	var equatorial := ecliptic.rotated(Vector3.RIGHT, deg_to_rad(23.4393 - 0.0000003563 * days))
	var horizontal := equatorial_to_horizontal(unix_utc,
		rad_to_deg(atan2(equatorial.y, equatorial.x)), rad_to_deg(asin(equatorial.z)), observer)
	var altitude := deg_to_rad(horizontal.y)
	horizontal.y = rad_to_deg(atan2(distance * sin(altitude) - 1.0, distance * cos(altitude)))
	return horizontal


static func lunar_light(lunar: Vector2, solar: Vector2) -> Vector3:
	var delta_azimuth := deg_to_rad(solar.x - lunar.x)
	var sun_altitude := deg_to_rad(solar.y)
	var moon_altitude := deg_to_rad(lunar.y)
	return Vector3(
		sin(delta_azimuth) * cos(sun_altitude),
		-(sin(sun_altitude) * cos(moon_altitude)
			- cos(sun_altitude) * sin(moon_altitude) * cos(delta_azimuth)),
		-(sin(sun_altitude) * sin(moon_altitude)
			+ cos(sun_altitude) * cos(moon_altitude) * cos(delta_azimuth)))


static func palette(solar: Vector2) -> Vector4:
	var twilight := smoothstep(-12.0, 0.0, solar.y)
	var day := smoothstep(0.0, 12.0, solar.y)
	# The eastward component changes sign at transit. A blend keeps low
	# winter noons and bright summer midnights continuous.
	var east := sin(deg_to_rad(solar.x)) * cos(deg_to_rad(solar.y))
	var morning := smoothstep(-0.25, 0.25, east)
	var twilight_weight := twilight - day
	return Vector4(1.0 - twilight, twilight_weight * morning, day,
		twilight_weight * (1.0 - morning))
