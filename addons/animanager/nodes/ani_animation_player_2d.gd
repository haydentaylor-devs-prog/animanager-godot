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
#
# SHADED MODE (spec v1.6): with `shaded` on, every v1.2 bone with a
# texture gets a child Sprite2D carrying its own ShaderMaterial
# (ani_shaded_part.gdshader) fed by the rig's shade-mask sidecars —
# material mask (metal/lit/emissive/flat) + baked normal map. Parts
# without sidecars render as plain albedo through the same shader.
# The game drives `light_direction`; `matcap` falls back to a
# procedural chrome sphere when unset.

const SHADED_PART_SHADER := preload(
	"res://addons/animanager/shaders/ani_shaded_part.gdshader"
)

signal animation_finished
signal animation_looped
# Emitted once per event entry when the playhead first crosses the
# event's frame. `event_name` and `payload` come from the .rig file's
# events array (spec §8.3). Multiple events at the same frame fire
# in array order, each via its own emission of this signal.
signal animation_event(event_name: String, payload: String)

# ── Inspector properties ───────────────────────────────────────────

@export var rig: AniRigResource:
	set(value):
		rig = value
		_rebuild_indices()
		_auto_bind_from_sprite_pack()
		_rebuild_shaded_children()
		_evaluate_pose(_current_frame)
		queue_redraw()

# bone_uuid OR bone_name → Texture2D. Lookups try uuid first then
# fall back to name (case-sensitive).
@export var sprite_bindings: Dictionary = {}:
	set(value):
		sprite_bindings = value
		_rebuild_shaded_children()
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
		_rebuild_shaded_children()
		queue_redraw()

# ── Shading (spec v1.6) ────────────────────────────────────────────

@export_group("Shading")
# When on, bound v1.2 parts render through child Sprite2Ds with the
# shaded-part shader instead of plain draw calls. Legacy (pre-v1.2)
# bones keep the unshaded draw path even when this is on.
@export var shaded: bool = false:
	set(value):
		shaded = value
		_rebuild_shaded_children()
		queue_redraw()

# Lit-metal-sphere image sampled by the metal bucket. Leave unset to
# use a built-in procedural chrome matcap.
@export var matcap: Texture2D:
	set(value):
		matcap = value
		_apply_shading_uniforms()

# World-space light direction fed to every part material. Y-down to
# match the canvas (negative y = light from above), z toward the
# viewer. Games animate this via set_light_direction().
@export var light_direction: Vector3 = Vector3(0.35, -0.55, 0.75):
	set(value):
		light_direction = value
		_apply_shading_uniforms()

# How strongly the painted color tints metal reflections (gold shines
# gold instead of washing to steel). 0 = legacy chrome, 1 = fully
# albedo-tinted matcap, past 1 extrapolates the tint harder. Default
# 2.0 picked by eye on the Herald. Mirrors the shader's metal_tint.
@export_range(0.0, 3.0) var metal_tint: float = 2.0:
	set(value):
		metal_tint = value
		_apply_shading_uniforms()

@export_group("")

# When true, the first root bone's FRAME-0 translate is treated as a
# baseline and subtracted from its translate at every frame (and from
# the IK-target ride-along shift). Games that move the character body
# themselves enable this so a stray authored root offset can't sink
# or shift one clip relative to another — RELATIVE root motion within
# the clip (e.g. a run-cycle bob) is preserved. Default false =
# spec-faithful playback of the file as authored.
@export var zero_root_translate: bool = false:
	set(value):
		zero_root_translate = value
		_evaluate_pose(_current_frame)
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
# Highest integer frame the event dispatcher has fired for since the
# last loop wrap. Initialized to -1 so frame-0 events fire on the
# first tick of playback. Reset to -1 on every loop wrap so events
# re-fire on the next pass.
var _last_event_int_frame: int = -1

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

# Shaded mode: bone uuid → child Sprite2D (transient, never saved
# into the scene). Rebuilt whenever rig / bindings / shaded change.
var _shaded_sprites: Dictionary = {}
var _fallback_matcap: ImageTexture = null


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
	_clear_fade()
	_evaluate_pose(_current_frame)
	queue_redraw()


func is_playing() -> bool:
	return _is_playing


func get_current_frame() -> float:
	return _current_frame


func set_current_frame(frame: float) -> void:
	# Scrub the playhead manually.
	if rig == null:
		_current_frame = 0.0
		return
	if rig.is_looping:
		# Looping clips have a valid domain of [0, total_frames): the
		# wrap segment past the last integer frame is real playable
		# time (it interpolates back toward frame 0), so scrubs may
		# land there and out-of-range scrubs wrap around the cycle.
		_current_frame = fposmod(frame, float(rig.total_frames))
	else:
		_current_frame = clampf(frame, 0.0, float(rig.total_frames - 1))
	_evaluate_pose(_current_frame)
	queue_redraw()


# ── Cross-fade (runtime pose blending) ─────────────────────────────────

# While fading, every local pose blends the OUTGOING clip (advancing
# on its own playhead) into the CURRENT rig's pose — clip switches
# work from ANY frame of ANY clip without authored transition art.
# The captured source is self-contained (rig ref + its own frame
# index), so it survives the rig setter tearing the live indices
# down.
var _fade_from_rig: AniRigResource = null
var _fade_from_frames_by_bone: Dictionary = {}
var _fade_from_root_baseline: Vector2 = Vector2.ZERO
var _fade_from_frame: float = 0.0
var _fade_elapsed: float = 0.0
var _fade_duration: float = 0.0


## Switch to [new_rig] with a timed pose cross-fade instead of a hard
## cut. Replaces the `rig = r; set_current_frame(0); play()` sequence.
## Falls back to a hard cut when there's nothing to fade from, the
## target is the current rig, or duration <= 0.
func crossfade_to(new_rig: AniRigResource, duration: float = 0.18) -> void:
	if rig != null and new_rig != null and new_rig != rig and duration > 0.0:
		_fade_from_rig = rig
		_fade_from_frame = _current_frame
		_fade_elapsed = 0.0
		_fade_duration = duration
		# Own copy of the outgoing frame index — _rebuild_indices
		# clears the live dictionaries in place.
		_fade_from_frames_by_bone = {}
		for kf in rig.keyframes:
			var bu: String = kf.bone_uuid
			if bu.is_empty():
				continue
			if not _fade_from_frames_by_bone.has(bu):
				_fade_from_frames_by_bone[bu] = []
			(_fade_from_frames_by_bone[bu] as Array).append(kf)
		for bu in _fade_from_frames_by_bone:
			(_fade_from_frames_by_bone[bu] as Array).sort_custom(
				func(a, b): return int(a.frame_number) < int(b.frame_number)
			)
		# Source-side zero_root_translate baseline, so root motion
		# blends between each clip's own normalized translate.
		_fade_from_root_baseline = Vector2.ZERO
		if zero_root_translate:
			for bone in rig.bones:
				var parent: Variant = bone.parent_uuid
				if parent == null or (parent is String and (parent as String).is_empty()):
					var rf: Array = _fade_from_frames_by_bone.get(bone.uuid, [])
					if not rf.is_empty():
						var rp0 := AniPoseEvaluator.interpolate(
							rf, 0.0, rig.total_frames, rig.is_looping
						)
						_fade_from_root_baseline = Vector2(
							rp0.translate_x, rp0.translate_y
						)
					break
	else:
		_clear_fade()
	rig = new_rig
	set_current_frame(0.0)
	play()


func _clear_fade() -> void:
	_fade_from_rig = null
	_fade_from_frames_by_bone = {}
	_fade_from_root_baseline = Vector2.ZERO
	_fade_duration = 0.0
	_fade_elapsed = 0.0


# Weight of the TARGET clip (0 = all source, 1 = all target).
# Smoothstepped so the switch eases in and out.
func _fade_target_weight() -> float:
	if _fade_from_rig == null or _fade_duration <= 0.0:
		return 1.0
	var t: float = clampf(_fade_elapsed / _fade_duration, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


# Local pose for [uuid] on the CURRENT rig, blended with the outgoing
# clip while a cross-fade is active. Bones match by uuid (all clips
# of a character export from the same project, so uuids line up); a
# bone absent from the source blends from its rest values.
func _blended_local(uuid: String, frames: Array, frame: float) -> Dictionary:
	var p := AniPoseEvaluator.interpolate(
		frames, frame, rig.total_frames, rig.is_looping
	)
	if _fade_from_rig == null:
		return p
	var w := _fade_target_weight()
	if w >= 1.0:
		return p
	var q := AniPoseEvaluator.interpolate(
		_fade_from_frames_by_bone.get(uuid, []) as Array,
		_fade_from_frame,
		_fade_from_rig.total_frames,
		_fade_from_rig.is_looping,
	)
	return {
		"rotation": lerp_angle(q.rotation, p.rotation, w),
		"translate_x": lerpf(q.translate_x, p.translate_x, w),
		"translate_y": lerpf(q.translate_y, p.translate_y, w),
		"scale_x": lerpf(q.scale_x, p.scale_x, w),
		"scale_y": lerpf(q.scale_y, p.scale_y, w),
		"ik_target_x": _lerp_ik(q.ik_target_x, p.ik_target_x, w),
		"ik_target_y": _lerp_ik(q.ik_target_y, p.ik_target_y, w),
	}


# NAN = "no IK target on this side" — take the defined side rather
# than poisoning the blend.
func _lerp_ik(a: float, b: float, w: float) -> float:
	if is_nan(a):
		return b
	if is_nan(b):
		return a
	return lerpf(a, b, w)


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


func set_light_direction(dir: Vector3) -> void:
	# Convenience for game code that animates the light (e.g. a torch
	# passing by). Same as assigning light_direction.
	light_direction = dir


func get_part_material(bone_uuid_or_name: String) -> ShaderMaterial:
	# The shaded child's per-part material, for games that want to
	# tweak uniforms beyond matcap/light (rim color, emissive energy,
	# metalness scaler...). Null when shaded mode is off or the bone
	# has no shaded child.
	var sprite: Variant = _shaded_sprites.get(bone_uuid_or_name)
	if sprite == null:
		for uuid in _shaded_sprites:
			var bone: Dictionary = _bone_by_uuid.get(uuid, {})
			if bone.get("name", "") == bone_uuid_or_name:
				sprite = _shaded_sprites[uuid]
				break
	if sprite == null or not is_instance_valid(sprite):
		return null
	return (sprite as Sprite2D).material as ShaderMaterial


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

	# Cross-fade bookkeeping: the outgoing clip keeps playing on its
	# own playhead for the duration of the blend.
	if _fade_from_rig != null:
		_fade_elapsed += delta
		_fade_from_frame += delta * float(_fade_from_rig.frame_rate) * speed
		if _fade_from_rig.is_looping:
			_fade_from_frame = fposmod(
				_fade_from_frame, float(_fade_from_rig.total_frames)
			)
		else:
			_fade_from_frame = minf(
				_fade_from_frame, float(_fade_from_rig.total_frames - 1)
			)
		if _fade_elapsed >= _fade_duration:
			_clear_fade()

	_current_frame += delta * float(rig.frame_rate) * speed
	var wrapped := false
	if _current_frame >= float(rig.total_frames):
		var loops: bool = (loop_override == 1) or (
			loop_override == -1 and rig.is_looping
		)
		if loops:
			_current_frame = fmod(_current_frame, float(rig.total_frames))
			wrapped = true
			emit_signal("animation_looped")
		else:
			_current_frame = float(rig.total_frames - 1)
			_is_playing = false
			emit_signal("animation_finished")

	_dispatch_events(int(_current_frame), wrapped)

	_evaluate_pose(_current_frame)
	queue_redraw()


# Emit `animation_event` for every event row whose frame is now
# crossed by the playhead since the last tick. On a loop wrap the
# tracker resets to -1 so events at the start of the animation fire
# again on the next pass.
func _dispatch_events(new_int_frame: int, wrapped: bool) -> void:
	if rig == null or (rig.events as Array).is_empty():
		_last_event_int_frame = new_int_frame
		return
	if wrapped:
		_last_event_int_frame = -1
	if new_int_frame <= _last_event_int_frame:
		return
	for ev in rig.events:
		var f: int = int(ev.get("frame", 0))
		if f > _last_event_int_frame and f <= new_int_frame:
			emit_signal(
				"animation_event",
				String(ev.get("name", "")),
				String(ev.get("payload", "")),
			)
	_last_event_int_frame = new_int_frame


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


# ── Shaded children (spec v1.6) ────────────────────────────────────

func _rebuild_shaded_children() -> void:
	# Tear down and (when shaded) respawn one child Sprite2D per
	# bound v1.2 bone. Children are transient: no owner is set, so
	# they never serialize into the user's scene file.
	for sprite in _shaded_sprites.values():
		if is_instance_valid(sprite):
			sprite.queue_free()
	_shaded_sprites.clear()
	if not shaded or rig == null:
		return

	for bone in rig.bones:
		var uuid: String = bone.get("uuid", "")
		if uuid.is_empty():
			continue
		# Legacy rigs without part-render hints keep the unshaded
		# _draw path — their placement math doesn't transplant onto a
		# child transform cleanly, and pre-v1.2 rigs predate masks
		# anyway.
		if bone.get("part_rest_offset_x") == null:
			continue
		var texture: Texture2D = _texture_for_bone(uuid, bone)
		if texture == null:
			continue

		var sprite := Sprite2D.new()
		var part_label := String(bone.get("name", uuid))
		sprite.name = "AniShadedPart_%s" % part_label.validate_node_name()
		sprite.texture = texture
		sprite.centered = false
		sprite.offset = -_part_pivot_px(bone)

		var mat := ShaderMaterial.new()
		mat.shader = SHADED_PART_SHADER
		var shade := _shade_textures_for_bone(bone)
		if shade.material != null:
			mat.set_shader_parameter("material_mask", shade.material)
		if shade.normal != null:
			mat.set_shader_parameter("normal_map", shade.normal)
		mat.set_shader_parameter(
			"matcap", matcap if matcap != null else _get_fallback_matcap()
		)
		mat.set_shader_parameter("light_dir", light_direction)
		mat.set_shader_parameter("metal_tint", metal_tint)
		sprite.material = mat

		add_child(sprite)
		_shaded_sprites[uuid] = sprite

	_update_shaded_children()


func _update_shaded_children() -> void:
	# Per-frame: move each child onto its bone. Same placement math
	# as the unshaded draw path (shared _part_transform_v1_2).
	if _shaded_sprites.is_empty():
		return
	for uuid in _shaded_sprites:
		var sprite: Sprite2D = _shaded_sprites[uuid]
		if not is_instance_valid(sprite):
			continue
		var pose: Dictionary = _pose_by_uuid.get(uuid, {})
		if pose.is_empty():
			sprite.visible = false
			continue
		var bone: Dictionary = _bone_by_uuid.get(uuid, {})
		sprite.visible = true
		sprite.transform = _part_transform_v1_2(bone, pose)
		sprite.z_index = clampi(_sort_key_for_bone(uuid, bone), -4096, 4096)


func _apply_shading_uniforms() -> void:
	# Push matcap + light_dir to every part material. Cheap enough to
	# run per-frame when a game animates the light.
	if _shaded_sprites.is_empty():
		return
	var cap: Texture2D = matcap if matcap != null else _get_fallback_matcap()
	for sprite in _shaded_sprites.values():
		if not is_instance_valid(sprite):
			continue
		var mat := (sprite as Sprite2D).material as ShaderMaterial
		if mat == null:
			continue
		mat.set_shader_parameter("matcap", cap)
		mat.set_shader_parameter("light_dir", light_direction)
		mat.set_shader_parameter("metal_tint", metal_tint)


func _shade_textures_for_bone(bone: Dictionary) -> Dictionary:
	# Sidecar lookup, mirroring the part-texture sources: embedded
	# bundle dicts first, then loose <folder>/<bone>.material.png /
	# .normal.png next to the sprite pack. Missing entries stay null —
	# the shader's defaults render such parts as plain albedo.
	var bone_name: String = bone.get("name", "")
	var out := {"material": null, "normal": null}
	if bone_name.is_empty():
		return out
	if rig != null:
		var m: Variant = rig.material_textures.get(bone_name)
		if m is Texture2D:
			out.material = m
		var n: Variant = rig.normal_textures.get(bone_name)
		if n is Texture2D:
			out.normal = n
	if sprite_pack_folder != null and sprite_pack_folder != "":
		var base := "%s/%s" % [sprite_pack_folder.rstrip("/"), bone_name]
		if out.material == null:
			out.material = _load_sidecar_png(base + ".material.png")
		if out.normal == null:
			out.normal = _load_sidecar_png(base + ".normal.png")
	return out


func _load_sidecar_png(path: String) -> Texture2D:
	# Existence-gated wrapper so missing sidecars (the common case)
	# don't spam load errors.
	if not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
		return null
	return _load_png_robust(path)


func _get_fallback_matcap() -> Texture2D:
	# Procedural chrome sphere so shaded mode works with zero assets:
	# diffuse + tight specular hotspot + rim fresnel, generated once.
	if _fallback_matcap != null:
		return _fallback_matcap
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := float(n) * 0.5
	var lv := Vector3(-0.35, -0.5, 0.6).normalized()
	var steel := Vector3(0.42, 0.46, 0.52)
	for y in n:
		for x in n:
			var u := (float(x) - c) / c
			var v := (float(y) - c) / c
			var r2 := u * u + v * v
			if r2 > 1.0:
				img.set_pixel(x, y, Color(0, 0, 0, 1))
				continue
			var nrm := Vector3(u, v, sqrt(1.0 - r2))
			var diff: float = maxf(nrm.dot(lv), 0.0)
			var refl := nrm * (2.0 * nrm.dot(lv)) - lv
			var spec: float = pow(maxf(refl.z, 0.0), 24.0)
			var fres: float = pow(1.0 - nrm.z, 3.0) * 0.3
			var col := steel * (0.28 + 0.72 * diff)
			col += Vector3(1, 1, 1) * spec * 0.9
			col += Vector3(0.8, 0.88, 1.0) * fres
			img.set_pixel(x, y, Color(
				clampf(col.x, 0, 1), clampf(col.y, 0, 1), clampf(col.z, 0, 1), 1.0
			))
	_fallback_matcap = ImageTexture.create_from_image(img)
	return _fallback_matcap


# ── Pose evaluation ────────────────────────────────────────────────

# First root bone's interpolated translate at the frame being
# evaluated — cached once per _evaluate_pose pass. IK targets are
# stored in REST sprite-local coords; shifting them by the root's
# animated translate keeps limbs reaching targets that ride along
# with the body (mirrors the reference impl's target adjustment).
var _root_translate: Vector2 = Vector2.ZERO
# Frame-0 root translate, non-zero only when zero_root_translate —
# subtracted from the root's translate at every frame (see the
# export's doc comment).
var _root_baseline: Vector2 = Vector2.ZERO


func _evaluate_pose(frame: float) -> void:
	# Model mirrors BoneTransformCalculator in the AniManager source:
	# bones are described by world start + end joints + world rotation,
	# not by composing parent-relative Transform2Ds. A bone's start
	# joint follows its parent's end joint (or start joint when
	# connect_to_parent_start is true); the keyframe rotation is LOCAL
	# (added to the parent's world rotation).
	#
	# IK is solved DURING the walk, exactly like the reference impl:
	# when a bone hosts an enabled chain (one of its children is the
	# chain leaf), the bone's own local rotation comes from the
	# two-bone solver BEFORE its children compose — so every child
	# inherits the post-IK pose: the leaf via the passed-down
	# override, and siblings (e.g. knee-plate armor hanging off a
	# thigh) via plain FK against the already-solved parent. The old
	# post-pass approach re-walked only the leaf's descendants, which
	# left the chain parent's other children composed against the
	# pre-IK pose — parts visibly detached whenever IK moved a limb.
	_pose_by_uuid.clear()
	_root_translate = Vector2.ZERO
	_root_baseline = Vector2.ZERO
	for root in _bone_roots:
		var root_frames: Array = _frames_by_bone.get(root, [])
		if not root_frames.is_empty():
			var rp := AniPoseEvaluator.interpolate(
				root_frames, frame, rig.total_frames, rig.is_looping
			)
			_root_translate = Vector2(rp.translate_x, rp.translate_y)
			if zero_root_translate:
				var rp0 := AniPoseEvaluator.interpolate(
					root_frames, 0.0, rig.total_frames, rig.is_looping
				)
				_root_baseline = Vector2(rp0.translate_x, rp0.translate_y)
				_root_translate -= _root_baseline
		break
	for root in _bone_roots:
		_evaluate_bone_fk(root, frame, NAN)
	_update_shaded_children()


# First child of [parent_uuid] that is the leaf of an enabled IK
# chain — the reference impl hosts at most one chain per parent.
func _outgoing_chain_child(parent_uuid: String) -> String:
	for child_uuid in _bone_children.get(parent_uuid, []):
		var chain: Variant = _ik_chains_by_leaf.get(child_uuid)
		if chain != null and bool((chain as Dictionary).get("enabled", true)):
			return child_uuid
	return ""


# Mirror of the app's Bone.constrainRotation: clamp the LOCAL
# rotation to [min_rotation, max_rotation]; a null bound is open.
func _constrain_rotation(bone: Dictionary, value: float) -> float:
	var mn: Variant = bone.get("min_rotation")
	if mn != null and value < float(mn):
		return float(mn)
	var mx: Variant = bone.get("max_rotation")
	if mx != null and value > float(mx):
		return float(mx)
	return value


func _evaluate_bone_fk(uuid: String, frame: float, ik_local_override: float = NAN) -> void:
	var bone: Dictionary = _bone_by_uuid.get(uuid, {})
	if bone.is_empty():
		return

	var frames: Array = _frames_by_bone.get(uuid, [])
	var p := _blended_local(uuid, frames, frame)

	var translate_x: float = p.translate_x
	var translate_y: float = p.translate_y
	var scale_x: float = p.scale_x
	var scale_y: float = p.scale_y
	var scaled_length: float = float(bone.length) * ((scale_x + scale_y) * 0.5)

	# zero_root_translate: the baseline is non-zero only when enabled
	# (see _evaluate_pose); it applies to ROOT bones only — child
	# translates are joint offsets and stay as authored.
	var bone_parent: Variant = bone.parent_uuid
	var bone_is_root: bool = (
		bone_parent == null
		or (bone_parent is String and (bone_parent as String).is_empty())
	)
	if bone_is_root:
		var eff_baseline := _root_baseline
		if _fade_from_rig != null:
			eff_baseline = _fade_from_root_baseline.lerp(
				_root_baseline, _fade_target_weight()
			)
		translate_x -= eff_baseline.x
		translate_y -= eff_baseline.y

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

	# Step 2: local rotation. Priority mirrors the reference impl:
	#   (a) IK override passed down from the chain parent (we're the
	#       chain leaf this pass)
	#   (b) we host an enabled outgoing chain — solve two-bone IK now,
	#       BEFORE our children compose
	#   (c) interpolated keyframe rotation
	#   (d) zero-keyframe rest fallback (spec §8.1): a bone with no
	#       keys stays in its rest pose, so use the authored local
	#       `rotation` (e.g. armor pauldrons parented to an animated
	#       arm ride the parent's swing instead of flailing)
	var ik_child_uuid := ""
	var ik_child_local := 0.0
	var local_rotation: float
	if not is_nan(ik_local_override):
		local_rotation = ik_local_override
	else:
		# Root bones with rootJointAtStart=false can't host IK — their
		# start position depends on the rotation being solved for.
		var can_host_ik: bool = has_parent or bool(bone.root_joint_at_start)
		var chain_child := ""
		if can_host_ik:
			chain_child = _outgoing_chain_child(uuid)
		if chain_child != "":
			var chain: Dictionary = _ik_chains_by_leaf[chain_child]
			var child_bone: Dictionary = _bone_by_uuid[chain_child]
			# Target: per-frame ikTargetX/Y on the leaf's keyframes
			# (interpolated) when present, else the chain's rest
			# target; either way shifted by the root's animated
			# translate so the target rides along with the body.
			var target := Vector2(float(chain.target_x), float(chain.target_y))
			var leaf_frames: Array = _frames_by_bone.get(chain_child, [])
			var interp := _blended_local(chain_child, leaf_frames, frame)
			if not is_nan(interp.ik_target_x):
				target.x = interp.ik_target_x
			if not is_nan(interp.ik_target_y):
				target.y = interp.ik_target_y
			target += _root_translate
			var pole_side: int = int(chain.get("pole_side", 1))
			var rotations: Vector2 = AniPoseEvaluator.solve_two_bone_ik(
				world_start, scaled_length, float(child_bone.length), target, pole_side
			)
			# Parent's local is clamped by its own constraints; the
			# leaf's local is measured against the UNclamped parent
			# world rotation (reference-impl trade-off: a clamped
			# parent means the leaf won't perfectly reach the target).
			local_rotation = _constrain_rotation(bone, rotations.x - parent_base_rotation)
			ik_child_uuid = chain_child
			ik_child_local = _constrain_rotation(child_bone, rotations.y - rotations.x)
		elif frames.is_empty():
			local_rotation = float(bone.rotation)
		else:
			local_rotation = p.rotation

	# Step 3: world rotation. For root bones the keyframe value IS
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
		var child_override := NAN
		if child_uuid == ik_child_uuid:
			child_override = ik_child_local
		_evaluate_bone_fk(child_uuid, frame, child_override)


# ── Drawing ────────────────────────────────────────────────────────

func _draw() -> void:
	if rig == null:
		return

	# Sort bones by per-frame partSortOrder if set, else by their
	# sortOrder field. Lower draws first (behind).
	var draw_order: Array = []
	for uuid in _bone_by_uuid:
		var bone: Dictionary = _bone_by_uuid[uuid]
		draw_order.append({"uuid": uuid, "key": _sort_key_for_bone(uuid, bone)})
	draw_order.sort_custom(func(a, b): return int(a.key) < int(b.key))

	# Debug skeleton lines are a diagnostic view, not a fallback per
	# bone: draw them only when NOTHING is bound (the "did my rig
	# load?" case) or when the editor explicitly asks. A rigged
	# character always has structural helper bones with no part
	# (shoulder/hip connectors) — drawing debug for just those painted
	# stray joints/lines over the finished art in-game.
	var any_bound := not sprite_bindings.is_empty()
	for entry in draw_order:
		var uuid: String = entry.uuid
		var bone: Dictionary = _bone_by_uuid[uuid]
		var pose: Dictionary = _pose_by_uuid.get(uuid, {})
		if pose.is_empty():
			continue
		if _shaded_sprites.has(uuid):
			continue  # Rendered by its shaded child Sprite2D.
		var texture: Texture2D = _texture_for_bone(uuid, bone)
		if texture != null:
			_draw_bone_sprite(bone, pose, texture)
		elif (
			not any_bound
			or (Engine.is_editor_hint() and draw_bones_in_editor)
		):
			_draw_bone_debug(pose)


func _sort_key_for_bone(uuid: String, bone: Dictionary) -> int:
	# Sort key priority: per-frame keyframe override > part's base
	# sortOrder (v1.2) > bone.sort_order (legacy fallback).
	# Bone.sort_order is bone-list ordering and gets parts wrong
	# whenever the artist set part.sortOrder independently (e.g. both
	# arms on top of chest because all bones share sort_order = 0 but
	# the parts have distinct values). Shared by the unshaded draw
	# order and the shaded children's z_index.
	var part_sort: Variant = _interpolated_part_sort_order(uuid)
	if part_sort != null:
		return int(part_sort)
	if bone.get("part_base_sort_order") != null:
		return int(bone.part_base_sort_order)
	return int(bone.sort_order)


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
	# The bodyRect is drawn with the part's pivot at the origin of its
	# own local coords — so pixels above/left of the pivot have
	# negative coords, pixels below/right have positive. This is what
	# makes draw_set_transform_matrix(world, rotation) put the pivot
	# at pivot_world automatically. The shaded-children path shares
	# the same math: Sprite2D with centered=false, offset=-pivot_px,
	# transform=_part_transform_v1_2.
	var pivot_px := _part_pivot_px(bone)
	var body_rect := Rect2(
		-pivot_px,
		Vector2(float(bone.part_width), float(bone.part_height)),
	)
	draw_set_transform_matrix(_part_transform_v1_2(bone, pose))
	draw_texture_rect(texture, body_rect, false)
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _part_pivot_px(bone: Dictionary) -> Vector2:
	return Vector2(
		float(bone.part_width) * float(bone.part_pivot_x),
		float(bone.part_height) * float(bone.part_pivot_y),
	)


func _part_transform_v1_2(bone: Dictionary, pose: Dictionary) -> Transform2D:
	# Spec §10.3 placement for v1.2 rigs: pivot-anchored, with the
	# bone-local rest offset rotated by the delta between current and
	# rest world rotation. Mirrors puppet_view._computePlacement in
	# the AniManager source, so sprites land where the artist saw
	# them on the tablet.
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

	var xf := Transform2D(part_world_rotation, pivot_world)
	if bone.part_flip_y:
		# Mirror across the BONE AXIS through the bone's start joint —
		# the app's Flip Part semantics (re-use one asset on both body
		# sides; the limb direction is preserved, only the cross-
		# section flips). A naive local Y-flip about the part pivot
		# mirrors about the wrong line entirely. Mirrors the reference
		# math in bone_canvas._drawParts.
		var cos_f := cos(part_world_rotation)
		var sin_f := sin(part_world_rotation)
		var bs_pre_x := -(rot_rest_off_x + rot_part_off_x)
		var bs_pre_y := -(rot_rest_off_y + rot_part_off_y)
		var bs := Vector2(
			bs_pre_x * cos_f + bs_pre_y * sin_f,
			-bs_pre_x * sin_f + bs_pre_y * cos_f,
		)
		var bone_angle_in_frame := (
			float(bone.rest_world_rotation) - float(bone.part_rotation_offset)
		)
		xf = xf.translated_local(bs)
		xf = xf.rotated_local(bone_angle_in_frame)
		xf = xf.scaled_local(Vector2(1.0, -1.0))
		xf = xf.rotated_local(-bone_angle_in_frame)
		xf = xf.translated_local(-bs)
	if bone.part_flip_x:
		xf = xf.scaled_local(Vector2(-1.0, 1.0))
	return xf


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
