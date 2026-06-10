# AniManager — Godot 4 Importer

[![Godot 4.x](https://img.shields.io/badge/Godot-4.x-blue.svg)](https://godotengine.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A Godot 4 editor plugin that imports `.rig` files exported from
[AniManager](https://github.com/haydentaylor-devs-prog/animanager)
and plays them back as 2D skeletal animations.

`AniManager` is a mobile 2D skeletal animation authoring tool aimed
at artists who want a Procreate-flavored workflow instead of paying
for ToonBoom Harmony. This plugin is the bridge that lets you take
animations you authored on a tablet and drop them straight into a
Godot game project.

---

## What it does

- **Imports `.rig` files** as native Godot `Resource`s. Drag a
  `.rig` into your project and Godot generates a `.tres` you can
  point a node at.
- **Plays back animations** through an `AniAnimationPlayer2D` node:
  `play()`, `pause()`, `stop()`, `set_current_frame()`, looping,
  speed control.
- **Renders bones as debug lines** when you haven't bound sprites
  yet, so you can verify the rig loaded correctly before doing any
  art work.
- **Binds sprites to bones** via a simple `Dictionary` (bone UUID
  or bone name → `Texture2D`).
- **Supports IK** (the v1.1 `ikChains` extension) — two-bone
  analytic solver runs after FK each frame.
- **Honors all interpolation types** the spec defines: linear,
  ease in / out / in-out, stepped, custom cubic bezier (with
  Newton-Raphson `x → t` solver matching the AniManager reference).

---

## Requirements

- Godot 4.0 or later (tested against 4.x master; please report
  version-specific issues).
- A `.rig` file produced by AniManager. The
  [.rig spec doc](https://github.com/haydentaylor-devs-prog/animanager/blob/main/docs/rig-spec.md)
  is the authoritative format reference.

---

## Installation

From your Godot project root, in PowerShell or bash:

```powershell
cd <your-godot-project>
git clone https://github.com/haydentaylor-devs-prog/animanager-godot.git temp
New-Item -ItemType Directory -Force -Path addons | Out-Null
Move-Item temp\addons\animanager addons\
Remove-Item -Recurse -Force temp
```

(bash users: `mkdir -p addons && cp -r temp/addons/animanager addons/ && rm -rf temp`)

Or download the latest release ZIP from this repo's Releases page
and extract `addons/animanager/` into your project's `addons/`
directory.

### Then in Godot

1. Open your project (or **Project → Reload Current Project** if
   it was already open).
2. **Project → Project Settings → Plugins** → tick **AniManager**.
3. The editor will reimport any `.rig` files in your project tree
   automatically.

## Updating

The plugin ships stable `.uid` sidecar files, so re-downloading
won't break your scene references the way it did in early versions.

The simplest update for any install style:

```powershell
cd <your-godot-project>
git clone https://github.com/haydentaylor-devs-prog/animanager-godot.git temp
Remove-Item -Recurse -Force addons\animanager
Move-Item temp\addons\animanager addons\
Remove-Item -Recurse -Force temp
```

Then **Project → Reload Current Project** in Godot. Scenes and
imported `.rig` files reconnect automatically.

---

## Quick start

1. Drop a `.rig` file into your Godot project (the
   `examples/quarter_turn.rig` here is a one-bone smoothstep
   rotation that's perfect for verifying setup).
2. Godot auto-imports it as a `.tres`.
3. Add an `AniAnimationPlayer2D` node to your scene
   (**Create Node → AniAnimationPlayer2D**, under Node2D).
4. In the inspector, set its **Rig** property to the imported
   `.tres`.
5. Tick **Auto Play** (or call `play()` from a script).
6. Hit play. You should see a debug line bone rotating 90° over
   half a second.

### Binding sprites

The `.rig` format itself never includes images, but AniManager's
"Export Rig" optionally writes a sister `<name>.parts/` directory
next to the `.rig` containing one PNG per bone (named by bone
name). The plugin can auto-bind from such a folder:

1. Drop both the `.rig` AND the `.parts/` folder into your Godot
   project tree.
2. On your `AniAnimationPlayer2D` node, set **Sprite Pack Folder**
   to the imported `.parts/` folder (browse for it in the inspector).
3. Assign the **Rig** — it'll print
   `AniManager: auto-bound N sprite(s) from <folder>` to the
   Output panel and fill the `sprite_bindings` dictionary.

To override or supplement what the pack provides, set entries on
`sprite_bindings` directly:

```gdscript
@onready var player := $AniAnimationPlayer2D

func _ready() -> void:
    # Auto-bind from the pack handles most bones; tweak specific
    # ones in code:
    player.sprite_bindings["Hand_R"] = preload("res://art/special_hand.png")
```

Explicit `sprite_bindings` entries take precedence — auto-bind
never overwrites them. Keys can be either the bone's `uuid`
(stable across exports, ugly) or its `name` (human-readable, must
match the editor exactly). Name lookup is case-sensitive.

### Attaching effects to a bone

```gdscript
func _process(_delta: float) -> void:
    var hand_transform := player.get_bone_world_transform("Hand_R")
    $Particles.global_position = hand_transform.origin
```

---

## API summary

| Property | Type | Default | What it does |
|---|---|---|---|
| `rig` | `AniRigResource` | `null` | The imported animation data. |
| `sprite_bindings` | `Dictionary` | `{}` | Bone uuid/name → `Texture2D`. |
| `auto_play` | `bool` | `false` | Call `play()` on `_ready()`. |
| `speed` | `float` | `1.0` | Playback speed multiplier. |
| `loop_override` | `int` (enum) | `-1` (use rig) | Force loop on / off, or defer to the rig's `is_looping` field. |
| `draw_bones_in_editor` | `bool` | `true` | Render debug bone lines for unbound bones. |
| `bone_color` / `bone_width` | | | Debug bone style. |
| `joint_color` / `joint_radius` | | | Debug joint style. |

| Signal | When |
|---|---|
| `animation_finished` | Last frame reached on a non-looping clip. |
| `animation_looped` | Wrap-around on a looping clip. |

| Method | What it does |
|---|---|
| `play()` | Start / resume playback. |
| `pause()` | Pause; current frame held. |
| `stop()` | Pause + reset to frame 0. |
| `is_playing()` | Whether playback is active. |
| `get_current_frame()` | Current playhead (float — sub-frame is fine). |
| `set_current_frame(frame)` | Scrub to a specific frame. |
| `get_bone_world_transform(uuid_or_name)` | World `Transform2D` of a bone — for game-side effect attachment. |

---

## Limitations

This plugin implements the v1.1 of the
[`.rig` spec](https://github.com/haydentaylor-devs-prog/animanager/blob/main/docs/rig-spec.md):

| Feature | Status |
|---|---|
| FK keyframe interpolation (linear, easeIn/Out/InOut, stepped, custom bezier) | ✅ |
| Shortest-arc angle interpolation | ✅ |
| Per-frame `partSortOrder` (stepped semantics) | ✅ |
| `frameColors` (workflow aid) | ⏭ Ignored (no playback effect, by design). |
| `audioMarkers` (v1, deprecated) | ⏭ Ignored. Use AniManager's per-frame audio (`AnimationAudio` rows) once the spec adds it in v2. |
| Two-bone analytic IK | ✅ Including per-frame `ikTargetX/Y` interpolation. |
| Per-frame audio clips with trim + envelope | ❌ Not in spec v1. Pending v2. |
| Image asset embedding | ❌ Not in spec, by design. Caller binds sprites. |
| `min_rotation` / `max_rotation` constraints | ⚠ Stored, not enforced. Pending. |

The pose evaluator and IK solver are pure GDScript. For a typical
animation (~10-30 bones, ~3-5 IK chains, 60 fps playback) this is
comfortably real-time on a mid-range mobile GPU. If you hit a perf
ceiling with much larger rigs we can revisit with a GDExtension
(C++) port.

---

## Troubleshooting

### "Parse Error" on enable

Pull the latest from this repo — early versions had GDScript
name-collisions with Godot 4 globals (`ease()`, `sign()`,
`lerp_angle()`). Fixed in commit `5ebc536` and after.

### Bones radiate from a single point instead of forming a chain

Pull the latest. Pre-`ee7c661` versions composed bones as
parent-relative transforms instead of following parent end joints.
Fixed.

### `Invalid UID` warnings after updating

Toggle the plugin off then on
(**Project → Project Settings → Plugins**) so the custom-type
registration rebinds. Right-click any imported `.rig` →
**Reimport** to refresh its companion `.import` file. Save the
scene to flush its `ext_resource` block.

Recent versions ship stable `.uid` sidecar files so this should
only happen once when updating from an install older than commit
`c779de3` (the UID commit). After that one toggle + reimport,
future re-downloads keep references intact.

### `AniAnimationPlayer2D` doesn't appear in the Create Node dialog

Plugin's custom-type registration didn't take. Toggle the plugin
off and back on. If still missing, check the Output panel for
errors — paste them in a GitHub issue.

### Animation plays but the character is upside down / mirrored

Likely a rest-pose authoring difference between AniManager's scene
and Godot's. AniManager uses Y-down (positive Y is screen-bottom),
matching Godot. If you authored a rig assuming Y-up, the rest pose
will be mirrored. Re-author with the correct orientation, or apply
a `Scale: (1, -1)` on the parent of the `AniAnimationPlayer2D`
node to flip Y at runtime.

### Bones in editor view don't update when I scrub the timeline

Editor view updates on `queue_redraw()` which fires from
`_process()`. If you have `auto_play` off in the inspector, the
node won't tick — set `current_frame` from a tool script if you
want editor scrubbing, or just play the scene to verify.

---

## Contributing

Bug reports and pull requests welcome on
[GitHub issues](https://github.com/haydentaylor-devs-prog/animanager-godot/issues).

For format / spec questions, open issues against the AniManager
main repo's `docs/rig-spec.md` — the spec is authoritative and the
plugin tracks it.

---

## License

MIT — see [LICENSE](LICENSE).
