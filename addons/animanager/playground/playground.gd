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
var _save_btn: Button
var _panel_collapsed := false
var _content: VBoxContainer  # swapped area (home / submenus / advanced)
var _char_list_box: VBoxContainer
var _name_label: Label
var _preset_pick: OptionButton
var _zoom_slider: HSlider
var _speed_slider: HSlider
var _sway_check: CheckBox
var _joy_check: CheckBox
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
var _capture_move_dir := ""
var _held_bind_key := ""
# In-game key-hold parking: parked-on-hold-frame by a held bind /
# release resumes and then idles once the release events fired.
var _ig_parked := false
var _ig_release_pending := false
# In-game per-animation release policy editor (open rig path).
var _release_edit_path := ""
var _anim_aim_bone := ""
var _anim_aim_angle := 0.0
var _anim_aim_w := 0.0
# Two-hand grip release state: "" = full grip; "primary"/"secondary"
# = that hand is off the weapon. The weapon's transform relative to
# the REMAINING hand is captured at release so nothing pops.
var _grip_released := ""
# Time spent parked on the hold frame by a held bind - drives the
# charged-release branch.
var _hold_elapsed := 0.0
# True while a direction-flagged movement animation drove the clip
# switch - releasing the directions then returns to the idle.
var _moving_via_anim := false
var _grip_off := Vector2.ZERO
var _grip_rot := 0.0
var _events_editor_built := false
var _scrub_box: HBoxContainer
# Sticky scrub-pause: while true, a newly activated animation (list
# tap or keybind) parks PAUSED on its frame 0 for inspection.
var _scrub_paused := false
var _show_frames_check: CheckBox
var _frame_readout: Label
var _fade_slider: HSlider

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
	# Window close asks about saving the preset first (see
	# _notification) instead of quitting outright.
	get_tree().auto_accept_quit = false
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
		# On the character-select menu (or with no preset picked)
		# there is nothing to prompt about.
		if _char_id.is_empty() or _preset_pick == null \
				or _preset_pick.selected < 0:
			get_tree().quit()
			return
		var n := _preset_pick.get_item_text(_preset_pick.selected)
		var d := ConfirmationDialog.new()
		d.title = "Save before exiting?"
		d.dialog_text = "Overwrite preset '%s' with the current session?" % n
		d.ok_button_text = "Save & Exit"
		d.add_button("Exit Without Saving", false, "nosave")
		d.get_cancel_button().text = "Keep Playing"
		d.confirmed.connect(func() -> void:
			_overwrite_current_preset()
			get_tree().quit())
		d.custom_action.connect(func(a: StringName) -> void:
			if a == "nosave":
				get_tree().quit())
		d.canceled.connect(func() -> void: d.queue_free())
		_dialog_layer.add_child(d)
		d.popup_centered()


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
	if _save_btn != null:
		_save_btn.visible = false
	if _scrub_box != null:
		_scrub_box.visible = false
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
	if _frame_readout != null:
		_frame_readout.visible = false
	_refresh_char_list()


# ── Workspace (per character) ──────────────────────────────────────

func _enter_character(id: String) -> void:
	_char_id = id
	_screen = Screen.SANDBOX
	_scrub_paused = false
	_moving_via_anim = false
	_active_rig_path = ""
	_release_edit_path = ""
	_assigning_idle = false
	_held_bind_key = ""
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
	_save_btn.visible = true
	_scrub_box.visible = true
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
	_joy.visible = bool(_char().playback.get("joystick", true))

	_name_label.text = String(_store.character(id).name)
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

	# One-click preset save at the play area's top-right corner.
	_save_btn = Button.new()
	_save_btn.text = "Save"
	_save_btn.tooltip_text = "Overwrite current preset"
	_save_btn.add_theme_font_size_override("font_size", 18)
	_save_btn.anchor_left = 1.0
	_save_btn.anchor_right = 1.0
	_save_btn.offset_top = 8
	_save_btn.offset_bottom = 48
	_save_btn.pressed.connect(func() -> void:
		_overwrite_current_preset()
		_save_btn.text = "Saved"
		get_tree().create_timer(0.6).timeout.connect(func() -> void:
			if is_instance_valid(_save_btn):
				_save_btn.text = "Save"))
	_layer.add_child(_save_btn)
	_apply_panel_state()

	# Frame readout, top-left of the play area (Playback toggle).
	_frame_readout = Label.new()
	_frame_readout.add_theme_font_size_override("font_size", FONT)
	_frame_readout.position = Vector2(16, 12)
	_frame_readout.visible = false
	_layer.add_child(_frame_readout)

	# Scrub row: pause / play / step one frame - frame-accurate
	# inspection without per-frame documentation (2026-09-27).
	_scrub_box = HBoxContainer.new()
	_scrub_box.position = Vector2(16, 40)
	_scrub_box.add_theme_constant_override("separation", 6)
	_scrub_box.visible = false
	for spec in [
		["Pause", func() -> void:
			# A HOLD, not a pause: speed 0 with the clip still playing,
			# so stepped frames dispatch their events (effects spawn
			# while scrubbing) and cloth keeps simulating.
			_scrub_paused = true
			if _ani != null:
				_ani.speed = 0.0
				_ani.play()],
		["Play", func() -> void:
			_scrub_paused = false
			_apply_playback()
			if _ani != null:
				_ani.play()],
		["+1 Frame", func() -> void:
			if _ani == null or _ani.rig == null:
				return
			_scrub_paused = true
			_ani.speed = 0.0
			_ani.play()
			var nf := int(_ani.get_current_frame()) + 1
			if nf >= _ani.rig.total_frames:
				nf = 0
			_ani.set_current_frame(float(nf))],
	]:
		var sb := Button.new()
		sb.text = String(spec[0])
		sb.add_theme_font_size_override("font_size", 12)
		sb.pressed.connect(spec[1])
		_scrub_box.add_child(sb)
	_layer.add_child(_scrub_box)

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

	_zoom_slider = _slider_into(v, "Zoom", 0.5, 10.0, 3.0,
		func(val: float) -> void:
			_char().playback.zoom = val
			_apply_playback()
			_store.save_store())
	_joy_check = _toggle_into(v, "Show joystick", true,
		func(on: bool) -> void:
			_char().playback.joystick = on
			_store.save_store()
			if _joy != null:
				_joy.visible = on and _screen == Screen.SANDBOX)

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
	_btn_into(box, "Overwrite current preset", _overwrite_current_preset)
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
		var n := _preset_pick.get_item_text(_preset_pick.selected)
		if (_char().presets as Dictionary).size() <= 1:
			var info := AcceptDialog.new()
			info.title = "Presets"
			info.dialog_text = "Cannot delete the only preset."
			info.confirmed.connect(func() -> void: info.queue_free())
			info.canceled.connect(func() -> void: info.queue_free())
			_dialog_layer.add_child(info)
			info.popup_centered()
			return
		var conf := ConfirmationDialog.new()
		conf.title = "Delete preset"
		conf.dialog_text = "Delete preset '%s'? This cannot be undone." % n
		conf.confirmed.connect(func() -> void:
			conf.queue_free()
			_char().presets.erase(n)
			# Re-point current_preset so preset-on-open never dangles.
			if String(_char().current_preset) == n:
				for remaining in _char().presets:
					_char().current_preset = String(remaining)
					break
			_store.save_store()
			_refresh_presets())
		conf.canceled.connect(func() -> void: conf.queue_free())
		_dialog_layer.add_child(conf)
		conf.popup_centered())


func _overwrite_current_preset() -> void:
	if _preset_pick == null or _preset_pick.selected < 0 \
			or _char_id.is_empty():
		return
	var n := _preset_pick.get_item_text(_preset_pick.selected)
	_char().presets[n] = _store.snapshot(_char_id)
	_char().current_preset = n
	_store.save_store()


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
	_show_frames_check = _toggle_into(box, "Display animation frame count",
		false, func(v: bool) -> void:
			_char().playback.show_frames = v
			_store.save_store())
	_fade_slider = _int_slider_into(box, "Crossfade duration (ms)",
		50.0, 1000.0, 350.0, func(v: float) -> void:
			_char().playback.fade_ms = int(v)
			_store.save_store())
	_btn_into(box, "Release Infinite Hold", func() -> void:
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
	if not _release_edit_path.is_empty():
		_build_release_editor()
	else:
		_build_sandbox_home()


func _build_sandbox_home() -> void:
	var cs_head := Label.new()
	cs_head.text = "Character Settings"
	cs_head.add_theme_font_size_override("font_size", FONT_HEAD)
	cs_head.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0))
	_content.add_child(cs_head)
	_btn_into(_content, "Physics Options", func() -> void: _show_submenu("physics"))
	_btn_into(_content, "Shading Options", func() -> void: _show_submenu("shading"))
	_btn_into(_content, "Weapon Menu", func() -> void: _show_submenu("weapon"))
	_btn_into(_content, "Animation Layering", func() -> void: _show_submenu("layering"))
	_btn_into(_content, "Events & Effects", func() -> void: _show_submenu("events"))
	var sep := HSeparator.new()
	_content.add_child(sep)
	_build_movement_section()
	_content.add_child(HSeparator.new())
	var head := Label.new()
	head.text = "Animations"
	head.add_theme_font_size_override("font_size", FONT_HEAD)
	head.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0))
	_content.add_child(head)
	_btn_into(_content, "Add animation...", _prompt_add_rig)
	for r in _char().rigs:
		_content.add_child(_rig_row(r))


func _build_movement_section() -> void:
	var box := _collapsible(_content, "Movement", true)
	var idle: String = _char().ingame.idle
	var idle_btn := Button.new()
	idle_btn.text = "Reassign idle" if not idle.is_empty() else "Assign Idle"
	idle_btn.add_theme_font_size_override("font_size", FONT)
	idle_btn.pressed.connect(func() -> void:
		_assigning_idle = true
		_rebuild_content())
	box.add_child(idle_btn)
	if _assigning_idle:
		var hint := Label.new()
		hint.text = "Click an animation below to make it the idle."
		hint.modulate = Color(0.5, 0.8, 1.0)
		hint.add_theme_font_size_override("font_size", 12)
		box.add_child(hint)
	# Movement has two layers (2026-09-28): animations flagged for
	# directions in their Advanced menu play while those inputs are
	# held (Herald's run); the static toggle below additionally
	# glides with NO animation switch (Seraph's flyer drift). Both
	# use the same direction binds, so the rows always show.
	_toggle_into(box, "Static movement (glide without a movement animation)",
		bool(_char().ingame.get("move_enabled", false)),
		func(v: bool) -> void:
			_char().ingame.move_enabled = v
			_store.save_store())
	_toggle_into(box, "Auto-face left/right movement",
		bool(_char().ingame.get("face_move", true)),
		func(v: bool) -> void:
			_char().ingame.face_move = v
			_store.save_store())
	if true:
		var mv: Dictionary = _char().ingame.get("move", {})
		for dir in ["left", "right", "up", "down"]:
			var d := String(dir)
			var mrow := HBoxContainer.new()
			var ml := Label.new()
			ml.text = "Move " + d
			ml.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ml.add_theme_font_size_override("font_size", FONT)
			mrow.add_child(ml)
			var mbind := Button.new()
			var mkey := String(mv.get(d, ""))
			mbind.text = mkey if not mkey.is_empty() else "Assign"
			mbind.custom_minimum_size = Vector2(110, 0)
			mbind.pressed.connect(func() -> void: _prompt_movebind(d))
			mrow.add_child(mbind)
			box.add_child(mrow)


func _rig_row(r: Dictionary) -> Control:
	var wrap := PanelContainer.new()
	var v := VBoxContainer.new()
	wrap.add_child(v)
	var rig_path: String = r.path

	var name_btn := Button.new()
	name_btn.text = String(r.name) \
		+ ("   [IDLE]" if rig_path == String(_char().ingame.idle) else "")
	name_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_btn.add_theme_font_size_override("font_size", FONT)
	if _assigning_idle:
		name_btn.modulate = Color(0.5, 1.0, 0.6)
	elif rig_path == _active_rig_path:
		name_btn.modulate = Color(0.5, 0.8, 1.0)
	name_btn.pressed.connect(func() -> void:
		if _assigning_idle:
			_char().ingame.idle = rig_path
			_assigning_idle = false
			_store.save_store()
			_activate_rig(rig_path)
		else:
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

	var bind := Button.new()
	var bkey: String = _char().ingame.binds.get(rig_path, "")
	bind.text = bkey if not bkey.is_empty() else "Assign"
	bind.tooltip_text = "Bind a key or mouse button: hold to play this animation"
	bind.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bind.pressed.connect(func() -> void: _prompt_keybind(rig_path))
	row.add_child(bind)

	var adv := Button.new()
	adv.text = "Advanced"
	adv.tooltip_text = "Release behavior + hold-frame settings"
	adv.pressed.connect(func() -> void:
		_release_edit_path = rig_path
		_rebuild_content())
	row.add_child(adv)

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
	# Collapsible per-class sub-sections (2026-09-27): the flat list
	# made it too easy to grab a Hair slider while aiming for Cloth.
	var cloth_box := _collapsible(_content, "Cloth", true)
	for spec in [
		["Stiffness", "c_st", 0.01, 0.6], ["Damping", "c_da", 0.0, 0.9],
		["Inertia", "c_in", 0.0, 4.0],
	]:
		var key: String = spec[1]
		_slider_into(cloth_box, spec[0], spec[2], spec[3], float(p[key]),
			func(v: float) -> void: _domain_edit("physics", key, v))
	var hair_box := _collapsible(_content, "Hair", true)
	for spec in [
		["Stiffness", "h_st", 0.01, 1.0], ["Damping", "h_da", 0.0, 0.9],
		["Inertia", "h_in", 0.0, 4.0],
	]:
		var key: String = spec[1]
		_slider_into(hair_box, spec[0], spec[2], spec[3], float(p[key]),
			func(v: float) -> void: _domain_edit("physics", key, v))
	var limb_box := _collapsible(_content, "Limbs", true)
	_toggle_into(limb_box, "Limb sway (flyer legs)", bool(p.limbs),
		func(v: bool) -> void: _domain_edit("physics", "limbs", v))
	for spec in [
		["Stiffness", "l_st", 0.01, 1.0], ["Damping", "l_da", 0.0, 0.9],
		["Inertia", "l_in", 0.0, 4.0],
	]:
		var key: String = spec[1]
		_slider_into(limb_box, spec[0], spec[2], spec[3], float(p[key]),
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
	_caption_into(_content, "Second hand (two-handed grip):")
	var hand2_pick := OptionButton.new()
	hand2_pick.add_item("(one-handed)")
	if _ani != null and _ani.rig != null:
		for bone2 in _ani.rig.bones:
			hand2_pick.add_item(String(bone2.name))
	for i in range(hand2_pick.item_count):
		if i > 0 and hand2_pick.get_item_text(i) == String(w.get("bone2", "")):
			hand2_pick.select(i)
	hand2_pick.item_selected.connect(func(i: int) -> void:
		_domain_edit("weapon", "bone2",
			"" if i == 0 else hand2_pick.get_item_text(i))
		_grip_released = "")
	_content.add_child(hand2_pick)
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
	# Exact layering (2026-09-27): slot the weapon's z directly
	# against one part (e.g. just behind the right hand) instead of
	# the all-or-nothing behind/front toggle. Follows animated part
	# sort orders per frame. Shaded mode only - unshaded rendering
	# draws all parts in one canvas item, so the simple toggle
	# stays the fallback.
	_caption_into(_content, "Layer weapon against a part:")
	var lay_pick := OptionButton.new()
	lay_pick.add_item("(simple behind/front)")
	if _ani != null and _ani.rig != null:
		for bone in _ani.rig.bones:
			lay_pick.add_item(String(bone.name))
	for i in range(lay_pick.item_count):
		if i > 0 and lay_pick.get_item_text(i) == String(w.get("behind_bone", "")):
			lay_pick.select(i)
	lay_pick.item_selected.connect(func(i: int) -> void:
		_domain_edit("weapon", "behind_bone",
			"" if i == 0 else lay_pick.get_item_text(i))
		_apply_weapon_layer())
	_content.add_child(lay_pick)
	_toggle_into(_content, "In front of that part (instead of behind)",
		bool(w.get("layer_front", false)), func(v: bool) -> void:
			_domain_edit("weapon", "layer_front", v)
			_apply_weapon_layer())
	# Crossfades blend each bone's LOCAL rotation, so the hand's
	# composed WORLD rotation can swing through a wide transient arc
	# even when both clips hold the staff upright - seen as the staff
	# waving ~90 deg on in-game release-to-idle fades (2026-09-27).
	# This pins the weapon bone's world rotation via set_bone_aim;
	# children keep their animated locals.
	_toggle_into(_content, "Steady hand angle (lock weapon bone)",
		bool(w.get("steady", false)), func(v: bool) -> void:
			_domain_edit("weapon", "steady", v)
			var t2 := _domain_target("weapon")
			var t2bone := String(t2.get("bone", ""))
			if v and not t2.has("steady_deg") and _ani != null \
					and not t2bone.is_empty():
				# First enable captures the hand's CURRENT angle, so
				# the staff stays put instead of snapping.
				t2.steady_deg = rad_to_deg(
					_ani.get_bone_world_transform(t2bone).get_rotation())
				_store.save_store()
			_apply_domain("weapon")
			_show_submenu("weapon"))
	_int_slider_into(_content, "Steady angle (deg)", -180.0, 180.0,
		float(w.get("steady_deg", 0.0)), func(v: float) -> void:
			_domain_edit("weapon", "steady_deg", v)
			_apply_domain("weapon"))
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
	# Grouped per animation with the frame each event sits on
	# (2026-09-27) - a flat name list said nothing about where or
	# when an event fires. An event named in several clips lists
	# under each; bindings stay keyed by NAME so one binding serves
	# them all. Orphan bindings (event renamed away) list last.
	_events_editor_built = false
	var seen := {}
	for r in _char().rigs:
		var res := _load_rig_res(String(r.path))
		if res == null or (res.events as Array).is_empty():
			continue
		_caption_into(_content, String(r.name) + ":")
		var evs: Array = (res.events as Array).duplicate()
		evs.sort_custom(func(a, b) -> bool:
			return int(a.get("frame", 0)) < int(b.get("frame", 0)))
		for ev in evs:
			var ev_name := String(ev.get("name", ""))
			if ev_name.is_empty():
				continue
			seen[ev_name] = true
			_add_event_row(ev_name, int(ev.get("frame", 0)), bindings)
	var orphans := []
	for n in bindings:
		if not seen.has(n):
			orphans.append(String(n))
	if not orphans.is_empty():
		orphans.sort()
		_caption_into(_content, "Bindings with no matching event:")
		for n2 in orphans:
			_add_event_row(String(n2), -1, bindings)


func _add_event_row(ev_name: String, frame: int, bindings: Dictionary) -> void:
	var cfg: Variant = bindings.get(ev_name)
	var b := Button.new()
	var summary := "unbound" if not cfg is Dictionary \
		else String(cfg.get("type", "?")) + " · " + String(cfg.get("file", ""))
	var frame_txt := "  (frame %d)" % frame if frame >= 0 else ""
	b.text = "%s%s  —  %s" % [ev_name, frame_txt, summary]
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_size_override("font_size", FONT)
	b.modulate = Color(0.5, 0.9, 0.5) if cfg is Dictionary else Color.WHITE
	b.pressed.connect(func() -> void:
		_events_expanded = "" if _events_expanded == ev_name else ev_name
		_show_submenu("events"))
	_content.add_child(b)
	# The same event can list under several animations - build the
	# editor only once, under the first listed row.
	if _events_expanded == ev_name and not _events_editor_built:
		_events_editor_built = true
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
	for t in ["projectile", "burst", "beam_on", "beam_off", "loop",
			"weapon_release", "weapon_engage", "none"]:
		type_pick.add_item(t)
	for i in range(type_pick.item_count):
		if type_pick.get_item_text(i) == String(cfg.type):
			type_pick.select(i)
	type_pick.item_selected.connect(func(i: int) -> void:
		cfg.type = type_pick.get_item_text(i)
		_store.save_store()
		_show_submenu("events"))
	v.add_child(type_pick)

	if String(cfg.type) == "weapon_release":
		# Which hand lets go of a two-handed weapon; the other keeps
		# holding it (transform captured at the release moment).
		_caption_into(v, "Hand that releases:")
		var hand_pick := OptionButton.new()
		hand_pick.add_item("secondary")
		hand_pick.add_item("primary")
		if String(cfg.get("hand", "secondary")) == "primary":
			hand_pick.select(1)
		hand_pick.item_selected.connect(func(i: int) -> void:
			cfg["hand"] = "primary" if i == 1 else "secondary"
			_store.save_store())
		v.add_child(hand_pick)
	if String(cfg.type) not in ["beam_off", "none", "weapon_release", "weapon_engage"]:
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
		# Art-orientation correction (2026-09-27): sheets drawn facing
		# up (etc.) rotate to match their travel/anchor direction.
		_int_slider_into(v, "Effect rotation (deg)", -180.0, 180.0,
			float(cfg.get("rot", 0)), func(val: float) -> void:
				cfg["rot"] = int(val)
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
		if String(cfg.type) in ["loop", "projectile"]:
			# Projectiles default to 1 column (a plain single image);
			# loops default to 4 - untouched old bindings keep their
			# behavior either way.
			var sheet_default := 4 if String(cfg.type) == "loop" else 1
			_int_slider_into(v, "Sheet columns (hframes)", 1.0, 16.0,
				float(cfg.get("hframes", sheet_default)), func(val: float) -> void:
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
		if String(cfg.type) == "loop":
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
	var cursor_aim := _aim_enabled
	if not cursor_aim and not _char_id.is_empty() \
			and not _active_rig_path.is_empty():
		cursor_aim = bool(
			_release_policy(_active_rig_path).get("fx_aim", false))
	if cursor_aim:
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
			# Sheet-aware (2026-09-27): hframes/vframes > 1 flip the
			# projectile through its frames while it travels, instead
			# of drawing the whole strip at once.
			sp.hframes = maxi(1, int(cfg.get("hframes", 1)))
			sp.vframes = maxi(1, int(cfg.get("vframes", 1)))
			sp.global_position = spawn
			var dir := _fx_direction(spawn)
			sp.rotation = dir.angle() + deg_to_rad(float(cfg.get("rot", 0)))
			sp.scale = Vector2(float(cfg.get("scale", 1)), float(cfg.get("scale", 1)))
			add_child(sp)
			_projectiles.append({
				"node": sp, "vel": dir * float(cfg.speed),
				"ttl": float(cfg.life), "cfg": cfg, "t": 0.0,
			})
		"burst":
			var tex2: Texture2D = load(VFX_DIR + "/" + String(cfg.file))
			if tex2 == null:
				return
			var b := Sprite2D.new()
			_crispify(b)
			b.texture = tex2
			b.rotation = deg_to_rad(float(cfg.get("rot", 0)))
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
		"weapon_release":
			_grip_release(String(cfg.get("hand", "secondary")))
		"weapon_engage":
			_grip_released = ""
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


## A hand lets go of a two-handed weapon: capture the weapon's
## transform relative to the REMAINING hand so it rides that hand
## with zero pop until weapon_engage (or a clip switch) restores
## the full grip.
func _grip_release(hand: String) -> void:
	if _weapon == null or _ani == null or _active_rig_path.is_empty():
		return
	var w := _store.effective(_char_id, _active_rig_path, "weapon")
	var keep := String(w.get("bone", "")) if hand == "secondary" \
		else String(w.get("bone2", ""))
	if keep.is_empty() or String(w.get("bone2", "")).is_empty():
		return
	var tk := _ani.get_bone_world_transform(keep)
	_grip_off = tk.affine_inverse() * _weapon.position
	_grip_rot = _weapon.rotation - tk.get_rotation()
	_grip_released = hand


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
		pr["t"] = float(pr.get("t", 0.0)) + delta
		var pcfg: Dictionary = pr.get("cfg", {})
		var ptotal := maxi(1, int(pcfg.get("hframes", 1))) \
			* maxi(1, int(pcfg.get("vframes", 1)))
		if ptotal > 1:
			(pr.node as Sprite2D).frame = \
				int(float(pr["t"]) * float(pcfg.get("fps", 10.0))) % ptotal
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
		node.rotation = lt.get_rotation() + _ani.rotation \
			+ deg_to_rad(float(lcfg.get("rot", 0)))
		# Scale + sheet grid read LIVE like fps already was - they
		# were spawn-frozen, so slider changes did nothing to a
		# long-lived loop (parked charge-ups) until it respawned
		# (2026-09-27). lcfg is the stored binding dict itself, so
		# the editor's writes land here immediately.
		node.scale = Vector2.ONE * float(lcfg.get("scale", 1.0))
		node.hframes = maxi(1, int(lcfg.get("hframes", 4)))
		node.vframes = maxi(1, int(lcfg.get("vframes", 1)))
		var total := maxi(1, int(lcfg.get("hframes", 4))) \
			* maxi(1, int(lcfg.get("vframes", 1)))
		node.frame = int(lp.t * float(lcfg.get("fps", 10.0))) % total
		live_loops.append(lp)
	_loops = live_loops
	if _beam != null and _ani != null and not _beam_cfg.is_empty():
		var spawn := _bone_anchor_global(_beam_cfg)
		var dir := _fx_direction(spawn)
		_beam.global_position = spawn
		_beam.rotation = dir.angle() + deg_to_rad(float(_beam_cfg.get("rot", 0)))
		_beam_len = minf(
			_beam_len + float(_beam_cfg.get("rate", 1200.0)) * delta,
			float(_beam_cfg.get("length", 260.0)))
		var tex_w := float(_beam.texture.get_width())
		_beam.scale = Vector2(
			_beam_len / maxf(tex_w, 1.0),
			float(_beam_cfg.get("scale", 1.0)))


# ── In-Game mode ───────────────────────────────────────────────────

func _prompt_keybind(rig_path: String) -> void:
	_capture_rig_path = rig_path
	_capture_move_dir = ""
	_open_capture(String(_char().ingame.binds.get(rig_path, "")))


func _prompt_movebind(dir: String) -> void:
	_capture_rig_path = ""
	_capture_move_dir = dir
	_open_capture(String(
		(_char().ingame.get("move", {}) as Dictionary).get(dir, "")))


func _open_capture(existing: String) -> void:
	_captured_key = ""
	_capture_dialog = AcceptDialog.new()
	_capture_dialog.title = "Press a key - or pick a mouse button below"
	_capture_dialog.ok_button_text = "Confirm"
	_capture_label = Label.new()
	_capture_label.text = "(waiting for input...)"
	_capture_label.custom_minimum_size = Vector2(260, 40)
	_capture_label.add_theme_font_size_override("font_size", FONT_HEAD)
	_capture_dialog.add_child(_capture_label)
	var dlg_btns: Array = [
		_capture_dialog.get_ok_button(),
		_capture_dialog.add_cancel_button("Cancel"),
	]
	# Mouse buttons come from dialog buttons rather than raw click
	# capture - raw capture would swallow the clicks aimed at
	# Confirm/Cancel themselves.
	dlg_btns.append(_capture_dialog.add_button("LMB", false, "mouse1"))
	dlg_btns.append(_capture_dialog.add_button("RMB", false, "mouse2"))
	dlg_btns.append(_capture_dialog.add_button("MMB", false, "mouse3"))
	if not existing.is_empty():
		dlg_btns.append(_capture_dialog.add_button("Unbind", false, "unbind"))
	# Keys must reach the capture listener, not a focused button -
	# otherwise Space/Enter "click" the button instead of binding.
	for b in dlg_btns:
		(b as Control).focus_mode = Control.FOCUS_NONE
	# The dialog is a Window: while it has focus, key events route to
	# ITS viewport and never reach this node's _input - listen on the
	# dialog itself (the capture sat at "waiting for input..." forever
	# otherwise, 2026-09-26).
	_capture_dialog.window_input.connect(func(ev: InputEvent) -> void:
		if not ev is InputEventKey:
			return
		var ke := ev as InputEventKey
		if ke.pressed and not ke.echo and ke.keycode not in [
			KEY_CTRL, KEY_SHIFT, KEY_ALT, KEY_META,
		]:
			_captured_key = OS.get_keycode_string(
				ke.get_keycode_with_modifiers())
			_capture_label.text = _captured_key)
	_capture_dialog.confirmed.connect(func() -> void:
		if not _captured_key.is_empty():
			_commit_bind(_captured_key)
		_close_capture())
	_capture_dialog.custom_action.connect(func(action: StringName) -> void:
		var a := String(action)
		if a.begins_with("mouse"):
			_captured_key = "Mouse" + a.substr(5)
			_capture_label.text = _captured_key
			return
		if a == "unbind":
			_commit_bind("")
			_close_capture())
	_capture_dialog.canceled.connect(_close_capture)
	_dialog_layer.add_child(_capture_dialog)
	_capture_dialog.popup_centered()


## Write the captured bind to whichever slot the dialog was opened
## for (clip bind or movement direction); empty = unbind.
func _commit_bind(key: String) -> void:
	if not _capture_move_dir.is_empty():
		var mv: Dictionary = _char().ingame.get("move", {})
		if key.is_empty():
			mv.erase(_capture_move_dir)
		else:
			mv[_capture_move_dir] = key
		_char().ingame.move = mv
	elif key.is_empty():
		_char().ingame.binds.erase(_capture_rig_path)
	else:
		_char().ingame.binds[_capture_rig_path] = key
	_store.save_store()


func _close_capture() -> void:
	if _capture_dialog != null:
		_capture_dialog.queue_free()
		_capture_dialog = null
	_rebuild_content()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and _capture_dialog == null \
			and _screen == Screen.SANDBOX and _ani != null \
			and _ani.rig != null and not _attach_mode:
		var mb := event as InputEventMouseButton
		var over_ui := (_work_root != null and _work_root.visible \
			and _work_root.get_global_rect().has_point(mb.position)) \
			or (_joy != null and _joy.visible \
			and _joy.get_global_rect().has_point(mb.position)) \
			or (_panel_tab != null and _panel_tab.visible \
			and _panel_tab.get_global_rect().has_point(mb.position)) \
			or (_scrub_box != null and _scrub_box.visible \
			and _scrub_box.get_global_rect().has_point(mb.position)) \
			or (_save_btn != null and _save_btn.visible \
			and _save_btn.get_global_rect().has_point(mb.position))
		var mname := "Mouse%d" % mb.button_index
		var mbinds: Dictionary = _char().ingame.binds
		if mb.pressed and not over_ui and not _anim_committed():
			for rig_path in mbinds:
				if mbinds[rig_path] == mname:
					_held_bind_key = mname
					_crossfade_to_path(rig_path)
					return
		elif not mb.pressed and _held_bind_key == mname:
			# Releases count even over the panel, so a clip can't
			# stick on after a drag onto the UI.
			_release_held_bind()
		return
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
	# Bound key held -> that clip; released -> idle.
	if _screen != Screen.SANDBOX or _ani == null or _ani.rig == null:
		return
	var pressed_name := OS.get_keycode_string(
		key_event.get_keycode_with_modifiers())
	var binds: Dictionary = _char().ingame.binds
	if key_event.pressed:
		# Typing in a text field must not fire attacks.
		if get_viewport().gui_get_focus_owner() is LineEdit:
			return
		# A committed clip (complete / past-cutoff) finishes first.
		if _anim_committed():
			return
		for rig_path in binds:
			if binds[rig_path] == pressed_name:
				_held_bind_key = pressed_name
				_crossfade_to_path(rig_path)
				return
	else:
		var released_plain := OS.get_keycode_string(key_event.keycode)
		if _held_bind_key != "" and (_held_bind_key == pressed_name
				or _held_bind_key.ends_with(released_plain)):
			_release_held_bind()


## First animation flagged (Advanced menu) for ANY of the held
## movement directions; "" when none matches.
func _movement_anim_for(held: Array) -> String:
	for r in _char().rigs:
		var path := String(r.path)
		var rel := _release_policy(path)
		for d in held:
			if bool(rel.get("move_" + String(d), false)):
				return path
	return ""


## Is the named bind currently held? Handles "Mouse<n>" and plain
## keys; a modifier combo polls its final key (movement binds are
## expected to be plain keys).
func _bind_down(bind_name: String) -> bool:
	if bind_name.is_empty():
		return false
	if bind_name.begins_with("Mouse"):
		return Input.is_mouse_button_pressed(
			int(bind_name.substr(5)) as MouseButton)
	var plain := bind_name.get_slice(
		"+", bind_name.get_slice_count("+") - 1)
	return Input.is_key_pressed(OS.find_keycode_from_string(plain))


## Per-animation release policy: what happens when the bound input
## is let go. "complete" plays the clip to its final frame first;
## "cut" idles immediately; "cutoff" completes only when released at
## or past the chosen frame (an attack-commit point).
## Playback-tunable crossfade length for every playground clip
## switch (sandbox activation and all in-game transitions).
func _fade_sec() -> float:
	return maxf(0.05, float(_char().playback.get("fade_ms", 350)) / 1000.0)


func _release_policy(path: String) -> Dictionary:
	var all: Dictionary = _char().ingame.get("release", {})
	var rel: Variant = all.get(path)
	if rel is Dictionary:
		return rel
	return {"mode": "complete", "frame": 0, "hold_frame": -1,
		"hold_secs": 1.0, "charge_clip": "", "charge_ms": 500}


func _set_release(path: String, key: String, value: Variant) -> void:
	var all: Dictionary = _char().ingame.get("release", {})
	var rel: Dictionary = all.get(path,
		{"mode": "complete", "frame": 0, "hold_frame": -1, "hold_secs": 1.0})
	rel[key] = value
	all[path] = rel
	_char().ingame.release = all
	_store.save_store()


func _build_release_editor() -> void:
	var title := Label.new()
	title.text = _release_edit_path.get_file().get_basename() + " - Advanced"
	title.add_theme_font_size_override("font_size", FONT_HEAD)
	_content.add_child(title)
	var rel := _release_policy(_release_edit_path)
	_caption_into(_content, "When its button is released:")
	var modes := ["complete", "cut", "cutoff"]
	var pick := OptionButton.new()
	pick.add_item("Complete the animation")
	pick.add_item("Cut to idle immediately")
	pick.add_item("Complete only past a cutoff frame")
	pick.select(maxi(0, modes.find(String(rel.get("mode", "complete")))))
	pick.item_selected.connect(func(i: int) -> void:
		_set_release(_release_edit_path, "mode", modes[i])
		_rebuild_content())
	_content.add_child(pick)
	if String(rel.get("mode", "complete")) == "cutoff":
		_int_slider_into(_content, "Cutoff frame", 0.0, 119.0,
			float(rel.get("frame", 0)), func(v: float) -> void:
				_set_release(_release_edit_path, "frame", int(v)))
		var ch := Label.new()
		ch.text = "Released before that frame: cut to idle. At or after: completes."
		ch.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		ch.modulate = Color(1, 1, 1, 0.6)
		ch.add_theme_font_size_override("font_size", 12)
		_content.add_child(ch)
	_content.add_child(HSeparator.new())
	# Per-animation cursor aiming (2026-09-27): a bone (an arm) can
	# track the cursor while this clip plays, and/or the clip's
	# spawned effects (projectiles, beam) can fire toward the cursor.
	_caption_into(_content, "Cursor aiming (while this animation plays):")
	_toggle_into(_content, "Aim a bone at the cursor",
		bool(rel.get("aim_enabled", false)), func(v: bool) -> void:
			_set_release(_release_edit_path, "aim_enabled", v)
			_rebuild_content())
	if bool(rel.get("aim_enabled", false)):
		_caption_into(_content, "Aimed bone:")
		var aim_pick := OptionButton.new()
		_fill_bone_pick(aim_pick, "arm")
		var aim_matched := false
		for i in range(aim_pick.item_count):
			if aim_pick.get_item_text(i) == String(rel.get("aim_bone", "")):
				aim_pick.select(i)
				aim_matched = true
		# Commit the displayed default (same write-back rule as the
		# event editor's dropdowns).
		if not aim_matched and aim_pick.selected >= 0:
			_set_release(_release_edit_path, "aim_bone",
				aim_pick.get_item_text(aim_pick.selected))
		aim_pick.item_selected.connect(func(i: int) -> void:
			_set_release(_release_edit_path, "aim_bone",
				aim_pick.get_item_text(i)))
		_content.add_child(aim_pick)
		_int_slider_into(_content, "Aim strength (%)", 0.0, 100.0,
			float(rel.get("aim_weight", 100)), func(v: float) -> void:
				_set_release(_release_edit_path, "aim_weight", int(v)))
	_toggle_into(_content, "Effects aim at the cursor",
		bool(rel.get("fx_aim", false)), func(v: bool) -> void:
			_set_release(_release_edit_path, "fx_aim", v))
	_content.add_child(HSeparator.new())
	# Movement animation (2026-09-28): while a bound direction input
	# with a checked box here is held, this animation plays and the
	# character glides that way (left/right auto-mirror facing when
	# the Movement section's auto-face toggle is on).
	_caption_into(_content, "Movement animation for held directions:")
	var mdir_row := HBoxContainer.new()
	mdir_row.add_theme_constant_override("separation", 10)
	for mspec in [["Left", "move_l"], ["Right", "move_r"],
			["Up", "move_u"], ["Down", "move_d"]]:
		var mkey: String = mspec[1]
		_toggle_into(mdir_row, String(mspec[0]),
			bool(rel.get(mkey, false)), func(v: bool) -> void:
				_set_release(_release_edit_path, mkey, v))
	_content.add_child(mdir_row)
	_content.add_child(HSeparator.new())
	# Charge-hold, per animation: park on this frame (auto-play uses
	# the timer; a held bind parks while the input is down).
	_int_slider_into(_content, "Hold at frame (-1 = off)", -1.0, 119.0,
		float(rel.get("hold_frame", -1)), func(v: float) -> void:
			_set_release(_release_edit_path, "hold_frame", int(v)))
	_int_slider_into(_content, "Hold seconds (-1 = forever)", -1.0, 10.0,
		float(rel.get("hold_secs", 1.0)), func(v: float) -> void:
			_set_release(_release_edit_path, "hold_secs", v))
	# Charged release (2026-09-28): released from an infinite hold
	# after at least the threshold, a DIFFERENT animation plays as
	# the release instead of this clip's own tail - tap keeps the
	# quick attack, a long hold branches to the heavy one.
	_caption_into(_content, "Charged release plays instead (optional):")
	var cc_pick := OptionButton.new()
	var cc_paths := [""]
	cc_pick.add_item("(none)")
	for r in _char().rigs:
		if String(r.path) != _release_edit_path:
			cc_pick.add_item(String(r.name))
			cc_paths.append(String(r.path))
	for i in range(cc_paths.size()):
		if i > 0 and cc_paths[i] == String(rel.get("charge_clip", "")):
			cc_pick.select(i)
	cc_pick.item_selected.connect(func(i: int) -> void:
		_set_release(_release_edit_path, "charge_clip", cc_paths[i]))
	_content.add_child(cc_pick)
	if not String(rel.get("charge_clip", "")).is_empty():
		_int_slider_into(_content, "Charge threshold (ms)", 100.0, 5000.0,
			float(rel.get("charge_ms", 500)), func(v: float) -> void:
				_set_release(_release_edit_path, "charge_ms", int(v)))
		var cc_hint := Label.new()
		cc_hint.text = ("Needs a hold frame with Hold seconds -1: time "
			+ "parked there while the input is held is what charges.")
		cc_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		cc_hint.modulate = Color(1, 1, 1, 0.6)
		cc_hint.add_theme_font_size_override("font_size", 12)
		_content.add_child(cc_hint)
	_btn_into(_content, "Back", func() -> void:
		_release_edit_path = ""
		_rebuild_content())


## True while the active bind-triggered clip is COMMITTED: its
## release policy says it must finish ("complete", or "cutoff" with
## the playhead already at/past the cutoff frame), so new bind
## presses are ignored until it lands back at idle (2026-09-27).
## Only in-flight clips lock (a held input or a playing release
## tail) - the idle loop never does - and scrub-hold bypasses it.
func _anim_committed() -> bool:
	if _ani == null or _ani.rig == null or _active_rig_path.is_empty():
		return false
	if _scrub_paused:
		return false
	if _held_bind_key.is_empty() and not _ig_release_pending:
		return false
	var rel := _release_policy(_active_rig_path)
	match String(rel.get("mode", "complete")):
		"complete":
			return true
		"cutoff":
			return int(_ani.get_current_frame()) >= int(rel.get("frame", 0))
	return false


func _release_held_bind() -> void:
	_held_bind_key = ""
	if _ani == null:
		return
	if _scrub_paused:
		# Scrub-hold: a release neither cancels nor completes - the
		# clip stays parked for frame stepping. Cut-on-release
		# policies made bind-triggered clips impossible to scrub
		# (the release yanked them to idle, 2026-09-28).
		return
	var rel := _release_policy(_active_rig_path)
	# Charged-release branch: released from the hold park after the
	# threshold, a different clip IS the release - it plays out and
	# then idles like a completed tail.
	var charge_clip := String(rel.get("charge_clip", ""))
	if _ig_parked and not charge_clip.is_empty() \
			and _hold_elapsed * 1000.0 >= float(rel.get("charge_ms", 500)):
		_ig_parked = false
		# Clamp the outgoing clip so it holds its parked pose under
		# the fade instead of wrapping and replaying its start.
		_ani.loop_override = 0
		_crossfade_to_path(charge_clip)
		_ig_release_pending = true
		return
	var complete := true
	match String(rel.get("mode", "complete")):
		"cut":
			complete = false
		"cutoff":
			complete = int(_ani.get_current_frame()) >= int(rel.get("frame", 0))
	if _ig_parked:
		_ig_parked = false
		_ani.play()
	if complete:
		# _process idles once the clip reaches its final frame.
		_ig_release_pending = true
		return
	# Cutting mid-clip skips the events that would end effects, so
	# kill them here instead of leaving a stuck beam/loop.
	_beam_off()
	_loops_off()
	var idle: String = _char().ingame.idle
	if not idle.is_empty():
		# The abandoned clip must not wrap around under the fade.
		_ani.loop_override = 0
		_crossfade_to_path(idle)


func _crossfade_to_path(path: String) -> void:
	var res := _load_rig_res(path)
	if res == null:
		return
	# Any clip switch cancels hold/pending state (a re-press during
	# the pending window keeps its fresh clip instead of idling).
	_ig_parked = false
	_ig_release_pending = false
	if _ani.rig == null:
		_activate_rig(path)
		return
	# Scrub-hold: hard-cut (a fade would freeze mid-blend showing
	# the OLD pose) and park on frame 0 - speed stays 0 via
	# _apply_playback, so frame-0 events still fire.
	_ani.crossfade_to(res, 0.0 if _scrub_paused else _fade_sec())
	_ani.loop_override = 1
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
	_ig_parked = false
	_ig_release_pending = false
	_grip_released = ""
	_hold_elapsed = 0.0
	# One-time adoption of a weapon fitting saved by the pre-rework
	# playground (keyed by root-bone uuid) into this character.
	_store.adopt_legacy_weapon(_char_id, res)
	# Blend into the new clip instead of hard-cutting (crossfade_to
	# falls back to a cut when there is nothing to fade from). The
	# loop override is set AFTER the fade capture, so the OUTGOING
	# clip keeps its own effective looping through the blend.
	_ani.crossfade_to(res, 0.0 if _scrub_paused else _fade_sec())
	_ani.loop_override = 1
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
			var steady_bone := String(t.get("bone", ""))
			if not steady_bone.is_empty():
				_ani.set_bone_aim(
					steady_bone,
					deg_to_rad(float(t.get("steady_deg", 0.0))),
					1.0 if bool(t.get("steady", false)) else 0.0)
				# The rig setter cleared bone aims and already
				# evaluated a pose WITHOUT the steady lock - without
				# this re-evaluation that unpinned pose renders for
				# one frame on every clip switch (the staff flicked
				# ~15 deg at the end of the beam attack, 2026-09-27).
				_ani.set_current_frame(_ani.get_current_frame())


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


## z of the shaded child sprite for [bone_name]; a sentinel when the
## bone has no shaded child (unshaded mode / bad name).
func _weapon_part_z(bone_name: String) -> int:
	if _ani == null:
		return -100000
	for uuid in _ani._bone_by_uuid:
		var bn := String((_ani._bone_by_uuid[uuid] as Dictionary).get("name", ""))
		if bn == bone_name:
			var sp: Variant = _ani._shaded_sprites.get(uuid)
			if sp != null and is_instance_valid(sp):
				return (sp as Sprite2D).z_index
			return -100000
	return -100000


func _apply_weapon_layer() -> void:
	if _weapon == null:
		return
	var w := _store.effective(_char_id, _active_rig_path, "weapon")
	_weapon.z_as_relative = true
	var bb := String(w.get("behind_bone", ""))
	if not bb.is_empty():
		var pz := _weapon_part_z(bb)
		if pz > -100000:
			_weapon.show_behind_parent = false
			_weapon.z_index = pz + \
				(1 if bool(w.get("layer_front", false)) else -1)
			return
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
	if _joy_check != null:
		_joy_check.button_pressed = bool(pb.get("joystick", true))
	if _show_frames_check != null:
		_show_frames_check.button_pressed = bool(pb.get("show_frames", false))
	if _fade_slider != null:
		_fade_slider.value = float(pb.get("fade_ms", 350))


func _apply_playback() -> void:
	if _ani == null:
		return
	var pb: Dictionary = _char().playback
	var z := float(pb.zoom)
	_ani.scale = Vector2(z * signf(_ani.scale.x if _ani.scale.x != 0 else 1.0), z)
	_ani.speed = 0.0 if _scrub_paused else float(pb.speed)


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
	# Two-handed grips derive rotation from the primary-grip -> second
	# hand line, so the saved offset must be measured against THAT.
	var bone2 := String(target.get("bone2", ""))
	if bone2.is_empty():
		target.rot = _weapon.rotation - t.get_rotation()
	else:
		var hand2 := _ani.get_bone_world_transform(bone2).origin
		target.rot = _weapon.rotation - (hand2 - _weapon.position).angle()
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
	if _save_btn != null:
		_save_btn.offset_right = edge - 8.0
		_save_btn.offset_left = edge - 76.0
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
	if _frame_readout != null:
		var show_fr: bool = not _char_id.is_empty() and _ani.rig != null \
			and bool(_char().playback.get("show_frames", false))
		_frame_readout.visible = show_fr
		if show_fr:
			var anim_name := _active_rig_path.get_file().get_basename()
			var fr_entry := _store.rig_entry(_char_id, _active_rig_path)
			if not fr_entry.is_empty():
				anim_name = String(fr_entry.name)
			_frame_readout.text = "%s — Frame %d / %d" % [anim_name,
				int(_ani.get_current_frame()), _ani.rig.total_frames]
	if _screen == Screen.SANDBOX:
		var tilt := _joy.deflect if _joy != null else Vector2.ZERO
		if tilt != Vector2.ZERO:
			_ani.position += tilt \
				* (DRAG_MAX_DEFLECT * DRAG_SPEED_PER_PX) * delta
		elif bool(_char().playback.sway) and not _attach_mode:
			_sway_t += delta
			_ani.position = _base_pos + Vector2(sin(_sway_t * 2.2) * 90.0, 0)
	# Charge hold (per animation, Advanced menu). A TIMED hold (secs
	# >= 0) takes priority in every playback mode: the clip parks on
	# the hold frame for the set time - held key or not - then
	# resumes (2026-09-27). An INFINITE hold (-1) parks until
	# 'Release Infinite Hold' in plain playback, or tracks the held
	# input via the block below when bind-triggered. The cooldown
	# keeps the resume from re-parking until the playhead has left
	# the hold frame (looping clips re-arm on the next pass).
	if _screen == Screen.SANDBOX and not _char_id.is_empty() \
			and not _active_rig_path.is_empty():
		var rel_hold := _release_policy(_active_rig_path)
		var hold_f := int(rel_hold.get("hold_frame", -1))
		var hold_secs := float(rel_hold.get("hold_secs", 1.0))
		var timed: bool = hold_secs >= 0.0
		if _hold_cooldown and int(_ani.get_current_frame()) != hold_f:
			_hold_cooldown = false
		elif _hold_waiting and hold_f < 0:
			# Sliding Hold-at-frame back to -1 releases a parked hold.
			_hold_waiting = false
			_hold_cooldown = true
			_ani.play()
		elif hold_f >= 0 and not _hold_waiting and not _hold_cooldown \
				and _ani.is_playing() \
				and int(_ani.get_current_frame()) == hold_f \
				and (timed or (_held_bind_key.is_empty() \
					and not _ig_release_pending)):
			_ani.pause()
			_hold_waiting = true
			if timed:
				var held := _ani
				get_tree().create_timer(maxf(0.1, hold_secs)) \
					.timeout.connect(func() -> void:
						_hold_waiting = false
						_hold_cooldown = true
						if is_instance_valid(held) and held == _ani:
							held.play())
			# infinite: released by the button, the hold-frame
			# slider, or a rig switch.
	# Held-bind hold: a held input parks its clip on the animation's
	# hold frame (-1 = off) until released; the release resumes the
	# clip first so the events past the hold (beam_end) fire, then
	# _process idles once the clip reaches its final frame.
	if _screen == Screen.SANDBOX and not _char_id.is_empty() \
			and not _active_rig_path.is_empty():
		var ig_rel := _release_policy(_active_rig_path)
		var ig_hold := int(ig_rel.get("hold_frame", -1))
		var at_hold: bool = ig_hold >= 0 and int(_ani.get_current_frame()) == ig_hold
		if _ig_parked:
			_hold_elapsed += delta
		if not _held_bind_key.is_empty() and not _ig_parked and at_hold \
				and _ani.is_playing() \
				and float(ig_rel.get("hold_secs", 1.0)) < 0.0:
			_ani.pause()
			_ig_parked = true
			_hold_elapsed = 0.0
		elif _ig_release_pending and _ani.is_playing():
			# Play the authored return-to-idle tail out in full; only
			# the LAST frame hands off to the idle crossfade. Fading
			# out one frame past the hold skipped the return arc and
			# made the staff jump across the chest (2026-09-27).
			if int(_ani.get_current_frame()) >= _ani.rig.total_frames - 1:
				_ig_release_pending = false
				var post_idle: String = _char().ingame.idle
				if not post_idle.is_empty():
					# Clamp the finished clip so the fade blends from
					# its held FINAL pose - looping through frame 0
					# mid-fade read as the whole clip replaying.
					_ani.loop_override = 0
					_crossfade_to_path(post_idle)
	# Movement: bound direction inputs. An animation flagged for a
	# held direction (Advanced menu) plays while moving; the static
	# toggle glides even without one (flyers). Left/right auto-
	# mirrors facing (art faces LEFT natively). An in-flight attack
	# is never interrupted - the glide continues and the movement
	# animation resumes when the attack lands.
	if _screen == Screen.SANDBOX and not _char_id.is_empty() \
			and _capture_dialog == null and not _scrub_paused:
		var mvb: Dictionary = _char().ingame.get("move", {})
		var dv := Vector2.ZERO
		var held_dirs := []
		if _bind_down(String(mvb.get("left", ""))):
			dv.x -= 1.0
			held_dirs.append("l")
		if _bind_down(String(mvb.get("right", ""))):
			dv.x += 1.0
			held_dirs.append("r")
		if _bind_down(String(mvb.get("up", ""))):
			dv.y -= 1.0
			held_dirs.append("u")
		if _bind_down(String(mvb.get("down", ""))):
			dv.y += 1.0
			held_dirs.append("d")
		var move_anim := ""
		if not held_dirs.is_empty():
			move_anim = _movement_anim_for(held_dirs)
		var attack_busy: bool = not _held_bind_key.is_empty() \
			or _ig_release_pending
		if dv != Vector2.ZERO and (not move_anim.is_empty() \
				or bool(_char().ingame.get("move_enabled", false))):
			_ani.position += dv.normalized() \
				* (DRAG_MAX_DEFLECT * DRAG_SPEED_PER_PX) * delta
			if dv.x != 0.0 and bool(_char().ingame.get("face_move", true)):
				_ani.scale.x = absf(_ani.scale.x) \
					* (-1.0 if dv.x > 0.0 else 1.0)
		if not attack_busy:
			if not move_anim.is_empty() and move_anim != _active_rig_path:
				_moving_via_anim = true
				_crossfade_to_path(move_anim)
			elif move_anim.is_empty() and _moving_via_anim:
				_moving_via_anim = false
				var move_idle: String = _char().ingame.idle
				if not move_idle.is_empty() \
						and move_idle != _active_rig_path:
					_crossfade_to_path(move_idle)
	# Cursor aim.
	if _aim_enabled and _ani.rig != null and _aim_bone_pick != null \
			and _aim_bone_pick.selected >= 0:
		var aim_bone := _aim_bone_pick.get_item_text(_aim_bone_pick.selected)
		var origin: Vector2 = _ani.get_bone_world_transform(aim_bone).origin
		var local_target := _ani.to_local(get_global_mouse_position())
		_ani.set_bone_aim(
			aim_bone, (local_target - origin).angle(), _aim_weight)
	# Per-animation cursor aim (Advanced menu): while this clip plays,
	# its chosen bone tracks the cursor. The Layering menu's manual
	# aim toggle overrides while enabled (explicit test tool).
	elif not _char_id.is_empty() and not _active_rig_path.is_empty() \
			and _ani.rig != null:
		var arel := _release_policy(_active_rig_path)
		var abone := String(arel.get("aim_bone", ""))
		var aiming: bool = bool(arel.get("aim_enabled", false)) \
			and not abone.is_empty()
		if aiming and abone != _anim_aim_bone \
				and not _anim_aim_bone.is_empty():
			# The aimed bone changed between clips: drop the old one.
			_ani.set_bone_aim(_anim_aim_bone, 0.0, 0.0)
			_anim_aim_w = 0.0
		if aiming:
			_anim_aim_bone = abone
			var aorigin: Vector2 = _ani.get_bone_world_transform(abone).origin
			_anim_aim_angle = (_ani.to_local(get_global_mouse_position())
				- aorigin).angle()
		# The weight eases in/out over the crossfade duration instead
		# of snapping - the arm used to jump off the cursor the
		# instant the throw handed back to idle (2026-09-27). The
		# last cursor angle is held while fading out, and bone aims
		# survive rig switches, so the fade rides the transition.
		var aim_goal := 0.0
		if aiming:
			aim_goal = float(arel.get("aim_weight", 100)) / 100.0
		if not _anim_aim_bone.is_empty():
			_anim_aim_w = move_toward(_anim_aim_w, aim_goal,
				delta / maxf(_fade_sec(), 0.05))
			_ani.set_bone_aim(_anim_aim_bone, _anim_aim_angle, _anim_aim_w)
			if _anim_aim_w <= 0.0 and not aiming:
				_ani.set_bone_aim(_anim_aim_bone, 0.0, 0.0)
				_anim_aim_bone = ""
	# Weapon live follow (not while fitting).
	var w := {} if _active_rig_path.is_empty() else \
		_store.effective(_char_id, _active_rig_path, "weapon")
	if _weapon != null and not _attach_mode \
			and not String(w.get("bone", "")).is_empty():
		var t := _ani.get_bone_world_transform(String(w.bone))
		var wb2 := String(w.get("bone2", ""))
		if not wb2.is_empty() and not _grip_released.is_empty():
			# Momentary one-hand hold (weapon_release event): ride the
			# remaining hand with the transform captured at release.
			var keep := String(w.bone) if _grip_released == "secondary" else wb2
			var tk := _ani.get_bone_world_transform(keep)
			_weapon.position = tk * _grip_off
			_weapon.rotation = tk.get_rotation() + _grip_rot
		elif not wb2.is_empty():
			# Two-handed grip (2026-09-28): anchored at the primary
			# grip point, rotated along the line to the second hand -
			# the weapon always lies on the grip axis, which is the
			# stability between the hands.
			var p1 := t * Vector2(float(w.get("ox", 0)), float(w.get("oy", 0)))
			var p2: Vector2 = _ani.get_bone_world_transform(wb2).origin
			_weapon.position = p1
			if p1.distance_to(p2) > 0.5:
				_weapon.rotation = (p2 - p1).angle() + float(w.get("rot", 0))
		else:
			_weapon.position = t * Vector2(float(w.get("ox", 0)), float(w.get("oy", 0)))
			_weapon.rotation = t.get_rotation() + float(w.get("rot", 0))
		_weapon.scale = Vector2(float(w.get("scale", 1)), float(w.get("scale", 1)))
		# Part sort orders can be ANIMATED - keep the part-relative
		# weapon z in step with them.
		if not String(w.get("behind_bone", "")).is_empty():
			_apply_weapon_layer()
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
