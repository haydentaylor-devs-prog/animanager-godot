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


func _ready() -> void:
	_ani = AniAnimationPlayer2D.new()
	_ani.scale = Vector2(3, 3)
	_ani.shaded = true
	_ani.zero_root_translate = true
	add_child(_ani)
	_center_rig()
	_build_ui()
	get_viewport().size_changed.connect(_center_rig)

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
	_update_readout()


func _unhandled_input(event: InputEvent) -> void:
	# Drag the character around to feel the cloth react to real motion.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
	elif event is InputEventMouseMotion and _dragging:
		_ani.position += event.relative


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

	_dialog = FileDialog.new()
	_dialog.access = FileDialog.ACCESS_RESOURCES
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dialog.filters = ["*.animrig, *.rig, *.tres ; AniManager rigs"]
	_dialog.current_dir = "res://animations" if DirAccess.dir_exists_absolute(
		"res://animations") else "res://"
	_dialog.file_selected.connect(_load_rig)
	layer.add_child(_dialog)


func _header(text: String) -> void:
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


func _toggle(text: String, initial: bool, on_change: Callable) -> void:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = initial
	c.toggled.connect(on_change)
	_panel.add_child(c)


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


func _set_light(axis: int, v: float) -> void:
	var d := _ani.light_direction
	d[axis] = v
	_ani.light_direction = d


func _update_readout() -> void:
	if _ani.rig == null:
		_readout.text = "No rig loaded. Load one, then drag the character\naround to feel the cloth."
		return
	_readout.text = (
		"cloth_stiffness = %.2f\ncloth_damping = %.2f\ncloth_inertia = %.2f\n"
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


func _take_shot(path: String) -> void:
	await get_tree().create_timer(1.2).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	get_tree().quit()
