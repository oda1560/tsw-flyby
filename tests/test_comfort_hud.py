"""
Tests for the comfort HUD mod: runs ComfortHUD/Scripts/main.lua in real Lua 5.4 against a stand-in for UE4SS and
the game (tests/fake_comfort_game.lua): a passenger train, an AI train, and the HUD's objective box.

    python -m unittest discover tests

Needs lupa (Lua for Python). If it isn't installed normally, set FLYBY_PYLIB to the folder it was installed into
with pip --target.
"""

import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "ComfortHUD", "Scripts").replace("\\", "/")
TESTS = os.path.join(ROOT, "tests").replace("\\", "/")

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
    def start(self, settings=None, load=True, **sim):
        """The game with a train, the mod loaded into it, then the drive loading (load=True)."""
        self.lua = lua54.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(f'package.path = "{SCRIPTS}/?.lua;{TESTS}/?.lua;" .. package.path')
        self.sim = self.lua.eval('(require("fake_comfort_game"))')
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
        self.assertIn("2 passenger cars on your train of 3 in the world (same formation)", self.logs())

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
        self.run_at(2)
        self.assertIn("service 2W09", self.logs())
        self.assertTrue(self.shown()[1].endswith("comfort 100"), self.shown())    # the ride going on, on 2W09

    # ---- trains without passengers, and what can't be read

    def test_freight_shows_nothing_and_isn_t_judged(self):
        self.start(passengers=False)
        self.drive_off()
        self.run_at(2, -1.4)
        self.assertEqual(self.shown(), ("DRIVE TO SHIPLEY", "Arrive by 19:12:00"))
        self.assertIn("0 passenger cars on your train of 1 in the world", self.logs())

    def test_without_the_formation_only_the_car_you_drive(self):
        self.start(no_formation=True)
        self.run_at(2)
        self.assertIn("40 aboard", self.shown()[1])
        self.assertIn("only the vehicle you drive", self.logs())

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
        self.assertEqual(self.sim.searched("PassengerCargoModelComponent"), 1)
        self.assertEqual(self.sim.searched("HUDObjectiveWidget_Minimal_C"), 0)

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

    def test_debug_line(self):
        self.start()
        self.drive_off()
        self.run_at(6)
        self.assertIn("20.0 m/s, +0.00 m/s², 62 aboard, comfort 100, showing the objective", self.logs())
        self.assertNotIn("something went wrong", self.logs())


if __name__ == "__main__":
    unittest.main()
