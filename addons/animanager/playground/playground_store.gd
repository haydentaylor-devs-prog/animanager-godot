extends RefCounted
## Persistence for the AniMate Playground (2026-09-25 rework):
## characters, each owning their rigs (with per-rig setting
## overrides), layering bookkeeping, named presets, in-game
## keybinds/idle, and a continuously-autosaved working session.
## One JSON at user://animate_playground.json. The old per-rig
## preset/weapon files are superseded; a legacy weapon fitting is
## adopted the first time its rig is added to a character.

const PATH := "user://animate_playground.json"
const LEGACY_WEAPONS := "user://weapon_attachments.json"

var data: Dictionary = {"characters": {}}


func load_store() -> void:
	if not FileAccess.file_exists(PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if parsed is Dictionary and (parsed as Dictionary).has("characters"):
		data = parsed


func save_store() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "  "))


func characters() -> Dictionary:
	return data.characters


static func default_physics() -> Dictionary:
	return {
		"enabled": true,
		"c_st": 0.12, "c_da": 0.18, "c_in": 1.0,
		"h_st": 0.25, "h_da": 0.08, "h_in": 1.2,
		"limbs": false,
		"l_st": 0.35, "l_da": 0.25, "l_in": 0.6,
	}


static func default_shading() -> Dictionary:
	return {"shaded": true, "tint": 2.0, "lx": 0.35, "ly": -0.55, "lz": 0.75}


static func default_playback() -> Dictionary:
	return {"zoom": 3.0, "speed": 1.0, "sway": true}


func create_character(char_name: String) -> String:
	var id := "%d_%d" % [Time.get_unix_time_from_system(), randi() % 10000]
	data.characters[id] = {
		"name": char_name,
		"shared": {
			"physics": default_physics(),
			"shading": default_shading(),
			"weapon": {},
		},
		"playback": default_playback(),
		"rigs": [],
		"layers": [],
		"next_group": 1,
		"presets": {},
		"current_preset": "Default",
		"ingame": {"idle": "", "binds": {}},
	}
	# Every character starts with a Default preset (the spec).
	var c: Dictionary = data.characters[id]
	c.presets["Default"] = snapshot(id)
	save_store()
	return id


func character(id: String) -> Dictionary:
	return data.characters.get(id, {})


## Deep snapshot of everything a preset covers.
func snapshot(id: String) -> Dictionary:
	var c := character(id)
	return {
		"shared": (c.shared as Dictionary).duplicate(true),
		"playback": (c.playback as Dictionary).duplicate(true),
		"rigs": (c.rigs as Array).duplicate(true),
		"layers": (c.layers as Array).duplicate(true),
		"ingame": (c.ingame as Dictionary).duplicate(true),
	}


func apply_snapshot(id: String, snap: Dictionary) -> void:
	var c := character(id)
	if c.is_empty() or snap.is_empty():
		return
	c.shared = (snap.get("shared", c.shared) as Dictionary).duplicate(true)
	c.playback = (snap.get("playback", c.playback) as Dictionary).duplicate(true)
	c.rigs = (snap.get("rigs", c.rigs) as Array).duplicate(true)
	c.layers = (snap.get("layers", c.layers) as Array).duplicate(true)
	c.ingame = (snap.get("ingame", c.ingame) as Dictionary).duplicate(true)
	save_store()


func add_rig(id: String, path: String) -> Dictionary:
	var c := character(id)
	for r in c.rigs:
		if r.path == path:
			return r
	var entry := {
		"path": path,
		"name": path.get_file().get_basename(),
		"ovr": {"physics": null, "shading": null, "weapon": null},
		"group": 0,
	}
	c.rigs.append(entry)
	save_store()
	return entry


func rig_entry(id: String, path: String) -> Dictionary:
	for r in character(id).get("rigs", []):
		if r.path == path:
			return r
	return {}


## Effective settings for a rig: its override when flagged unique,
## else the character's shared block.
func effective(id: String, rig_path: String, domain: String) -> Dictionary:
	var r := rig_entry(id, rig_path)
	if not r.is_empty() and r.ovr.get(domain) is Dictionary:
		return r.ovr[domain]
	return character(id).shared[domain]


## Record a layering pair; base rigs with 2+ overlays keep their
## first group number but display as 'L' (UI concern).
func add_layer(id: String, base_path: String, overlay_path: String, mask: String) -> int:
	var c := character(id)
	var group: int = c.next_group
	c.next_group += 1
	c.layers.append({
		"base": base_path, "overlay": overlay_path,
		"group": group, "mask": mask,
	})
	for r in c.rigs:
		if r.path == overlay_path:
			r.group = group
		elif r.path == base_path and int(r.group) == 0:
			r.group = group
	save_store()
	return group


func layers_of_base(id: String, base_path: String) -> Array:
	var out := []
	for l in character(id).get("layers", []):
		if l.base == base_path:
			out.append(l)
	return out


## Adopt a weapon fitting saved by the pre-rework playground
## (keyed by the rig's root-bone uuid) into the character's shared
## weapon block, once.
func adopt_legacy_weapon(id: String, rig: AniRigResource) -> void:
	var c := character(id)
	if not (c.shared.weapon as Dictionary).is_empty():
		return
	if not FileAccess.file_exists(LEGACY_WEAPONS):
		return
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(LEGACY_WEAPONS))
	if not parsed is Dictionary:
		return
	var roots := []
	for bone in rig.bones:
		var parent: Variant = bone.get("parent_uuid")
		if parent == null or (parent is String and String(parent).is_empty()):
			roots.append(String(bone.get("uuid", "")))
	roots.sort()
	if roots.is_empty():
		return
	var legacy: Variant = (parsed as Dictionary).get(roots[0])
	if legacy is Dictionary:
		c.shared.weapon = {
			"file": legacy.get("weapon", ""),
			"bone": legacy.get("bone", ""),
			"ox": legacy.get("offset_x", 0.0),
			"oy": legacy.get("offset_y", 0.0),
			"rot": legacy.get("rotation", 0.0),
			"scale": legacy.get("scale", 1.0),
			"behind": legacy.get("behind", false),
		}
		save_store()
