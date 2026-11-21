extends Node2D
## Animate the limbs of the side-view worker around a planted foot.

const ART := preload("res://assets/sprites/worker-walk.png")
const HEIGHT_FACTOR := 0.75
const HUMAN_SCALE := 1.25 * HEIGHT_FACTOR
const STEP_LENGTH := 42.0
const CLIMB_STEP_LENGTH := 20.0
const LANDING_REACH := 0.30
const TOE_OFF := 1.14
const TOE_ROLL_START := 0.78
const TOE_ROLL := 0.48
const HIP := Vector2(38, 70)
const KNEE := Vector2(39, 84)
const ANKLE := Vector2(41, 95)
const SOLE := Vector2(42, 99)
const TOE := Vector2(55, 99)
const SHOULDER := Vector2(20, 35)
const ARM_ELBOW := Vector2(12, 48)
const FIST := Vector2(10, 60)
const CRANK_SHOULDER := Vector2(39, 34)

# Source contours overlap at the joints to cover the seams as the knee bends.
const TORSO := [
	Vector2(0, 0), Vector2(57, 0), Vector2(57, 40), Vector2(42, 40),
	Vector2(39, 48), Vector2(38, 52), Vector2(42, 59), Vector2(45, 68),
	Vector2(43, 71), Vector2(36, 74), Vector2(30, 77), Vector2(24, 78),
	Vector2(19, 77), Vector2(14, 75), Vector2(7, 74), Vector2(17, 65),
	Vector2(17, 54), Vector2(20, 43), Vector2(24, 39), Vector2(25, 34),
	Vector2(23, 30), Vector2(17, 30), Vector2(0, 28),
]
const ARM := [
	Vector2(16, 28), Vector2(23, 27), Vector2(27, 32), Vector2(27, 38),
	Vector2(22, 43), Vector2(18, 45), Vector2(16, 50), Vector2(14, 55),
	Vector2(16, 60), Vector2(14, 64), Vector2(9, 65), Vector2(5, 62),
	Vector2(5, 57), Vector2(7, 54), Vector2(7, 48), Vector2(10, 42),
	Vector2(13, 37), Vector2(14, 32),
]
const LEG := [
	Vector2(32, 70), Vector2(44, 70), Vector2(33, 84), Vector2(45, 84),
	Vector2(37, 95), Vector2(46, 95),
]
const FOOT := [
	Vector2(37, 91), Vector2(43, 88), Vector2(46, 91), Vector2(57, 91),
	Vector2(57, 100), Vector2(35, 100),
]

var planted_stance := false
var cover_idle_shoulder := false
var hand_position := Vector2.ZERO
var _rear: Array[Polygon2D]
var _near: Array[Polygon2D]
var _torso: Polygon2D
var _shoulder_cover: Polygon2D
var _far_arm: Polygon2D
var _near_arm: Polygon2D
var _crank_arm: Line2D
var _crank_hand: Line2D


func _ready() -> void:
	_rear = _make_leg(Color(0.73, 0.68, 0.70))
	_near = _make_leg(Color.WHITE)
	_far_arm = _part(ARM, Color(0.75, 0.67, 0.67))
	if cover_idle_shoulder:
		# Back the arm cutout with cloth sampled from inside the tunic.
		var contour := PackedVector2Array([
			Vector2(17, 30), Vector2(24, 28), Vector2(30, 35), Vector2(29, 46),
			Vector2(20, 49), Vector2(17, 45), Vector2(16, 39), Vector2(16, 33),
		])
		_shoulder_cover = _part(contour, Color(0.8, 0.8, 0.8))
		var cloth_uv := PackedVector2Array()
		for point in contour:
			cloth_uv.append(Vector2(32, 42) + (point - Vector2(21, 40)) * 0.3)
		_shoulder_cover.uv = cloth_uv
		_shoulder_cover.hide()
	_torso = _part(TORSO, Color.WHITE)
	_near_arm = _part(ARM, Color.WHITE)
	_crank_arm = _arm_line(Color("#b56d38"), 8.0)
	_crank_hand = _arm_line(Color("#e6a45c"), 7.0)


static func step_length(travel: Vector2) -> float:
	return CLIMB_STEP_LENGTH if is_zero_approx(travel.x) else STEP_LENGTH


func pose(steps: float, travel: Vector2, facing: float, pulling: bool = false,
		stride_weight: float = 1.0) -> void:
	var moving := travel != Vector2.ZERO
	var along := Vector2(absf(travel.x), travel.y)
	var climbing := is_zero_approx(along.x)
	var length := step_length(travel)
	var cycle := fposmod(steps, 2.0)
	var phase := fposmod(cycle, 1.0)
	var bob := -4.0 * sin(phase * PI) if moving else -2.0
	var forward := 0.0
	# Lower the torso on ramps to keep the downhill leg within reach.
	if moving and not climbing:
		bob += 7.0 * absf(along.y)
		forward = 3.0 + 1.5 * sin(phase * TAU)
	var hip := Vector2(forward, -28 + bob)
	var lean := 0.09 if pulling else 0.0
	if moving:
		lean += 0.04 * cos(cycle * PI)
	var torso := _pose_body(hip, lean, facing)
	_pose_arms(torso, cycle, moving, climbing, pulling)

	for index in range(2):
		var leg := _rear if index == 0 else _near
		var side := -1.0 if index == 0 else 1.0
		var sole := Vector2(side * (2.0 if moving else 5.0), -1.5 if index == 0 else 0.0)
		var pitch := 0.0
		if moving:
			var leg_phase := fposmod(cycle + index, 2.0)
			var landing := 0.5 if climbing else LANDING_REACH
			var release := 1.0 if climbing else TOE_OFF
			var reach := landing - leg_phase
			if leg_phase >= release:
				var swing := inverse_lerp(release, 2.0, leg_phase)
				# Advance to the next contact in world space while the body moves on.
				reach += 2.0 * smoothstep(0.0, 1.0, swing)
				sole.y -= sin(swing * PI) * (4.0 if climbing else 11.0)
				pitch = sin(swing * TAU) * 0.32 if climbing else TOE_ROLL * (1.0 - smoothstep(0.0, 0.70, swing))
			elif not climbing:
				# Keep the trailing toe down until the other foot takes weight.
				pitch = TOE_ROLL * smoothstep(TOE_ROLL_START, TOE_OFF, leg_phase)
			sole += along * length * reach
			if not climbing:
				# Raising the heel rotates around the planted toe.
				var toe_from_sole := TOE - SOLE
				sole += toe_from_sole - toe_from_sole.rotated(pitch)
		var leg_hip := torso * (HIP + Vector2(-6.0 + side * 1.5, -3.0))
		if planted_stance:
			var weight := stride_weight if moving else 0.0
			leg_hip = _standing_hip(torso, side).lerp(leg_hip, weight)
			sole = _standing_sole(side).lerp(sole, weight)
			pitch *= weight
		_pose_leg(leg, leg_hip, sole, pitch)


func pose_idle(seconds: float, facing: float, point_amount := 0.0, point_angle := 0.0) -> void:
	var breath := sin(seconds * TAU / 3.3)
	var shift := sin(seconds * TAU / 5.6)
	var hip := Vector2(1.4 * shift, -29.0 + 0.7 * breath)
	var torso := _pose_body(hip, 0.025 * shift, facing)
	if _shoulder_cover != null:
		_shoulder_cover.transform = torso
		_shoulder_cover.show()
	_far_arm.show()
	var arm_angle := lerpf(-0.28 + 0.07 * shift, -1.88 + point_angle, point_amount)
	var shoulder := SHOULDER.lerp(Vector2(37, 35), point_amount)
	var grip := _pose_arm(_near_arm, torso, shoulder, arm_angle, 0.12)
	_pose_arm(_far_arm, torso, Vector2(34, 34), -0.27 - 0.07 * shift, 0.12)
	hand_position = grip * scale
	if planted_stance:
		_pose_leg(_rear, _standing_hip(torso, -1.0), _standing_sole(-1.0), 0.0)
		_pose_leg(_near, _standing_hip(torso, 1.0), _standing_sole(1.0), 0.0)
		return
	# Keep both ankles under their hips instead of leaving one foot out in front.
	_pose_leg(_rear, torso * (HIP + Vector2(-7.5, -3.0)), Vector2(-6.5, -1.5), 0.0)
	_pose_leg(_near, torso * (HIP + Vector2(-4.5, -3.0)), Vector2(-3.5, 0.0), 0.0)


func _standing_hip(torso: Transform2D, side: float) -> Vector2:
	var hip := torso * (HIP + Vector2(-5.0 + side * 3.0, -3.0))
	# Keep the legs extended as the torso breathes above them.
	hip.y = -32.7
	return hip


func _standing_sole(side: float) -> Vector2:
	# The foot contour extends one pixel below its rotation pivot.
	return Vector2(-4.0 + side * 3.0, -1.0)


func _pose_body(hip: Vector2, lean: float, facing: float) -> Transform2D:
	if _shoulder_cover != null:
		_shoulder_cover.hide()
	_crank_arm.hide()
	_crank_hand.hide()
	_near_arm.z_index = 0
	var torso := Transform2D(lean, hip)
	torso.origin = torso * -HIP
	_torso.transform = torso
	scale.x = facing * absf(scale.y)
	return torso


func grip_crank(handle: Vector2, textured := false) -> void:
	pose(0.5, Vector2.ZERO, 1.0)
	if textured:
		# Solve in torso coordinates, after pose() sets the stance and facing.
		var target := _torso.transform.affine_inverse() * to_local(handle) - CRANK_SHOULDER
		var upper := ARM_ELBOW - SHOULDER
		var lower := FIST - ARM_ELBOW
		var a := upper.length()
		var b := lower.length()
		var cosine := (target.length_squared() - a * a - b * b) / (2.0 * a * b)
		var delta := -acos(clampf(cosine, -1.0, 1.0))
		var angle := target.angle() - atan2(b * sin(delta), a + b * cos(delta)) - upper.angle()
		var bend := lower.angle() - upper.angle() - delta
		var fist := _pose_arm(_near_arm, _torso.transform, CRANK_SHOULDER, angle, bend)
		hand_position = fist * scale
		_near_arm.z_index = 1
		return
	_far_arm.hide()
	var grip := to_local(handle)
	var shoulder := _torso.transform * Vector2(39, 34)
	var elbow := shoulder.lerp(grip, 0.48) + Vector2(-5, 11)
	_crank_arm.points = PackedVector2Array([shoulder, elbow, grip])
	_crank_hand.points = PackedVector2Array([grip + Vector2(0, -1), grip + Vector2(0, 2)])
	_crank_arm.show()
	_crank_hand.show()


func _pose_arms(torso: Transform2D, cycle: float, moving: bool, climbing: bool, pulling: bool) -> void:
	_far_arm.show()
	# The far arm goes forward when the near leg lands.
	var swing := cos(cycle * PI) if moving else 0.0
	var amplitude := 0.30 if climbing else 0.50
	var near_angle := -0.45 - amplitude * swing
	var far_angle := -0.52 + amplitude * swing
	if pulling:
		near_angle = 0.20
		far_angle = -0.60 + 0.18 * swing
	var elbow_bend := 0.32 if climbing and moving else 0.16
	var near_bend := 0.09 if pulling else elbow_bend
	var grip := _pose_arm(_near_arm, torso, SHOULDER, near_angle, near_bend)
	_pose_arm(_far_arm, torso, Vector2(34, 34), far_angle, elbow_bend)
	hand_position = grip * Vector2(scale.x, scale.y)


func _pose_arm(arm: Polygon2D, torso: Transform2D, shoulder: Vector2, angle: float, bend: float) -> Vector2:
	var upper := Transform2D(angle, shoulder)
	upper.origin = upper * -SHOULDER
	var forearm := Transform2D(-bend, ARM_ELBOW)
	forearm.origin = forearm * -ARM_ELBOW
	var points := PackedVector2Array()
	for point: Vector2 in ARM:
		var lower_weight := smoothstep(ARM_ELBOW.y - 4, ARM_ELBOW.y + 5, point.y)
		points.append(point.lerp(forearm * point, lower_weight))
	arm.polygon = points
	arm.transform = torso * upper
	return arm.transform * (forearm * FIST)


func _arm_line(color: Color, width: float) -> Line2D:
	var line := Line2D.new()
	line.width = width
	line.default_color = color
	line.antialiased = true
	line.joint_mode = Line2D.LINE_JOINT_ROUND
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode = Line2D.LINE_CAP_ROUND
	add_child(line)
	line.hide()
	return line


func _make_leg(tint: Color) -> Array[Polygon2D]:
	var leg := _part(LEG, tint)
	leg.polygons = [
		PackedInt32Array([0, 1, 2]), PackedInt32Array([2, 1, 3]),
		PackedInt32Array([2, 3, 4]), PackedInt32Array([4, 3, 5]),
	]
	return [leg, _part(FOOT, tint)]


func _part(points: PackedVector2Array, tint: Color) -> Polygon2D:
	var part := Polygon2D.new()
	part.use_parent_material = true
	part.texture = ART
	part.polygon = points
	part.uv = points
	part.color = tint
	add_child(part)
	return part


func _pose_leg(leg: Array[Polygon2D], hip: Vector2, sole: Vector2, pitch: float) -> void:
	var foot := Transform2D(pitch, sole)
	var ankle := foot * (ANKLE - SOLE)
	var thigh_length := 14.0
	var shin_length := 14.0
	var span := ankle - hip
	var axis := span.normalized() if span.length_squared() > 0.01 else Vector2.DOWN
	var distance := clampf(span.length(), 5.0, thigh_length + shin_length)
	var mid := (distance * distance + thigh_length ** 2 - shin_length ** 2) / (2.0 * distance)
	var bend := sqrt(maxf(0.0, thigh_length ** 2 - mid * mid))
	var knee := hip + axis * mid + Vector2(axis.y, -axis.x) * bend
	var knee_cross := axis.rotated(-PI * 0.5)
	var ankle_cross := Vector2.RIGHT.rotated(pitch)
	# Both halves use the same pair of vertices at the knee.
	leg[0].polygon = PackedVector2Array([
		hip + Vector2(LEG[0].x - HIP.x, 0), hip + Vector2(LEG[1].x - HIP.x, 0),
		knee + knee_cross * (LEG[2].x - KNEE.x), knee + knee_cross * (LEG[3].x - KNEE.x),
		ankle + ankle_cross * (LEG[4].x - ANKLE.x), ankle + ankle_cross * (LEG[5].x - ANKLE.x),
	])
	foot.origin = foot * -SOLE
	leg[1].transform = foot
