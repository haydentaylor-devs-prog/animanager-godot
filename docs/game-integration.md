# Integrating AniManager Rigs into a Godot Game

**Audience:** developer using the AniManager Godot 4 plugin to drop
authored 2D skeletal animations into a game project.
**Prereqs:** plugin installed and enabled (see repo README).
**Spec reference:** the `.rig` file format is defined at
`animanager/docs/rig-spec.md` in the AniManager repo — this doc is
the *integration* side (what your Godot code touches), not the file
format itself.

---

## 1. The three pieces

| Piece | What it is | Where it lives |
|---|---|---|
| **`.rig` / `.animrig` file** | JSON (or a ZIP of JSON + PNGs) describing skeleton + keyframes. Contains no engine-specific data. | Anywhere in `res://` — the importer picks it up automatically. |
| **`AniRigResource`** | Godot `Resource` produced by the EditorImportPlugin. In-memory schema mirrors the `.rig` JSON but uses snake_case + Godot types. Serializes as `.tres`. | Sits next to the source file in the FileSystem dock as an imported resource. |
| **`AniAnimationPlayer2D`** | `Node2D` you place in your scene. Points at one `AniRigResource` and plays it back — evaluates FK, runs IK, dispatches events, draws bound sprites. | Add via **Create Node → AniAnimationPlayer2D**. |

The plugin has no runtime "manager" or singleton. Each animation
you want to play is one `AniAnimationPlayer2D` node with one rig
assigned. To play the *same* rig on two characters, drop two nodes.

---

## 2. What happens when you import a rig

### `.rig` (bare JSON file)

1. Godot detects `.rig` extension → runs `addons/animanager/importer/rig_importer.gd`.
2. Importer reads the JSON, validates `kind == "animanager.rig"` and
   `formatVersion == 1`, builds an `AniRigResource` with:
   - `format_version`, `animation_name`, `frame_rate`, `total_frames`, `is_looping`
   - `bones[]` — Array of Dictionary, one per bone
   - `keyframes[]` — Array of Dictionary, one per keyframe
   - `ik_chains[]` — if present in source
   - `events[]` — if present in source
   - `sprite_textures` — empty (bare `.rig` has no bundled art)
3. Saves as `<name>.tres`. The `.tres` is what your node references.
4. If a sister `<name>.parts/` folder exists next to the `.rig`, the
   PNGs get imported by Godot as normal `Texture2D` resources — the
   plugin doesn't touch them at import time. Auto-binding happens at
   the **node** level from `sprite_pack_folder`.

### `.animrig` (ZIP bundle)

1. Godot detects `.animrig` extension → same importer script.
2. Importer opens the ZIP with `ZIPReader`, reads `manifest.rig`,
   then walks every `parts/<bone_name>.png` entry.
3. Each PNG becomes an `ImageTexture` embedded on the resource's
   `sprite_textures` Dictionary (keyed by bone name, matching the
   PNG basename).
4. Same `.tres` output — but this one carries its textures with it.
   No sister folder needed, no `sprite_pack_folder` to set.

**Which format should you use?** For shipping games, `.animrig`. The
whole animation + art travels as one file, versioning is simpler,
and auto-bind is one property (`rig`) instead of two (`rig` +
`sprite_pack_folder`). Use bare `.rig` + sister folder only when
you want to hand-edit or replace individual sprite PNGs from the
Godot side without re-exporting.

---

## 3. Wiring a node up

Minimal scene:

```
YourScene (Node2D)
└── AniAnimationPlayer2D
    ├── rig: preload("res://animations/hero_run.tres")
    └── auto_play: true
```

That's the whole setup for a `.animrig` — sprites bind automatically
from the bundle's embedded textures on `rig` assignment. You'll see
`AniManager: auto-bound N sprite(s)` in the Output panel confirming.

For a bare `.rig` with a sister folder:

```
AniAnimationPlayer2D
├── rig: preload("res://animations/hero_run.tres")
├── sprite_pack_folder: "res://animations/hero_run.parts/"
└── auto_play: true
```

Setting either property triggers the auto-bind pass; the order
doesn't matter.

### Overriding or supplementing bindings

`sprite_bindings` is a `Dictionary<String, Texture2D>` you can edit
in the inspector or from code:

```gdscript
@onready var player := $AniAnimationPlayer2D

func _ready() -> void:
    # Swap one part with a variant sprite.
    player.sprite_bindings["Hand_R"] = preload("res://art/torch_hand.png")
```

Explicit entries **always win** over auto-bind — the auto-bind pass
only fills in keys that aren't already set. Keys can be a bone's
`uuid` (stable across renames, ugly) or `name` (readable, must
match exactly, case-sensitive). Name lookup is preferred for
game-side code because renames in AniManager keep uuids stable but
break code that expects them to change.

---

## 4. Playback API

```gdscript
player.play()                       # start / resume
player.pause()                      # freeze, keep frame
player.stop()                       # freeze + reset to frame 0
player.is_playing() -> bool
player.get_current_frame() -> float # sub-frame is fine
player.set_current_frame(12.5)      # scrub / snap
player.speed = 1.5                  # 1.0 = authored speed
player.loop_override = -1           # -1 = use rig; 0 = force off; 1 = force on
```

Playback advances `_current_frame` at `frame_rate * speed` per
second in `_process()`. When it passes `total_frames - 1`:
- `is_looping` (or `loop_override`) true → wraps to 0, emits
  `animation_looped`, resets the event dispatcher's frame counter.
- looping false → stops at the last frame, emits `animation_finished`.

**Scrubbing** is a first-class use case. `set_current_frame(f)`
re-evaluates the pose immediately; you can slide it from a UI
control or drive it from your own timeline system without ever
calling `play()`.

---

## 5. Rendering model

Under the hood, each frame:

1. Interpolate every bone's keyframes at `_current_frame`.
2. Walk the hierarchy from roots outward — parent pose computed
   before child pose. Each bone gets a `{world_start, world_end,
   world_rotation, scaled_length}` record.
3. If the rig has `ik_chains`, for each enabled chain run a
   two-bone analytic solver and overwrite the parent + leaf pose
   (see spec §7.2 for the exact math).
4. For each bone with a bound sprite: transform + draw the texture
   at the bone's world pose, honoring `part_pivot_x/y`,
   `part_rest_offset_x/y`, `part_rotation_offset`, `part_flip_x/y`,
   and per-frame `part_sort_order` overrides.
5. For any bone *without* a bound sprite, if `draw_bones_in_editor`
   is on, draw a debug line from `world_start` to `world_end`. This
   is what you see before you've assigned art — great for verifying
   a rig loaded correctly.

Everything renders through Godot's normal 2D pipeline (`draw_line`,
`draw_texture_rect_region`, `draw_circle`). The node's own
transform composes with the pose transforms, so parenting the
node under another `Node2D` and moving that parent works exactly
as you'd expect.

---

## 6. Attaching game logic to bones

Two hooks: **transforms** (per-frame positional queries) and
**events** (discrete callbacks).

### 6.1 Transform queries

```gdscript
func _process(_delta: float) -> void:
    # Follow the right hand with a particle system.
    var xf: Transform2D = player.get_bone_world_transform("Hand_R")
    $Muzzle.global_transform = player.global_transform * xf
```

`get_bone_world_transform` returns a `Transform2D` in the player's
local space. Multiply by the player's `global_transform` to get
world coords. The origin is the bone's pivot joint (start or end
depending on `rootJointAtStart`), and the basis carries the bone's
current rotation.

Use this for muzzle flashes, sword trails, hit-hurt volumes,
IK target pinning, camera follows — anything that needs to track a
bone across frames.

### 6.2 Frame events

Events come from the `.rig` file's `events` array (spec §8.3). Each
entry is `{frame, name, payload}`. The node emits an
`animation_event(name, payload)` signal the first time
`_current_frame` crosses an event's frame during a playback pass;
on loop wrap, the dispatcher resets and events re-fire on the
next pass.

```gdscript
func _ready() -> void:
    player.animation_event.connect(_on_animation_event)

func _on_animation_event(event_name: String, payload: String) -> void:
    match event_name:
        "footstep":
            $FootstepAudio.play()
        "hit":
            var data := JSON.parse_string(payload)
            _apply_damage(data.get("damage", 0))
        "swing_start":
            $SwordTrail.enable()
```

`payload` is a plain string. If the author put JSON in it, parse
with `JSON.parse_string(payload)`. Multiple events on the same
frame each get their own emission in array order — no coalescing.

The event dispatcher uses `_last_event_int_frame` internally to
guarantee **one fire per event per playback pass**. Scrubbing
backwards past an event does not re-fire it; a full loop wrap does.

---

## 7. Common patterns

### Playing multiple animations on one character

The plugin has one rig per player node. To swap animations
(idle → run → attack), keep several `AniRigResource`s and reassign:

```gdscript
@export var idle: AniRigResource
@export var run: AniRigResource

func _set_state(new_state: String) -> void:
    match new_state:
        "idle": player.rig = idle
        "run":  player.rig = run
    player.play()
```

Reassigning `rig` triggers `_rebuild_indices()` and
`_auto_bind_from_sprite_pack()` — if all animations share the
same bone names, sprite bindings persist. If they diverge, use
one `AniAnimationPlayer2D` per animation and toggle their
`visible` and `_is_playing` flags.

**Cross-fading** isn't in v1 of the spec or plugin. If you need
it, run two players and cross-fade their `modulate.a`.

### Facing direction

Pixel-art side-scrollers usually flip the whole character rather
than authoring left- and right-facing rigs. Flip the parent
node's `scale.x`:

```gdscript
func _flip(facing_right: bool) -> void:
    scale.x = 1.0 if facing_right else -1.0
```

The player node inherits the flip; all bound sprites flip with
their bones. `part_flip_x` in the rig is for *authored* per-part
flipping, not runtime facing.

### Following the character in an animation

Root-bone `translate_x/y` keyframes move the whole rig within the
scene. If the author intended the character to physically move
during the animation, drive your CharacterBody2D by extracting
the root motion each frame:

```gdscript
var _prev_root_pos: Vector2 = Vector2.ZERO

func _process(delta: float) -> void:
    var root_uuid := player.rig.bones[0].uuid  # assumes first bone is root
    var xf := player.get_bone_world_transform(root_uuid)
    var delta_motion := xf.origin - _prev_root_pos
    _prev_root_pos = xf.origin
    velocity = delta_motion / delta
    move_and_slide()
```

Then in AniManager either zero out the root translate keyframes
(and use the extracted motion), or subtract them from the player
node's position after `_process` so the character stays in place
in the scene while the animation drives the CharacterBody2D.

Both models are valid; pick one project-wide.

### Hit boxes / hurt boxes

Two options:

1. **Author them as bones.** Add invisible bones for hit volumes
   in AniManager, don't bind sprites to them, then in Godot
   attach an `Area2D` positioned via `get_bone_world_transform`
   each frame.
2. **Static shapes parented to bones via node references.** Add a
   `Node2D` child of your player, register it against a bone
   uuid, and drive its `transform` from `get_bone_world_transform`
   in `_process`. Simpler if the hit volume doesn't need to be
   authored precisely per-frame.

---

## 8. Performance notes

- Pose evaluation is O(bones + keyframes) per frame. Typical
  character rigs (10-30 bones, ~50-200 keyframes) evaluate in
  well under a millisecond.
- Sprite draws go through Godot's 2D renderer — same cost as any
  `Sprite2D`. There's no shader or SubViewport in the render path.
- Multiple `AniAnimationPlayer2D` nodes scale linearly. 20-30
  characters on-screen at 60fps is fine on modest hardware.
- Scrubbing (repeated `set_current_frame`) forces a pose re-eval
  and redraw each call. For timeline-driven UI, throttle to the
  frame rate you actually need.
- The `sprite_textures` Dictionary in `.animrig` bundles is
  loaded once at import time and lives on the `.tres`. Runtime
  cost of `.animrig` vs `.rig` + sister folder is identical after
  import — same texture references either way.

---

## 9. Debugging

**"I dropped a `.rig` in but nothing shows up."**
- Check the Output panel for import errors. Bad JSON, wrong `kind`,
  or a `formatVersion > 1` all get reported there.
- Verify `rig` is assigned on the node. `null` = nothing to draw.
- Check `sprite_bindings.size()` in your `_ready`. If it's 0 and
  `draw_bones_in_editor` is off, you'll see nothing — flip the debug
  flag back on to confirm bones are there.

**"Sprites are in the wrong place / rotated wrong."**
- The rig might be pre-v1.2 (no `part_rest_offset_x/y` etc.). The
  runtime falls back to the legacy path which centers sprites on
  bone start joints and ignores pivots. Re-export from AniManager
  after updating.
- `part_flip_x/y` might be flipping in the wrong direction because
  of a scene-level scale flip. Only one flip layer at a time.

**"Events don't fire."**
- Confirm the signal is connected: `player.animation_event.is_connected(_on_animation_event)`.
- Events fire on integer-frame crossings only. If your `speed` is
  extremely low or you're scrubbing, frames may not cross in the
  direction the dispatcher tracks.
- Backwards scrubbing does NOT re-fire events, by design.

**"Animation looks like it's playing but nothing moves."**
- The rig might have keyframes only at frame 0. The exporter
  writes a frame-0 anchor even when nothing else exists, so this
  usually means the animation is one static pose. Not a bug.

**"IK looks wrong at the extremes."**
- `pole_side` in the IK chain determines elbow bend direction.
  Re-export from AniManager with the correct pole side, or
  temporarily override with `rig.ik_chains[i].pole_side = -1`
  to test.
- When the target is exactly at max reach, the analytic solver
  clamps to `l1 + l2 - epsilon` and the leaf points straight at
  the target with no bend. This is expected.

---

## 10. What the plugin does NOT do

- **Bundle audio.** Per-frame audio clips authored in AniManager
  don't ship in the `.rig` yet (spec v2). Handle sound via
  `animation_event` callbacks that trigger your own `AudioStreamPlayer`s.
- **Cross-fade between animations.** Reassign `rig` for a hard
  cut; layer two players for a manual cross-fade.
- **Runtime rig editing.** The `AniRigResource` is meant to be
  read-only at runtime. Mutating `bones[]` or `keyframes[]`
  works but the pose evaluator caches indices; you'd need to
  call `_rebuild_indices()` (currently private) to pick up changes.
- **Mesh deformation / weighted skinning.** Rigid attachments
  only. Every sprite is a whole texture on one bone.
- **Physics / secondary motion.** Springs, cloth, and dangly bits
  are your game code's responsibility. Query `get_bone_world_transform`
  and drive whatever you like.

For anything on this list, the pattern is the same: use the
plugin for the authored motion, layer your own game systems on
top via signals and transform queries.
