extends Node2D
## Interactive tuning playground for AniManager rigs (2026-08-30).
##
## Launch it as a scene (F6 in the editor, or:
##   godot --path . res://addons/animanager/playground/playground.tscn
## ) and use Load Rig to open any .animrig / .rig / .tres in the
## project. Live sliders drive the node's exported properties — cloth
## physics (stiffness / damping / inertia), shading (metal tint,
## light direction — move it to see the height-map normals respond),
## and playback speed — while the clip loops.
##
## Exciting the cloth: Auto-sway bobs the rig side to side; you can
## also DRAG the character with the mouse to yank it around, and Flip
## mirrors the facing (exercises the sim's flip reset).
##
## Env hooks (headless verification / scripting):
##   AM_PLAYGROUND_RIG   res:// path of a rig to load at boot
##   AM_PLAYGROUND_SHOT  save a PNG here ~1.2 s after boot, then quit

var _ani: AniAnimationPlayer2D
var _panel: VBoxContainer
var _dialog: FileDialog
var _readout: Label
var _sway: bool = true
var _sway_t: float = 0.0
var _dragging: bool = false
var _base_pos: Vector2
# Click-hold virtual joystick (2026-09-20): direct cursor-following
# transferred every mouse jitter straight into the cloth sim and
# read as violent. Instead, the click point becomes a stick center
# and cursor deflection from it drives a smooth capped velocity.
var _drag_origin: Vector2 = Vector2.ZERO
var _drag_current: Vector2 = Vector2.ZERO
# Per-section reset support (2026-09-20): sliders/toggles register
# themselves with their default; _header closes the previous
# section with a small "Reset section" button that restores those
# controls (setting the control re-fires its signal, so the node
# properties and labels update through the normal path).
var _section_controls: Array = []
# Named presets (2026-09-20): every slider/toggle also registers in a
# label-keyed map; Save snapshots their live values to a JSON at
# user://playground_presets.json, Load pushes values back through
# the controls (signals re-fire, so everything applies + labels
# update — same mechanism as the section resets).
var _all_controls: Dictionary = {}
var _preset_name: LineEdit
var _preset_pick: OptionButton
const PRESETS_PATH := "user://playground_presets.json"
# Weapon attachment fitting (2026-09-20): freeze the pose, drag +
# rotate a weapon PNG into the hand, then Save computes the
# transform RELATIVE TO THE HAND BONE — which makes it valid for
# every clip, since the runtime re-derives the weapon's placement
# from the bone's evaluated transform each frame (the live follow
# after saving demonstrates exactly what the game will do).
var _weapon: Sprite2D
var _weapon_pick: OptionButton
var _bone_pick: OptionButton
var _attach_mode := false
var _attach_btn: Button
var _follow: Dictionary = {}  # bone / offset_x/y / rotation / scale
const WEAPONS_DIR := "res://assets/weapons"
const ATTACH_PATH := "user://weapon_attachment.json"
const DRAG_SPEED_PER_PX := 4.0  # px/s of motion per px of deflection
const DRAG_MAX_DEFLECT := 150.0


func _ready() -> void:
	_ani = AniAnimationPlayer2D.new()
	_ani.scale = Vector2(3, 3)
	_ani.shaded = true
	_ani.zero_root_translate = true
	add_child(_ani)
	_center_rig()
	_build_ui()
	get_viewport().size_changed.connect(_center_rig)

	_load_attachment()
	var env_rig := OS.get_environment("AM_PLAYGROUND_RIG")
	if env_rig != "":
		_load_rig(env_rig)
	var shot := OS.get_environment("AM_PLAYGROUND_SHOT")
	if shot != "":
		_take_shot(shot)


func _center_rig() -> void:
	var vp := get_viewport_rect().size
	_base_pos = Vector2(vp.x * 0.38, vp.y * 0.55)
	if not _dragging:
		_ani.position = _base_pos


func _process(delta: float) -> void:
	if _sway and not _dragging:
		_sway_t += delta
		_ani.position = _base_pos + Vector2(sin(_sway_t * 2.2) * 90.0, 0)
	elif _dragging and not _attach_mode:
		var stick := (_drag_current - _drag_origin).limit_length(
			DRAG_MAX_DEFLECT)
		_ani.position += stick * DRAG_SPEED_PER_PX * delta
	# Live weapon follow: re-derive placement from the hand bone's
	# evaluated transform every frame — what the game will do.
	if _weapon != null and not _attach_mode and not _follow.is_empty():
		var t := _ani.get_bone_world_transform(String(_follow.bone))
		_weapon.position = t * Vector2(
			float(_follow.offset_x), float(_follow.offset_y))
		_weapon.rotation = t.get_rotation() + float(_follow.rotation)
		_weapon.scale = Vector2(float(_follow.scale), float(_follow.scale))
	_update_readout()


func _unhandled_input(event: InputEvent) -> void:
	# Drag the character around to feel the cloth react to real motion.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if _dragging:
			_drag_origin = event.position
			_drag_current = event.position
	elif event is InputEventMouseMotion and _dragging:
		_drag_current = event.position
		# Attach mode: the drag moves the WEAPON, in rig-local units
		# (signed division handles zoom AND the facing flip).
		if _attach_mode and _weapon != null:
			_weapon.position += Vector2(
				event.relative.x / _ani.scale.x,
				event.relative.y / _ani.scale.y)


# ── UI ─────────────────────────────────────────────────────────────

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	scroll.custom_minimum_size = Vector2(340, 0)
	scroll.anchor_bottom = 1.0
	scroll.offset_left = -340
	layer.add_child(scroll)

	var bg := PanelContainer.new()
	bg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(bg)
	_panel = VBoxContainer.new()
	_panel.add_theme_constant_override("separation", 6)
	bg.add_child(_panel)

	_button("Load Rig...", _pick_rig)
	_readout = Label.new()
	_readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_readout.add_theme_font_size_override("font_size", 12)
	_panel.add_child(_readout)

	_header("Presets")
	_preset_name = LineEdit.new()
	_preset_name.placeholder_text = "Preset name..."
	_panel.add_child(_preset_name)
	_button("Save current settings", _save_preset)
	_preset_pick = OptionButton.new()
	_panel.add_child(_preset_pick)
	_refresh_preset_list()
	_button("Load selected", _load_preset)
	_button("Delete selected", _delete_preset)

	_header("Playback")
	_slider("Zoom", 0.5, 10.0, 3.0, func(v: float) -> void:
		# Preserve the facing flip (scale.x sign).
		_ani.scale = Vector2(v * signf(_ani.scale.x), v))
	_slider("Speed", 0.1, 3.0, 1.0, func(v: float) -> void: _ani.speed = v)
	_toggle("Auto-sway (excite cloth)", true,
		func(v: bool) -> void: _sway = v)
	_button("Flip facing", func() -> void: _ani.scale.x = -_ani.scale.x)

	_header("Cloth physics")
	_toggle("Enabled", true, func(v: bool) -> void: _ani.cloth_enabled = v)
	_slider("Stiffness", 0.01, 0.6, _ani.cloth_stiffness,
		func(v: float) -> void: _ani.cloth_stiffness = v)
	_slider("Damping", 0.0, 0.9, _ani.cloth_damping,
		func(v: float) -> void: _ani.cloth_damping = v)
	_slider("Inertia", 0.0, 4.0, _ani.cloth_inertia,
		func(v: float) -> void: _ani.cloth_inertia = v)

	_header("Hair physics")
	_slider("Hair stiffness", 0.01, 1.0, _ani.hair_stiffness,
		func(v: float) -> void: _ani.hair_stiffness = v)
	_slider("Hair damping", 0.0, 0.9, _ani.hair_damping,
		func(v: float) -> void: _ani.hair_damping = v)
	_slider("Hair inertia", 0.0, 4.0, _ani.hair_inertia,
		func(v: float) -> void: _ani.hair_inertia = v)

	_header("Limb sway (flyers)")
	_toggle("Sway legs (leg/foot bones)", false, func(v: bool) -> void:
		var kws := PackedStringArray(["leg", "foot"]) if v else PackedStringArray()
		_ani.limb_bone_keywords = kws)
	_slider("Limb stiffness", 0.01, 1.0, _ani.limb_stiffness,
		func(v: float) -> void: _ani.limb_stiffness = v)
	_slider("Limb damping", 0.0, 0.9, _ani.limb_damping,
		func(v: float) -> void: _ani.limb_damping = v)
	_slider("Limb inertia", 0.0, 4.0, _ani.limb_inertia,
		func(v: float) -> void: _ani.limb_inertia = v)

	_header("Weapon")
	_weapon_pick = OptionButton.new()
	_panel.add_child(_weapon_pick)
	_refresh_weapon_list()
	_weapon_pick.item_selected.connect(func(_i: int) -> void: _spawn_weapon())
	_bone_pick = OptionButton.new()
	_panel.add_child(_bone_pick)
	_attach_btn = Button.new()
	_attach_btn.text = "Attach mode (freeze + drag weapon)"
	_attach_btn.toggle_mode = true
	_attach_btn.toggled.connect(_set_attach_mode)
	_panel.add_child(_attach_btn)
	_slider("Weapon rotation (deg)", -180.0, 180.0, 0.0,
		func(v: float) -> void:
			if _weapon != null and _attach_mode:
				_weapon.rotation_degrees = v)
	_slider("Weapon scale", 0.1, 4.0, 1.0,
		func(v: float) -> void:
			if _weapon != null and _attach_mode:
				_weapon.scale = Vector2(v, v))
	_button("Save attachment", _save_attachment)

	_header("Shading (material + height)")
	_toggle("Shaded", true, func(v: bool) -> void: _ani.shaded = v)
	_slider("Metal tint", 0.0, 3.0, _ani.metal_tint,
		func(v: float) -> void: _ani.metal_tint = v)
	_slider("Light X", -1.0, 1.0, _ani.light_direction.x,
		func(v: float) -> void: _set_light(0, v))
	_slider("Light Y", -1.0, 1.0, _ani.light_direction.y,
		func(v: float) -> void: _set_light(1, v))
	_slider("Light Z (height depth)", 0.1, 1.5, _ani.light_direction.z,
		func(v: float) -> void: _set_light(2, v))

	_end_section()

	_dialog = FileDialog.new()
	_dialog.access = FileDialog.ACCESS_RESOURCES
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dialog.filters = ["*.animrig, *.rig, *.tres ; AniManager rigs"]
	_dialog.current_dir = "res://animations" if DirAccess.dir_exists_absolute(
		"res://animations") else "res://"
	_dialog.file_selected.connect(_load_rig)
	layer.add_child(_dialog)


func _refresh_weapon_list() -> void:
	_weapon_pick.clear()
	var dir := DirAccess.open(WEAPONS_DIR)
	if dir == null:
		_weapon_pick.add_item("(no assets/weapons folder)")
		return
	for f in dir.get_files():
		if f.get_extension().to_lower() == "png":
			_weapon_pick.add_item(f)
	if _weapon_pick.item_count == 0:
		_weapon_pick.add_item("(drop PNGs in assets/weapons)")


func _refresh_bone_list() -> void:
	_bone_pick.clear()
	if _ani.rig == null:
		return
	var hands := []
	var others := []
	for bone in _ani.rig.bones:
		var n := String(bone.get("name", ""))
		if n.is_empty():
			continue
		if n.containsn("hand"):
			hands.append(n)
		else:
			others.append(n)
	for n in hands + others:
		_bone_pick.add_item(n)


func _spawn_weapon() -> void:
	var fname := _weapon_pick.get_item_text(_weapon_pick.selected)
	if not fname.ends_with(".png"):
		return
	var tex: Texture2D = load(WEAPONS_DIR + "/" + fname)
	if tex == null:
		return
	if _weapon == null:
		_weapon = Sprite2D.new()
		_ani.add_child(_weapon)
	_weapon.texture = tex
	if _follow.is_empty():
		_weapon.position = Vector2.ZERO
		_weapon.rotation = 0.0


func _set_attach_mode(on: bool) -> void:
	_attach_mode = on
	if on:
		if _weapon == null:
			_spawn_weapon()
		_sway = false
		_ani.pause()
	else:
		_ani.play()


func _save_attachment() -> void:
	if _weapon == null or _bone_pick.selected < 0:
		return
	var bone := _bone_pick.get_item_text(_bone_pick.selected)
	var t := _ani.get_bone_world_transform(bone)
	var local_off := t.affine_inverse() * _weapon.position
	var local_rot := _weapon.rotation - t.get_rotation()
	_follow = {
		"weapon": _weapon_pick.get_item_text(_weapon_pick.selected),
		"bone": bone,
		"offset_x": local_off.x,
		"offset_y": local_off.y,
		"rotation": local_rot,
		"scale": _weapon.scale.x,
	}
	var f := FileAccess.open(ATTACH_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(_follow, "  "))
	_attach_btn.button_pressed = false  # exits attach mode -> live follow


func _load_attachment() -> void:
	if not FileAccess.file_exists(ATTACH_PATH):
		return
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(ATTACH_PATH))
	if not parsed is Dictionary:
		return
	_follow = parsed
	for i in range(_weapon_pick.item_count):
		if _weapon_pick.get_item_text(i) == String(_follow.get("weapon", "")):
			_weapon_pick.select(i)
	_spawn_weapon()


func _read_presets() -> Dictionary:
	if not FileAccess.file_exists(PRESETS_PATH):
		return {}
	var txt := FileAccess.get_file_as_string(PRESETS_PATH)
	var parsed: Variant = JSON.parse_string(txt)
	return parsed if parsed is Dictionary else {}


func _write_presets(presets: Dictionary) -> void:
	var f := FileAccess.open(PRESETS_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(presets, "  "))


func _refresh_preset_list() -> void:
	_preset_pick.clear()
	for preset_name in _read_presets().keys():
		_preset_pick.add_item(String(preset_name))


func _save_preset() -> void:
	var preset_name := _preset_name.text.strip_edges()
	if preset_name.is_empty():
		return
	var values := {}
	for label in _all_controls:
		var ctrl: Control = _all_controls[label]
		if ctrl is HSlider:
			values[label] = (ctrl as HSlider).value
		elif ctrl is CheckBox:
			values[label] = (ctrl as CheckBox).button_pressed
	var presets := _read_presets()
	presets[preset_name] = values
	_write_presets(presets)
	_refresh_preset_list()
	for i in range(_preset_pick.item_count):
		if _preset_pick.get_item_text(i) == preset_name:
			_preset_pick.select(i)


func _load_preset() -> void:
	if _preset_pick.selected < 0:
		return
	var presets := _read_presets()
	var values: Variant = presets.get(
		_preset_pick.get_item_text(_preset_pick.selected))
	if not values is Dictionary:
		return
	for label in (values as Dictionary):
		var ctrl: Control = _all_controls.get(label)
		if ctrl is HSlider:
			(ctrl as HSlider).value = float(values[label])
		elif ctrl is CheckBox:
			(ctrl as CheckBox).button_pressed = bool(values[label])


func _delete_preset() -> void:
	if _preset_pick.selected < 0:
		return
	var presets := _read_presets()
	presets.erase(_preset_pick.get_item_text(_preset_pick.selected))
	_write_presets(presets)
	_refresh_preset_list()


func _end_section() -> void:
	if _section_controls.is_empty():
		return
	var captured := _section_controls.duplicate()
	_section_controls = []
	var b := Button.new()
	b.text = "Reset section"
	b.add_theme_font_size_override("font_size", 11)
	b.pressed.connect(func() -> void:
		for pair in captured:
			if pair[0] is HSlider:
				(pair[0] as HSlider).value = pair[1]
			elif pair[0] is CheckBox:
				(pair[0] as CheckBox).button_pressed = pair[1])
	_panel.add_child(b)


func _header(text: String) -> void:
	_end_section()
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0))
	_panel.add_child(l)


func _slider(
	label_text: String, mn: float, mx: float, value: float, on_change: Callable
) -> void:
	var row := VBoxContainer.new()
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 12)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = 0.01
	s.value = value
	s.custom_minimum_size = Vector2(300, 0)
	var update := func(v: float) -> void:
		l.text = "%s: %.2f" % [label_text, v]
		on_change.call(v)
	s.value_changed.connect(update)
	update.call(value)
	row.add_child(s)
	_panel.add_child(row)
	_section_controls.append([s, value])
	_all_controls[label_text] = s


func _toggle(text: String, initial: bool, on_change: Callable) -> void:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = initial
	c.toggled.connect(on_change)
	_panel.add_child(c)
	_section_controls.append([c, initial])
	_all_controls[text] = c


func _button(text: String, on_press: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.pressed.connect(on_press)
	_panel.add_child(b)


func _pick_rig() -> void:
	_dialog.popup_centered_ratio(0.7)


func _load_rig(path: String) -> void:
	var res := load(path)
	if res is AniRigResource:
		_ani.rig = res
		_ani.loop_override = 1  # playground always loops, even one-shots
		_ani.set_current_frame(0.0)
		_ani.play()
		_refresh_bone_list()


func _set_light(axis: int, v: float) -> void:
	var d := _ani.light_direction
	d[axis] = v
	_ani.light_direction = d


func _update_readout() -> void:
	if _ani.rig == null:
		_readout.text = "No rig loaded. Load one, then drag the character\naround to feel the cloth."
		return
	var counts := {0: 0, 1: 0, 2: 0}
	for cls in _ani._cloth_uuids.values():
		counts[int(cls)] = int(counts.get(int(cls), 0)) + 1
	_readout.text = (
		"sim bones — cloth: %d · hair: %d · limbs: %d\n"
		% [counts[0], counts[1], counts[2]]
		+ "cloth_stiffness = %.2f\ncloth_damping = %.2f\ncloth_inertia = %.2f\n"
		% [_ani.cloth_stiffness, _ani.cloth_damping, _ani.cloth_inertia]
		+ "hair_stiffness = %.2f\nhair_damping = %.2f\nhair_inertia = %.2f\n"
		% [_ani.hair_stiffness, _ani.hair_damping, _ani.hair_inertia]
		+ "metal_tint = %.2f  light = (%.2f, %.2f, %.2f)\n"
		% [
			_ani.metal_tint,
			_ani.light_direction.x,
			_ani.light_direction.y,
			_ani.light_direction.z,
		]
		+ "(copy these into your scene/config when happy)"
	)
	if not _follow.is_empty():
		_readout.text += (
			"\nATTACH %s -> %s off=(%.1f, %.1f) rot=%.1f deg scale=%.2f"
			% [
				_follow.get("weapon"), _follow.get("bone"),
				float(_follow.get("offset_x", 0)),
				float(_follow.get("offset_y", 0)),
				rad_to_deg(float(_follow.get("rotation", 0))),
				float(_follow.get("scale", 1)),
			]
		)


func _take_shot(path: String) -> void:
	await get_tree().create_timer(1.2).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	get_tree().quit()
