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
	# One-click access to the playground (2026-09-25): Project →
	# Tools → AniMate Playground runs the scene without hunting for
	# addons/animanager/playground/playground.tscn.
	add_tool_menu_item("AniMate Playground", _open_playground)


func _open_playground() -> void:
	EditorInterface.play_custom_scene(
		"res://addons/animanager/playground/playground.tscn")


func _exit_tree() -> void:
	remove_import_plugin(_importer)
	_importer = null
	remove_custom_type("AniAnimationPlayer2D")
	remove_tool_menu_item("AniMate Playground")
