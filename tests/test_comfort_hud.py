"""
Tests for the comfort HUD mod: runs ComfortHUD/Scripts/main.lua in real Lua 5.4 against a stand-in for UE4SS and
the game (tests/fake_comfort_game.lua): a passenger train, an AI train, and the HUD's objective box.

    python -m unittest discover tests

Needs lupa (Lua for Python). If it isn't installed normally, set FLYBY_PYLIB to the folder it was installed into
with pip --target.
"""

import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "ComfortHUD", "Scripts").replace("\\", "/")
TESTS = os.path.join(ROOT, "tests").replace("\\", "/")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gvas  # noqa: E402

try:
    from lupa import lua54
except ImportError:
    sys.path.insert(0, os.environ.get("FLYBY_PYLIB", r"F:\TSW mod downloads\pylib"))
    try:
        from lupa import lua54
    except ImportError:
        lua54 = None

DOT = " \u00b7 "


@unittest.skipIf(lua54 is None, "needs lupa: pip install lupa")
class ComfortHUD(unittest.TestCase):
    def start(self, settings=None, load=True, saves=None, **sim):
        """The game with a train, the mod loaded into it, then the drive loading (load=True). `saves`: the game's save
        files, as install.py tells the mod where they are."""
        self.lua = lua54.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(f'package.path = "{SCRIPTS}/?.lua;{TESTS}/?.lua;" .. package.path')
        if saves is not None:
            self.lua.globals().SAVE_LIST = self.lua.table_from(saves)
            self.lua.execute('package.preload["comfort_save_files"] = function() return SAVE_LIST end')
        self.sim = self.lua.eval('(require("fake_comfort_game"))')
        self.lua.globals().Sim = self.sim
        sim = {k: self.lua.table_from(v) if isinstance(v, list) else v for k, v in sim.items()}
        self.sim.setup(self.lua.table_from(sim))
        s = self.lua.eval('(require("comfort_settings"))')
        for key, value in (settings or {}).items():
            s[key] = value
        self.lua.execute(f'dofile("{SCRIPTS}/main.lua")')
        self.assertIn("[Comfort] loaded", self.logs())
        if load:
            self.sim.load_hud()
            self.sim.objective("LOAD PASSENGERS", "Wait until 19:06:00")

    def logs(self):
        return self.sim.all_logs()

    def clear_calls(self):
        self.lua.execute("for k in pairs(Sim.calls) do Sim.calls[k] = nil end")

    def shown(self):
        return tuple(self.sim.shown())

    def colour(self):
        c = self.sim.name_colour()
        return (round(c.R, 2), round(c.G, 2), round(c.B, 2))

    def run_at(self, seconds, acc=0.0):
        self.sim.acc = acc
        self.sim.run(seconds)

    def drive_off(self, to=20.0, rate=0.8):
        """Speeds up gently (comfortable) to `to` m/s."""
        self.sim.objective("DRIVE TO SHIPLEY", "Arrive by 19:12:00")
        self.run_at(to / rate, rate)
        self.sim.v = to
        self.run_at(2, 0.0)

    def stop(self, rate, ease_below=0.0, eased=0.3):
        """Brakes at `rate` m/s² to a stand, easing to `eased` below `ease_below` m/s; returns what the box said as
        the train stopped and a moment after."""
        seen = []

        def drive(t, v):
            return -(rate if v > ease_below else eased) if v > 0 else 0.0
        self.sim.drive = drive
        last = [None]

        def each(t):
            now = self.shown()
            if now != last[0]:
                seen.append(now)
                last[0] = now
        self.sim.run(60, each)
        self.sim.drive = None
        self.sim.acc = 0.0
        return seen

    # ---- the objective box

    def test_passengers_after_the_objective(self):
        self.start()
        self.run_at(2)
        self.assertEqual(self.shown(), ("LOAD PASSENGERS", "Wait until 19:06:00" + DOT + "62 aboard"))

    def test_only_your_train_s_passengers(self):
        self.start(passengers=[10, 5])
        self.run_at(2)
        self.assertIn("15 aboard", self.shown()[1])
        self.assertIn("2 passenger cars on your train (the game's list of your train, 3 vehicles)", self.logs())
        self.assertEqual(self.sim.searched("PassengerCargoModelComponent"), 0)

    def test_comfort_once_the_first_ride_has_begun(self):
        self.start()
        self.drive_off()
        self.assertEqual(self.shown(), ("DRIVE TO SHIPLEY", "Arrive by 19:12:00" + DOT + "62 aboard" + DOT +
                                        "comfort 100"))

    def test_firm_braking_takes_over_the_box_then_what_it_cost(self):
        self.start()
        self.drive_off()
        self.run_at(2.5, -1.0)
        title, line = self.shown()
        self.assertEqual(title, "FIRM BRAKING 1.0 m/s\u00b2")
        self.assertEqual(line, "Ease off a step" + DOT + "comfort 98")
        self.assertEqual(self.colour(), (0.93, 0.58, 0.0))
        self.run_at(1.5, -0.3)
        title, line = self.shown()
        self.assertEqual(title, "FIRM BRAKING -2")
        self.assertEqual(line, "This ride 98" + DOT + "comfort 98" + DOT + "62 aboard")
        self.run_at(5, -0.3)
        self.assertEqual(self.shown(), ("DRIVE TO SHIPLEY", "Arrive by 19:12:00" + DOT + "62 aboard" + DOT +
                                        "comfort 98"))
        self.assertEqual(self.colour(), (1.0, 1.0, 1.0))

    def test_harsh_braking_in_red_with_what_it_has_cost(self):
        self.start()
        self.drive_off()
        self.run_at(2, -1.4)
        title, line = self.shown()
        self.assertEqual(title, "HARSH BRAKING 1.4 m/s\u00b2")
        self.assertTrue(line.startswith("-1"), line)
        self.assertIn("62 aboard", line)
        self.assertEqual(self.colour()[1:], (0.06, 0.04))

    def test_ease_off_before_the_stop_then_the_jolt(self):
        self.start()
        self.drive_off(to=8.0)
        seen = self.stop(1.0)
        titles = [t for t, _ in seen]
        self.assertIn("EASE OFF THE BRAKE", titles)
        ease = [line for t, line in seen if t == "EASE OFF THE BRAKE"]
        self.assertTrue(ease[0].startswith("Stopping in 4 s") or ease[0].startswith("Stopping in 5 s"), ease[0])
        jolt = [line for t, line in seen if t == "JOLT ON STOPPING"]
        self.assertTrue(jolt, titles)
        self.assertTrue(jolt[0].startswith("1.0 m/s\u00b2 as it stopped" + DOT + "-9" + DOT + "comfort"), jolt[0])
        self.assertIn("jolt on stopping, braking 1.0 m/s² as it stopped, 62 aboard", self.logs())

    def test_easing_off_is_a_smooth_stop(self):
        self.start()
        self.drive_off(to=8.0)
        seen = self.stop(0.7, ease_below=2.5, eased=0.3)
        titles = [t for t, _ in seen]
        self.assertIn("SMOOTH STOP", titles)
        self.assertNotIn("JOLT ON STOPPING", titles)
        smooth = [line for t, line in seen if t == "SMOOTH STOP"]
        self.assertEqual(smooth[0], "comfort 100" + DOT + "62 aboard")

    def test_no_warnings_when_switched_off_in_the_settings(self):
        self.start({"Warnings": False})
        self.drive_off()
        self.run_at(2, -1.4)
        self.assertEqual(self.shown()[0], "DRIVE TO SHIPLEY")

    def test_plain_text(self):
        self.start({"PlainText": True})
        self.drive_off()
        self.run_at(2.5, -1.0)
        self.assertEqual(self.shown(), ("FIRM BRAKING 1.0 m/s2", "Ease off a step / comfort 98"))

    # ---- stations and rides

    def test_leaving_a_station_ends_the_ride(self):
        self.start()
        self.drive_off(to=8.0)
        self.stop(0.7, ease_below=2.5, eased=0.3)
        self.sim.objective("LOAD PASSENGERS", "Wait until 19:12:30")
        self.run_at(3)
        self.drive_off()
        self.assertIn("the ride to the stop marked 100, 62 passengers; 1M56 so far 100 over 1 ride", self.logs())

    def test_a_stop_at_a_signal_doesn_t(self):
        self.start()
        self.drive_off(to=8.0)
        self.stop(0.7, ease_below=2.5, eased=0.3)
        self.run_at(20)
        self.drive_off()
        self.assertNotIn("the ride to the stop", self.logs())

    def test_another_service_starts_afresh(self):
        self.start()
        self.drive_off()
        self.run_at(3, -1.0)
        self.run_at(6)
        self.assertIn("comfort 9", self.shown()[1])
        self.sim.service = "2W09"
        self.run_at(6)
        self.assertIn("service 2W09", self.logs())
        self.assertTrue(self.shown()[1].endswith("comfort 100"), self.shown())    # the ride going on, on 2W09

    # ---- the game's saves

    def with_saves(self, folder=None, **kw):
        """The game's save and checkpoint, from the day before, then the mod and the drive (start)."""
        if folder is None:
            folder = tempfile.mkdtemp()
            for name in ("TSWSaveGame_abc.sav", "TSWCheckpointSaveGame_abc.sav"):
                gvas.write_save(os.path.join(folder, name), "1M56", 63876686400.0)    # 2025-03-04 12:00
        self.folder = folder
        self.save = os.path.join(folder, "TSWSaveGame_abc.sav").replace("\\", "/")
        self.checkpoint = os.path.join(folder, "TSWCheckpointSaveGame_abc.sav").replace("\\", "/")
        self.start(saves=[self.save, self.checkpoint], **kw)

    def day(self):
        return self.sim.day0 + self.sim.time

    def game_saves(self, path, service="1M56"):
        """The game writing its save or checkpoint as the drive is now; the time of day it was made at."""
        at = self.day()
        gvas.write_save(path, service, at)
        return at

    def kept(self, path):
        with open(path.replace(".sav", ".comfort"), encoding="utf-8") as f:
            return f.read()

    def to_station(self, rate=0.7):
        """Drives off, stops at `rate` m/s² (0.7: easing off, smooth; 1.0: a jolt) and stands at a station."""
        self.drive_off(to=8.0)
        if rate < 0.9:
            self.stop(rate, ease_below=2.5, eased=0.3)
        else:
            self.stop(rate)
        self.sim.objective("LOAD PASSENGERS", "Wait until 19:12:30")
        self.run_at(3)

    def test_kept_beside_the_checkpoint_made_on_arriving(self):
        self.with_saves()
        self.assertIn("keeping the comfort beside the game's saves: TSWSaveGame_abc.sav, "
                      "TSWCheckpointSaveGame_abc.sav", self.logs())
        self.to_station()
        self.drive_off()                                  # the ride to the first station done
        self.to_station(1.0)                              # a jolt at the second
        self.game_saves(self.checkpoint)
        self.run_at(2)
        self.assertIn("the game's time of day: 2025-03-05 19:00:0", self.logs())
        self.assertIn("kept with the game's checkpoint of 1M56 at 19:0", self.logs())
        self.assertIn(": 1 ride done, comfort 100", self.logs())
        text = self.kept(self.checkpoint)
        self.assertIn('service = "1M56"', text)
        self.assertIn('stop = "jolt"', text)              # the ride going on, to this station
        self.assertIn("station = true", text)
        self.assertNotIn("TSWSaveGame_abc.comfort", os.listdir(self.folder))   # the game's own save wasn't written

    def test_put_back_when_the_checkpoint_is_loaded(self):
        self.with_saves()
        self.to_station()
        self.drive_off()
        self.to_station(1.0)
        at = self.game_saves(self.checkpoint)
        self.run_at(2)
        self.drive_off()                                  # the ride with the jolt done: comfort below 100
        self.run_at(3, -1.4)                              # and harsh braking after
        self.assertIn("1M56 so far 9", self.logs())
        self.sim.new_world(at + 0.4)                      # the checkpoint loaded: back at the second station
        self.sim.load_hud()
        self.sim.objective("LOAD PASSENGERS", "Wait until 19:12:30")
        self.run_at(3)
        self.assertIn("the game's checkpoint of 1M56 at 19:0", self.logs())
        self.assertIn(" loaded: back to 1 ride done, comfort 100", self.logs())
        self.sim.objective("DRIVE TO SAPPHIRE", "Arrive by 19:20:00")
        self.drive_off()                                  # leaving the station ends the ride with the jolt again
        logs = self.logs()
        self.assertEqual(logs.count("over 2 rides"), 2)   # once before the load, once after: not a third ride
        self.assertNotIn("harsh", logs[logs.index("loaded: back to"):])

    def test_put_back_when_the_game_sets_its_time_of_day_late(self):
        self.with_saves()
        self.to_station()
        self.drive_off()
        self.to_station(1.0)
        at = self.game_saves(self.checkpoint)
        self.run_at(2)
        self.drive_off()
        self.sim.new_world(at - 3600)                     # aboard at the service's start time at first ...
        self.sim.load_hud()
        self.run_at(2)
        self.sim.day0 = at + 0.4 - self.sim.time          # ... then the save's
        self.run_at(6)
        self.assertIn(" loaded: back to 1 ride done, comfort 100", self.logs())

    def test_the_time_of_day_written_out_if_the_datetime_can_t_be_read(self):
        self.with_saves()
        self.sim.datetime_empty = True
        self.to_station()
        self.drive_off()
        self.to_station(1.0)
        at = self.game_saves(self.checkpoint)
        self.run_at(2)
        self.assertIn("the game's time of day: 2025-03-05 19:00:0", self.logs())
        self.assertIn("(GetLocalTimeOfDayAsString)", self.logs())
        self.assertIn("kept with the game's checkpoint of 1M56", self.logs())
        self.drive_off()
        self.sim.new_world(at + 0.4)
        self.sim.load_hud()
        self.run_at(3)
        self.assertIn(" loaded: back to 1 ride done, comfort 100", self.logs())

    def test_carried_over_when_the_game_is_started_again(self):
        self.with_saves()
        self.to_station()
        self.drive_off()
        self.to_station(1.0)
        self.sim.paused = True                            # Save in the menu
        at = self.game_saves(self.save)
        self.run_at(2)
        self.assertIn("kept with the game's save of 1M56", self.logs())
        self.with_saves(self.folder, day=at + 3.0)        # another evening: the game started again on that save
        self.run_at(3)
        self.assertIn("the game's save of 1M56 at 19:0", self.logs())
        self.assertIn(" loaded: back to 1 ride done, comfort 100", self.logs())
        self.assertRegex(self.shown()[1], "comfort 9[0-9]$")    # with the jolt in the ride going on

    def test_saving_and_quitting_still_kept(self):
        self.with_saves()
        self.to_station()
        self.drive_off()
        self.sim.paused = True
        self.game_saves(self.save)
        self.sim.walked_off = True                        # the drive gone before the mod saw the save
        self.run_at(2)
        self.assertIn("not driving", self.logs())
        self.assertIn("kept with the game's save of 1M56", self.logs())

    def test_saved_while_stopping_kept_once_the_stop_is_judged(self):
        self.with_saves()
        self.drive_off(to=8.0)
        self.sim.drive = lambda t, v: -1.0 if v > 0 else 0.0
        while self.sim.v > 1.5:
            self.sim.run(0.1)
        self.game_saves(self.checkpoint)                  # the game saving as the train comes in
        self.sim.run(10)
        self.assertIn("kept with the game's checkpoint", self.logs())
        self.assertIn('stop = "jolt"', self.kept(self.checkpoint))

    def test_gone_back_with_nothing_kept(self):
        self.with_saves()
        start = self.day()
        self.to_station()
        self.drive_off()
        self.to_station()
        self.drive_off()
        self.assertIn("over 2 rides", self.logs())
        second_arrived = self.day() - 30
        self.sim.new_world(second_arrived - 20)           # an older save, made without the mod
        self.sim.load_hud()
        self.run_at(3)
        self.assertIn("nothing kept with a save there: 1 ride from after it dropped, 1 ride done", self.logs())
        self.assertGreater(second_arrived - 20, start)

    def test_another_save_there_since_isn_t_taken_for_the_one_kept(self):
        self.with_saves()
        self.to_station()
        self.drive_off()
        at = self.game_saves(self.checkpoint)
        self.run_at(2)
        self.assertIn("kept with the game's checkpoint", self.logs())
        gvas.write_save(self.checkpoint, "1M56", at + 200)   # the game's next checkpoint, made with the mod off
        self.sim.new_world(at + 200.5)
        self.sim.load_hud()
        self.run_at(3)
        self.assertIn("on the game's checkpoint of 1M56", self.logs())
        self.assertIn("nothing kept with it", self.logs())

    def test_without_the_save_files_nothing_kept(self):
        self.start()
        self.assertIn("the game's save files aren't known", self.logs())
        self.to_station()
        self.drive_off()
        self.assertNotIn("kept with the game", self.logs())
        self.assertNotIn("GetDateTime", self.sim.calls)

    def test_time_of_day_that_can_t_be_read(self):
        self.with_saves()
        self.sim.no_clock = True
        self.to_station()
        self.game_saves(self.checkpoint)
        self.clear_calls()
        self.run_at(40)
        self.assertEqual(self.sim.log_count("can't read the game's time of day"), 1)
        self.assertNotIn("kept with the game", self.logs())
        self.assertLessEqual(self.sim.calls["GetDateTime"] or 0, 2)     # tried again every 30 s, not every look

    def test_saves_switched_off_in_the_settings(self):
        self.with_saves(settings={"KeepWithSaves": False})
        self.to_station()
        self.game_saves(self.checkpoint)
        self.run_at(2)
        self.assertNotIn("kept with the game", self.logs())
        self.assertNotIn("keeping the comfort beside", self.logs())

    def test_few_game_calls_with_saves_kept(self):
        """The time of day is read on getting aboard and every 30 s after, a few calls each time; the time once more
        a second."""
        self.with_saves()
        self.drive_off()
        self.clear_calls()
        self.run_at(60)
        calls = {k: v for k, v in self.sim.calls.items()}
        self.assertLessEqual(calls.pop("GetTimeSeconds"), 3600 + 60)
        self.assertEqual(calls.pop("GetVelocity"), 3600)
        self.assertLessEqual(calls.pop("GetDateTime"), 2)
        self.assertLessEqual(sum(calls.values()), 6 * 60 + 2 * 4, calls)

    # ---- trains without passengers, and what can't be read

    def test_freight_shows_nothing_and_isn_t_judged(self):
        self.start(passengers=False)
        self.drive_off()
        self.run_at(2, -1.4)
        self.assertEqual(self.shown(), ("DRIVE TO SHIPLEY", "Arrive by 19:12:00"))
        self.assertIn("0 passenger cars on your train (the game's list of your train, 3 vehicles)", self.logs())

    def test_without_the_formation_only_the_car_you_drive(self):
        self.start(no_formation=True)
        self.run_at(2)
        self.assertIn("40 aboard", self.shown()[1])
        self.assertIn("only the vehicle you drive, of 3 in the world", self.logs())

    def test_without_the_formation_the_player_s_trains(self):
        self.start(no_formation=True, player_trains=True)
        self.run_at(2)
        self.assertIn("62 aboard", self.shown()[1])
        self.assertIn("the player's trains, of 3 in the world", self.logs())

    def test_coupled_at_a_stop(self):
        self.start()
        self.run_at(2)
        self.lua.execute('''
            local first = Sim.train[1]
            local extra = { valid = true, address = 9999, class = "RVM_Class150_DMS", path = "x.RVM_Class150_DMS_9",
                            IsValid = function(self) return self.valid end, GetAddress = function(self) return 9999 end,
                            GetFullName = function(self) return self.class .. " " .. self.path end,
                            GetComponentByClass = first.GetComponentByClass, GetFormation = first.GetFormation,
                            consist = Sim.train }
            extra.cargo = { valid = true, IsValid = function() return true end, GetOwner = function() return extra end,
                            GetPassengerCount = function() return 30 end }
            table.insert(Sim.train, extra)
        ''')
        self.run_at(6)
        self.assertIn("your train is now 4 vehicles", self.logs())
        self.assertIn("92 aboard", self.shown()[1])

    def test_service_name_given_back_either_way(self):
        for returned in (False, True):
            self.start(service="2W09")
            self.sim.service_returned = returned
            self.drive_off(to=8.0)
            self.stop(0.7, ease_below=2.5, eased=0.3)
            self.sim.objective("LOAD PASSENGERS", "Wait until 19:12:30")
            self.run_at(3)
            self.drive_off()
            self.assertIn("2W09 so far 100 over 1 ride", self.logs())

    # ---- the train's own holding brake (a Class 350's comes on at 0.62 m/s, braking it 0.9-1.0 m/s²)

    def held_stop(self, hold):
        self.start(hold=hold)
        self.drive_off(to=8.0)

        def drive(t, v):
            if v <= 0:
                return 0.0
            self.sim.hold_on = hold and v < 0.62
            if v < 0.62:
                return -0.95           # the train's own brake, whatever the handle says
            return -(0.7 if v > 2.5 else 0.37)
        self.sim.drive = drive
        self.sim.run(30)
        self.sim.drive = None
        return self.logs()

    def test_the_holding_brake_isn_t_a_jolt(self):
        logs = self.held_stop(True)
        self.assertIn("the train's own holding brake: DirectBrakeControlPowered", logs)
        self.assertIn("the train's own holding brake came on at 0.", logs)
        self.assertIn("smooth stop", logs)

    def test_without_it_the_same_stop_is_a_jolt(self):
        logs = self.held_stop(False)
        self.assertIn("the train's own holding brake: none", logs)
        self.assertIn("jolt on stopping", logs)

    def test_holding_brake_only_read_when_slow(self):
        self.start(hold=True)
        self.drive_off()
        self.clear_calls()
        self.run_at(10)
        self.assertEqual(self.sim.calls["GetSimulationNodeParameterAsBool"] or 0, 0)

    def test_passengers_that_can_t_be_counted_still_judged(self):
        self.start()
        self.sim.count_breaks = True
        self.sim.v = 0
        self.run_at(7)                                 # counted again while stopped
        self.drive_off()
        self.run_at(2, -1.4)
        self.assertIn("can't count the passengers", self.logs())

    def test_off_the_train_the_box_is_the_game_s(self):
        self.start()
        self.drive_off()
        self.sim.walked_off = True
        self.run_at(2)
        self.assertEqual(self.shown(), ("DRIVE TO SHIPLEY", "Arrive by 19:12:00"))
        self.assertIn("not driving: not aboard your train", self.logs())

    # ---- the game writing in the box

    def test_the_game_rewriting_the_box_is_put_right_at_once(self):
        self.start()
        self.run_at(2)
        self.sim.objective_text("LOAD PASSENGERS", "Wait until 19:07:00")
        self.assertEqual(self.shown()[1], "Wait until 19:07:00" + DOT + "62 aboard")  # the game's new time, at once

    def test_rewritten_without_a_hook_put_right_within_a_second(self):
        self.start()
        self.run_at(2)
        self.sim.objective_text("LOAD PASSENGERS", "Wait until 19:07:00", True)
        self.run_at(1)
        self.assertEqual(self.shown()[1], "Wait until 19:07:00" + DOT + "62 aboard")

    def test_templates_left_alone(self):
        self.start()
        self.run_at(2)
        self.assertEqual(self.sim.template.Description.shown, "Description")
        self.assertEqual(self.logs().count("found the objective box"), 1)

    def test_an_objective_box_the_game_didn_t_announce_is_found(self):
        self.start(widget=False)
        self.run_at(2)
        self.sim.widget_on_screen = True
        self.run_at(16)
        self.assertEqual(self.shown()[1], "Wait until 19:06:00" + DOT + "62 aboard")

    # ---- cost to the game

    def test_searches_only_when_something_changes(self):
        self.start()
        self.drive_off()
        self.run_at(60)
        self.assertEqual(self.sim.pc_searches, 1)
        self.assertEqual(self.sim.searched("PassengerCargoModelComponent"), 0)
        self.assertEqual(self.sim.searched("HUDObjectiveWidget_Minimal_C"), 0)

    def test_few_game_calls_while_driving(self):
        """Driving along with nothing happening: the time and the velocity each frame, and only a few calls a second
        besides (the driver still aboard, whether the box is shown and the game's objective)."""
        self.start()
        self.drive_off()
        self.clear_calls()
        self.run_at(10)
        calls = {k: v for k, v in self.sim.calls.items()}
        self.assertEqual(calls.pop("GetTimeSeconds"), 600)
        self.assertEqual(calls.pop("GetVelocity"), 600)
        self.assertLessEqual(sum(calls.values()), 60, calls)
        self.assertNotIn("SetText", calls)

    def test_the_hidden_box_left_alone(self):
        self.start()
        self.run_at(2)
        self.sim.widget.hidden = True
        self.run_at(2)
        self.clear_calls()
        self.sim.objective_text("LOAD PASSENGERS", "Wait until 19:07:00", True)
        self.run_at(5)
        self.assertNotIn("SetText", self.sim.calls)

    def test_paused_while_braking_costs_nothing_more(self):
        self.start()
        self.drive_off()
        self.run_at(1.0, -1.0)
        self.sim.paused = True
        self.run_at(10, -1.0)
        self.sim.paused = False
        self.run_at(6, -0.3)
        self.assertIn("comfort 99", self.shown()[1])

    def test_text_written_only_when_it_changes(self):
        self.start()
        self.run_at(2)
        before = self.sim.set_texts
        self.run_at(30)
        self.assertEqual(self.sim.set_texts, before)

    def test_off_does_nothing_and_gives_the_box_back(self):
        self.start()
        self.run_at(2)
        self.assertTrue(self.sim.press("OEM_PLUS"))
        self.assertEqual(self.shown(), ("LOAD PASSENGERS", "Wait until 19:06:00"))
        self.assertEqual(len(self.sim.frame_fns), 0)
        self.sim.press("OEM_PLUS")
        self.run_at(2)
        self.assertEqual(self.shown(), ("LOAD PASSENGERS", "Wait until 19:06:00" + DOT + "62 aboard"))

    def test_paused(self):
        self.start()
        self.drive_off()
        self.sim.paused = True
        self.run_at(5)
        self.sim.paused = False
        self.run_at(2)
        self.assertNotIn("something went wrong", self.logs())

    def test_report(self):
        self.start()
        self.drive_off()
        self.assertTrue(self.sim.press("F11"))
        self.assertIn("---- end of report", self.logs())
        self.assertNotIn("(train:", self.logs())
        self.assertIn("passenger cars: 2", self.logs())
        self.assertIn("HUDObjectiveWidget_Minimal_C, shown", self.logs())

    def test_report_on_the_saves(self):
        self.with_saves()
        self.to_station()
        self.game_saves(self.checkpoint)
        self.run_at(2)
        self.sim.press("F11")
        self.assertIn("the game's time of day: 2025-03-05 19:0", self.logs())
        self.assertIn("TSWCheckpointSaveGame_abc.sav: 1M56 at 2025-03-05 19:0", self.logs())
        self.assertIn("kept beside it: 1M56 at 2025-03-05", self.logs())
        self.assertIn("TSWSaveGame_abc.sav: 1M56 at 2025-03-04 ", self.logs())
        self.assertNotIn("(saves:", self.logs())

    def test_debug_line(self):
        self.start()
        self.drive_off()
        self.run_at(6)
        self.assertIn("20.0 m/s, +0.00 m/s², 62 aboard, comfort 100, showing the objective", self.logs())
        self.assertNotIn("something went wrong", self.logs())


if __name__ == "__main__":
    unittest.main()
