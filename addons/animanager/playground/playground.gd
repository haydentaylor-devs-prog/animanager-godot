extends Node2D
## AniMate Playground (2026-09-25 rework) — character-centric
## authoring bench for AniManager rigs.
##
## Flow: a MAIN MENU of created characters → per-character workspace
## with two modes:
##  - SANDBOX: the looping play-area + joystick, a persistent header
##    (return / name / mode / zoom / presets / playback), nav to
##    Physics / Shading / Weapon / Animation Layering sub-menus, and
##    the character's animrig list with per-rig override flags
##    (P/S/W), layer-group indicators, and rename.
##  - IN-GAME: assign an idle + per-rig keybinds, then play: idle
##    loops, bound keys crossfade to their clips while held.
##
## Everything autosaves to user://animate_playground.json (the
## working session survives any exit; named presets are snapshots
## on top). Open from the editor via Project → Tools →
## AniMate Playground, or run this scene (F6).
##
## Env hooks: AM_PLAYGROUND_RIG (auto-creates/enters a "Test"
## character with that rig), AM_PLAYGROUND_SHOT (screenshot + quit).

const Store := preload("res://addons/animanager/playground/playground_store.gd")

enum Screen { MENU, SANDBOX, INGAME }

# 560 fits the widest rows (rig 1x5, event editors) without the
# horizontal scrolling the old 400 forced (2026-09-26).
const PANEL_W := 560.0
const PANEL_TAB_W := 28.0
const FONT := 14
const FONT_HEAD := 17
const DRAG_SPEED_PER_PX := 3.0
const DRAG_MAX_DEFLECT := 100.0
const WEAPONS_DIR := "res://assets/weapons"
const VFX_DIR := "res://assets/vfx"
# Texel-AA shader for the weapon + effect sprites: they render at
# arbitrary fitted/slider scales (non-integer effective magnification)
# where plain nearest shimmers during slow sub-pixel motion — the
# "weapon jitters while the body is still" report (2026-09-26).
const CRISP_SHADER := preload(
	"res://addons/animanager/shaders/ani_crisp_sprite.gdshader")

var _store: Store
var _char_id := ""
var _screen: Screen = Screen.MENU
var _active_rig_path := ""
var _rig_cache: Dictionary = {}

var _ani: AniAnimationPlayer2D
var _joy: VirtualJoystick
var _weapon: Sprite2D
var _sway_t := 0.0
var _base_pos: Vector2

# UI roots
var _layer: CanvasLayer
var _menu_root: Control
var _work_root: Control
var _panel_tab: Button
var _panel_collapsed := false
var _content: VBoxContainer  # swapped area (home / submenu / ingame)
var _char_list_box: VBoxContainer
var _name_label: Label
var _sandbox_btn: Button
var _ingame_btn: Button
var _preset_pick: OptionButton
var _zoom_slider: HSlider
var _speed_slider: HSlider
var _sway_check: CheckBox
var _hold_frame_slider: HSlider
var _hold_secs_slider: HSlider
var _hold_waiting := false
var _hold_cooldown := false
var _preset_name_edit: LineEdit
var _readout: Label

# Weapon attach mode
var _attach_mode := false
var _attach_btn: Button
var _weapon_pick: OptionButton
var _weapon_bone_pick: OptionButton
var _dragging := false

# Layering / aim test state
var _layer_overlay_path := ""
var _layer_mask_pick: OptionButton
var _layer_hold := -1.0
var _layer_hold_secs := 0.0  # auto-release timer; 0 = manual release
var _aim_enabled := false
var _aim_weight := 1.0
var _aim_bone_pick: OptionButton

# In-game mode state
var _assigning_idle := false
var _capture_dialog: AcceptDialog
var _capture_label: Label
var _capture_rig_path := ""
var _captured_key := ""
var _held_bind_key := ""

var _dialog_layer: CanvasLayer

# Events & Effects (2026-09-26): per-character bindings from frame-
# event NAMES (auto-discovered from the character's rigs) to visual
# effects, previewed live in both modes. Types: projectile / burst /
# beam_on / beam_off.
var _events_expanded := ""  # event name whose editor is open
var _projectiles: Array = []  # [{node, vel, ttl}]
var _beam: Sprite2D
var _beam_cfg: Dictionary = {}
# Live beam length: jumps to max on fire, or grows from 0 at the
# binding's extend rate when its "gradual" flag is on (2026-09-26).
var _beam_len := 0.0
# Anchored spritesheet loops (charge-up effects): follow a bone +
# bone-local offset every frame, flip through sheet frames, die when
# their configured stop event fires.
var _loops: Array = []  # [{node, cfg, t}]


func _ready() -> void:
	# Run our _process AFTER the animation node's: the weapon (and
	# beam) follow bone transforms, and reading them before the
	# frame's pose evaluation left them one frame behind - a visible
	# pixel jitter against slow motion like an idle bob (2026-09-26).
	process_priority = 100
	# The playground drives every transform in _process (no physics),
	# but a consuming project may enable physics_interpolation
	# globally (angel-squadron does, for its HD-2D demo). Interpolating
	# process-driven transforms through 60Hz physics snapshots
	# temporally aliases slow motion - the weapon micro-jittered
	# against the idle bob whenever the node itself was stationary
	# (2026-09-26). No physics here, so interpolation is pure harm:
	# off for the whole subtree.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	get_window().title = "AniMate Playground"
	get_tree().set_auto_accept_quit(false)
	randomize()
	_store = Store.new()
	_store.load_store()

	_layer = CanvasLayer.new()
	add_child(_layer)
	_dialog_layer = CanvasLayer.new()
	_dialog_layer.layer = 5
	add_child(_dialog_layer)

	_build_menu_screen()
	_show_menu()
	get_viewport().size_changed.connect(_recenter)

	var env_rig := OS.get_environment("AM_PLAYGROUND_RIG")
	if env_rig != "":
		_env_boot(env_rig)
	var shot := OS.get_environment("AM_PLAYGROUND_SHOT")
	if shot != "":
		_take_shot(shot)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_store.save_store()
		get_tree().quit()


func _env_boot(rig_path: String) -> void:
	var target_id := ""
	for id in _store.characters():
		if _store.character(id).name == "Test":
			target_id = id
			break
	if target_id.is_empty():
		target_id = _store.create_character("Test")
	_enter_character(target_id)
	_store.add_rig(_char_id, rig_path)
	_rebuild_content()
	_activate_rig(rig_path)


# ── Main menu (character select) ───────────────────────────────────

func _build_menu_screen() -> void:
	_menu_root = PanelContainer.new()
	_menu_root.anchor_left = 0.5
	_menu_root.anchor_right = 0.5
	_menu_root.anchor_top = 0.5
	_menu_root.anchor_bottom = 0.5
	_menu_root.offset_left = -230
	_menu_root.offset_right = 230
	_menu_root.offset_top = -210
	_menu_root.offset_bottom = 210
	_layer.add_child(_menu_root)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	_menu_root.add_child(v)

	var title := Label.new()
	title.text = "AniMate Playground"
	title.add_theme_font_size_override("font_size", 24)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)

	var add_btn := Button.new()
	add_btn.text = "Add new character"
	add_btn.add_theme_font_size_override("font_size", FONT_HEAD)
	add_btn.pressed.connect(_prompt_new_character)
	v.add_child(add_btn)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(440, 300)
	v.add_child(scroll)
	_char_list_box = VBoxContainer.new()
	_char_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_char_list_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_char_list_box)


func _refresh_char_list() -> void:
	for child in _char_list_box.get_children():
		child.queue_free()
	var chars := _store.characters()
	for id in chars:
		var row := HBoxContainer.new()
		var play := Button.new()
		play.text = "▶"
		play.custom_minimum_size = Vector2(44, 0)
		var char_id: String = id
		play.pressed.connect(func() -> void: _enter_character(char_id))
		row.add_child(play)
		var nm := Label.new()
		nm.text = String(chars[id].name)
		nm.add_theme_font_size_override("font_size", FONT_HEAD)
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(nm)
		_char_list_box.add_child(row)


func _prompt_new_character() -> void:
	var d := AcceptDialog.new()
	d.title = "New character"
	d.ok_button_text = "Submit"
	var edit := LineEdit.new()
	edit.placeholder_text = "Character name..."
	edit.custom_minimum_size = Vector2(280, 0)
	d.add_child(edit)
	d.register_text_enter(edit)
	d.add_cancel_button("Cancel")
	d.confirmed.connect(func() -> void:
		var n := edit.text.strip_edges()
		if not n.is_empty():
			_store.create_character(n)
			_refresh_char_list()
		d.queue_free())
	d.canceled.connect(func() -> void: d.queue_free())
	_dialog_layer.add_child(d)
	d.popup_centered()
	edit.grab_focus()


func _show_menu() -> void:
	_screen = Screen.MENU
	_menu_root.visible = true
	if _work_root != null:
		_work_root.visible = false
	if _panel_tab != null:
		_panel_tab.visible = false
	if _ani != null:
		_ani.queue_free()
		_ani = null
		_weapon = null
	_beam_off()
	_loops_off()
	for pr in _projectiles:
		if is_instance_valid(pr.node):
			(pr.node as Node).queue_free()
	_projectiles = []
	if _joy != null:
		_joy.visible = false
	_refresh_char_list()


# ── Workspace (per character) ──────────────────────────────────────

func _enter_character(id: String) -> void:
	_char_id = id
	_screen = Screen.SANDBOX
	_active_rig_path = ""
	_menu_root.visible = false
	# Opening a character resumes its last loaded/saved preset — the
	# working session between visits is the preset, so tweaks NOT
	# saved on return (the "No" choice) are discarded here by design.
	var cur := String(_char().get("current_preset", ""))
	if not cur.is_empty() and (_char().presets as Dictionary).has(cur):
		_store.apply_snapshot(id, _char().presets[cur])

	_ani = AniAnimationPlayer2D.new()
	_ani.zero_root_translate = true
	add_child(_ani)
	_ani.animation_event.connect(_on_frame_event)
	_recenter()

	if _work_root == null:
		_build_workspace()
	_panel_tab.visible = true
	_apply_panel_state()
	if _joy == null:
		_joy = VirtualJoystick.new()
		_joy.anchor_top = 1.0
		_joy.anchor_bottom = 1.0
		_joy.offset_left = 48
		_joy.offset_right = 218
		_joy.offset_top = -218
		_joy.offset_bottom = -48
		_layer.add_child(_joy)
	_joy.visible = true

	_name_label.text = String(_store.character(id).name)
	_apply_mode_buttons()
	_refresh_presets()
	_apply_playback()
	_sync_playback_controls()
	# QOL (2026-09-26): a character with animations starts playing
	# their first one immediately instead of an empty play area.
	if not (_char().rigs as Array).is_empty():
		_activate_rig(String(_char().rigs[0].path))
	_rebuild_content()


func _build_workspace() -> void:
	_work_root = PanelContainer.new()
	_work_root.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_work_root.anchor_bottom = 1.0
	_work_root.offset_left = -PANEL_W
	_layer.add_child(_work_root)

	# Edge tab: sticks out of the panel's left edge and collapses the
	# whole panel into the right side of the screen (and back).
	_panel_tab = Button.new()
	_panel_tab.tooltip_text = "Collapse / expand the settings panel"
	_panel_tab.anchor_left = 1.0
	_panel_tab.anchor_right = 1.0
	_panel_tab.anchor_top = 0.5
	_panel_tab.anchor_bottom = 0.5
	_panel_tab.offset_top = -45
	_panel_tab.offset_bottom = 45
	_panel_tab.pressed.connect(func() -> void:
		_panel_collapsed = not _panel_collapsed
		_apply_panel_state())
	_layer.add_child(_panel_tab)
	_apply_panel_state()

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_work_root.add_child(scroll)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(PANEL_W - 20, 0)
	v.add_theme_constant_override("separation", 8)
	scroll.add_child(v)

	# ── Persistent header ──
	var ret := Button.new()
	ret.text = "◀ Return to character select"
	ret.add_theme_font_size_override("font_size", FONT)
	ret.pressed.connect(_prompt_save_and_return)
	v.add_child(ret)

	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", 22)
	v.add_child(_name_label)

	var modes := HBoxContainer.new()
	_sandbox_btn = Button.new()
	_sandbox_btn.text = "Sandbox Mode"
	_sandbox_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sandbox_btn.pressed.connect(func() -> void: _set_mode(Screen.SANDBOX))
	_ingame_btn = Button.new()
	_ingame_btn.text = "In-Game Mode"
	_ingame_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ingame_btn.pressed.connect(func() -> void: _set_mode(Screen.INGAME))
	modes.add_child(_sandbox_btn)
	modes.add_child(_ingame_btn)
	v.add_child(modes)

	_zoom_slider = _slider_into(v, "Zoom", 0.5, 10.0, 3.0,
		func(val: float) -> void:
			_char().playback.zoom = val
			_apply_playback()
			_store.save_store())

	_build_presets_section(v)
	_build_playback_section(v)

	var sep := HSeparator.new()
	v.add_child(sep)

	_readout = Label.new()
	_readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_readout.add_theme_font_size_override("font_size", 12)
	v.add_child(_readout)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 8)
	v.add_child(_content)


func _char() -> Dictionary:
	return _store.character(_char_id)


func _set_mode(mode: Screen) -> void:
	_screen = mode
	_held_bind_key = ""
	_assigning_idle = false
	_apply_mode_buttons()
	if mode == Screen.INGAME:
		_joy.visible = false
		# Play area empty until the idle is assigned.
		var idle: String = _char().ingame.idle
		if idle.is_empty() or _store.rig_entry(_char_id, idle).is_empty():
			_ani.rig = null
		else:
			_activate_rig(idle)
	else:
		_joy.visible = true
		if _active_rig_path.is_empty() and not (_char().rigs as Array).is_empty():
			_activate_rig(_char().rigs[0].path)
	_rebuild_content()


func _apply_mode_buttons() -> void:
	var blue := Color(0.3, 0.55, 1.0)
	_sandbox_btn.modulate = blue if _screen == Screen.SANDBOX else Color.WHITE
	_ingame_btn.modulate = blue if _screen == Screen.INGAME else Color.WHITE


func _prompt_save_and_return() -> void:
	var d := AcceptDialog.new()
	d.title = "Save your changes?"
	d.dialog_text = "Save the current settings to a preset before returning?"
	d.ok_button_text = "No"
	var overwrite := d.add_button("Overwrite current preset", false, "overwrite")
	var as_new := d.add_button("As new preset", false, "new")
	overwrite.add_theme_font_size_override("font_size", FONT)
	as_new.add_theme_font_size_override("font_size", FONT)
	d.confirmed.connect(func() -> void:
		d.queue_free()
		_show_menu())
	d.custom_action.connect(func(action: StringName) -> void:
		d.queue_free()
		if action == "overwrite":
			var cur: String = _char().current_preset
			_char().presets[cur] = _store.snapshot(_char_id)
			_store.save_store()
			_show_menu()
		elif action == "new":
			_prompt_preset_name(func(preset_name: String) -> void:
				_char().presets[preset_name] = _store.snapshot(_char_id)
				_char().current_preset = preset_name
				_store.save_store()
				_show_menu()))
	d.canceled.connect(func() -> void: d.queue_free())
	_dialog_layer.add_child(d)
	d.popup_centered()


func _prompt_preset_name(on_submit: Callable) -> void:
	var d := AcceptDialog.new()
	d.title = "Preset name"
	d.ok_button_text = "Submit"
	var edit := LineEdit.new()
	edit.custom_minimum_size = Vector2(260, 0)
	d.add_child(edit)
	d.register_text_enter(edit)
	d.add_cancel_button("Cancel")
	d.confirmed.connect(func() -> void:
		var n := edit.text.strip_edges()
		d.queue_free()
		if not n.is_empty():
			on_submit.call(n))
	d.canceled.connect(func() -> void: d.queue_free())
	_dialog_layer.add_child(d)
	d.popup_centered()
	edit.grab_focus()


# ── Presets + Playback (collapsible, persistent) ───────────────────

func _build_presets_section(parent: VBoxContainer) -> void:
	var box := _collapsible(parent, "Presets", true)
	_preset_name_edit = LineEdit.new()
	_preset_name_edit.placeholder_text = "Preset name..."
	box.add_child(_preset_name_edit)
	_btn_into(box, "Save new preset", func() -> void:
		var n := _preset_name_edit.text.strip_edges()
		if n.is_empty():
			return
		_char().presets[n] = _store.snapshot(_char_id)
		_char().current_preset = n
		_store.save_store()
		_refresh_presets())
	_btn_into(box, "Overwrite current preset", func() -> void:
		if _preset_pick.selected < 0:
			return
		var n := _preset_pick.get_item_text(_preset_pick.selected)
		_char().presets[n] = _store.snapshot(_char_id)
		_char().current_preset = n
		_store.save_store())
	_preset_pick = OptionButton.new()
	box.add_child(_preset_pick)
	_btn_into(box, "Load selected", func() -> void:
		if _preset_pick.selected < 0:
			return
		var n := _preset_pick.get_item_text(_preset_pick.selected)
		_store.apply_snapshot(_char_id, _char().presets.get(n, {}))
		_char().current_preset = n
		_store.save_store()
		_apply_playback()
		_sync_playback_controls()
		if not _active_rig_path.is_empty():
			_activate_rig(_active_rig_path)
		_rebuild_content())
	_btn_into(box, "Delete selected", func() -> void:
		if _preset_pick.selected < 0:
			return
		_char().presets.erase(_preset_pick.get_item_text(_preset_pick.selected))
		_store.save_store()
		_refresh_presets())


func _refresh_presets() -> void:
	_preset_pick.clear()
	var cur: String = _char().current_preset
	var i := 0
	for n in _char().presets:
		_preset_pick.add_item(String(n))
		if String(n) == cur:
			_preset_pick.select(i)
		i += 1


func _build_playback_section(parent: VBoxContainer) -> void:
	var box := _collapsible(parent, "Playback", true)
	_speed_slider = _slider_into(box, "Speed", 0.1, 3.0, 1.0,
		func(v: float) -> void:
			_char().playback.speed = v
			_apply_playback()
			_store.save_store())
	_sway_check = _toggle_into(box, "Auto-sway (excite physics)", false,
		func(v: bool) -> void:
			_char().playback.sway = v
			_store.save_store())
	# Charge-hold for PLAIN playback: park the active clip on this
	# frame for the duration below, as if the attack key were held —
	# lets a beam chargeup + hold be tested without setting up a
	# layer first (the Layering submenu has its own overlay hold).
	_hold_frame_slider = _int_slider_into(box, "Hold at frame (-1 = off)",
		-1.0, 119.0, -1.0, func(v: float) -> void:
			_char().playback.hold_frame = int(v)
			_store.save_store())
	_hold_secs_slider = _int_slider_into(box, "Hold seconds (-1 = forever)",
		-1.0, 10.0, 1.0, func(v: float) -> void:
			_char().playback.hold_secs = v
			_store.save_store())
	_btn_into(box, "Release hold now", func() -> void:
		if _hold_waiting and _ani != null:
			_hold_waiting = false
			_hold_cooldown = true
			_ani.play())
	_btn_into(box, "Flip facing", func() -> void:
		if _ani != null:
			_ani.scale.x = -_ani.scale.x)


# ── Content area: sandbox home / submenus / in-game ────────────────

func _rebuild_content() -> void:
	for child in _content.get_children():
		child.queue_free()
	if _screen == Screen.INGAME:
		_build_ingame_content()
	else:
		_build_sandbox_home()


func _build_sandbox_home() -> void:
	_btn_into(_content, "Physics Options", func() -> void: _show_submenu("physics"))
	_btn_into(_content, "Shading Options", func() -> void: _show_submenu("shading"))
	_btn_into(_content, "Weapon Menu", func() -> void: _show_submenu("weapon"))
	_btn_into(_content, "Animation Layering", func() -> void: _show_submenu("layering"))
	_btn_into(_content, "Events & Effects", func() -> void: _show_submenu("events"))
	var sep := HSeparator.new()
	_content.add_child(sep)
	var head := Label.new()
	head.text = "Animations"
	head.add_theme_font_size_override("font_size", FONT_HEAD)
	head.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0))
	_content.add_child(head)
	_btn_into(_content, "Add animation...", _prompt_add_rig)
	for r in _char().rigs:
		_content.add_child(_rig_row(r))


func _rig_row(r: Dictionary) -> Control:
	var wrap := PanelContainer.new()
	var v := VBoxContainer.new()
	wrap.add_child(v)
	var rig_path: String = r.path

	var name_btn := Button.new()
	name_btn.text = String(r.name)
	name_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_btn.add_theme_font_size_override("font_size", FONT)
	if rig_path == _active_rig_path:
		name_btn.modulate = Color(0.5, 0.8, 1.0)
	name_btn.pressed.connect(func() -> void:
		_activate_rig(rig_path)
		_rebuild_content())
	v.add_child(name_btn)

	var row := HBoxContainer.new()
	for domain in ["physics", "shading", "weapon"]:
		var b := Button.new()
		b.text = domain.substr(0, 1).to_upper()
		b.custom_minimum_size = Vector2(40, 0)
		var unique: bool = r.ovr.get(domain) is Dictionary
		b.modulate = Color(1.0, 0.6, 0.15) if unique else Color(0.3, 0.9, 0.4)
		b.tooltip_text = ("Unique settings for this animation" if unique
			else "Shared settings (tap to make unique)")
		var dom: String = domain
		b.pressed.connect(func() -> void: _toggle_override(rig_path, dom))
		row.add_child(b)

	var grp := Button.new()
	grp.custom_minimum_size = Vector2(40, 0)
	grp.disabled = true
	var overlays := _store.layers_of_base(_char_id, rig_path)
	if overlays.size() > 1:
		grp.text = "L"
		grp.modulate = Color(0.5, 0.75, 1.0)
	elif int(r.group) > 0:
		grp.text = str(int(r.group))
		grp.modulate = Color(0.5, 0.75, 1.0)
	else:
		grp.text = ""
		grp.modulate = Color(0.4, 0.4, 0.4)
	row.add_child(grp)

	var dots := MenuButton.new()
	dots.text = "⋮"
	dots.custom_minimum_size = Vector2(40, 0)
	dots.get_popup().add_item("Rename animation")
	dots.get_popup().id_pressed.connect(func(_id: int) -> void:
		_prompt_preset_name(func(new_name: String) -> void:
			_store.rig_entry(_char_id, rig_path).name = new_name
			_store.save_store()
			_rebuild_content()))
	row.add_child(dots)
	v.add_child(row)

	# Multi-layer parent: extra row listing each overlay's group.
	if overlays.size() > 1:
		var row2 := HBoxContainer.new()
		for l in overlays:
			var gb := Button.new()
			gb.text = str(int(l.group))
			gb.custom_minimum_size = Vector2(40, 0)
			gb.disabled = true
			gb.modulate = Color(0.5, 0.75, 1.0)
			row2.add_child(gb)
		v.add_child(row2)
	return wrap


func _toggle_override(rig_path: String, domain: String) -> void:
	var r := _store.rig_entry(_char_id, rig_path)
	if r.is_empty():
		return
	if r.ovr.get(domain) is Dictionary:
		var d := ConfirmationDialog.new()
		d.title = "Revert to shared?"
		d.dialog_text = "Drop this animation's unique %s settings and go back to shared?" % domain
		d.confirmed.connect(func() -> void:
			r.ovr[domain] = null
			_store.save_store()
			if rig_path == _active_rig_path:
				_apply_domain(domain)
			_rebuild_content()
			d.queue_free())
		d.canceled.connect(func() -> void: d.queue_free())
		_dialog_layer.add_child(d)
		d.popup_centered()
	else:
		# Unique starts as a copy of the current shared settings.
		r.ovr[domain] = (_char().shared[domain] as Dictionary).duplicate(true)
		_store.save_store()
		_rebuild_content()


func _prompt_add_rig() -> void:
	var d := FileDialog.new()
	d.access = FileDialog.ACCESS_RESOURCES
	d.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	d.filters = ["*.animrig, *.rig, *.tres ; AniManager rigs"]
	d.current_dir = "res://animations" if DirAccess.dir_exists_absolute(
		"res://animations") else "res://"
	d.file_selected.connect(func(path: String) -> void:
		_store.add_rig(_char_id, path)
		var res := _load_rig_res(path)
		if res != null:
			_store.adopt_legacy_weapon(_char_id, res)
		_activate_rig(path)
		_rebuild_content()
		d.queue_free())
	d.canceled.connect(func() -> void: d.queue_free())
	_dialog_layer.add_child(d)
	d.popup_centered_ratio(0.7)


# ── Sub-menus ──────────────────────────────────────────────────────

func _show_submenu(which: String) -> void:
	for child in _content.get_children():
		child.queue_free()
	_btn_into(_content, "◀ Back", func() -> void:
		_attach_set(false)
		_rebuild_content())
	var title := Label.new()
	title.text = {"physics": "Physics Options", "shading": "Shading Options",
		"weapon": "Weapon Menu", "layering": "Animation Layering",
		"events": "Events & Effects"}[which]
	title.add_theme_font_size_override("font_size", FONT_HEAD)
	title.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0))
	_content.add_child(title)
	var scope := Label.new()
	var r := _store.rig_entry(_char_id, _active_rig_path)
	var unique: bool = not r.is_empty() \
		and which != "layering" and which != "events" \
		and r.ovr.get(which) is Dictionary
	scope.text = ("Editing: UNIQUE to %s" % String(r.get("name", "?"))) if unique \
		else "Editing: shared (all animations)"
	scope.add_theme_font_size_override("font_size", 12)
	scope.modulate = Color(1.0, 0.7, 0.3) if unique else Color(0.5, 0.9, 0.5)
	_content.add_child(scope)
	match which:
		"physics":
			_build_physics_menu()
		"shading":
			_build_shading_menu()
		"weapon":
			_build_weapon_menu()
		"layering":
			_build_layering_menu()
		"events":
			_build_events_menu()


func _domain_target(domain: String) -> Dictionary:
	var r := _store.rig_entry(_char_id, _active_rig_path)
	if not r.is_empty() and r.ovr.get(domain) is Dictionary:
		return r.ovr[domain]
	return _char().shared[domain]


func _domain_edit(domain: String, key: String, value: Variant) -> void:
	_domain_target(domain)[key] = value
	_apply_domain(domain)
	_store.save_store()


func _build_physics_menu() -> void:
	var p := _domain_target("physics")
	_toggle_into(_content, "Physics enabled", bool(p.enabled),
		func(v: bool) -> void: _domain_edit("physics", "enabled", v))
	for spec in [
		["Cloth stiffness", "c_st", 0.01, 0.6], ["Cloth damping", "c_da", 0.0, 0.9],
		["Cloth inertia", "c_in", 0.0, 4.0],
		["Hair stiffness", "h_st", 0.01, 1.0], ["Hair damping", "h_da", 0.0, 0.9],
		["Hair inertia", "h_in", 0.0, 4.0],
	]:
		var key: String = spec[1]
		_slider_into(_content, spec[0], spec[2], spec[3], float(p[key]),
			func(v: float) -> void: _domain_edit("physics", key, v))
	_toggle_into(_content, "Limb sway (flyer legs)", bool(p.limbs),
		func(v: bool) -> void: _domain_edit("physics", "limbs", v))
	for spec in [
		["Limb stiffness", "l_st", 0.01, 1.0], ["Limb damping", "l_da", 0.0, 0.9],
		["Limb inertia", "l_in", 0.0, 4.0],
	]:
		var key: String = spec[1]
		_slider_into(_content, spec[0], spec[2], spec[3], float(p[key]),
			func(v: float) -> void: _domain_edit("physics", key, v))
	_btn_into(_content, "Reset physics to defaults", func() -> void:
		var t := _domain_target("physics")
		t.clear()
		t.merge(Store.default_physics())
		_apply_domain("physics")
		_store.save_store()
		_show_submenu("physics"))


func _build_shading_menu() -> void:
	var s := _domain_target("shading")
	_toggle_into(_content, "Shaded", bool(s.shaded),
		func(v: bool) -> void: _domain_edit("shading", "shaded", v))
	_slider_into(_content, "Metal tint", 0.0, 3.0, float(s.tint),
		func(v: float) -> void: _domain_edit("shading", "tint", v))
	_slider_into(_content, "Light X", -1.0, 1.0, float(s.lx),
		func(v: float) -> void: _domain_edit("shading", "lx", v))
	_slider_into(_content, "Light Y", -1.0, 1.0, float(s.ly),
		func(v: float) -> void: _domain_edit("shading", "ly", v))
	_slider_into(_content, "Light Z (height depth)", 0.1, 1.5, float(s.lz),
		func(v: float) -> void: _domain_edit("shading", "lz", v))
	_btn_into(_content, "Reset shading to defaults", func() -> void:
		var t := _domain_target("shading")
		t.clear()
		t.merge(Store.default_shading())
		_apply_domain("shading")
		_store.save_store()
		_show_submenu("shading"))


func _build_weapon_menu() -> void:
	_weapon_pick = OptionButton.new()
	_content.add_child(_weapon_pick)
	var dir := DirAccess.open(WEAPONS_DIR)
	if dir == null:
		_weapon_pick.add_item("(no assets/weapons folder)")
	else:
		for f in dir.get_files():
			if f.get_extension().to_lower() == "png":
				_weapon_pick.add_item(f)
		if _weapon_pick.item_count == 0:
			_weapon_pick.add_item("(drop PNGs in assets/weapons)")
	var w := _domain_target("weapon")
	for i in range(_weapon_pick.item_count):
		if _weapon_pick.get_item_text(i) == String(w.get("file", "")):
			_weapon_pick.select(i)
	_weapon_bone_pick = OptionButton.new()
	_content.add_child(_weapon_bone_pick)
	_fill_bone_pick(_weapon_bone_pick, "hand")
	for i in range(_weapon_bone_pick.item_count):
		if _weapon_bone_pick.get_item_text(i) == String(w.get("bone", "")):
			_weapon_bone_pick.select(i)
	_attach_btn = Button.new()
	_attach_btn.text = "Attach mode (freeze + drag weapon)"
	_attach_btn.toggle_mode = true
	_attach_btn.toggled.connect(_attach_set)
	_content.add_child(_attach_btn)
	_slider_into(_content, "Weapon rotation (deg)", -180.0, 180.0,
		rad_to_deg(float(w.get("rot", 0.0))), func(v: float) -> void:
			if _weapon != null and _attach_mode:
				_weapon.rotation_degrees = v)
	_slider_into(_content, "Weapon scale", 0.1, 4.0,
		float(w.get("scale", 1.0)), func(v: float) -> void:
			if _weapon != null and _attach_mode:
				_weapon.scale = Vector2(v, v))
	_toggle_into(_content, "Draw behind character",
		bool(w.get("behind", false)), func(v: bool) -> void:
			_domain_edit("weapon", "behind", v)
			_apply_weapon_layer())
	_btn_into(_content, "Save attachment", _save_attachment)
	_btn_into(_content, "Remove weapon", func() -> void:
		var t := _domain_target("weapon")
		t.clear()
		_apply_domain("weapon")
		_store.save_store())


func _build_layering_menu() -> void:
	var info := Label.new()
	info.text = "Base = the active animation (%s).\nPick an overlay to layer onto it:" \
		% (_active_rig_path.get_file() if not _active_rig_path.is_empty() else "none")
	info.add_theme_font_size_override("font_size", 12)
	_content.add_child(info)
	for r in _char().rigs:
		if r.path == _active_rig_path:
			continue
		var rig_path: String = r.path
		var b := Button.new()
		b.text = "Overlay: " + String(r.name)
		b.modulate = Color(0.6, 1.0, 0.6) if rig_path == _layer_overlay_path \
			else Color.WHITE
		b.pressed.connect(func() -> void:
			_layer_overlay_path = rig_path
			_show_submenu("layering"))
		_content.add_child(b)
	_layer_mask_pick = OptionButton.new()
	_content.add_child(_layer_mask_pick)
	_fill_bone_pick(_layer_mask_pick, "torso upper")
	_slider_into(_content, "Hold at frame (-1 = off)", -1.0, 60.0, _layer_hold,
		func(v: float) -> void: _layer_hold = roundf(v))
	_slider_into(_content, "Hold duration (s, 0 = manual release)", 0.0, 10.0,
		_layer_hold_secs, func(v: float) -> void: _layer_hold_secs = v)
	_btn_into(_content, "Play layered (once)", func() -> void:
		_play_layer_test(false))
	_btn_into(_content, "Save layering (records the pair)", func() -> void:
		_play_layer_test(true)
		_rebuild_content())
	_btn_into(_content, "Release hold", func() -> void: _ani.release_layer_hold())
	_btn_into(_content, "Stop layer", func() -> void: _ani.stop_layer(0.1))
	var sep := HSeparator.new()
	_content.add_child(sep)
	_aim_bone_pick = OptionButton.new()
	_content.add_child(_aim_bone_pick)
	_fill_bone_pick(_aim_bone_pick, "arm upper")
	_toggle_into(_content, "Aim bone at mouse cursor", _aim_enabled,
		func(v: bool) -> void:
			_aim_enabled = v
			if not v and _ani != null:
				_ani.clear_all_aims())
	_slider_into(_content, "Aim weight", 0.0, 1.0, _aim_weight,
		func(v: float) -> void: _aim_weight = v)


func _play_layer_test(record: bool) -> void:
	if _layer_overlay_path.is_empty() or _layer_mask_pick.selected < 0:
		return
	var overlay := _load_rig_res(_layer_overlay_path)
	if overlay == null:
		return
	var mask := _layer_mask_pick.get_item_text(_layer_mask_pick.selected)
	if _ani.play_layer(overlay, mask, 0.12) and _layer_hold >= 0.0:
		_ani.set_layer_hold(_layer_hold)
		# Simulate the player holding the attack: auto-release after
		# the set duration (2026-09-26 - beam testing without a
		# keybind). Guards: same node, layer still active.
		if _layer_hold_secs > 0.0:
			var node := _ani
			get_tree().create_timer(_layer_hold_secs).timeout.connect(
				func() -> void:
					if is_instance_valid(node) and node == _ani 							and node.has_layer():
						node.release_layer_hold())
	if record:
		_store.add_layer(_char_id, _active_rig_path, _layer_overlay_path, mask)


# ── Events & Effects ───────────────────────────────────────────────

## Every event name in the character's rigs, plus any already bound.
func _discover_event_names() -> Array:
	var names := {}
	for r in _char().rigs:
		var res := _load_rig_res(String(r.path))
		if res == null:
			continue
		for ev in res.events:
			var n := String(ev.get("name", ""))
			if not n.is_empty():
				names[n] = true
	for n in _char().get("events", {}):
		names[n] = true
	var out := names.keys()
	out.sort()
	return out


func _build_events_menu() -> void:
	var names := _discover_event_names()
	if names.is_empty():
		var hint := Label.new()
		hint.text = ("No frame events found in this character's animations.\n"
			+ "Add events in AniMate's timeline (Events button on the\n"
			+ "frame bar), re-export the .animrig, and they appear here\n"
			+ "automatically - ready to bind to projectiles, bursts and\n"
			+ "beams.")
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", 12)
		hint.modulate = Color(0.7, 0.7, 0.7)
		_content.add_child(hint)
		return
	var intro := Label.new()
	intro.text = "Events found in this character's animations.\nTap one to bind an effect:"
	intro.add_theme_font_size_override("font_size", 12)
	intro.modulate = Color(0.7, 0.7, 0.7)
	_content.add_child(intro)
	var bindings: Dictionary = _char().get("events", {})
	for n in names:
		var ev_name: String = n
		var cfg: Variant = bindings.get(ev_name)
		var b := Button.new()
		var summary := "unbound" if not cfg is Dictionary \
			else String(cfg.get("type", "?")) + " · " + String(cfg.get("file", ""))
		b.text = "%s  —  %s" % [ev_name, summary]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", FONT)
		b.modulate = Color(0.5, 0.9, 0.5) if cfg is Dictionary else Color.WHITE
		b.pressed.connect(func() -> void:
			_events_expanded = "" if _events_expanded == ev_name else ev_name
			_show_submenu("events"))
		_content.add_child(b)
		if _events_expanded == ev_name:
			_build_event_editor(ev_name)


func _event_cfg(ev_name: String) -> Dictionary:
	var events: Dictionary = _char().get("events", {})
	if not events.get(ev_name) is Dictionary:
		events[ev_name] = {
			"type": "projectile", "file": "", "bone": "",
			"speed": 700.0, "life": 1.2, "scale": 1.0, "length": 260.0,
		}
		_char().events = events
	return events[ev_name]


## Recursive assets/vfx listing as VFX_DIR-relative paths, so art
## can be organized in per-character subfolders (2026-09-26).
func _vfx_files(rel: String = "") -> Array:
	var out := []
	var path := VFX_DIR if rel.is_empty() else VFX_DIR + "/" + rel
	var dir := DirAccess.open(path)
	if dir == null:
		return out
	for f in dir.get_files():
		if f.get_extension().to_lower() == "png":
			out.append(f if rel.is_empty() else rel + "/" + f)
	for d in dir.get_directories():
		out.append_array(_vfx_files(d if rel.is_empty() else rel + "/" + d))
	return out


func _build_event_editor(ev_name: String) -> void:
	var cfg := _event_cfg(ev_name)
	var box := PanelContainer.new()
	var v := VBoxContainer.new()
	box.add_child(v)
	_content.add_child(box)

	_caption_into(v, "Effect type:")
	var type_pick := OptionButton.new()
	for t in ["projectile", "burst", "beam_on", "beam_off", "loop", "none"]:
		type_pick.add_item(t)
	for i in range(type_pick.item_count):
		if type_pick.get_item_text(i) == String(cfg.type):
			type_pick.select(i)
	type_pick.item_selected.connect(func(i: int) -> void:
		cfg.type = type_pick.get_item_text(i)
		_store.save_store()
		_show_submenu("events"))
	v.add_child(type_pick)

	if String(cfg.type) != "beam_off" and String(cfg.type) != "none":
		_caption_into(v, "Effect image (assets/vfx):")
		var file_pick := OptionButton.new()
		for f in _vfx_files():
			file_pick.add_item(String(f))
		if file_pick.item_count == 0:
			file_pick.add_item("(drop PNGs in assets/vfx)")
		var file_matched := false
		for i in range(file_pick.item_count):
			if file_pick.get_item_text(i) == String(cfg.file):
				file_pick.select(i)
				file_matched = true
		# An OptionButton DISPLAYS its selection even when the user
		# never tapped it - the store must match what the panel shows,
		# or a binding silently keeps file "" while looking configured
		# (the chargeup loop that never spawned, 2026-09-26).
		if not file_matched and file_pick.selected >= 0 \
				and not file_pick.get_item_text(file_pick.selected) \
					.begins_with("("):
			cfg.file = file_pick.get_item_text(file_pick.selected)
			_store.save_store()
		file_pick.item_selected.connect(func(i: int) -> void:
			cfg.file = file_pick.get_item_text(i)
			_store.save_store())
		v.add_child(file_pick)

		_caption_into(v, "Anchor bone:")
		var bone_pick := OptionButton.new()
		_fill_bone_pick(bone_pick, "hand")
		var bone_matched := false
		for i in range(bone_pick.item_count):
			if bone_pick.get_item_text(i) == String(cfg.bone):
				bone_pick.select(i)
				bone_matched = true
		if not bone_matched and bone_pick.selected >= 0:
			cfg.bone = bone_pick.get_item_text(bone_pick.selected)
			_store.save_store()
		bone_pick.item_selected.connect(func(i: int) -> void:
			cfg.bone = bone_pick.get_item_text(i)
			_store.save_store())
		v.add_child(bone_pick)

		_slider_into(v, "Effect scale", 0.1, 6.0, float(cfg.get("scale", 1.0)),
			func(val: float) -> void:
				cfg["scale"] = val
				_store.save_store())
		# Bone-local anchor offset: rides the bone's rotation, so an
		# offset reaching the staff TIP stays on the tip through the
		# charge swing and through movement (2026-09-26).
		_slider_into(v, "Anchor offset X (bone-local px)", -120.0, 120.0,
			float(cfg.get("ox", 0.0)), func(val: float) -> void:
				cfg["ox"] = val
				_store.save_store())
		_slider_into(v, "Anchor offset Y (bone-local px)", -120.0, 120.0,
			float(cfg.get("oy", 0.0)), func(val: float) -> void:
				cfg["oy"] = val
				_store.save_store())
		if String(cfg.type) == "projectile":
			_slider_into(v, "Speed (px/s)", 50.0, 2000.0, float(cfg.speed),
				func(val: float) -> void:
					cfg.speed = val
					_store.save_store())
			_slider_into(v, "Lifetime (s)", 0.2, 4.0, float(cfg.life),
				func(val: float) -> void:
					cfg.life = val
					_store.save_store())
		if String(cfg.type) == "beam_on":
			_int_slider_into(v, "Beam length (px)", 60.0, 1200.0,
				float(cfg.get("length", 260.0)), func(val: float) -> void:
					cfg["length"] = val
					_store.save_store())
			_toggle_into(v, "Gradual extend (grow from 0 on fire)",
				bool(cfg.get("gradual", false)), func(val: bool) -> void:
					cfg["gradual"] = val
					_store.save_store())
			_int_slider_into(v, "Extend rate (px/s)", 100.0, 4000.0,
				float(cfg.get("rate", 1200.0)), func(val: float) -> void:
					cfg["rate"] = val
					_store.save_store())
		if String(cfg.type) == "loop":
			_int_slider_into(v, "Sheet columns (hframes)", 1.0, 16.0,
				float(cfg.get("hframes", 4)), func(val: float) -> void:
					cfg["hframes"] = int(roundf(val))
					_store.save_store())
			_int_slider_into(v, "Sheet rows (vframes)", 1.0, 8.0,
				float(cfg.get("vframes", 1)), func(val: float) -> void:
					cfg["vframes"] = int(roundf(val))
					_store.save_store())
			_int_slider_into(v, "Flipbook FPS", 2.0, 30.0,
				float(cfg.get("fps", 10.0)), func(val: float) -> void:
					cfg["fps"] = val
					_store.save_store())
			_caption_into(v, "Stop loop on event:")
			var stop_pick := OptionButton.new()
			stop_pick.add_item("(no stop event)")
			for other in _discover_event_names():
				if String(other) != ev_name:
					stop_pick.add_item(String(other))
			for i in range(stop_pick.item_count):
				if stop_pick.get_item_text(i) == String(cfg.get("stop_on", "")):
					stop_pick.select(i)
			stop_pick.item_selected.connect(func(i: int) -> void:
				cfg["stop_on"] = "" if i == 0 else stop_pick.get_item_text(i)
				_store.save_store())
			v.add_child(stop_pick)


func _fx_direction(spawn_global: Vector2) -> Vector2:
	if _aim_enabled:
		var d := get_global_mouse_position() - spawn_global
		if d.length() > 1.0:
			return d.normalized()
	return Vector2(signf(_ani.scale.x if _ani.scale.x != 0 else 1.0), 0)


func _crispify(s: Sprite2D) -> void:
	# The AA seam blend needs bilinear samples; the shader re-sharpens.
	s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var m := ShaderMaterial.new()
	m.shader = CRISP_SHADER
	s.material = m


func _bone_anchor_global(cfg: Dictionary) -> Vector2:
	var bone := String(cfg.get("bone", ""))
	if bone.is_empty():
		return _ani.global_position
	var t := _ani.get_bone_world_transform(bone)
	return _ani.to_global(
		t * Vector2(float(cfg.get("ox", 0.0)), float(cfg.get("oy", 0.0))))


func _on_frame_event(ev_name: String, _payload: String) -> void:
	if _ani == null or _char_id.is_empty():
		return
	# Any event may be some loop's stop event.
	var still := []
	for lp in _loops:
		if String((lp.cfg as Dictionary).get("stop_on", "")) == ev_name:
			if is_instance_valid(lp.node):
				(lp.node as Node).queue_free()
		else:
			still.append(lp)
	_loops = still
	var cfg: Variant = _char().get("events", {}).get(ev_name)
	if not cfg is Dictionary:
		return
	var spawn := _bone_anchor_global(cfg)
	match String(cfg.type):
		"projectile":
			var tex: Texture2D = load(VFX_DIR + "/" + String(cfg.file))
			if tex == null:
				return
			var sp := Sprite2D.new()
			_crispify(sp)
			sp.texture = tex
			sp.global_position = spawn
			var dir := _fx_direction(spawn)
			sp.rotation = dir.angle()
			sp.scale = Vector2(float(cfg.get("scale", 1)), float(cfg.get("scale", 1)))
			add_child(sp)
			_projectiles.append({
				"node": sp, "vel": dir * float(cfg.speed),
				"ttl": float(cfg.life),
			})
		"burst":
			var tex2: Texture2D = load(VFX_DIR + "/" + String(cfg.file))
			if tex2 == null:
				return
			var b := Sprite2D.new()
			_crispify(b)
			b.texture = tex2
			b.global_position = spawn
			b.scale = Vector2.ONE * float(cfg.get("scale", 1)) * 0.5
			add_child(b)
			var tw := create_tween()
			tw.set_parallel(true)
			tw.tween_property(b, "scale",
				Vector2.ONE * float(cfg.get("scale", 1)) * 1.6, 0.3)
			tw.tween_property(b, "modulate:a", 0.0, 0.3)
			tw.chain().tween_callback(b.queue_free)
		"beam_on":
			_beam_off()
			var tex3: Texture2D = load(VFX_DIR + "/" + String(cfg.file))
			if tex3 == null:
				return
			_beam = Sprite2D.new()
			_crispify(_beam)
			_beam.texture = tex3
			_beam.centered = false
			_beam.offset = Vector2(0, -tex3.get_height() * 0.5)
			add_child(_beam)
			_beam_cfg = cfg
			_beam_len = 0.0 if bool(cfg.get("gradual", false)) \
				else float(cfg.get("length", 260.0))
		"beam_off":
			_beam_off()
		"loop":
			var tex4: Texture2D = load(VFX_DIR + "/" + String(cfg.file))
			if tex4 == null:
				return
			# Retrigger REPLACES this event's live loop instead of
			# stacking a second copy (looping clips re-fire the spawn
			# event every pass while a long-lived loop - e.g. one that
			# only stops on beam_end - is still alive).
			var kept := []
			for lp0 in _loops:
				if String(lp0.get("ev", "")) == ev_name:
					if is_instance_valid(lp0.node):
						(lp0.node as Node).queue_free()
				else:
					kept.append(lp0)
			_loops = kept
			var lp := Sprite2D.new()
			_crispify(lp)
			lp.texture = tex4
			lp.hframes = maxi(1, int(cfg.get("hframes", 4)))
			lp.vframes = maxi(1, int(cfg.get("vframes", 1)))
			lp.global_position = spawn
			lp.scale = Vector2.ONE * float(cfg.get("scale", 1))
			add_child(lp)
			_loops.append({"node": lp, "cfg": cfg, "t": 0.0, "ev": ev_name})


func _beam_off() -> void:
	if _beam != null:
		_beam.queue_free()
		_beam = null
	_beam_cfg = {}


func _loops_off() -> void:
	for lp in _loops:
		if is_instance_valid(lp.node):
			(lp.node as Node).queue_free()
	_loops = []


func _update_effects(delta: float) -> void:
	var alive := []
	for pr in _projectiles:
		pr.ttl -= delta
		if pr.ttl <= 0.0 or not is_instance_valid(pr.node):
			if is_instance_valid(pr.node):
				(pr.node as Node).queue_free()
			continue
		(pr.node as Sprite2D).global_position += (pr.vel as Vector2) * delta
		alive.append(pr)
	_projectiles = alive
	# Anchored loops: follow their bone anchor + flip through frames.
	var live_loops := []
	for lp in _loops:
		if not is_instance_valid(lp.node) or _ani == null:
			continue
		lp.t += delta
		var lcfg: Dictionary = lp.cfg
		var node := lp.node as Sprite2D
		var lt := _ani.get_bone_world_transform(String(lcfg.get("bone", "")))
		node.global_position = _bone_anchor_global(lcfg)
		node.rotation = lt.get_rotation() + _ani.rotation
		var total := maxi(1, int(lcfg.get("hframes", 4))) \
			* maxi(1, int(lcfg.get("vframes", 1)))
		node.frame = int(lp.t * float(lcfg.get("fps", 10.0))) % total
		live_loops.append(lp)
	_loops = live_loops
	if _beam != null and _ani != null and not _beam_cfg.is_empty():
		var spawn := _bone_anchor_global(_beam_cfg)
		var dir := _fx_direction(spawn)
		_beam.global_position = spawn
		_beam.rotation = dir.angle()
		_beam_len = minf(
			_beam_len + float(_beam_cfg.get("rate", 1200.0)) * delta,
			float(_beam_cfg.get("length", 260.0)))
		var tex_w := float(_beam.texture.get_width())
		_beam.scale = Vector2(
			_beam_len / maxf(tex_w, 1.0),
			float(_beam_cfg.get("scale", 1.0)))


# ── In-Game mode ───────────────────────────────────────────────────

func _build_ingame_content() -> void:
	var idle: String = _char().ingame.idle
	var idle_btn := Button.new()
	idle_btn.text = "Reassign idle" if not idle.is_empty() else "Assign Idle"
	idle_btn.add_theme_font_size_override("font_size", FONT)
	idle_btn.pressed.connect(func() -> void:
		_assigning_idle = true
		_rebuild_content())
	_content.add_child(idle_btn)
	if _assigning_idle:
		var hint := Label.new()
		hint.text = "Click an animation below to make it the idle."
		hint.modulate = Color(0.5, 0.8, 1.0)
		hint.add_theme_font_size_override("font_size", 12)
		_content.add_child(hint)

	for r in _char().rigs:
		var rig_path: String = r.path
		var row := HBoxContainer.new()
		var nm := Button.new()
		nm.text = String(r.name) + ("   [IDLE]" if rig_path == idle else "")
		nm.alignment = HORIZONTAL_ALIGNMENT_LEFT
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nm.add_theme_font_size_override("font_size", FONT)
		if _assigning_idle:
			nm.modulate = Color(0.5, 1.0, 0.6)
		nm.pressed.connect(func() -> void:
			if _assigning_idle:
				_char().ingame.idle = rig_path
				_assigning_idle = false
				_store.save_store()
				_activate_rig(rig_path)
				_rebuild_content())
		row.add_child(nm)
		var bind := Button.new()
		var key: String = _char().ingame.binds.get(rig_path, "")
		bind.text = key if not key.is_empty() else "Assign"
		bind.custom_minimum_size = Vector2(110, 0)
		bind.pressed.connect(func() -> void: _prompt_keybind(rig_path))
		row.add_child(bind)
		_content.add_child(row)


func _prompt_keybind(rig_path: String) -> void:
	_capture_rig_path = rig_path
	_captured_key = ""
	_capture_dialog = AcceptDialog.new()
	_capture_dialog.title = "Press a key or key-combination"
	_capture_dialog.ok_button_text = "Confirm"
	_capture_label = Label.new()
	_capture_label.text = "(waiting for input...)"
	_capture_label.custom_minimum_size = Vector2(260, 40)
	_capture_label.add_theme_font_size_override("font_size", FONT_HEAD)
	_capture_dialog.add_child(_capture_label)
	_capture_dialog.add_cancel_button("Cancel")
	var existing: String = _char().ingame.binds.get(rig_path, "")
	if not existing.is_empty():
		_capture_dialog.add_button("Unbind", false, "unbind")
	_capture_dialog.confirmed.connect(func() -> void:
		if not _captured_key.is_empty():
			_char().ingame.binds[_capture_rig_path] = _captured_key
			_store.save_store()
		_close_capture())
	_capture_dialog.custom_action.connect(func(action: StringName) -> void:
		if action == "unbind":
			_char().ingame.binds.erase(_capture_rig_path)
			_store.save_store()
		_close_capture())
	_capture_dialog.canceled.connect(_close_capture)
	_dialog_layer.add_child(_capture_dialog)
	_capture_dialog.popup_centered()


func _close_capture() -> void:
	if _capture_dialog != null:
		_capture_dialog.queue_free()
		_capture_dialog = null
	_rebuild_content()


func _input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if key_event.echo:
		return
	# Capturing a bind?
	if _capture_dialog != null and _capture_dialog.visible:
		if key_event.pressed and key_event.keycode not in [
			KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META,
		]:
			_captured_key = OS.get_keycode_string(
				key_event.get_keycode_with_modifiers())
			_capture_label.text = _captured_key
		return
	# In-game playback: bound key held -> that clip; released -> idle.
	if _screen != Screen.INGAME or _ani == null or _ani.rig == null:
		return
	var pressed_name := OS.get_keycode_string(
		key_event.get_keycode_with_modifiers())
	var binds: Dictionary = _char().ingame.binds
	if key_event.pressed:
		for rig_path in binds:
			if binds[rig_path] == pressed_name:
				_held_bind_key = pressed_name
				_crossfade_to_path(rig_path)
				return
	else:
		var released_plain := OS.get_keycode_string(key_event.keycode)
		if _held_bind_key != "" and (_held_bind_key == pressed_name
				or _held_bind_key.ends_with(released_plain)):
			_held_bind_key = ""
			var idle: String = _char().ingame.idle
			if not idle.is_empty():
				_crossfade_to_path(idle)


func _crossfade_to_path(path: String) -> void:
	var res := _load_rig_res(path)
	if res == null:
		return
	if _ani.rig == null:
		_activate_rig(path)
		return
	_ani.loop_override = 1
	_ani.crossfade_to(res, 0.15)
	_active_rig_path = path
	_apply_all_domains()


# ── Rig activation + settings application ──────────────────────────

func _load_rig_res(path: String) -> AniRigResource:
	if _rig_cache.has(path):
		return _rig_cache[path]
	var res := load(path)
	if res is AniRigResource:
		_rig_cache[path] = res
		return res
	return null


func _activate_rig(path: String) -> void:
	var res := _load_rig_res(path)
	if res == null or _ani == null:
		return
	_active_rig_path = path
	_beam_off()
	_loops_off()
	_hold_waiting = false
	_hold_cooldown = false
	# One-time adoption of a weapon fitting saved by the pre-rework
	# playground (keyed by root-bone uuid) into this character.
	_store.adopt_legacy_weapon(_char_id, res)
	_ani.rig = res
	_ani.loop_override = 1
	_ani.set_current_frame(0.0)
	_ani.play()
	_apply_all_domains()
	_apply_playback()
	# Auto-play the recorded layering for this base (runtime supports
	# one overlay at a time - the most recent pair plays).
	var overlays := _store.layers_of_base(_char_id, path)
	if not overlays.is_empty() and _screen == Screen.SANDBOX:
		var l: Dictionary = overlays[overlays.size() - 1]
		var ov := _load_rig_res(String(l.overlay))
		if ov != null:
			_ani.play_layer(ov, String(l.mask), 0.12)


func _apply_all_domains() -> void:
	for d in ["physics", "shading", "weapon"]:
		_apply_domain(d)


func _apply_domain(domain: String) -> void:
	if _ani == null or _active_rig_path.is_empty():
		return
	var t := _store.effective(_char_id, _active_rig_path, domain)
	match domain:
		"physics":
			_ani.cloth_enabled = bool(t.enabled)
			_ani.cloth_stiffness = float(t.c_st)
			_ani.cloth_damping = float(t.c_da)
			_ani.cloth_inertia = float(t.c_in)
			_ani.hair_stiffness = float(t.h_st)
			_ani.hair_damping = float(t.h_da)
			_ani.hair_inertia = float(t.h_in)
			_ani.limb_stiffness = float(t.l_st)
			_ani.limb_damping = float(t.l_da)
			_ani.limb_inertia = float(t.l_in)
			_ani.limb_bone_keywords = PackedStringArray(["leg", "foot"]) \
				if bool(t.limbs) else PackedStringArray()
		"shading":
			_ani.shaded = bool(t.shaded)
			_ani.metal_tint = float(t.tint)
			_ani.light_direction = Vector3(
				float(t.lx), float(t.ly), float(t.lz))
		"weapon":
			_apply_weapon(t)


func _apply_weapon(w: Dictionary) -> void:
	if w.is_empty() or String(w.get("file", "")).is_empty():
		if _weapon != null:
			_weapon.queue_free()
			_weapon = null
		return
	var tex: Texture2D = load(WEAPONS_DIR + "/" + String(w.file))
	if tex == null:
		return
	if _weapon == null:
		_weapon = Sprite2D.new()
		_crispify(_weapon)
		_ani.add_child(_weapon)
	_weapon.texture = tex
	_apply_weapon_layer()


func _apply_weapon_layer() -> void:
	if _weapon == null:
		return
	var w := _store.effective(_char_id, _active_rig_path, "weapon")
	_weapon.z_as_relative = true
	_weapon.z_index = -100 if bool(w.get("behind", false)) else 100
	_weapon.show_behind_parent = bool(w.get("behind", false))


## Push the stored playback values into the (once-built, reused)
## header controls so what they display is what _process reads.
func _sync_playback_controls() -> void:
	var pb: Dictionary = _char().playback
	if _zoom_slider != null:
		_zoom_slider.value = float(pb.zoom)
	if _speed_slider != null:
		_speed_slider.value = float(pb.speed)
	if _sway_check != null:
		_sway_check.button_pressed = bool(pb.sway)
	if _hold_frame_slider != null:
		_hold_frame_slider.value = float(pb.get("hold_frame", -1))
	if _hold_secs_slider != null:
		_hold_secs_slider.value = float(pb.get("hold_secs", 1.0))


func _apply_playback() -> void:
	if _ani == null:
		return
	var pb: Dictionary = _char().playback
	var z := float(pb.zoom)
	_ani.scale = Vector2(z * signf(_ani.scale.x if _ani.scale.x != 0 else 1.0), z)
	_ani.speed = float(pb.speed)


func _attach_set(on: bool) -> void:
	_attach_mode = on
	if _attach_btn != null:
		_attach_btn.set_pressed_no_signal(on)
	if _ani == null:
		return
	if on:
		var w := _domain_target("weapon")
		if _weapon == null and _weapon_pick != null \
				and _weapon_pick.selected >= 0:
			var fname := _weapon_pick.get_item_text(_weapon_pick.selected)
			if fname.ends_with(".png"):
				w.file = fname
				_apply_weapon(w)
		_ani.pause()
	else:
		_ani.play()


func _save_attachment() -> void:
	if _weapon == null or _weapon_bone_pick == null \
			or _weapon_bone_pick.selected < 0:
		return
	var bone := _weapon_bone_pick.get_item_text(_weapon_bone_pick.selected)
	var t := _ani.get_bone_world_transform(bone)
	var local_off := t.affine_inverse() * _weapon.position
	var target := _domain_target("weapon")
	target.file = _weapon_pick.get_item_text(_weapon_pick.selected)
	target.bone = bone
	target.ox = local_off.x
	target.oy = local_off.y
	target.rot = _weapon.rotation - t.get_rotation()
	target["scale"] = _weapon.scale.x
	_store.save_store()
	_attach_set(false)


func _fill_bone_pick(pick: OptionButton, prefer: String) -> void:
	pick.clear()
	if _ani == null or _ani.rig == null:
		return
	var idx := 0
	var chosen := 0
	for bone in _ani.rig.bones:
		var n := String(bone.get("name", ""))
		if n.is_empty():
			continue
		pick.add_item(n)
		if chosen == 0 and n.containsn(prefer):
			chosen = idx
		idx += 1
	if pick.item_count > 0:
		pick.select(chosen)


# ── Frame loop ─────────────────────────────────────────────────────

func _apply_panel_state() -> void:
	_work_root.visible = not _panel_collapsed
	_panel_tab.text = "\u25c0" if _panel_collapsed else "\u25b6"
	var edge := 0.0 if _panel_collapsed else -PANEL_W
	_panel_tab.offset_right = edge
	_panel_tab.offset_left = edge - PANEL_TAB_W
	if _ani != null:
		_recenter()


func _recenter() -> void:
	var vp := get_viewport_rect().size
	var pw := 0.0 if _panel_collapsed else PANEL_W
	_base_pos = Vector2((vp.x - pw) * 0.45, vp.y * 0.55)
	if _ani != null:
		_ani.position = _base_pos


func _process(delta: float) -> void:
	if _ani == null:
		return
	if _screen == Screen.SANDBOX:
		var tilt := _joy.deflect if _joy != null else Vector2.ZERO
		if tilt != Vector2.ZERO:
			_ani.position += tilt \
				* (DRAG_MAX_DEFLECT * DRAG_SPEED_PER_PX) * delta
		elif bool(_char().playback.sway) and not _attach_mode:
			_sway_t += delta
			_ani.position = _base_pos + Vector2(sin(_sway_t * 2.2) * 90.0, 0)
	# Plain-playback charge hold: pause on the stored hold frame, then
	# resume after hold_secs. The cooldown keeps the resume from
	# re-parking until the playhead has left the hold frame (looping
	# clips re-arm on the next pass).
	if _screen == Screen.SANDBOX and not _char_id.is_empty():
		var hold_f := int(_char().playback.get("hold_frame", -1))
		if _hold_cooldown and int(_ani.get_current_frame()) != hold_f:
			_hold_cooldown = false
		elif _hold_waiting and hold_f < 0:
			# Sliding Hold-at-frame back to -1 releases a parked hold.
			_hold_waiting = false
			_hold_cooldown = true
			_ani.play()
		elif hold_f >= 0 and not _hold_waiting and not _hold_cooldown \
				and _ani.is_playing() \
				and int(_ani.get_current_frame()) == hold_f:
			_ani.pause()
			_hold_waiting = true
			var secs := float(_char().playback.get("hold_secs", 1.0))
			if secs >= 0.0:
				var held := _ani
				get_tree().create_timer(maxf(0.1, secs)) \
					.timeout.connect(func() -> void:
						_hold_waiting = false
						_hold_cooldown = true
						if is_instance_valid(held) and held == _ani:
							held.play())
			# secs < 0: hold forever - release with the button, the
			# hold-frame slider, or by switching rigs.
	# Cursor aim.
	if _aim_enabled and _ani.rig != null and _aim_bone_pick != null \
			and _aim_bone_pick.selected >= 0:
		var aim_bone := _aim_bone_pick.get_item_text(_aim_bone_pick.selected)
		var origin: Vector2 = _ani.get_bone_world_transform(aim_bone).origin
		var local_target := _ani.to_local(get_global_mouse_position())
		_ani.set_bone_aim(
			aim_bone, (local_target - origin).angle(), _aim_weight)
	# Weapon live follow (not while fitting).
	var w := {} if _active_rig_path.is_empty() else \
		_store.effective(_char_id, _active_rig_path, "weapon")
	if _weapon != null and not _attach_mode \
			and not String(w.get("bone", "")).is_empty():
		var t := _ani.get_bone_world_transform(String(w.bone))
		_weapon.position = t * Vector2(float(w.get("ox", 0)), float(w.get("oy", 0)))
		_weapon.rotation = t.get_rotation() + float(w.get("rot", 0))
		_weapon.scale = Vector2(float(w.get("scale", 1)), float(w.get("scale", 1)))
	_update_effects(delta)
	_update_readout()


func _unhandled_input(event: InputEvent) -> void:
	# Free mouse drag exists only for weapon attach mode.
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
	elif event is InputEventMouseMotion and _dragging \
			and _attach_mode and _weapon != null:
		_weapon.position += Vector2(
			event.relative.x / _ani.scale.x,
			event.relative.y / _ani.scale.y)


func _update_readout() -> void:
	if _readout == null:
		return
	if _ani == null or _ani.rig == null:
		_readout.text = "No animation loaded."
		return
	var counts := {0: 0, 1: 0, 2: 0}
	for cls in _ani._cloth_uuids.values():
		counts[int(cls)] = int(counts.get(int(cls), 0)) + 1
	_readout.text = "sim bones — cloth: %d · hair: %d · limbs: %d" \
		% [counts[0], counts[1], counts[2]]


func _take_shot(path: String) -> void:
	await get_tree().create_timer(1.5).timeout
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()


# ── UI helpers ─────────────────────────────────────────────────────

func _collapsible(parent: VBoxContainer, text: String, collapsed: bool) -> VBoxContainer:
	var btn := Button.new()
	btn.flat = true
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_font_size_override("font_size", FONT_HEAD)
	btn.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.visible = not collapsed
	btn.text = ("v  " if box.visible else ">  ") + text
	btn.pressed.connect(func() -> void:
		box.visible = not box.visible
		btn.text = ("v  " if box.visible else ">  ") + text)
	parent.add_child(btn)
	parent.add_child(box)
	return box


func _slider_into(
	parent: Container, label_text: String, mn: float, mx: float,
	value: float, on_change: Callable
) -> HSlider:
	var row := VBoxContainer.new()
	var l := Label.new()
	l.add_theme_font_size_override("font_size", FONT)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = 0.01
	# Mouse wheel must SCROLL the settings panel, not tweak whatever
	# slider the cursor happens to cross (an hframes slider silently
	# knocked from 12 to 11 that way - 2026-09-26).
	s.scrollable = false
	s.value = value
	s.custom_minimum_size = Vector2(PANEL_W - 60, 0)
	var update := func(v: float) -> void:
		l.text = "%s: %.2f" % [label_text, v]
		on_change.call(v)
	s.value_changed.connect(update)
	l.text = "%s: %.2f" % [label_text, value]
	row.add_child(s)
	parent.add_child(row)
	return s


## Whole-number slider (frame counts, sheet grids): step 1, %d label.
func _int_slider_into(
	parent: Container, label_text: String, mn: float, mx: float,
	value: float, on_change: Callable
) -> HSlider:
	var row := VBoxContainer.new()
	var l := Label.new()
	l.add_theme_font_size_override("font_size", FONT)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = 1.0
	s.rounded = true
	s.scrollable = false
	s.value = value
	s.custom_minimum_size = Vector2(PANEL_W - 60, 0)
	var update := func(v: float) -> void:
		l.text = "%s: %d" % [label_text, int(v)]
		on_change.call(v)
	s.value_changed.connect(update)
	l.text = "%s: %d" % [label_text, int(value)]
	row.add_child(s)
	parent.add_child(row)
	return s


func _toggle_into(
	parent: Container, text: String, initial: bool, on_change: Callable
) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.add_theme_font_size_override("font_size", FONT)
	c.button_pressed = initial
	c.toggled.connect(on_change)
	parent.add_child(c)
	return c


## Small caption above a control (dropdowns show only their current
## selection - without a caption, a picked value says nothing about
## what the control IS).
func _caption_into(parent: Container, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", FONT - 2)
	l.modulate = Color(1, 1, 1, 0.7)
	parent.add_child(l)


func _btn_into(parent: Container, text: String, on_press: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", FONT)
	b.pressed.connect(on_press)
	parent.add_child(b)


## Literal transparent on-screen joystick: click inside, drag to
## tilt; the knob follows and snaps back on release.
class VirtualJoystick extends Control:
	var deflect := Vector2.ZERO
	var _active := false
	const RADIUS := 70.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _gui_input(event: InputEvent) -> void:
		var center := size * 0.5
		if event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and event.position.distance_to(center) <= RADIUS:
				_active = true
				deflect = ((event.position - center) / RADIUS).limit_length(1.0)
			elif not event.pressed:
				_active = false
				deflect = Vector2.ZERO
			queue_redraw()
		elif event is InputEventMouseMotion and _active:
			deflect = ((event.position - center) / RADIUS).limit_length(1.0)
			queue_redraw()

	func _draw() -> void:
		var center := size * 0.5
		draw_circle(center, RADIUS, Color(1, 1, 1, 0.06))
		draw_arc(center, RADIUS, 0.0, TAU, 48, Color(1, 1, 1, 0.18), 2.0)
		draw_circle(center + deflect * RADIUS, 22.0,
			Color(1, 1, 1, 0.28 if _active else 0.16))
