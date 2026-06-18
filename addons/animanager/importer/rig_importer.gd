@tool
extends EditorImportPlugin

# EditorImportPlugin: turns .rig and .animrig files (drag in,
# autoimport, etc.) into AniRigResource .tres files. Once imported,
# point an AniAnimationPlayer2D node's `rig` property at the resource.
#
# Two source shapes are handled:
#   - .rig: a single JSON file. Companion sprite art (if any) lives
#     in a sister `<name>.parts/` directory.
#   - .animrig: a ZIP bundle containing `manifest.rig` plus
#     `parts/<bone_name>.png` entries. Textures are extracted at
#     import time and embedded on the resource as sprite_textures,
#     so the runtime auto-binds without needing a separate folder.

const AniRigResource := preload("res://addons/animanager/resource/ani_rig_resource.gd")

# ── Importer registration ──────────────────────────────────────────

func _get_importer_name() -> String:
	return "animanager.rig"


func _get_visible_name() -> String:
	return "AniManager Rig"


func _get_recognized_extensions() -> PackedStringArray:
	return PackedStringArray(["rig", "animrig"])


func _get_save_extension() -> String:
	return "tres"


func _get_resource_type() -> String:
	return "Resource"


func _get_priority() -> float:
	return 1.0


func _get_import_order() -> int:
	return 0


func _get_preset_count() -> int:
	return 1


func _get_preset_name(_index: int) -> String:
	return "Default"


func _get_import_options(_path: String, _preset_index: int) -> Array[Dictionary]:
	return []


func _get_option_visibility(_path: String, _option: StringName, _options: Dictionary) -> bool:
	return true


# ── Actual import ──────────────────────────────────────────────────

func _import(
	source_file: String,
	save_path: String,
	_options: Dictionary,
	_platform_variants: Array[String],
	_gen_files: Array[String]
) -> Error:
	# Two branches: .animrig is a ZIP bundle; .rig is a bare JSON file.
	# The bundle path additionally extracts sprite textures from
	# parts/*.png so they're embedded on the resource — runtime
	# auto-binds with no folder field required.
	var manifest_text: String = ""
	var bundled_textures := {}
	if source_file.get_extension().to_lower() == "animrig":
		var reader := ZIPReader.new()
		if reader.open(source_file) != OK:
			push_error("AniManager: could not open .animrig %s" % source_file)
			return FAILED
		if not reader.file_exists("manifest.rig"):
			push_error("AniManager: .animrig missing manifest.rig entry")
			reader.close()
			return FAILED
		manifest_text = reader.read_file("manifest.rig").get_string_from_utf8()
		# Pull each parts/<bone_name>.png entry into an ImageTexture
		# keyed by the basename (matching the bone's name). The runtime
		# uses the same name → texture mapping the folder-based
		# auto-bind does, so the runtime code path stays unified.
		for entry in reader.get_files():
			if not entry.begins_with("parts/"):
				continue
			if not entry.to_lower().ends_with(".png"):
				continue
			var png_bytes := reader.read_file(entry)
			var img := Image.new()
			if img.load_png_from_buffer(png_bytes) != OK:
				push_warning("AniManager: failed to decode %s" % entry)
				continue
			var bone_name := entry.substr(6, entry.length() - 6 - 4)  # strip "parts/" and ".png"
			bundled_textures[bone_name] = ImageTexture.create_from_image(img)
		reader.close()
	else:
		var file := FileAccess.open(source_file, FileAccess.READ)
		if file == null:
			push_error("AniManager: could not open .rig file %s" % source_file)
			return FAILED
		manifest_text = file.get_as_text()
		file.close()

	var json := JSON.new()
	var err := json.parse(manifest_text)
	if err != OK:
		push_error("AniManager: .rig JSON parse failed: %s" % json.get_error_message())
		return FAILED

	var data: Variant = json.data
	if typeof(data) != TYPE_DICTIONARY:
		push_error("AniManager: .rig root is not a JSON object")
		return FAILED

	# Spec §3 guard rails.
	if data.get("kind", "") != "animanager.rig":
		push_error("AniManager: file rejected — kind != \"animanager.rig\"")
		return FAILED
	var format_version: int = int(data.get("formatVersion", 0))
	if format_version <= 0 or format_version > 1:
		push_error(
			"AniManager: unsupported formatVersion %d (this plugin supports 1)" %
				format_version
		)
		return FAILED

	var resource := AniRigResource.new()
	var anim: Dictionary = data.get("animation", {})
	resource.format_version = format_version
	resource.animation_uuid = anim.get("uuid", "")
	resource.animation_name = anim.get("name", "")
	resource.frame_rate = int(anim.get("frameRate", 24))
	resource.total_frames = int(anim.get("totalFrames", 1))
	resource.is_looping = anim.get("isLooping", true)

	# Bones: rename JSON camelCase → snake_case so downstream GDScript
	# stays idiomatic. Keep every field — runtime needs `length`,
	# `min_rotation`, etc. even if some get used later.
	resource.bones = []
	for raw in data.get("skeleton", []):
		var bone: Dictionary = raw
		resource.bones.append({
			"uuid": bone.get("uuid", ""),
			"name": bone.get("name", ""),
			"parent_uuid": bone.get("parentBoneUuid"),
			"start_x": float(bone.get("startX", 0.0)),
			"start_y": float(bone.get("startY", 0.0)),
			"end_x": float(bone.get("endX", 0.0)),
			"end_y": float(bone.get("endY", 0.0)),
			"length": float(bone.get("length", 0.0)),
			"rotation": float(bone.get("rotation", 0.0)),
			"sort_order": int(bone.get("sortOrder", 0)),
			"part_rotation_offset": float(bone.get("partRotationOffset", 0.0)),
			"part_flip_x": bone.get("partFlipX", false),
			"part_flip_y": bone.get("partFlipY", false),
			"connect_to_parent_start": bone.get("connectToParentStart", false),
			"root_joint_at_start": bone.get("rootJointAtStart", true),
			"part_offset_x": float(bone.get("partOffsetX", 0.0)),
			"part_offset_y": float(bone.get("partOffsetY", 0.0)),
			"min_rotation": bone.get("minRotation"),
			"max_rotation": bone.get("maxRotation"),
			# v1.2 optional part-render hints. Pass through as null
			# when absent so _draw_bone_sprite can detect them with
			# `bone.part_width != null` and fall back to the legacy
			# centered-on-pivot path for older rigs.
			"part_width": bone.get("partWidth"),
			"part_height": bone.get("partHeight"),
			"part_pivot_x": bone.get("partPivotX"),
			"part_pivot_y": bone.get("partPivotY"),
			"part_rest_offset_x": bone.get("partRestOffsetX"),
			"part_rest_offset_y": bone.get("partRestOffsetY"),
			"rest_world_rotation": bone.get("restWorldRotation"),
			"part_base_sort_order": bone.get("partBaseSortOrder"),
		})

	# Keyframes: same rename. ik_target_x/y are sentinel NAN when
	# absent so the evaluator can detect "no IK target on this frame"
	# without a separate has_x map.
	resource.keyframes = []
	for raw in data.get("keyframes", []):
		var kf: Dictionary = raw
		resource.keyframes.append({
			"bone_uuid": kf.get("boneUuid", ""),
			"frame_number": int(kf.get("frameNumber", 0)),
			"rotation": float(kf.get("rotation", 0.0)),
			"translate_x": float(kf.get("translateX", 0.0)),
			"translate_y": float(kf.get("translateY", 0.0)),
			"scale_x": float(kf.get("scaleX", 1.0)),
			"scale_y": float(kf.get("scaleY", 1.0)),
			"interpolation_type": String(kf.get("interpolationType", "linear")),
			"bezier_cp1_x": kf.get("bezierCP1X"),
			"bezier_cp1_y": kf.get("bezierCP1Y"),
			"bezier_cp2_x": kf.get("bezierCP2X"),
			"bezier_cp2_y": kf.get("bezierCP2Y"),
			"part_sort_order": kf.get("partSortOrder"),
			"ik_target_x": kf.get("ikTargetX", NAN),
			"ik_target_y": kf.get("ikTargetY", NAN),
		})

	# IK chains: optional v1.1.
	resource.ik_chains = []
	for raw in data.get("ikChains", []):
		var chain: Dictionary = raw
		resource.ik_chains.append({
			"child_bone_uuid": chain.get("childBoneUuid", ""),
			"target_x": float(chain.get("targetX", 0.0)),
			"target_y": float(chain.get("targetY", 0.0)),
			"pole_side": int(chain.get("poleSide", 1)),
			"enabled": chain.get("enabled", true),
		})

	# Frame events: optional v1.4. Flat list, multiple entries can
	# share a frame value. Payload is stored as a plain String
	# (possibly empty); the runtime hands it to listeners verbatim.
	resource.events = []
	for raw in data.get("events", []):
		var ev: Dictionary = raw
		resource.events.append({
			"frame": int(ev.get("frame", 0)),
			"name": String(ev.get("name", "")),
			"payload": String(ev.get("payload", "")),
		})

	# Embedded textures from a .animrig bundle. Empty dict for plain
	# .rig imports — the runtime falls back to the sprite_pack_folder
	# field on AniAnimationPlayer2D in that case.
	resource.sprite_textures = bundled_textures

	var output_path: String = "%s.%s" % [save_path, _get_save_extension()]
	return ResourceSaver.save(resource, output_path)
