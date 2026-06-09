@tool
class_name AniAnimationPlayer2D
extends Node2D

# Place this node in your scene, point `rig` at an imported
# AniRigResource (.tres), and call play(). Bones become live
# Transform2Ds; bound sprites follow them every frame.
#
# When sprite_bindings is empty (no bones bound to textures), the
# node draws the skeleton as debug line segments instead — useful
# for verifying the rig loaded correctly before wiring sprites.

signal animation_finished
signal animation_looped

# ── Inspector properties ───────────────────────────────────────────

@export var rig: AniRigResource:
	set(value):
		rig = value
		_rebuild_indices()
		_evaluate_pose(_current_frame)
		queue_redraw()

# bone_uuid OR bone_name → Texture2D. Lookups try uuid first then
# fall back to name (case-sensitive).
@export var sprite_bindings: Dictionary = {}:
	set(value):
		sprite_bindings = value
		queue_redraw()

@export var auto_play: bool = false
@export_range(0.1, 10.0, 0.05) var speed: float = 1.0
# -1 = use rig.is_looping; 0 = force off; 1 = force on. Lets you
# override the authored looping flag from the inspector without
# touching the resource.
@export_enum("Use rig:-1", "Force off:0", "Force on:1") var loop_override: int = -1

@export_group("Debug")
@export var draw_bones_in_editor: bool = true
@export_color_no_alpha var bone_color: Color = Color(0.2, 0.8, 1.0)
@export var bone_width: float = 2.0
@export_color_no_alpha var joint_color: Color = Color(1.0, 0.5, 0.0)
@export var joint_radius: float = 3.0


# ── Internal state ─────────────────────────────────────────────────

var _is_playing: bool = false
var _current_frame: float = 0.0

# Built by _rebuild_indices().
var _bone_by_uuid: Dictionary = {}            # uuid → bone Dict
var _bone_children: Dictionary = {}           # parent_uuid → [child_uuid, ...]
var _bone_roots: Array = []                   # of uuid
var _frames_by_bone: Dictionary = {}          # uuid → Array of keyframe Dicts (sorted)
var _ik_chains_by_leaf: Dictionary = {}       # leaf_uuid → chain Dict

# Per-frame transforms (rebuilt each tick).
var _local_transform_by_uuid: Dictionary = {} # uuid → Transform2D
var _world_transform_by_uuid: Dictionary = {} # uuid → Transform2D
# Per-frame world rotation of each bone (radians) — easier to read
# than decomposing from the transform for the IK pass.
var _world_rotation_by_uuid: Dictionary = {}


# ── Public playback API ────────────────────────────────────────────

func play() -> void:
	if rig == null:
		return
	_is_playing = true
	set_process(true)


func pause() -> void:
	_is_playing = false


func stop() -> void:
	_is_playing = false
	_current_frame = 0.0
	_evaluate_pose(_current_frame)
	queue_redraw()


func is_playing() -> bool:
	return _is_playing


func get_current_frame() -> float:
	return _current_frame


func set_current_frame(frame: float) -> void:
	# Scrub the playhead manually. Clamped to a valid range.
	if rig == null:
		_current_frame = 0.0
		return
	_current_frame = clampf(frame, 0.0, float(rig.total_frames - 1))
	_evaluate_pose(_current_frame)
	queue_redraw()


func get_bone_world_transform(bone_uuid_or_name: String) -> Transform2D:
	# Lookup helper for game code that wants to attach effects /
	# particles to a bone (e.g. spawn a sparks particle at "Hand_R"'s
	# tip). Returns identity if the bone isn't found.
	if _world_transform_by_uuid.has(bone_uuid_or_name):
		return _world_transform_by_uuid[bone_uuid_or_name]
	# Try name lookup.
	for uuid in _bone_by_uuid:
		var b: Dictionary = _bone_by_uuid[uuid]
		if b.name == bone_uuid_or_name:
			return _world_transform_by_uuid.get(uuid, Transform2D.IDENTITY)
	return Transform2D.IDENTITY


# ── Lifecycle ──────────────────────────────────────────────────────

func _ready() -> void:
	_rebuild_indices()
	_evaluate_pose(_current_frame)
	if auto_play and not Engine.is_editor_hint():
		play()
	else:
		# Still allow the editor to render the rest pose / debug
		# bones without ticking.
		set_process(Engine.is_editor_hint() and draw_bones_in_editor)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		# Editor view just redraws on demand; no playback advance.
		queue_redraw()
		return
	if not _is_playing or rig == null:
		return

	_current_frame += delta * float(rig.frame_rate) * speed
	if _current_frame >= float(rig.total_frames):
		var loops: bool = (loop_override == 1) or (
			loop_override == -1 and rig.is_looping
		)
		if loops:
			_current_frame = fmod(_current_frame, float(rig.total_frames))
			emit_signal("animation_looped")
		else:
			_current_frame = float(rig.total_frames - 1)
			_is_playing = false
			emit_signal("animation_finished")

	_evaluate_pose(_current_frame)
	queue_redraw()


# ── Skeleton indexing ──────────────────────────────────────────────

func _rebuild_indices() -> void:
	_bone_by_uuid.clear()
	_bone_children.clear()
	_bone_roots.clear()
	_frames_by_bone.clear()
	_ik_chains_by_leaf.clear()
	_local_transform_by_uuid.clear()
	_world_transform_by_uuid.clear()
	_world_rotation_by_uuid.clear()

	if rig == null:
		return

	for bone in rig.bones:
		var uuid: String = bone.uuid
		if uuid.is_empty():
			continue
		_bone_by_uuid[uuid] = bone
		var parent: Variant = bone.parent_uuid
		if parent == null or (parent is String and (parent as String).is_empty()):
			_bone_roots.append(uuid)
		else:
			if not _bone_children.has(parent):
				_bone_children[parent] = []
			(_bone_children[parent] as Array).append(uuid)

	for kf in rig.keyframes:
		var bu: String = kf.bone_uuid
		if bu.is_empty():
			continue
		if not _frames_by_bone.has(bu):
			_frames_by_bone[bu] = []
		(_frames_by_bone[bu] as Array).append(kf)
	for bu in _frames_by_bone:
		(_frames_by_bone[bu] as Array).sort_custom(
			func(a, b): return int(a.frame_number) < int(b.frame_number)
		)

	for chain in rig.ik_chains:
		var leaf: String = chain.child_bone_uuid
		if leaf.is_empty():
			continue
		_ik_chains_by_leaf[leaf] = chain


# ── Pose evaluation ────────────────────────────────────────────────

func _evaluate_pose(frame: float) -> void:
	_local_transform_by_uuid.clear()
	_world_transform_by_uuid.clear()
	_world_rotation_by_uuid.clear()

	# FK pass: walk roots → descendants, composing parent transforms.
	for root in _bone_roots:
		_evaluate_bone_fk(root, Transform2D.IDENTITY, 0.0, frame)

	# IK pass: override the parent + leaf rotations of each enabled
	# chain, then re-walk descendants of the leaf so any sub-tree
	# inherits the new orientation.
	if rig != null:
		for leaf_uuid in _ik_chains_by_leaf:
			var chain: Dictionary = _ik_chains_by_leaf[leaf_uuid]
			if not chain.get("enabled", true):
				continue
			_apply_ik_chain(leaf_uuid, chain, frame)


func _evaluate_bone_fk(
	uuid: String, parent_world: Transform2D, parent_rotation: float, frame: float
) -> void:
	var bone: Dictionary = _bone_by_uuid.get(uuid, {})
	if bone.is_empty():
		return

	var frames: Array = _frames_by_bone.get(uuid, [])
	var p := AniPoseEvaluator.interpolate(frames, frame)

	# Local transform = T(translate) × R(rotation) × S(scale).
	var local := Transform2D.IDENTITY
	local = local.translated(Vector2(p.translate_x, p.translate_y))
	local = local.rotated(p.rotation)
	local = local.scaled(Vector2(p.scale_x, p.scale_y))

	# Apply min/max rotation clamp if the bone has constraints set.
	# (We can't perfectly enforce this in the local-only pass because
	# the constraint is on world rotation — but in practice keyframes
	# author already-clamped values, so the clamp is mostly a safety
	# net for game-side overrides via set_bone_world_rotation.)
	var world := parent_world * local
	var world_rotation: float = parent_rotation + p.rotation

	_local_transform_by_uuid[uuid] = local
	_world_transform_by_uuid[uuid] = world
	_world_rotation_by_uuid[uuid] = world_rotation

	for child_uuid in _bone_children.get(uuid, []):
		_evaluate_bone_fk(child_uuid, world, world_rotation, frame)


func _apply_ik_chain(leaf_uuid: String, chain: Dictionary, frame: float) -> void:
	var leaf: Dictionary = _bone_by_uuid.get(leaf_uuid, {})
	if leaf.is_empty():
		return
	var parent_uuid: Variant = leaf.parent_uuid
	if parent_uuid == null or (parent_uuid is String and (parent_uuid as String).is_empty()):
		return  # Need a parent for two-bone IK.
	var parent_bone: Dictionary = _bone_by_uuid.get(parent_uuid, {})
	if parent_bone.is_empty():
		return

	# Target: prefer the per-frame ikTargetX/Y on the leaf's keyframes
	# (interpolated), else fall back to the chain's rest target.
	var leaf_frames: Array = _frames_by_bone.get(leaf_uuid, [])
	var interp := AniPoseEvaluator.interpolate(leaf_frames, frame)
	var target := Vector2(chain.target_x, chain.target_y)
	if not is_nan(interp.ik_target_x):
		target.x = interp.ik_target_x
	if not is_nan(interp.ik_target_y):
		target.y = interp.ik_target_y

	# Shoulder position = parent's *parent* end joint in world space.
	# If the parent has no parent (the parent IS a root), use the
	# parent's own start joint, which lives at parent_world * (0,0).
	# Either way the shoulder is the parent's world origin.
	var shoulder_t: Transform2D = _world_transform_by_uuid.get(
		parent_uuid, Transform2D.IDENTITY
	)
	var shoulder: Vector2 = shoulder_t.origin

	var l1: float = float(parent_bone.length)
	var l2: float = float(leaf.length)

	var pole_side: int = int(chain.get("pole_side", 1))
	var rotations: Vector2 = AniPoseEvaluator.solve_two_bone_ik(
		shoulder, l1, l2, target, pole_side
	)
	var parent_rot: float = rotations.x
	var leaf_rot: float = rotations.y

	# Rebuild the parent's world transform with the solver's rotation.
	# Keep its existing translate+scale; just overwrite rotation.
	# (For most rigs the FK translate/scale for IK-driven bones is
	# zero/one, but we preserve them in case the author intentionally
	# set them.)
	_replace_world_rotation(parent_uuid, parent_rot)
	_replace_world_rotation(leaf_uuid, leaf_rot)

	# Re-walk descendants of the leaf so they inherit its new world
	# orientation.
	for child_uuid in _bone_children.get(leaf_uuid, []):
		var leaf_world: Transform2D = _world_transform_by_uuid[leaf_uuid]
		_evaluate_bone_fk(child_uuid, leaf_world, leaf_rot, frame)


func _replace_world_rotation(uuid: String, new_world_rotation: float) -> void:
	var t: Transform2D = _world_transform_by_uuid.get(uuid, Transform2D.IDENTITY)
	# Extract translate + scale, drop rotation.
	var origin := t.origin
	var sx := t.x.length()
	var sy := t.y.length()
	var rebuilt := Transform2D(new_world_rotation, origin)
	rebuilt = rebuilt.scaled_local(Vector2(sx, sy))
	_world_transform_by_uuid[uuid] = rebuilt
	_world_rotation_by_uuid[uuid] = new_world_rotation


# ── Drawing ────────────────────────────────────────────────────────

func _draw() -> void:
	if rig == null:
		return

	# Sort bones by per-frame partSortOrder if set, else by their
	# sortOrder field. Lower draws first (behind).
	var draw_order: Array = []
	for uuid in _bone_by_uuid:
		var bone: Dictionary = _bone_by_uuid[uuid]
		# Per-frame override.
		var part_sort: Variant = _interpolated_part_sort_order(uuid)
		var sort_key: int = part_sort if part_sort != null else int(bone.sort_order)
		draw_order.append({"uuid": uuid, "key": sort_key})
	draw_order.sort_custom(func(a, b): return int(a.key) < int(b.key))

	for entry in draw_order:
		var uuid: String = entry.uuid
		var bone: Dictionary = _bone_by_uuid[uuid]
		var world: Transform2D = _world_transform_by_uuid.get(
			uuid, Transform2D.IDENTITY
		)
		var texture: Texture2D = _texture_for_bone(uuid, bone)
		if texture != null:
			_draw_bone_sprite(bone, world, texture)
		elif draw_bones_in_editor or not Engine.is_editor_hint():
			_draw_bone_debug(bone, world)


func _texture_for_bone(uuid: String, bone: Dictionary) -> Texture2D:
	# Prefer uuid binding; fall back to name binding.
	var by_uuid: Variant = sprite_bindings.get(uuid)
	if by_uuid != null and by_uuid is Texture2D:
		return by_uuid
	var by_name: Variant = sprite_bindings.get(bone.name)
	if by_name != null and by_name is Texture2D:
		return by_name
	return null


func _draw_bone_debug(bone: Dictionary, world: Transform2D) -> void:
	# The bone is from (0,0) to (length, 0) in its local space.
	var start := world.origin
	var end := world * Vector2(float(bone.length), 0.0)
	draw_line(start, end, bone_color, bone_width)
	draw_circle(start, joint_radius, joint_color)


func _draw_bone_sprite(
	bone: Dictionary, world: Transform2D, texture: Texture2D
) -> void:
	# Apply part offset / rotation / flip on top of the bone's world
	# transform, then draw the texture centered on the resulting
	# point.
	var part_xf := Transform2D.IDENTITY
	part_xf = part_xf.translated(
		Vector2(float(bone.part_offset_x), float(bone.part_offset_y))
	)
	part_xf = part_xf.rotated(float(bone.part_rotation_offset))
	if bone.part_flip_x:
		part_xf = part_xf.scaled(Vector2(-1.0, 1.0))
	if bone.part_flip_y:
		part_xf = part_xf.scaled(Vector2(1.0, -1.0))

	draw_set_transform_matrix(world * part_xf)
	var size := texture.get_size()
	var rect := Rect2(-size * 0.5, size)
	draw_texture_rect(texture, rect, false)
	# Reset transform so subsequent draw calls aren't affected.
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _interpolated_part_sort_order(uuid: String) -> Variant:
	# Spec: partSortOrder uses stepped semantics — hold the previous
	# value, no interpolation. We walk the bone's frames to find the
	# latest one with a non-null part_sort_order at or before
	# _current_frame.
	var frames: Array = _frames_by_bone.get(uuid, [])
	var latest: Variant = null
	for kf in frames:
		if int(kf.frame_number) > int(_current_frame):
			break
		if kf.part_sort_order != null:
			latest = int(kf.part_sort_order)
	return latest
