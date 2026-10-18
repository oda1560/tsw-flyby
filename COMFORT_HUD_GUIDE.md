# TSW Comfort HUD User Guide

Last updated 2026-10-18

## What it does

The comfort HUD adds passenger information to the objective box at the top left of Train Sim World 7's screen, where the game shows your objective and the clock. The second line of the objective gets how many passengers are aboard and how comfortable the service has been so far:

> **LOAD PASSENGERS**
> Wait until 19:06:00 · 62 aboard · comfort 87

While there's something to tell you, a comfort warning takes the objective's place, then the game's objective comes back:

| The box says | When |
| --- | --- |
| **EASE OFF THE BRAKE** (amber), Stopping in 3 s · 62 aboard | Braking over 0.6 m/s² and about to stop: ease off before the train stops |
| **SMOOTH STOP** (green), comfort 87 · 62 aboard | For 6 s after a stop with no jolt |
| **JOLT ON STOPPING** (red), 1.4 m/s² as it stopped · -21 · comfort 79 | For 6 s after a stop that braked harder than 0.7 m/s² in its last 1 m/s, and what that cost |
| **FIRM BRAKING 1.0 m/s²** (amber), Ease off a step · comfort 87 | Braking over 0.9 m/s², or speeding up over 1.3 m/s² (FIRM ACCELERATION) |
| **HARSH BRAKING 1.3 m/s²** (red), -10 this ride · comfort 84 · 62 aboard | Braking over 1.2 m/s², or speeding up over 1.5 m/s² |
| **FIRM BRAKING -4** (amber or red), This ride 96 · comfort 96 · 62 aboard | For 4 s once a firm or harsh stretch is over: what it cost |

The rules and the comfort score are the same as tsw-joystick's passenger comfort, ported from it. Each ride from one station to the next starts at 100. It loses a point for each second of firm braking or acceleration, and 10 for a harsh moment plus 2 for each second it lasts past the first. A stop with a jolt costs 30 for each m/s² over 0.7, at most 30. The service's comfort is the average of the rides' marks, weighted by the passengers aboard. The slope isn't counted, so steep lines don't set it off.

Only passenger trains are judged, empty ones included. On freight trains and light engines the objective box stays as the game has it.

| Key | What it does |
| --- | --- |
| = | Switch the comfort HUD off (the objective box goes back to the game's own) and on again |
| F11 | Write a report of what the mod can see into UE4SS.log (for fixing problems) |

TSW7 doesn't bind = or F11 itself. The fly-by camera uses 6, 7 and F10, so the two mods can run together.

## Installing

The comfort HUD runs through UE4SS, like the fly-by camera: see [the fly-by camera's guide](USER_GUIDE.md#before-you-start) for what's needed.

Close the game, then double-click **Install comfort HUD.bat**. It goes into `ue4ss\Mods\ComfortHUD` in the game's Win64 folder. `python install.py` installs both mods; `--mod ComfortHUD` installs just this one.

**Uninstall comfort HUD.bat** takes it out again and leaves UE4SS and the fly-by camera.

If you also run tsw-joystick, switch off its **Show passenger comfort** setting, or you'll get each warning twice.

## Changing how it behaves

The settings are in `ComfortHUD\Scripts\comfort_settings.lua`. Edit the copy here and run **Install comfort HUD.bat** again, then restart the game.

- **ShowPassengers, ShowComfort:** the "62 aboard" and "comfort 87" after the objective.
- **Warnings:** the warnings in the objective's place. Set to `false` to keep the game's objective there all the time.
- **PlainText:** writes " / " and "m/s2" instead of " · " and "m/s²", in case the game shows those characters oddly.
- **ToggleKey, ReportKey:** the keys.
- **DebugLog:** a line in the log every 5 seconds while you drive.

## Framerate

The mod draws nothing of its own. It changes the text in the game's own objective box, and only when the words change. Each frame it asks the game two things, the time and the train's velocity. Besides that it makes about six calls a second: whether you're still aboard, whether the box is shown, and the game's objective. While stopped it also counts the passengers every 5 s. Working out the comfort and the box's words is the mod's own arithmetic, with no calls into the game. There are no windows over the game and no requests to the game's web API, the two things most likely to have slowed the game down with tsw-joystick.

Searching through all the game's objects takes milliseconds, so the mod only does that once, to find the player when a drive loads. Your train's cars come from the game's own list of your train, without a search. The F11 report does search, so the game may stutter for a moment when you press it.

To see what it costs, look at the `[Comfort]` lines every 5 seconds in `UE4SS.log`. Each one ends with how long the mod's work took, on average per frame and at most. The clock it uses counts in whole milliseconds, so the average comes from many frames and the most is either 0 or 1 ms. To compare framerates, press **=** to switch the mod off completely and **=** again to switch it back on.

## How it works

- **Speed:** read every frame from the vehicle you're in, with the game's own time. The acceleration is the change of speed over the last 0.3 s of game time, so it doesn't stretch when the game runs slowly.
- **Passengers:** the game lists the vehicles of your train (`GetFormation`), and each one with passengers has a `PassengerCargoModel` the mod counts. It counts when you get into the train and every 5 s while stopped, and notices if the train is coupled or split at a stop. Cars of other trains, AI ones included, aren't counted.
- **The train's own holding brake:** read from the train's simulation the way the game's own blueprints read it (`DirectBrakeControlPowered.BrakeHoldActive` and the like, as tsw-joystick reads them). From when it comes on as the train stops, braking harder than just before isn't counted, so a Class 350's stops aren't all jolts. It's only read while the train is coming to a stop or moving off.
- **Stations:** a stop counts as a station when, as the train comes in or while it stands, the game moves the objective on or the passengers change. Leaving a station ends the ride to it. A stop at a signal doesn't end the ride: a jolt there counts towards the ride it's on.
- **The objective box:** the mod writes into the game's own objective box, in both the full and the minimal HUD. When the game writes its own text there, for a new objective or a new time, the mod puts its text back straight away.

## Differences from tsw-joystick

- **Brake timing:** the ease-off warning allows 3 s for the brake to release on every train. tsw-joystick times each train's brake.
- **Holding brakes:** recognised as in tsw-joystick, but not yet seen working in the game. If stops on a Class 350, 331, 333 or 380 all show as jolts however gently you stop, look for `the train's own holding brake` in the log.
- **Saves:** the comfort so far is lost when you quit the game or load a save. tsw-joystick keeps it with the game's saves.
- **Without an objective:** in free roam, or whenever the game hides the objective box, nothing is shown.

## When something's wrong

Everything the mod does is written to `ue4ss\UE4SS.log` in the game's Win64 folder, on lines starting `[Comfort]`:

- **Loading a drive:** whether it found the objective box and could watch it for the game's text.
- **Getting into a train:** which train, how many passenger cars it found in it and how (the game's list of your train is the one expected), and whether the train has its own holding brake.
- **Stops:** smooth or jolt and how hard, and the mark of each ride when you leave a station.
- **Every 5 seconds while driving:** speed, acceleration, passengers, comfort, what the box is showing, and how long the mod's work took.

Pressing **F11** adds a report: your train front to back and which vehicles carry passengers, the service's name as the game gives it, each passenger car and its count, the holding brake, the comfort so far, what the objective box says and how big it is, and the game functions the mod uses with their parameters.

**Nothing changes in the objective box:**
- Look for `[Comfort] loaded` in the log. If it's missing, UE4SS didn't load the mod.
- If it's there, look for `found the objective box`.

**No passenger numbers:**
- Look for `passenger cars on your train`.
- A line saying `only the vehicle you drive` means the game wouldn't list your train, and the reason follows. Only the vehicle you drive is counted then.
- A line saying `can't count the passengers` means the count couldn't be read. Comfort is still judged then.

**The line runs onto two lines:** the minimal HUD wraps its second line at about 40 characters. Turn off **ShowPassengers** or **ShowComfort**.

## What's been seen in the game

It was built from the game's own files: the objective box's layout and logic (it's `HUDObjectiveWidget_Minimal` on the minimal HUD), and the game functions it calls. Their parameters were read from the game's reflection tables in `TrainSimWorld.exe`.

**First drive, 2026-10-18 (TfW Class 150, from a station stop to about 18 m/s):**
- The mod loaded. The game said when it made both objective boxes, so no search was needed, and the mod hooked the game's writing in them.
- It found the train, read 0.5 m/s² pulling away and showed comfort 100 once moving.
- The game ran at about 30 fps. The mod's work averaged 0.1–0.3 ms a frame.
- It couldn't tell which cars were yours, so it counted only the car you drove: 50 aboard, then 17–22 after the stop. The game functions had been called without the parameters they take. Since fixed: the cars now come from the game's list of your train, and the service's name and the holding brake are read with the right parameters. The work each frame was cut down too: the box's words are worked out without asking the game, and the hidden box (the full HUD's, under the minimal one) is left alone.

**Still to see in the game:**
- the passenger count for the whole train, against the game's own
- the service's name: whether the game gives it back as the mod expects
- whether "·" and "²" look right, and the second line fits on one line
- the warnings and how stops are judged, compared with tsw-joystick's if you have it
- a Class 350's holding brake
- the mod's work each frame since it was cut down

## For working on it

- `ComfortHUD\Scripts\main.lua`: the parts that talk to the game: finding the train, its passenger cars and the objective box, reading the speed, writing the text, the keys and the report.
- `ComfortHUD\Scripts\comfort_judge.lua`: the comfort rules, ported line for line from tsw-joystick's `tsw_comfort.py` (`Judge`). No game objects in it.
- `ComfortHUD\Scripts\hud_text.lua`: what the objective box says for each warning.
- `tests\test_comfort_judge.py`: runs the Lua rules and tsw-joystick's Python side by side on the drives logged there (a Class 150 on 1M56, a Class 350 stop on 2W09) and on made-up services, and checks they agree at every reading. It needs tsw-joystick in `C:\code\tsw-joystick`.
- `tests\test_comfort_hud.py`: runs the whole mod against `tests\fake_comfort_game.lua`, a passenger train, an AI train and the minimal HUD's objective box. Run `python -m unittest discover tests`.
