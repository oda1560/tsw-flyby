"""
Tests for the fly-by camera mod: runs FlyByCamera/Scripts/main.lua in real Lua 5.4 against a stand-in
for UE4SS and the game (tests/fake_ue4ss.lua), with a train driving along a line that curves.

    python -m unittest discover tests

Needs lupa (Lua for Python). If it isn't installed normally, set FLYBY_PYLIB to the folder it was
installed into with pip --target.
"""

import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "FlyByCamera", "Scripts").replace("\\", "/")
TESTS = os.path.join(ROOT, "tests").replace("\\", "/")

try:
    from lupa import lua54
except ImportError:
    sys.path.insert(0, os.environ.get("FLYBY_PYLIB", r"F:\TSW mod downloads\pylib"))
    try:
        from lupa import lua54
    except ImportError:
        lua54 = None

M = 100  # centimetres in a metre


@unittest.skipIf(lua54 is None, "needs lupa: pip install lupa")
class FlyBy(unittest.TestCase):
    def start(self, settings=None, **sim):
        """The game with a train, then the mod loaded into it."""
        self.lua = lua54.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(f'package.path = "{SCRIPTS}/?.lua;{TESTS}/?.lua;" .. package.path')
        self.sim = self.lua.eval('(require("fake_ue4ss"))')
        self.lua.globals().Sim = self.sim
        self.sim.setup(self.lua.table_from(sim))
        s = self.lua.eval('(require("flyby_settings"))')
        for key, value in (settings or {}).items():
            s[key] = value
        self.lua.execute(f'dofile("{SCRIPTS}/main.lua")')
        self.assertIn("[FlyBy] loaded", self.logs())

    def switch_on(self):
        """Press 7 and let it time the train and cut to its camera."""
        self.sim.press("SEVEN")
        self.sim.run(0.5)

    def logs(self):
        return self.sim.all_logs()

    def camera(self):
        cam = self.sim.camera_line_pos()
        return cam and (cam.X, cam.Y, cam.Z)

    def train(self):
        t = self.sim.train_line_pos()
        return (t.X, t.Y, t.Z)

    def on_camera(self):
        return self.sim.viewing(self.sim.camera())

    def run_watching_spots(self, seconds):
        """Runs the game, noting each new camera spot with where the train was then."""
        spots = []

        def each():
            cam = self.camera()
            if cam and (not spots or spots[-1][0] != cam):
                spots.append((cam, self.train(), self.sim.s))
        self.sim.run(seconds, each)
        return spots

    def no_errors(self):
        self.assertNotIn("went wrong", self.logs())
        self.assertNotIn("couldn't", self.logs())

    # ---- switching on and off

    def test_7_times_the_train_then_cuts_to_a_camera_beside_the_line_ahead(self):
        self.start(speed=40 * M)
        self.sim.press("SEVEN")
        self.assertTrue(self.sim.viewing(self.sim.pawn))        # still the game's view while timing
        self.sim.run(0.5)
        self.assertTrue(self.on_camera())
        x, y, z = self.camera()
        self.assertAlmostEqual(x - self.train()[0], 8 * 40 * M, delta=10 * M)  # 8 seconds ahead at 40 m/s
        self.assertAlmostEqual(abs(y), 12 * M, delta=1 * M)     # 12 m to the side
        self.assertAlmostEqual(z, 1.7 * M, delta=1)             # standing on the ground
        self.assertFalse(self.sim.camera().CameraComponent.bConstrainAspectRatio)
        self.assertIn("timed the train at 40.0 m/s", self.logs())
        self.no_errors()

    def test_it_follows_the_vehicle_you_see_not_the_model_at_the_origin(self):
        self.start(speed=40 * M, start=1000 * M)
        self.switch_on()
        self.assertIn("following RVV_AABS_Class70_C_2", self.logs())
        self.assertGreater(self.camera()[0], 1000 * M)          # by the train, not by the world's origin
        self.assertLess(self.sim.aim_error(), 0.5)

    def test_without_the_view_class_it_follows_whatever_the_driver_is_on_that_moves(self):
        self.start(speed=40 * M, start=1000 * M, view_class=False)
        self.switch_on()
        self.assertIn("following RVV_AABS_Class70_C_2", self.logs())

    def test_if_the_whole_train_reports_the_origin_it_follows_the_driver(self):
        self.start(speed=40 * M, start=1000 * M, view_at_origin=True)
        self.switch_on()
        self.assertIn("following TS2DefaultDriverPawn_C_0", self.logs())
        self.assertGreater(self.camera()[0], 1000 * M)
        self.assertLess(self.sim.aim_error(), 0.5)

    def test_not_in_a_cab_it_follows_the_train_nearest_the_camera(self):
        self.start(speed=40 * M, start=1000 * M, attached=False)
        self.switch_on()
        self.assertIn("following RVV_AABS_Class70_C_2", self.logs())
        self.assertIn("nearest the camera", self.logs())

    def test_the_games_velocity_isnt_needed(self):
        self.start(speed=40 * M, velocity=False)
        self.switch_on()
        self.assertAlmostEqual(self.camera()[0] - self.train()[0], 8 * 40 * M, delta=10 * M)

    def test_it_keeps_looking_at_the_train(self):
        self.start(speed=40 * M)
        self.switch_on()
        worst = []
        self.sim.run(30, lambda: worst.append(self.sim.aim_error()))
        self.assertLess(max(worst), 0.5)

    def test_7_again_moves_to_a_new_spot_ahead(self):
        self.start(speed=20 * M)
        self.switch_on()
        self.sim.run(2)
        before = self.camera()
        self.sim.press("SEVEN")
        self.sim.run(0.1)
        after = self.camera()
        self.assertTrue(self.on_camera())
        self.assertIn("new spot 160 m ahead on the left (you asked for a new spot)", self.logs())
        self.assertGreater(after[0], before[0])                 # further on
        self.assertLess(after[1] * before[1], 0)                # and across the line

    def test_7_while_timing_changes_nothing(self):
        self.start(speed=20 * M)
        self.sim.press("SEVEN")
        self.sim.run(0.2)
        self.sim.press("SEVEN")
        self.sim.run(0.3)
        self.assertTrue(self.on_camera())
        self.assertEqual(self.logs().count("] new spot"), 1)

    def test_6_goes_back_to_the_games_view(self):
        self.start(speed=20 * M)
        pawn = self.sim.pawn
        self.switch_on()
        self.sim.run(2)
        cam = self.sim.camera()
        self.sim.press("SIX")
        self.assertTrue(self.sim.viewing(pawn))
        self.assertFalse(cam.valid)
        self.assertEqual(len(self.sim.frame_fns), 0)
        self.assertIn("off: you switched it off", self.logs())

    def test_6_while_timing_cancels_without_touching_the_view(self):
        self.start(speed=20 * M)
        self.sim.press("SEVEN")
        self.sim.run(0.2)
        self.sim.press("SIX")
        self.assertTrue(self.sim.viewing(self.sim.pawn))
        self.assertIsNone(self.sim.camera())

    def test_the_train_going_away_switches_it_off(self):
        self.start(speed=20 * M)
        self.switch_on()
        self.sim.train.valid = False
        self.sim.run(0.1)
        self.assertIsNone(self.sim.camera())
        self.assertIn("the train or the camera has gone", self.logs())

    # ---- the game taking the view

    def test_the_game_taking_the_view_by_itself_is_taken_back(self):
        self.start(speed=20 * M)
        self.switch_on()
        self.sim.game_switches_to(self.sim.pawn)
        self.sim.run(0.1)
        self.assertTrue(self.on_camera())
        self.assertIn("the game took the view (to TS2DefaultDriverPawn_C_0), taking it back", self.logs())

    def test_if_the_game_keeps_taking_it_it_gives_up(self):
        self.start(speed=20 * M)
        self.switch_on()
        for _ in range(4):
            self.sim.game_switches_to(self.sim.pawn)
            self.sim.run(0.5)
        self.assertTrue(self.sim.viewing(self.sim.pawn))
        self.assertIsNone(self.sim.camera())
        self.assertIn("the game keeps taking the view back (4 times", self.logs())

    def test_a_camera_key_then_the_games_switch_hands_over(self):
        self.start(speed=20 * M)
        self.switch_on()
        self.assertTrue(self.sim.press("TWO"))
        self.sim.game_switches_to(self.sim.outside)
        self.sim.run(0.1)
        self.assertTrue(self.sim.viewing(self.sim.outside))
        self.assertIsNone(self.sim.camera())
        self.assertIn("you switched to the game's camera (TS2DefaultDriverCameraPawn_C_5)", self.logs())

    def test_the_games_switch_then_a_late_camera_key_hands_over_to_the_games_choice(self):
        self.start(speed=20 * M)
        self.switch_on()
        self.sim.game_switches_to(self.sim.outside)
        self.sim.run(0.05)                                      # taken back before the key shows up
        self.assertTrue(self.on_camera())
        self.sim.press("TWO")
        self.assertTrue(self.sim.viewing(self.sim.outside))
        self.assertIsNone(self.sim.camera())

    def test_a_camera_key_the_game_ignores_goes_back_to_the_view_from_before(self):
        self.start(speed=20 * M)
        self.switch_on()
        self.sim.press("ONE")                                   # already "in the cab" as far as the game knows
        self.sim.run(0.5)
        self.assertTrue(self.sim.viewing(self.sim.pawn))
        self.assertIn("off: you pressed a camera key", self.logs())

    def test_the_games_camera_switched_event_counts_as_yours(self):
        self.start(speed=20 * M)
        self.switch_on()
        self.sim.game_switches_to(self.sim.outside, True)
        self.sim.run(0.1)
        self.assertTrue(self.sim.viewing(self.sim.outside))
        self.assertIsNone(self.sim.camera())

    def test_photo_mode_key_leaves(self):
        self.start(speed=20 * M)
        self.switch_on()
        self.assertTrue(self.sim.press("SHIFT+SPACE"))
        self.sim.run(0.5)
        self.assertIsNone(self.sim.camera())

    def test_other_keys_dont_leave(self):
        self.start(speed=20 * M)
        self.switch_on()
        self.assertFalse(self.sim.press("E"))
        self.sim.run(1)
        self.assertTrue(self.on_camera())

    # ---- moving on

    def test_it_moves_on_ahead_once_the_train_has_gone_by(self):
        self.start(speed=40 * M)
        self.switch_on()
        spots = self.run_watching_spots(45)
        self.assertGreaterEqual(len(spots), 4)
        for cam, train, _ in spots:
            self.assertGreater(cam[0], train[0] + 50 * M)       # always ahead of the train
        self.assertIn("the train has gone by", self.logs())
        self.no_errors()

    def test_sides_alternate(self):
        self.start(speed=40 * M)
        self.switch_on()
        spots = self.run_watching_spots(30)
        sides = [cam[1] > 0 for cam, _, _ in spots]
        self.assertTrue(all(a != b for a, b in zip(sides, sides[1:])), sides)

    def test_round_a_curve_it_stays_beside_the_line(self):
        # 800 m radius curve from 2 km. Carrying straight on would put spots 50 m or more off the line.
        self.start(speed=40 * M, start=1500 * M, straight=2000 * M, radius=800 * M)
        self.switch_on()
        spots = self.run_watching_spots(50)
        on_curve = [cam for cam, _, s in spots if s > 2100 * M]
        self.assertGreaterEqual(len(on_curve), 2)
        for cam in on_curve:
            off = self.sim.distance_to_line(self.lua.table_from({"X": cam[0], "Y": cam[1], "Z": 0})) / M
            self.assertTrue(9 < off < 15, f"{off:.1f} m from the line")

    def closest_pass(self, seconds):
        """Runs the game and returns how close (flat, in metres) the train came to the camera."""
        closest = []

        def each():
            cam, train = self.camera(), self.train()
            if cam:
                closest.append(((cam[0] - train[0]) ** 2 + (cam[1] - train[1]) ** 2) ** 0.5 / M)
        self.sim.run(seconds, each)
        return min(closest)

    def test_the_first_spot_allows_for_a_gentle_curve_on_its_inside(self):
        # As in the game on 2026-10-18: 60 mph on a right-hand curve of about 3 km, camera on the right.
        # Straight on, the first spot came within 6 m of the train.
        self.start(speed=26.5 * M, start=2300 * M, straight=2000 * M, radius=3000 * M)
        self.switch_on()
        cam = self.camera()
        self.assertGreater(cam[1], self.train()[1])             # on the inside of the curve
        off = self.sim.distance_to_line(self.lua.table_from({"X": cam[0], "Y": cam[1], "Z": 0})) / M
        self.assertTrue(11 < off < 13, f"{off:.1f} m from the line")
        self.assertGreater(self.closest_pass(12), 11)
        self.assertIn("line curving right, 3000 m radius", self.logs())

    def test_the_first_spot_round_a_tight_curve(self):
        self.start(speed=40 * M, start=2300 * M, straight=2000 * M, radius=800 * M)
        self.switch_on()
        cam = self.camera()
        off = self.sim.distance_to_line(self.lua.table_from({"X": cam[0], "Y": cam[1], "Z": 0})) / M
        self.assertTrue(10 < off < 14, f"{off:.1f} m from the line")

    def test_a_stopped_train_keeps_its_camera(self):
        self.start(speed=0)
        self.switch_on()
        spots = self.run_watching_spots(60)
        self.assertEqual(len(spots), 1)
        self.assertEqual(self.logs().count("] new spot"), 1)

    def test_after_reversing_the_camera_goes_ahead_the_other_way(self):
        self.start(speed=20 * M, start=500 * M)
        self.switch_on()
        self.sim.run(3)
        self.sim.speed = -20 * M
        self.sim.run(1.5)
        self.assertIn("the train is going the other way", self.logs())
        self.assertLess(self.camera()[0], self.train()[0] - 100 * M)

    def test_a_vehicle_facing_backwards_still_gets_a_camera_ahead(self):
        self.start(speed=20 * M, start=500 * M, flipped=True)
        self.switch_on()
        self.assertGreater(self.camera()[0], self.train()[0])

    def test_the_game_moving_its_world_origin(self):
        self.start(speed=40 * M)
        self.switch_on()
        self.sim.run(2)
        self.lua.execute("Sim.shift_origin({ X = 2000000, Y = -500000, Z = 1000 })")
        spots = self.run_watching_spots(20)
        self.assertIn("the train jumped", self.logs())
        self.assertNotIn("too far away", self.logs())
        self.assertGreaterEqual(len(spots), 2)
        self.assertLess(self.sim.aim_error(), 0.5)
        self.no_errors()

    # ---- the ground and things in the way

    def test_on_a_slope_it_stands_on_the_ground(self):
        self.start(speed=40 * M)
        self.lua.execute("Sim.ground = function(x, y) return math.max(0, (math.abs(y) - 400) * 0.5) end")
        self.switch_on()
        x, y, z = self.camera()
        ground = max(0, (abs(y) - 400) * 0.5)
        self.assertGreater(ground, 300)
        self.assertAlmostEqual(z, ground + 1.7 * M, delta=2)
        self.assertIn("ground +3.5 m from the train", self.logs())

    def test_a_wall_in_the_way_picks_the_other_side(self):
        self.start(speed=40 * M)
        self.lua.execute("Sim.walls = { { min = { X = 0, Y = 300, Z = -1000 }, max = { X = 200000, Y = 500, Z = 1000 } } }")
        self.switch_on()
        self.assertLess(self.camera()[1], 0)                    # left, away from the wall on the right
        self.assertIn("line in view, train in view (spot 2 tried)", self.logs())

    def test_with_view_checks_off_it_does_no_traces(self):
        self.start(settings={"CheckView": False}, speed=40 * M)
        self.switch_on()
        self.sim.run(20)
        self.assertEqual(self.sim.traces, 0)
        self.assertAlmostEqual(self.camera()[2], 50 + 2.5 * M, delta=1)

    # ---- zoom, the debug lines and the report

    def test_zoom_narrows_while_the_train_is_far(self):
        self.start(speed=40 * M)
        self.switch_on()
        far = self.sim.camera().fov
        self.sim.run(7.9)                                       # about level with the camera
        near = self.sim.camera().fov
        self.assertLess(far, 25)
        self.assertGreater(near, 55)

    def test_debug_lines_every_couple_of_seconds(self):
        self.start(speed=20 * M)
        self.switch_on()
        self.sim.run(6.1)
        self.assertEqual(self.logs().count("moved 40 m in 2.0 s"), 3)

    def test_report_runs_on_and_off(self):
        self.start(speed=20 * M)
        self.sim.press("F10")
        self.switch_on()
        self.sim.run(2)
        self.sim.press("F10")
        self.assertEqual(self.logs().count("end of report"), 2)
        self.assertIn("would follow: RVV_AABS_Class70_C_2", self.logs())
        self.assertIn("RVV_AABS_Class70_C_2 at", self.logs())
        self.assertIn("CL70_FL_RVM_C_1 at 0 0 0", self.logs())
        self.assertIn("tracking: 20.0 m/s", self.logs())
        self.no_errors()


if __name__ == "__main__":
    unittest.main()
