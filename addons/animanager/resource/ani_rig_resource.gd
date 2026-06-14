@tool
class_name AniRigResource
extends Resource

# In-memory representation of one parsed AniManager .rig file.
# Produced by the EditorImportPlugin at import time and saved as a
# .tres. Consumed by AniAnimationPlayer2D at runtime.
#
# Schema mirrors the .rig JSON (see the spec doc in the AniManager
# repo, docs/rig-spec.md). All fields use Godot-native types so the
# resource survives ResourceSaver/Loader round-trips cleanly.

# ── Format / animation metadata ─────────────────────────────────────
@export var format_version: int = 1
@export var animation_uuid: String = ""
@export var animation_name: String = ""
@export var frame_rate: int = 24
@export var total_frames: int = 1
@export var is_looping: bool = true

# ── Skeleton ────────────────────────────────────────────────────────
# Each entry is a Dictionary with the keys from the spec's §7:
#   uuid, name, parent_uuid (renamed from parentBoneUuid for snake_case),
#   start_x, start_y, end_x, end_y, length, rotation, sort_order,
#   part_rotation_offset, part_flip_x, part_flip_y,
#   connect_to_parent_start, root_joint_at_start,
#   part_offset_x, part_offset_y, min_rotation, max_rotation.
# v1.2-optional keys (null when not present in source rig):
#   part_width, part_height, part_pivot_x, part_pivot_y,
#   part_rest_offset_x, part_rest_offset_y, rest_world_rotation.
# Kept as Dictionary (not a typed class) to keep the data layer
# inspector-friendly and easy to .tres-serialize.
@export var bones: Array = []

# Each entry is a Dictionary with:
#   bone_uuid, frame_number, rotation, translate_x, translate_y,
#   scale_x, scale_y, interpolation_type (String), bezier_cp1_x,
#   bezier_cp1_y, bezier_cp2_x, bezier_cp2_y, part_sort_order,
#   ik_target_x, ik_target_y.
@export var keyframes: Array = []

# Optional v1.1 IK chains. Each entry:
#   child_bone_uuid, target_x, target_y, pole_side, enabled.
@export var ik_chains: Array = []

# Sprite textures embedded from a .animrig bundle, keyed by bone
# name (matching the bundle's parts/<bone_name>.png filenames).
# Empty when the source file was a bare .rig — in that case the
# AniAnimationPlayer2D node reads from its sprite_pack_folder
# property instead. Both sources can coexist; explicit
# sprite_bindings on the node take precedence over either.
@export var sprite_textures: Dictionary = {}
