# TSW Fly-by Camera User Guide

Last updated 2026-10-18

## What it does

Press **7** while driving in Train Sim World 7. After a moment spent timing your train, the view cuts to a camera standing beside the line ahead of it, like a railfan with a camera. It turns to follow the train as it goes by. Once the train is well past, the camera jumps ahead to a new spot, swapping sides each time. Press **7** again to jump to a new spot ahead straight away. Press **6** to go back to your own view.

Press **4** for the view from a random passenger seat on your train. The camera sits at a passenger's eye height and rides along with the train. Press **4** again to move to another random seat. From the seat view, **7** goes to the fly-by camera, and from the fly-by, **4** goes to a seat.

The passenger looks the way their seat faces, turned towards the window nearest them: ahead in a forward-facing seat, back along the train in a backward-facing one. Their gaze wanders a little, and now and then they glance elsewhere for a few seconds: straight out of the window, back along the train, across the car, or down. Their head shakes with the track, more the faster the train goes. It leans back as the train speeds up, forward as it brakes and out on curves. Move the mouse to look around yourself; a few seconds after you leave it, the passenger goes back to looking out of the window.

You can keep driving while either view is on: the game's controls, HUD and keys all still work.

Pressing one of the game's own camera keys also hands the view back: 1 (cab), 2 (boom), 3 (outside), 5 (passenger), 8 (free camera), 0 (camera shortcuts) or Shift+Space (photo mode). If the game switches cameras by itself, the mod takes the view back. If the game keeps doing that, the mod gives up and leaves the game's view.

| Key | What it does |
| --- | --- |
| 7 | Fly-by camera on; pressed again, move it to a new spot ahead |
| 4 | View from a random passenger seat; pressed again, another seat |
| 6 | Fly-by camera or seat view off, back to the view you had |
| F10 | Write a report of what the mod can see into UE4SS.log (for fixing problems) |

TSW7 binds 4, 6, 7 and F10 only with Ctrl, according to its own `DefaultInput.ini`. 4 sits next to 5, the game's own passenger camera.

The other mod here, the comfort HUD, puts passenger numbers and comfort warnings in the game's objective box: see [its guide](COMFORT_HUD_GUIDE.md).

## Before you start

The mod is a script that runs inside the game through **UE4SS**, a free, open-source tool for scripting Unreal Engine games. TSW7 has no official way to add camera views, so UE4SS is needed.

| What | Why |
| --- | --- |
| Train Sim World 7 on PC (Steam) | Console versions can't be modded |
| UE4SS (tested with the 2026-10-17 test build, `UE4SS_v3.0.1-1181-g83330635.zip`) | Loads the mod into the game |
| Python 3 | Runs the installer (and the tests) |

UE4SS's builds are on its [releases page](https://github.com/UE4SS-RE/RE-UE4SS/releases); the one used here is under **experimental-latest**. A copy is kept in `F:\TSW mod downloads\ue4ss-zip`.

## Installing

Close the game first. Then either double-click **Install fly-by camera.bat** (UE4SS already installed), or install UE4SS and the mods together:

```
python install.py --ue4ss "F:\TSW mod downloads\ue4ss-zip\UE4SS_v3.0.1-1181-g83330635.zip"
```

That installs both mods, the fly-by camera and the comfort HUD. Add `--mod FlyByCamera` for just the fly-by camera.

The installer finds the game through Steam and puts these next to `TrainSimWorld.exe` in `...\Train Sim World 7\WindowsNoEditor\TS2Prototype\Binaries\Win64`:

- `dwmapi.dll`: the loader that starts UE4SS with the game.
- `ue4ss\`: UE4SS itself, its settings and its mods. The fly-by camera is `ue4ss\Mods\FlyByCamera`.

It also sets UE4SS up quietly:

- **No windows:** UE4SS opens no console or GUI windows over the game.
- **No hot reload:** mods aren't reloaded by pressing Ctrl+R.
- **Sample mods off:** UE4SS's sample mods are switched off in `ue4ss\Mods\mods.txt`, including its Ctrl+J / Ctrl+H object-dump keys. UE4SS's original settings are kept as `UE4SS-settings.ini.original`.

Steam's "Verify integrity of game files" leaves these files alone. A game update can stop UE4SS loading until UE4SS itself is updated: install the newer UE4SS zip the same way.

## Changing how it behaves

The settings are in `FlyByCamera\Scripts\flyby_settings.lua`: how far ahead and to the side the camera stands, when it moves on, which side, zoom, the seat view, and the keys. Edit the copy here and run **Install fly-by camera.bat** again, then restart the game.

A few you may want:

- **LeadSeconds, MinLead, MaxLead:** how far ahead it waits. 8 seconds of travel, between 60 and 350 m.
- **SideOffset:** 12 m from the line.
- **Side:** `"alternate"`, `"left"` or `"right"`.
- **PassDistance:** how far past the train goes before the camera moves on, 200 m. Raise it for long trains.
- **Zoom:** zooms in while the train is far away. Set to `false` for a fixed `Fov`.
- **CheckView:** before picking a spot, looks for hills, cuttings, walls and buildings in the way, and stands the camera on the ground.
- **SeatFov:** the field of view from a seat, 70 degrees.
- **SeatEyeHeight:** for seats that don't say where a seated passenger's eyes are, the camera goes 1.15 m above the seat.
- **SeatKey:** `"FOUR"`. Any key name from UE4SS's Key table works.
- **SeatWindowTurn:** how far round from the way their seat faces towards the window the passenger looks, 50 degrees.
- **SeatNeckTurn:** the furthest round from the way their seat faces they turn their head when they glance about, 110 degrees.
- **SeatLookAround:** `false` keeps the gaze steady, with no wandering or glances.
- **SeatShake:** how much the head moves with the train. `0` holds it still; `2` is twice as much.
- **SeatMouse, SeatMouseSpeed, SeatMouseReturn:** turning the view with the mouse, at 2.5 degrees per step of the game's mouse movement (as in the cab). `SeatMouseReturn` is the seconds before the gaze goes back by itself; `false` leaves it where you put it.

## How it picks a spot

TSW splits each rail vehicle in two:

- **The model actor** (`CL70_FL_RVM_C` for the Class 70) stays at the world's origin.
- **The vehicle you see** (`RVV_AABS_Class70_C`) is the one that moves.

The mod follows the one you see, which your driver is attached to.

It times your train for its speed, and reads the vehicle's heading for the direction of the line and how sharply it's curving. The heading turns as the line curves, so the curve is known within a few metres of switching on. It watches where the train has been for the gradient.

It carries that curve on ahead to guess where the line goes, then tries spots beside that point. It traces a line from each spot across to the track and towards the train, and takes the first spot with a clear view of both. It doesn't read the game's track data (yet), so a spot can be off just after a change of curve, a junction or a tunnel mouth. Press 7 for another.

## How it picks a seat

The seats are the game's own: the ones you can sit in when walking through a train. Each vehicle has groups of them, with each seat's position, the way it faces and where a seated passenger's eyes go. A cab seat or two is a `SeatComponent`; a car's passenger seating is usually one `MultiSeatComponent`.

1. It asks the game for the vehicles of your train, and finds the seat groups on them.
2. It goes by each group's role first (passenger, driver or guard), then its name (first class, standard class, driver's seat, steps and so on). Some trains (the Class 331 for one) leave the name at the game's default, which reads as "Engineer", so that name alone doesn't count. A multi-seat counts as passenger seating unless its role says otherwise. It leaves out cab seats, guard's seats, steps and ladders. If no seat on the train says what it is, any of them will do.
3. It picks a random seat, preferring one with no passenger of the game's sitting in it, and never the one you're already in.
4. It attaches the camera to the seat's vehicle, at the seat, so it rides with the train exactly. If the game won't attach it, the camera is moved to the seat every frame instead. The game lets go of a car's seats when the car is far off (the Rotem cars' beyond 80 m), and they drop to the world's origin and stay there; the mod places those where they belong on their car.
5. It works out which way the seat faces by finding its back: a short line traced forward and back from the passenger's eyes hits the headrest on one side. If neither side hits anything, it goes by the seat's own rotation. Unreal's characters face their Y axis, and the Class 331's seats are turned that way.
6. Each frame, the passenger's head (`seat_head.lua`) decides where they look and how far it has moved. Where they look follows their seat and their window, whichever way the train goes. How their head leans and shakes follows the train: its speed and way of travel come from the vehicle's own velocity.

If your vehicles won't list their seats, it searches every seat in the world and keeps those on your train. Seats more than 1 km from your vehicle are left out.

## When something's wrong

Everything the mod does is written to `ue4ss\UE4SS.log` in the game's Win64 folder, on lines starting `[FlyBy]`:

- **Switching on:** which vehicle it follows and where it is, and the train's speed as timed and as the game reports it.
- **Each spot:** how far ahead, which side, the ground height, and whether the line and the train are in view.
- **Every 2 seconds while on:** where the train is and how far it moved. Turn these off with `DebugLog = false`.
- **The game taking the view:** each time, and what it switched to.
- **Each seat:** which seat and vehicle, where the eyes went, which way it faces, whether the game had let go of its group, and whether the camera is attached. Before that, how many seats it found on your train, on other trains and away from the train.
- **Every 2 seconds in a seat:** where the camera is and how far from the middle of its vehicle (it stays the same if the camera rides along properly), the speed, and how far round from the way of travel the passenger is looking.
- **The mouse:** the first time it turns the seat view, or that it can't be read.

Pressing **F10** in a drive adds a report: which vehicle it would follow, everything the driver is attached to and where, the game's camera functions, and the first few seat groups on your train with what the game says about them.

**Nothing happens on 7:**
- Check `UE4SS.log` exists. If it doesn't, UE4SS didn't load.
- If it does, look for `[FlyBy] loaded`.

**The view flicks back:** look for `the game took the view` and `the game keeps taking the view back` in the log, with what the game switched to.

**The camera is somewhere odd:** the `new spot` and `train at` lines show where the train was and what the mod found there.

**4 says there are no passenger seats:** the line after it says how many seat groups it found and where. A freight train has none.

**Removing:**
- **Uninstall fly-by camera.bat** removes the mod and leaves UE4SS and the comfort HUD.
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

**Seat view, first try, same day (Airedale & Wharfedale, Class 331):**
- 4 did nothing. The mod found the train's 13 seat groups but counted every one as crew. The 331's passenger seating has its role set to Passenger and its name left at the default ("Engineer"), and the mod checked the name first. Since fixed: the role goes first.
- The game's own list of the train (GetFormation) came back empty, as it did for the comfort HUD. The game's IsConsistPlayerDriven found the train instead.

**Seat view, second try, same day and train:**
- 4 put the camera in the passenger seats: 184 of them in 3 multi-seats, the camera attached at the game's own eye point for each (118 cm above the seat).
- Every seat logged "facing sideways": the seats are turned a quarter turn from what the mod assumed. Since fixed: the view now follows the passenger's gaze, and the seat's facing comes from its back.
- You asked for a more human view: looking ahead out of the nearest window, the head moving with the train, and the mouse to look around. That's what the passenger's head now does.

**Seat view, third try, same day and train:**
- Nearly right. Passengers in backward-facing seats looked round towards the front, which looked like their heads were turned too far. Since fixed: everyone looks the way their seat faces, towards their own window.

**Seat view, same day (BL36PH with three Rotem cars, `MPB_TR`):**
- 4 found 362 seats in 3 multi-seats, one per car. In the coaches the camera rode along at the seats' eyes, and the mouse turned the view.
- Now and then the camera sat still under the track. Every time, the seat was in the cab car at the back. The Rotem cars' blueprints have the game unregister and detach their seats once the car is more than 80 m off, so the cab car's seat group had dropped to the world's origin and stayed there, and the camera with it. Since fixed: the camera rides on the car itself, and a seat group the game has let go of is placed where it belongs on its car (`let go of by the game` in the log).
- The line traces found no seat backs on these cars: every seat's facing was guessed from its rotation.

**Still to see in the game:**
- the first spot on curves since that fix
- the camera moving itself on once the train is past (every test so far was switched off first)
- 7 moving to a new spot while on
- a seat in a car the game had let go of: whether the car's seats and passengers are drawn once you sit there (the Rotem cars' seat models are let go of beyond 80 m too)
- the passenger's head in the game. The seat classes and their fields were read from `TrainSimWorld.exe` and the 331's own blueprints, and the key bindings from the game's `DefaultInput.ini`. Still to see:
  - whether the line traces find the seats' backs (`its back ... behind` in the log) on any train, or it always has to guess
  - whether the gaze, shake and glances feel right
  - whether the game hides the passenger in that seat

## For working on it

- `FlyByCamera\Scripts\main.lua`: the parts that talk to the game: keys, the camera, finding the train and its seats, the once-a-frame update.
- `FlyByCamera\Scripts\flyby_math.lua`: following the train, guessing the line ahead, picking and scoring spots, turning a seat's position into the world's. No game objects in it.
- `FlyByCamera\Scripts\seat_head.lua`: the seat view's passenger: where they look and how their head moves. No game objects in it either.
- `tests\`: runs the real Lua through [lupa](https://pypi.org/project/lupa/) against `tests\fake_ue4ss.lua`, a train driving a line that curves, with ground and walls, two coaches with seats behind the loco, and an AI train with seats of its own. Run `python -m unittest discover tests`. lupa is installed in `F:\TSW mod downloads\pylib`, which the tests find by themselves.
