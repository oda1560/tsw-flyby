# TSW Fly-by Camera User Guide

Last updated 2026-10-18

## What it does

Press **7** while driving in Train Sim World 7. After a moment spent timing your train, the view cuts to a camera standing beside the line ahead of it, like a railfan with a camera. It turns to follow the train as it goes by. Once the train is well past, the camera jumps ahead to a new spot, swapping sides each time. Press **7** again to jump to a new spot ahead straight away. Press **6** to go back to your own view.

You can keep driving while it's on: the game's controls, HUD and keys all still work.

Pressing one of the game's own camera keys also hands the view back: 1 (cab), 2 (boom), 3 (outside), 5 (passenger), 8 (free camera), 0 (camera shortcuts) or Shift+Space (photo mode). If the game switches cameras by itself, the mod takes the view back. If the game keeps doing that, the mod gives up and leaves the game's view.

| Key | What it does |
| --- | --- |
| 7 | Fly-by camera on; pressed again, move it to a new spot ahead |
| 6 | Fly-by camera off, back to the view you had |
| F10 | Write a report of what the mod can see into UE4SS.log (for fixing problems) |

TSW7 doesn't bind 6, 7 or F10 itself.

## Before you start

The mod is a script that runs inside the game through **UE4SS**, a free, open-source tool for scripting Unreal Engine games. TSW7 has no official way to add camera views, so UE4SS is needed.

| What | Why |
| --- | --- |
| Train Sim World 7 on PC (Steam) | Console versions can't be modded |
| UE4SS (tested with the 2026-10-17 test build, `UE4SS_v3.0.1-1181-g83330635.zip`) | Loads the mod into the game |
| Python 3 | Runs the installer (and the tests) |

UE4SS's builds are on its [releases page](https://github.com/UE4SS-RE/RE-UE4SS/releases); the one used here is under **experimental-latest**. A copy is kept in `F:\TSW mod downloads\ue4ss-zip`.

## Installing

Close the game first. Then either double-click **Install fly-by camera.bat** (UE4SS already installed), or install UE4SS and the mod together:

```
python install.py --ue4ss "F:\TSW mod downloads\ue4ss-zip\UE4SS_v3.0.1-1181-g83330635.zip"
```

The installer finds the game through Steam and puts these next to `TrainSimWorld.exe` in `...\Train Sim World 7\WindowsNoEditor\TS2Prototype\Binaries\Win64`:

- `dwmapi.dll`: the loader that starts UE4SS with the game.
- `ue4ss\`: UE4SS itself, its settings and its mods. The fly-by camera is `ue4ss\Mods\FlyByCamera`.

It also sets UE4SS up quietly:

- **No windows:** UE4SS opens no console or GUI windows over the game.
- **No hot reload:** mods aren't reloaded by pressing Ctrl+R.
- **Sample mods off:** UE4SS's sample mods are switched off in `ue4ss\Mods\mods.txt`, including its Ctrl+J / Ctrl+H object-dump keys. UE4SS's original settings are kept as `UE4SS-settings.ini.original`.

Steam's "Verify integrity of game files" leaves these files alone. A game update can stop UE4SS loading until UE4SS itself is updated: install the newer UE4SS zip the same way.

## Changing how it behaves

The settings are in `FlyByCamera\Scripts\flyby_settings.lua`: how far ahead and to the side the camera stands, when it moves on, which side, zoom, and the keys. Edit the copy here and run **Install fly-by camera.bat** again, then restart the game.

A few you may want:

- **LeadSeconds, MinLead, MaxLead:** how far ahead it waits. 8 seconds of travel, between 60 and 350 m.
- **SideOffset:** 12 m from the line.
- **Side:** `"alternate"`, `"left"` or `"right"`.
- **PassDistance:** how far past the train goes before the camera moves on, 200 m. Raise it for long trains.
- **Zoom:** zooms in while the train is far away. Set to `false` for a fixed `Fov`.
- **CheckView:** before picking a spot, looks for hills, cuttings, walls and buildings in the way, and stands the camera on the ground.

## How it picks a spot

TSW splits each rail vehicle in two:

- **The model actor** (`CL70_FL_RVM_C` for the Class 70) stays at the world's origin.
- **The vehicle you see** (`RVV_AABS_Class70_C`) is the one that moves.

The mod follows the one you see, which your driver is attached to.

It times your train for its speed, and reads the vehicle's heading for the direction of the line and how sharply it's curving. The heading turns as the line curves, so the curve is known within a few metres of switching on. It watches where the train has been for the gradient.

It carries that curve on ahead to guess where the line goes, then tries spots beside that point. It traces a line from each spot across to the track and towards the train, and takes the first spot with a clear view of both. It doesn't read the game's track data (yet), so a spot can be off just after a change of curve, a junction or a tunnel mouth. Press 7 for another.

## When something's wrong

Everything the mod does is written to `ue4ss\UE4SS.log` in the game's Win64 folder, on lines starting `[FlyBy]`:

- **Switching on:** which vehicle it follows and where it is, and the train's speed as timed and as the game reports it.
- **Each spot:** how far ahead, which side, the ground height, and whether the line and the train are in view.
- **Every 2 seconds while on:** where the train is and how far it moved. Turn these off with `DebugLog = false`.
- **The game taking the view:** each time, and what it switched to.

Pressing **F10** in a drive adds a report: which vehicle it would follow, everything the driver is attached to and where, and the game's camera functions.

**Nothing happens on 7:**
- Check `UE4SS.log` exists. If it doesn't, UE4SS didn't load.
- If it does, look for `[FlyBy] loaded`.

**The view flicks back:** look for `the game took the view` and `the game keeps taking the view back` in the log, with what the game switched to.

**The camera is somewhere odd:** the `new spot` and `train at` lines show where the train was and what the mod found there.

**Removing:**
- **Uninstall fly-by camera.bat** removes the mod and leaves UE4SS.
- `python install.py --remove-ue4ss` removes UE4SS and all its mods.

## What's been seen in the game

**First drive, 2026-10-18 (Birmingham–Crewe, Class 70):**
- UE4SS loaded, and the mod found the train and cut to its camera.
- It followed the Class 70's model actor at the world's origin, so the camera stood about 860 m from the train looking at nothing. Since fixed: it now follows the vehicle you see.
- The game put its own camera back twice; the second drive showed both were camera keys.

**Second drive, same day and route:**
- It followed the visible Class 70 and timed it at 26.5 m/s, matching the game.
- Every spot had the ground found and the line and train in view.
- The game never took the view by itself.
- On a gentle right-hand curve (about 3 km radius) the first spot came within 6 m of the line instead of 12, because the curve wasn't known yet at switch-on. Since fixed by reading the train's heading.

**Still to see in the game:**
- the first spot on curves since that fix
- the camera moving itself on once the train is past (every test so far was switched off first)
- 7 moving to a new spot while on

## For working on it

- `FlyByCamera\Scripts\main.lua`: the parts that talk to the game: keys, the camera, finding the train, the once-a-frame update.
- `FlyByCamera\Scripts\flyby_math.lua`: following the train, guessing the line ahead, picking and scoring spots. No game objects in it.
- `tests\`: runs the real Lua through [lupa](https://pypi.org/project/lupa/) against `tests\fake_ue4ss.lua`, a train driving a line that curves, with ground and walls. Run `python -m unittest discover tests`. lupa is installed in `F:\TSW mod downloads\pylib`, which the tests find by themselves.
