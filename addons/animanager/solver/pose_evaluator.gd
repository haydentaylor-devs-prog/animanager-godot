@tool
class_name AniPoseEvaluator
extends RefCounted

# Pure-function pose math: keyframe interpolation, easing curves,
# shortest-arc angle lerp, two-bone analytic IK. Owns no state — the
# caller (AniAnimationPlayer2D) keeps the indices and feeds them in.
#
# Mirrors the formulas in the .rig spec doc, §9 (easing) and §7.2 (IK).

# Bezier solver tolerance — matches the spec's reference loop bound.
const _BEZIER_ITERS := 8
const _BEZIER_EPS := 0.001


# ── Easing curves (spec §9) ────────────────────────────────────────

static func ease(t: float, interp_type: String, kf: Dictionary) -> float:
	match interp_type:
		"linear":
			return t
		"easeIn":
			return t * t * t
		"easeOut":
			var inv := 1.0 - t
			return 1.0 - (inv * inv * inv)
		"easeInOut":
			return t * t * (3.0 - 2.0 * t)
		"stepped":
			# Caller should have detected stepped and held the
			# "before" value without calling ease() — but if it
			# didn't, return 0 (snap to "before") rather than
			# crashing.
			return 0.0
		"custom":
			return _cubic_bezier(
				t,
				kf.get("bezier_cp1_x", 0.25) if kf.get("bezier_cp1_x") != null else 0.25,
				kf.get("bezier_cp1_y", 0.1) if kf.get("bezier_cp1_y") != null else 0.1,
				kf.get("bezier_cp2_x", 0.75) if kf.get("bezier_cp2_x") != null else 0.75,
				kf.get("bezier_cp2_y", 0.9) if kf.get("bezier_cp2_y") != null else 0.9
			)
		_:
			return t


static func _cubic_bezier(t: float, cp1x: float, cp1y: float, cp2x: float, cp2y: float) -> float:
	# Newton-Raphson on x to find the parametric u, then return y(u).
	var u := t
	for i in _BEZIER_ITERS:
		var cx := _bezier_axis(u, cp1x, cp2x) - t
		if absf(cx) < _BEZIER_EPS:
			break
		var dcx := _bezier_axis_deriv(u, cp1x, cp2x)
		if absf(dcx) < 1e-6:
			break
		u -= cx / dcx
	return _bezier_axis(u, cp1y, cp2y)


static func _bezier_axis(t: float, p1: float, p2: float) -> float:
	# Cubic bezier with P0=(0), P3=(1) on one axis.
	var omt := 1.0 - t
	return 3.0 * omt * omt * t * p1 + 3.0 * omt * t * t * p2 + t * t * t


static func _bezier_axis_deriv(t: float, p1: float, p2: float) -> float:
	var omt := 1.0 - t
	return 3.0 * omt * omt * p1 + 6.0 * omt * t * (p2 - p1) + 3.0 * t * t * (1.0 - p2)


# ── Angle interpolation (shortest arc, spec §10.2) ─────────────────

static func lerp_angle(a: float, b: float, t: float) -> float:
	var diff := fposmod(b - a, TAU)
	if diff > PI:
		diff -= TAU
	elif diff < -PI:
		diff += TAU
	return a + diff * t


# ── Per-bone keyframe interpolation ────────────────────────────────
#
# `frames` is the bone's keyframe list (sorted ascending by
# frame_number). Returns a Dictionary with the interpolated transform
# at `frame` (which is a float — sub-frame queries are fine).
#
# Empty list → returns rest defaults. Single keyframe → returns it.
# Otherwise: find the two surrounding keyframes, apply easing, lerp.

static func interpolate(frames: Array, frame: float) -> Dictionary:
	var rest := {
		"rotation": 0.0,
		"translate_x": 0.0,
		"translate_y": 0.0,
		"scale_x": 1.0,
		"scale_y": 1.0,
		"ik_target_x": NAN,
		"ik_target_y": NAN,
	}
	if frames.is_empty():
		return rest

	# Find before / after via linear scan (animations rarely have
	# more than ~50 keyframes per bone; binary search not worth it).
	var before: Dictionary = {}
	var after: Dictionary = {}
	for kf in frames:
		var f: int = kf.frame_number
		if f <= frame:
			before = kf
		if f >= frame and after.is_empty():
			after = kf

	if before.is_empty():
		return _kf_to_dict(after)
	if after.is_empty() or before.frame_number == after.frame_number:
		return _kf_to_dict(before)

	# Stepped: hold the "before" value until the next keyframe.
	if before.interpolation_type == "stepped":
		return _kf_to_dict(before)

	var span: float = float(after.frame_number - before.frame_number)
	var t_linear: float = (frame - before.frame_number) / span
	var t_eased := ease(t_linear, before.interpolation_type, before)

	return {
		"rotation": lerp_angle(before.rotation, after.rotation, t_eased),
		"translate_x": lerp(before.translate_x, after.translate_x, t_eased),
		"translate_y": lerp(before.translate_y, after.translate_y, t_eased),
		"scale_x": lerp(before.scale_x, after.scale_x, t_eased),
		"scale_y": lerp(before.scale_y, after.scale_y, t_eased),
		"ik_target_x": _lerp_optional(before.ik_target_x, after.ik_target_x, t_eased),
		"ik_target_y": _lerp_optional(before.ik_target_y, after.ik_target_y, t_eased),
	}


static func _kf_to_dict(kf: Dictionary) -> Dictionary:
	return {
		"rotation": kf.rotation,
		"translate_x": kf.translate_x,
		"translate_y": kf.translate_y,
		"scale_x": kf.scale_x,
		"scale_y": kf.scale_y,
		"ik_target_x": kf.ik_target_x,
		"ik_target_y": kf.ik_target_y,
	}


static func _lerp_optional(a: float, b: float, t: float) -> float:
	# Both NaN → NaN (no IK target on either neighbour).
	if is_nan(a) and is_nan(b):
		return NAN
	if is_nan(a):
		return b
	if is_nan(b):
		return a
	return lerp(a, b, t)


# ── Two-bone analytic IK (spec §7.2) ───────────────────────────────
#
# Given the shoulder world position and the rest lengths of the two
# bones, plus the desired target and pole side, return the world
# rotations to apply to (parent_bone, leaf_bone).

static func solve_two_bone_ik(
	shoulder: Vector2,
	l1: float,
	l2: float,
	target: Vector2,
	pole_side: int
) -> Vector2:
	var to_target := target - shoulder
	var d := to_target.length()

	# Clamp the reach so the law-of-cosines stays in [-1, 1].
	var d_max := l1 + l2 - 0.0001
	var d_min := absf(l1 - l2) + 0.0001
	d = clampf(d, d_min, d_max)

	# Law of cosines on the shoulder triangle.
	var cos_a: float = (l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d)
	var cos_b: float = (l1 * l1 + l2 * l2 - d * d) / (2.0 * l1 * l2)
	var a := acos(clampf(cos_a, -1.0, 1.0))
	var b := acos(clampf(cos_b, -1.0, 1.0))

	var base_angle := atan2(to_target.y, to_target.x)
	var parent_rot := base_angle - a * sign(pole_side)
	var leaf_rot := parent_rot + (PI - b) * sign(pole_side)

	return Vector2(parent_rot, leaf_rot)


static func sign(x: int) -> int:
	if x > 0:
		return 1
	if x < 0:
		return -1
	return 1  # Default: bend "left" when poleSide is 0 / unspecified.
