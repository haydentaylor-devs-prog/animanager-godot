@tool
extends EditorPlugin

# Registers the .rig file importer + the AniAnimationPlayer2D custom node.
# Loaded automatically by Godot when the user enables this addon in
# Project Settings → Plugins.

const RigImporter := preload("res://addons/animanager/importer/rig_importer.gd")
const AniAnimationPlayer2D := preload("res://addons/animanager/nodes/ani_animation_player_2d.gd")

var _importer: RigImporter


func _enter_tree() -> void:
	_importer = RigImporter.new()
	add_import_plugin(_importer)
	add_custom_type(
		"AniAnimationPlayer2D",
		"Node2D",
		AniAnimationPlayer2D,
		preload("res://addons/animanager/icon.svg")
	)


func _exit_tree() -> void:
	remove_import_plugin(_importer)
	_importer = null
	remove_custom_type("AniAnimationPlayer2D")
