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
| `body_layering.gif` | Base clip playing (Herald run) + attack overlay via the Animation Layering menu (mask roots: both arms + neck) — legs keep running through the attack. | Playground | 4–6 s |
| `bone_aim.gif` | Per-animation cursor aim (Advanced menu > "Aim a bone at the cursor" on the idle, plus "Face the cursor"): sweep the mouse in a circle, arm tracks it while the idle plays underneath. | Playground | 3–5 s |
| `cloth_sim.gif` | Close-up of the physics: yank with the joystick, release, watch dress/cape/ponytail trail and settle; include one flip (sim reset). Zoom slider up for a tight crop. | Playground | 4–6 s |
| `shaded_mode.gif` | Herald (masked armor) with Shaded on: drag Light X/Y sliders end to end — the metal glints and normal-mapped shading sweep across the armor. | Playground | 4–6 s |
| `playground.png` | Full-window screenshot: character mid-sway, weapon attached, tuning panel visible with a couple of sections collapsed (shows the fold feature). | Playground | still |

## Combat sandbox reel

These three go in the README's "The playground: a combat sandbox"
section. They all use your saved playground characters, whose
binds and event effects are already set up (checked against
`animate_playground.json` on 2026-09-30). Record at a zoom where
the effects fit in the frame. A beam needs horizontal room, so
these can be wider (~800 px).

| File | What to capture | Setup already saved | Length |
|---|---|---|---|
| `events_effects.gif` | **Seraph**: hold RMB with the cursor off to one side. The charge swirl spins on the staff tip, then the beam fires toward the cursor. Sweep the cursor a little while it fires, then release so the beam ends. If there's time, finish with one LMB fireball flying at the cursor. | RMB = secondaryAttack (loop on `beam_charge_start`, beam on `beam_start`/`beam_end`, effects aim at the cursor). LMB = basicAttack (fireball loop, then projectile on `fireball_shot`). | 5–8 s |
| `two_hand_grip.gif` | **Herald** with HeraldWeapon: idle, then run and attack. The weapon stays between both hands through the swing. Turn on **Steady two-hand grip** in the Weapon Menu first if the arms scissor during the attack. | Weapon on Left Hand Bone with a second hand set. | 4–6 s |
| `playable_test.gif` | **Herald**: hold A, then D. He runs and turns to face each way, then returns to idle when you let go. Attack once while running. If you like, cut to **Seraph** strafing with WASD while facing the cursor and firing fireballs at it. | Herald: run marked as the Left/Right movement animation. Seraph: WASD, Face the cursor, Swap facing. | 6–8 s |

Before recording the two Herald shots, check that Herald's
character still loads. The Sep 28 re-export replaced `attack`
with `basicAttack` and removed the dodge and run-backward clips.
The playground stores clips by path, and the saved paths already
point at the new files, so it should load fine.

## Optional extras

Optional extras (no README slot yet — nice for the repo or the
Upwork gallery):

- `ingame.png` — Herald in the HD-2D demo level (crisp sprite over
  the depth-of-field world): the "this ships in a real game" shot.
- `weapon_fit.gif` — attach mode: dragging the staff into her hand,
  Save, then the live follow through the idle.

When all files are in, delete this checklist or leave it — the
README doesn't link it.
