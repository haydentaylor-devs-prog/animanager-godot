# README media — capture checklist

Every image the README references, with exactly what to record.
Drop finished files in THIS folder with THESE names — the README
links them already. GIFs: keep each under ~8 MB (GitHub renders
them inline); ~600–800 px wide is plenty; 3–8 s loops. OBS →
screen-record, then convert/trim to GIF (ScreenToGif or ezgif.com
both work). Record the playground zoomed in enough that the
character fills the frame — crop the tuning panel out unless the
shot is ABOUT the panel.

| File | What to capture | Where | Length |
|---|---|---|---|
| `hero.gif` | THE showcase: Seraph idling with dress + hair physics live, staff attached; joystick-drag her sideways, stop dead, let everything swing and settle; one facing flip. | Playground | 6–8 s |
| `crossfade.gif` | Run interrupted into a dodge (or idle→run→idle) with no popping. | Main game (F5) or HD-2D demo | 3–5 s |
| `body_layering.gif` | Base clip playing (Herald run or Seraph idle) + attack overlay on the upper body via the Body layer section — legs keep moving through the attack. | Playground | 4–6 s |
| `bone_aim.gif` | "Aim bone at mouse cursor" on: sweep the mouse in a circle, arm tracks it while the idle plays underneath. | Playground | 3–5 s |
| `cloth_sim.gif` | Close-up of the physics: yank with the joystick, release, watch dress/cape/ponytail trail and settle; include one flip (sim reset). Zoom slider up for a tight crop. | Playground | 4–6 s |
| `shaded_mode.gif` | Herald (masked armor) with Shaded on: drag Light X/Y sliders end to end — the metal glints and normal-mapped shading sweep across the armor. | Playground | 4–6 s |
| `playground.png` | Full-window screenshot: character mid-sway, weapon attached, tuning panel visible with a couple of sections collapsed (shows the fold feature). | Playground | still |
| `import_drop.gif` | Godot editor: drag an `.animrig` into the FileSystem dock, click the imported resource, show it assigned on an AniAnimationPlayer2D, press play — character animates. | Godot editor | 5–8 s |

Optional extras (no README slot yet — nice for the repo or the
Upwork gallery):

- `ingame.png` — Herald in the HD-2D demo level (crisp sprite over
  the depth-of-field world): the "this ships in a real game" shot.
- `weapon_fit.gif` — attach mode: dragging the staff into her hand,
  Save, then the live follow through the idle.

When all files are in, delete this checklist or leave it — the
README doesn't link it.
