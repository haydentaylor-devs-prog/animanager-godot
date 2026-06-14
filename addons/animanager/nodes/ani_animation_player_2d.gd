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
		_auto_bind_from_sprite_pack()
		_evaluate_pose(_current_frame)
		queue_redraw()

# bone_uuid OR bone_name → Texture2D. Lookups try uuid first then
# fall back to name (case-sensitive).
@export var sprite_bindings: Dictionary = {}:
	set(value):
		sprite_bindings = value
		queue_redraw()

# Optional path to a folder of PNGs named by bone name (matching what
# AniManager's "Export Rig" produces in its sister `.parts/` folder).
# When set, on rig assignment we auto-fill sprite_bindings with every
# bone whose name matches a PNG in the folder. Explicit entries in
# sprite_bindings take precedence — they're never overwritten.
@export_dir var sprite_pack_folder: String = "":
	set(value):
		sprite_pack_folder = value
		_auto_bind_from_sprite_pack()
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
# Per-frame pose data, keyed by bone uuid. Each entry is a Dictionary
# mirroring BoneWorldTransform in the AniManager source:
#   world_start: Vector2  — bone's start joint in world space
#   world_end:   Vector2  — bone's end joint in world space
#   world_rotation: float — bone's world-space rotation (radians)
#   scaled_length:  float — bone.length × ((scale_x + scale_y) / 2)
# Bones extend from world_start to world_end; sprites pivot on
# world_start (or world_end for bones with rootJointAtStart=false).
var _pose_by_uuid: Dictionary = {}


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
	# tip). The Transform2D is anchored at the bone's world_start with
	# its world_rotation — multiply by `Vector2(length, 0)` to land at
	# the end joint. Returns identity if the bone isn't found.
	var pose: Dictionary = _pose_by_uuid.get(bone_uuid_or_name, {})
	if pose.is_empty():
		# Try name lookup.
		for uuid in _bone_by_uuid:
			var b: Dictionary = _bone_by_uuid[uuid]
			if b.name == bone_uuid_or_name:
				pose = _pose_by_uuid.get(uuid, {})
				break
	if pose.is_empty():
		return Transform2D.IDENTITY
	return Transform2D(float(pose.world_rotation), Vector2(pose.world_start))


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
	_pose_by_uuid.clear()

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


# ── Sprite pack auto-binding ───────────────────────────────────────

func _auto_bind_from_sprite_pack() -> void:
	# Walk both auto-bind sources and fill sprite_bindings for every
	# bone whose name matches a texture, skipping bones that the user
	# has already explicitly bound. Sources (in priority order):
	#   1. rig.sprite_textures — embedded textures from a .animrig
	#      bundle. No filesystem traversal; texts are decoded once at
	#      import time.
	#   2. sprite_pack_folder — loose PNGs in the project tree
	#      (legacy two-file .rig + sister .parts/ flow).
	# Either can be empty; both can coexist. Skips silently when both
	# are empty so this is safe to call any time.
	if rig == null:
		return

	var bound_count := 0

	# Source 1 — embedded bundle textures.
	if rig.sprite_textures != null and not rig.sprite_textures.is_empty():
		for bone in rig.bones:
			var bone_name: String = bone.get("name", "")
			if bone_name.is_empty():
				continue
			if sprite_bindings.has(bone_name) or sprite_bindings.has(bone.get("uuid", "")):
				continue  # Don't clobber a user override.
			var tex: Variant = rig.sprite_textures.get(bone_name)
			if tex == null or not (tex is Texture2D):
				continue
			sprite_bindings[bone_name] = tex
			bound_count += 1

	# Source 2 — loose folder.
	if sprite_pack_folder != null and sprite_pack_folder != "":
		var dir := DirAccess.open(sprite_pack_folder)
		if dir == null:
			push_warning(
				"AniManager: sprite_pack_folder %s does not exist or isn't readable"
					% sprite_pack_folder
			)
		else:
			# Index PNGs by basename (without extension).
			var pngs := {}
			dir.list_dir_begin()
			var file_name := dir.get_next()
			while file_name != "":
				if not dir.current_is_dir() and file_name.to_lower().ends_with(".png"):
					var stem := file_name.substr(0, file_name.length() - 4)
					pngs[stem] = "%s/%s" % [sprite_pack_folder.rstrip("/"), file_name]
				file_name = dir.get_next()
			dir.list_dir_end()
			for bone in rig.bones:
				var bone_name: String = bone.get("name", "")
				if bone_name.is_empty():
					continue
				if sprite_bindings.has(bone_name) or sprite_bindings.has(bone.get("uuid", "")):
					continue
				if not pngs.has(bone_name):
					continue
				var tex: Texture2D = _load_png_robust(pngs[bone_name])
				if tex == null:
					continue
				sprite_bindings[bone_name] = tex
				bound_count += 1

	# Note: assigning a key into the existing Dictionary doesn't fire
	# the @export setter — that's fine, we don't want recursion. The
	# redraw is triggered by whichever caller set rig / sprite_pack_folder.
	print("AniManager: auto-bound %d sprite(s)" % bound_count)


# Loads a PNG by path, falling back to a raw Image read when Godot's
# import pipeline hasn't caught up to a freshly-dropped folder. The
# editor imports each PNG asynchronously after a drop; if auto-bind
# runs before that completes, load() returns null even though the
# file is on disk. Image.load_from_file() reads the bytes directly,
# bypassing the resource cache — so the bind succeeds regardless of
# import state. The user can re-set sprite_pack_folder later to
# pick up the properly-imported (compressed / mipmapped) version.
func _load_png_robust(path: String) -> Texture2D:
	var tex: Texture2D = load(path)
	if tex != null:
		return tex
	var img := Image.new()
	var err := img.load(path)
	if err != OK:
		# In editor mode, res:// paths resolve to project disk; in
		# exported games the resource pack would have answered in
		# load() above. Try the absolute path as a last-ditch.
		var abs_path := ProjectSettings.globalize_path(path)
		err = img.load(abs_path)
		if err != OK:
			return null
	return ImageTexture.create_from_image(img)


# ── Pose evaluation ────────────────────────────────────────────────

func _evaluate_pose(frame: float) -> void:
	# Model mirrors BoneTransformCalculator in the AniManager source:
	# bones are described by world start + end joints + world rotation,
	# not by composing parent-relative Transform2Ds. A bone's start
	# joint follows its parent's end joint (or start joint when
	# connect_to_parent_start is true); the keyframe rotation is LOCAL
	# (added to the parent's world rotation).
	_pose_by_uuid.clear()
	for root in _bone_roots:
		_evaluate_bone_fk(root, frame)

	# IK pass: solve each enabled chain, overwrite the parent's + leaf's
	# rotation + joint positions, then re-walk the leaf's descendants
	# so any sub-tree inherits the new orientation.
	if rig != null:
		for leaf_uuid in _ik_chains_by_leaf:
			var chain: Dictionary = _ik_chains_by_leaf[leaf_uuid]
			if not chain.get("enabled", true):
				continue
			_apply_ik_chain(leaf_uuid, chain, frame)


func _evaluate_bone_fk(uuid: String, frame: float) -> void:
	var bone: Dictionary = _bone_by_uuid.get(uuid, {})
	if bone.is_empty():
		return

	var frames: Array = _frames_by_bone.get(uuid, [])
	var p := AniPoseEvaluator.interpolate(frames, frame)

	var translate_x: float = p.translate_x
	var translate_y: float = p.translate_y
	var scale_x: float = p.scale_x
	var scale_y: float = p.scale_y
	var local_rotation: float = p.rotation
	var scaled_length: float = float(bone.length) * ((scale_x + scale_y) * 0.5)

	var parent_uuid: Variant = bone.parent_uuid
	var has_parent: bool = (
		parent_uuid != null
		and not (parent_uuid is String and (parent_uuid as String).is_empty())
	)

	# Step 1: world start position + the world rotation the local
	# rotation will be added on top of.
	var world_start: Vector2
	var parent_base_rotation: float
	if has_parent:
		var parent_pose: Dictionary = _pose_by_uuid.get(parent_uuid, {})
		if parent_pose.is_empty():
			# Parent wasn't visited yet — happens when the JSON lists
			# children before parents. Fall back to rest and continue.
			world_start = Vector2(float(bone.start_x), float(bone.start_y))
			parent_base_rotation = 0.0
		else:
			if bone.connect_to_parent_start:
				world_start = Vector2(parent_pose.world_start)
			else:
				world_start = Vector2(parent_pose.world_end)
			# Edge case from the reference impl: when the parent IS a
			# root bone and this bone connects to the joint that's the
			# parent's "root" (rootJointAtStart side), the base rotation
			# uses the parent's REST rotation, not its animated world
			# rotation. Affects rigs with a non-default rootJointAtStart.
			var parent_bone: Dictionary = _bone_by_uuid.get(parent_uuid, {})
			var parent_is_root: bool = (
				parent_bone.get("parent_uuid") == null
				or (
					parent_bone.get("parent_uuid") is String
					and (parent_bone.get("parent_uuid") as String).is_empty()
				)
			)
			var on_root_joint_side: bool = (
				parent_is_root
				and bone.connect_to_parent_start == parent_bone.root_joint_at_start
			)
			if on_root_joint_side:
				parent_base_rotation = float(parent_bone.rotation)
			else:
				parent_base_rotation = float(parent_pose.world_rotation)
		world_start += Vector2(translate_x, translate_y)
	else:
		# Root bone — its rest start position IS its world start.
		world_start = Vector2(
			float(bone.start_x) + translate_x,
			float(bone.start_y) + translate_y
		)
		parent_base_rotation = 0.0

	# Step 2: world rotation. For root bones the keyframe value IS
	# the world rotation; for descendants it's added on top of the
	# parent base.
	var world_rotation: float
	if has_parent:
		world_rotation = parent_base_rotation + local_rotation
	else:
		world_rotation = local_rotation
		# Root + rootJointAtStart=false edge: the bone's END joint is
		# the fixed anchor and the START joint slides with rotation.
		# Recompute world_start so the END lands at the rest end + the
		# keyframe translate.
		if not bone.root_joint_at_start:
			var rest_end_x: float = float(bone.start_x) + float(bone.length) * cos(
				float(bone.rotation)
			)
			var rest_end_y: float = float(bone.start_y) + float(bone.length) * sin(
				float(bone.rotation)
			)
			world_start = Vector2(
				rest_end_x + translate_x - scaled_length * cos(world_rotation),
				rest_end_y + translate_y - scaled_length * sin(world_rotation),
			)

	var world_end := world_start + Vector2(
		scaled_length * cos(world_rotation),
		scaled_length * sin(world_rotation),
	)

	_pose_by_uuid[uuid] = {
		"world_start": world_start,
		"world_end": world_end,
		"world_rotation": world_rotation,
		"scaled_length": scaled_length,
	}

	for child_uuid in _bone_children.get(uuid, []):
		_evaluate_bone_fk(child_uuid, frame)


func _apply_ik_chain(leaf_uuid: String, chain: Dictionary, frame: float) -> void:
	var leaf: Dictionary = _bone_by_uuid.get(leaf_uuid, {})
	if leaf.is_empty():
		return
	var parent_uuid: Variant = leaf.parent_uuid
	if (
		parent_uuid == null
		or (parent_uuid is String and (parent_uuid as String).is_empty())
	):
		return  # Two-bone IK needs a parent above the leaf.
	var parent_pose: Dictionary = _pose_by_uuid.get(parent_uuid, {})
	if parent_pose.is_empty():
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

	# Shoulder = the chain parent's world START joint (the joint
	# closest to the rest of the body that doesn't move with IK).
	var shoulder: Vector2 = parent_pose.world_start
	var l1: float = float(parent_pose.scaled_length)
	var l2: float = float(_pose_by_uuid.get(leaf_uuid, {"scaled_length": float(leaf.length)}).scaled_length)
	var pole_side: int = int(chain.get("pole_side", 1))
	var rotations: Vector2 = AniPoseEvaluator.solve_two_bone_ik(
		shoulder, l1, l2, target, pole_side
	)
	var parent_world_rotation: float = rotations.x
	var leaf_world_rotation: float = rotations.y

	# Rebuild the parent's pose: shoulder stays put; end follows the
	# new rotation.
	var parent_end := shoulder + Vector2(
		l1 * cos(parent_world_rotation), l1 * sin(parent_world_rotation)
	)
	_pose_by_uuid[parent_uuid] = {
		"world_start": shoulder,
		"world_end": parent_end,
		"world_rotation": parent_world_rotation,
		"scaled_length": l1,
	}

	# Leaf starts at the parent's new end joint, extends along the
	# leaf rotation.
	var leaf_end := parent_end + Vector2(
		l2 * cos(leaf_world_rotation), l2 * sin(leaf_world_rotation)
	)
	_pose_by_uuid[leaf_uuid] = {
		"world_start": parent_end,
		"world_end": leaf_end,
		"world_rotation": leaf_world_rotation,
		"scaled_length": l2,
	}

	# Re-walk descendants of the leaf so they inherit the new orientation.
	for child_uuid in _bone_children.get(leaf_uuid, []):
		_evaluate_bone_fk(child_uuid, frame)


# ── Drawing ────────────────────────────────────────────────────────

func _draw() -> void:
	if rig == null:
		return

	# Sort bones by per-frame partSortOrder if set, else by their
	# sortOrder field. Lower draws first (behind).
	var draw_order: Array = []
	for uuid in _bone_by_uuid:
		var bone: Dictionary = _bone_by_uuid[uuid]
		# Sort key priority: per-frame keyframe override > part's
		# base sortOrder (v1.2) > bone.sort_order (legacy fallback).
		# Bone.sort_order is bone-list ordering and gets parts
		# wrong whenever the artist set part.sortOrder independently
		# (e.g. both arms on top of chest because all bones share
		# sort_order = 0 but the parts have distinct values).
		var part_sort: Variant = _interpolated_part_sort_order(uuid)
		var sort_key: int
		if part_sort != null:
			sort_key = int(part_sort)
		elif bone.get("part_base_sort_order") != null:
			sort_key = int(bone.part_base_sort_order)
		else:
			sort_key = int(bone.sort_order)
		draw_order.append({"uuid": uuid, "key": sort_key})
	draw_order.sort_custom(func(a, b): return int(a.key) < int(b.key))

	for entry in draw_order:
		var uuid: String = entry.uuid
		var bone: Dictionary = _bone_by_uuid[uuid]
		var pose: Dictionary = _pose_by_uuid.get(uuid, {})
		if pose.is_empty():
			continue
		var texture: Texture2D = _texture_for_bone(uuid, bone)
		if texture != null:
			_draw_bone_sprite(bone, pose, texture)
		elif draw_bones_in_editor or not Engine.is_editor_hint():
			_draw_bone_debug(pose)


func _texture_for_bone(uuid: String, bone: Dictionary) -> Texture2D:
	# Prefer uuid binding; fall back to name binding.
	var by_uuid: Variant = sprite_bindings.get(uuid)
	if by_uuid != null and by_uuid is Texture2D:
		return by_uuid
	var by_name: Variant = sprite_bindings.get(bone.name)
	if by_name != null and by_name is Texture2D:
		return by_name
	return null


func _draw_bone_debug(pose: Dictionary) -> void:
	draw_line(pose.world_start, pose.world_end, bone_color, bone_width)
	draw_circle(pose.world_start, joint_radius, joint_color)


func _draw_bone_sprite(
	bone: Dictionary, pose: Dictionary, texture: Texture2D
) -> void:
	# Spec §10.3. Two paths: the v1.2 "preferred" math when the
	# exporter shipped part-render hints, and the legacy
	# centered-on-pivot fallback for older rigs (or rigs exported
	# without sprite_repository wired). The preferred path mirrors
	# puppet_view._computePlacement in the AniManager source, so
	# sprites land where the artist saw them on the tablet.
	if bone.get("part_rest_offset_x") != null:
		_draw_bone_sprite_v1_2(bone, pose, texture)
	else:
		_draw_bone_sprite_legacy(bone, pose, texture)


func _draw_bone_sprite_v1_2(
	bone: Dictionary, pose: Dictionary, texture: Texture2D
) -> void:
	# Delta between current world rotation and rest world rotation —
	# this is what rotates the stored bone-local rest offset into the
	# current frame's world space.
	var delta := float(pose.world_rotation) - float(bone.rest_world_rotation)
	var cos_d := cos(delta)
	var sin_d := sin(delta)

	var rest_off_x := float(bone.part_rest_offset_x)
	var rest_off_y := float(bone.part_rest_offset_y)
	var rot_rest_off_x := rest_off_x * cos_d - rest_off_y * sin_d
	var rot_rest_off_y := rest_off_x * sin_d + rest_off_y * cos_d

	var part_off_x := float(bone.part_offset_x)
	var part_off_y := float(bone.part_offset_y)
	var rot_part_off_x := part_off_x * cos_d - part_off_y * sin_d
	var rot_part_off_y := part_off_x * sin_d + part_off_y * cos_d

	var pivot_world := Vector2(
		(pose.world_start as Vector2).x + rot_rest_off_x + rot_part_off_x,
		(pose.world_start as Vector2).y + rot_rest_off_y + rot_part_off_y,
	)

	var part_world_rotation := delta + float(bone.part_rotation_offset)

	# The bodyRect is drawn with the part's pivot at the origin of its
	# own local coords — so pixels above/left of the pivot have
	# negative coords, pixels below/right have positive. This is what
	# makes draw_set_transform_matrix(world, rotation) put the pivot
	# at pivot_world automatically.
	var part_w := float(bone.part_width)
	var part_h := float(bone.part_height)
	var pivot_px := Vector2(
		part_w * float(bone.part_pivot_x),
		part_h * float(bone.part_pivot_y),
	)
	var body_rect := Rect2(-pivot_px, Vector2(part_w, part_h))

	var xf := Transform2D(part_world_rotation, pivot_world)
	if bone.part_flip_x:
		xf = xf.scaled_local(Vector2(-1.0, 1.0))
	if bone.part_flip_y:
		xf = xf.scaled_local(Vector2(1.0, -1.0))

	draw_set_transform_matrix(xf)
	draw_texture_rect(texture, body_rect, false)
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _draw_bone_sprite_legacy(
	bone: Dictionary, pose: Dictionary, texture: Texture2D
) -> void:
	# Pre-v1.2 fallback. Center the sprite on the bone's root joint
	# and rotate by world rotation + part_rotation_offset. Doesn't
	# honor per-part pivot — sprites can end up jumbled when the
	# author drew non-symmetric parts. v1.2+ rigs avoid this.
	var pivot: Vector2 = pose.world_start
	if not bone.root_joint_at_start:
		pivot = pose.world_end

	var part_xf := Transform2D(
		float(pose.world_rotation) + float(bone.part_rotation_offset),
		pivot,
	)
	part_xf = part_xf.translated_local(
		Vector2(float(bone.part_offset_x), float(bone.part_offset_y))
	)
	if bone.part_flip_x:
		part_xf = part_xf.scaled_local(Vector2(-1.0, 1.0))
	if bone.part_flip_y:
		part_xf = part_xf.scaled_local(Vector2(1.0, -1.0))

	draw_set_transform_matrix(part_xf)
	var size := texture.get_size()
	var rect := Rect2(-size * 0.5, size)
	draw_texture_rect(texture, rect, false)
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
