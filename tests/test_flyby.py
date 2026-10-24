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
        self.assertIn("line in view, train in view (1 of 12 spots tried, 15 traces", self.logs())
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
        self.assertIn("new spot 160 m ahead, 12 m to the left (you asked for a new spot)", self.logs())
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
        self.assertIn("line in view, train in view (2 of 12 spots tried", self.logs())

    def test_a_view_low_over_a_bank_is_in_the_grass(self):
        # A bank 1.2 m high, 7 to 10 m out on the right. From 12 m out the view across to the line clears it by
        # 0.8 m: line traces go through the grass on it, but you wouldn't see much of the train.
        self.start(speed=40 * M)
        self.lua.execute("Sim.ground = function(x, y) return (y >= 700 and y <= 1000) and 120 or 0 end")
        self.switch_on()
        self.assertLess(self.camera()[1], 0)                    # left, away from the bank
        self.assertIn("tried a spot 320 m ahead, 12 m to the right: ground -0.5 m from the train, "
                      "line in the grass (0.8 m over the ground 4 m out), train in view", self.logs())
        self.assertIn("line in view, train in view (2 of 12 spots tried", self.logs())

    def test_in_a_narrow_place_it_stands_closer_in(self):
        # Banks on both sides, 8 to 10 m out: from 12 m out the view crosses them in the grass. By the track it's clear.
        self.start(speed=40 * M)
        self.lua.execute("Sim.ground = function(x, y) return (math.abs(y) >= 800 and math.abs(y) <= 1000) "
                         "and 120 or 0 end")
        self.switch_on()
        x, y, z = self.camera()
        self.assertAlmostEqual(abs(y), 6 * M, delta=1)          # 6 m to the side
        self.assertAlmostEqual(x - self.train()[0], 8 * 40 * M, delta=10 * M)  # still 8 seconds ahead
        self.assertAlmostEqual(z, 1.7 * M, delta=1)
        self.assertIn("new spot 320 m ahead, 6 m to the right", self.logs())
        self.assertIn("line in view, train in view (5 of 12 spots tried", self.logs())
        self.no_errors()

    def test_where_no_view_is_clear_it_takes_the_best_after_trying_every_spot(self):
        # GrassHeight above EyeHeight puts nearly every view in the grass, and a wall hides the right. Closer in on the
        # left, the view across to the line rises clear of it: the best there is.
        self.start(settings={"GrassHeight": 1.9}, speed=40 * M)
        self.lua.execute("Sim.walls = { { min = { X = 0, Y = 300, Z = -1000 }, max = { X = 200000, Y = 500, Z = 1000 } } }")
        self.switch_on()
        self.assertIn("tried a spot 320 m ahead, 12 m to the left: ground -0.5 m from the train, line in the grass "
                      "(1.8 m over the ground 2 m out), train in the grass (1.7 m over the ground 2 m out)", self.logs())
        self.assertIn("new spot 320 m ahead, 6 m to the left (switched on)", self.logs())
        self.assertIn("line in view, train in the grass (1.7 m over the ground 2 m out) (12 of 12 spots tried",
                      self.logs())

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

    # ---- the seat view

    def sitting(self):
        """(seat group's address, seat number from 1) the camera is at the eyes of, give or take the head moving;
        None if it's at none."""
        cam = self.sim.camera()
        if cam is None:
            return None
        at, _ = self.sim.camera_place(cam)
        for g in self.sim.groups.values():
            for i, eye in self.sim.seat_eyes(g, 1.15 * M).items():
                d = ((at.X - eye.pos.X) ** 2 + (at.Y - eye.pos.Y) ** 2 + (at.Z - eye.pos.Z) ** 2) ** 0.5
                if d < 6:
                    return g.address, i
        return None

    def seat(self):
        """The fake's seat the camera is in: pos, face."""
        address, i = self.sitting()
        return self.sat_group().seats[i]

    def view(self):
        """The camera's rotation in the world: (pitch, yaw, roll)."""
        r = self.sim.camera_rot(self.sim.camera())
        return r.Pitch, r.Yaw, r.Roll

    @staticmethod
    def wrap(a):
        return (a + 180) % 360 - 180

    def expected_yaw(self, seat, car=0.0, window=50):
        """Where the passenger should look: the way their seat faces, turned towards the window nearest them, whichever
        way the train goes. `car`: the yaw of the car the seat is in."""
        import math
        side = (1 if seat.pos.Y > 0 else -1) * (1 if math.cos(math.radians(seat.face)) > 0 else -1)
        return self.wrap(car + seat.face + side * window)

    def still(self):
        return {"SeatLookAround": False, "SeatShake": 0}

    def eye_offset(self):
        """How far the head has moved from the seat's eyes: (along the car, across, up) in cm."""
        cam = self.sim.camera()
        eye = self.sim.seat_eyes(self.sat_group(), 1.15 * M)[self.sitting()[1]]
        at, _ = self.sim.camera_place(cam)
        return at.X - eye.pos.X, at.Y - eye.pos.Y, at.Z - eye.pos.Z

    def sat_group(self):
        """The seat group the camera sits in."""
        seat = self.sitting()
        self.assertIsNotNone(seat)
        return next(g for g in self.sim.groups.values() if g.address == seat[0])

    def coach_views(self):
        return {c.view.address for c in self.sim.coaches.values()}

    def test_4_puts_the_view_in_a_passenger_seat_on_your_train(self):
        self.start(speed=20 * M)
        self.assertTrue(self.sim.press("FOUR"))
        self.assertTrue(self.on_camera())                       # at once: no timing needed
        self.assertIn(self.sat_group().owner.address, self.coach_views())
        self.assertEqual(self.sim.camera().fov, 70)
        self.assertFalse(self.sim.camera().CameraComponent.bConstrainAspectRatio)
        self.assertIn("on: the view from a seat; 16 passenger seats on your train (5 seat groups on your train's "
                      "vehicles: 4 passenger, 0 unmarked and 1 crew on your train (by name/role: "
                      "UKStandardClass/Passenger 4, Driver/None 1), 0 on other trains, 0 away from your train; "
                      "your train from GetFormation of its RailVehiclePhysicsComponent", self.logs())
        self.assertRegex(self.logs(), r"in seat \d of Seats\d, a UKStandardClass/Passenger group in "
                                      r"RVV_Coach_C_1[35] \(vehicle [23] of 3, ")
        self.no_errors()

    def test_the_seat_rides_along_with_the_train(self):
        self.start(speed=30 * M)
        self.sim.press("FOUR")
        seat = self.sitting()
        before = self.sim.camera_place(self.sim.camera())[0].X
        self.sim.run(5)
        self.assertEqual(self.sitting(), seat)
        self.assertAlmostEqual(self.sim.camera_place(self.sim.camera())[0].X - before, 150 * M, delta=1 * M)
        self.assertTrue(self.on_camera())
        self.assertNotIn("each frame", self.logs())
        self.assertIn("seat camera at", self.logs())
        self.no_errors()

    def test_4_again_moves_to_another_seat(self):
        self.start(speed=20 * M)
        self.sim.press("FOUR")
        seats = [self.sitting()]
        for _ in range(10):
            self.sim.press("FOUR")
            self.sim.run(0.1)
            seats.append(self.sitting())
            self.assertNotEqual(seats[-1], seats[-2])
            self.assertTrue(self.on_camera())
        self.assertEqual(self.logs().count("another seat: 16 passenger seats"), 10)
        self.assertEqual(len(self.sim.cameras), 1)              # the same camera, moved

    def test_never_the_drivers_seat_or_another_train(self):
        self.start(speed=20 * M)                                # the AI train is 900 m away
        owners, kinds = set(), set()
        for _ in range(40):
            self.sim.press("FOUR")
            owners.add(self.sat_group().owner.address)
            kinds.add(self.sitting()[1] <= 2)
        self.assertEqual(owners, self.coach_views())
        self.assertEqual(kinds, {True, False})
        self.assertIn("eyes the seat's camera offset 0 0 70", self.logs())
        self.assertIn("eyes 1.15 m above the seat", self.logs())

    def test_if_the_vehicles_wont_list_their_seats_it_searches_the_world_for_them(self):
        self.start(speed=20 * M, search_only=True)              # the AI train is 900 m away
        owners = set()
        for _ in range(20):
            self.sim.press("FOUR")
            owners.add(self.sat_group().owner.address)
        self.assertEqual(owners, self.coach_views())
        self.assertIn("16 passenger seats on your train (6 seat groups in the world: 4 passenger, 0 unmarked and "
                      "1 crew on your train (by name/role: UKStandardClass/Passenger 4, Driver/None 1), "
                      "1 on other trains, 0 away from your train", self.logs())

    def test_6_goes_back_from_the_seat(self):
        self.start(speed=20 * M)
        self.sim.press("FOUR")
        self.sim.run(1)
        cam = self.sim.camera()
        self.sim.press("SIX")
        self.assertTrue(self.sim.viewing(self.sim.pawn))
        self.assertFalse(cam.valid)
        self.assertEqual(len(self.sim.frame_fns), 0)
        self.assertIn("off: you switched it off", self.logs())

    def test_a_camera_key_leaves_the_seat(self):
        self.start(speed=20 * M)
        self.sim.press("FOUR")
        self.sim.press("FIVE")                                  # the game's own passenger view
        self.sim.game_switches_to(self.sim.outside)
        self.sim.run(0.1)
        self.assertTrue(self.sim.viewing(self.sim.outside))
        self.assertIsNone(self.sim.camera())

    def test_a_camera_key_the_game_ignores_leaves_the_seat_for_the_view_from_before(self):
        self.start(speed=20 * M)
        self.sim.press("FOUR")
        self.sim.press("ONE")
        self.sim.run(0.5)
        self.assertTrue(self.sim.viewing(self.sim.pawn))
        self.assertIsNone(self.sim.camera())

    def test_the_game_taking_the_view_from_the_seat_is_taken_back(self):
        self.start(speed=20 * M)
        self.sim.press("FOUR")
        self.sim.game_switches_to(self.sim.pawn)
        self.sim.run(0.1)
        self.assertTrue(self.on_camera())
        self.assertIsNotNone(self.sitting())

    def test_7_from_the_seat_goes_to_the_fly_by_and_4_back(self):
        self.start(speed=20 * M)
        self.sim.press("FOUR")
        self.sim.run(1)
        self.sim.press("SEVEN")
        self.sim.run(0.2)
        self.assertTrue(self.on_camera())                       # still in the seat while it times the train
        self.assertIsNotNone(self.sitting())
        self.sim.run(0.3)
        cam = self.sim.camera()
        self.assertIsNone(cam.attach)
        x, y, _ = self.camera()
        self.assertAlmostEqual(x - self.train()[0], 8 * 20 * M, delta=10 * M)
        self.assertAlmostEqual(abs(y), 12 * M, delta=1 * M)
        self.assertLess(self.sim.aim_error(), 0.5)
        self.assertIn("fly-by: following RVV_AABS_Class70_C_2", self.logs())
        self.sim.press("FOUR")
        self.assertIsNotNone(self.sitting())
        self.assertEqual(self.sim.camera().fov, 70)
        self.assertIn("seat view: the view from a seat", self.logs())
        self.sim.run(1)
        self.assertIsNotNone(self.sitting())                    # the fly-by doesn't move it any more
        self.sim.press("SIX")
        self.assertTrue(self.sim.viewing(self.sim.pawn))        # the view from before either
        self.assertEqual(len(self.sim.cameras), 1)
        self.no_errors()

    def test_6_while_timing_from_the_seat_goes_back_to_the_view_from_before(self):
        self.start(speed=20 * M)
        self.sim.press("FOUR")
        self.sim.press("SEVEN")
        self.sim.run(0.1)
        self.sim.press("SIX")
        self.assertTrue(self.sim.viewing(self.sim.pawn))
        self.assertIsNone(self.sim.camera())

    def test_4_while_the_fly_by_is_timing_goes_to_a_seat(self):
        self.start(speed=20 * M)
        self.sim.press("SEVEN")
        self.sim.run(0.1)
        self.sim.press("FOUR")
        self.assertTrue(self.on_camera())
        self.sim.run(1)
        self.assertIsNotNone(self.sitting())
        self.assertNotIn("] new spot", self.logs())

    def test_seats_that_dont_say_what_they_are_still_do(self):
        self.start(speed=20 * M, unmarked=True)
        self.sim.press("FOUR")
        self.assertIn(self.sat_group().owner.address, self.coach_views())
        self.assertIn("16 unmarked seats on your train", self.logs())

    def test_seats_left_with_the_default_name_go_by_their_role(self):
        self.start(speed=20 * M, default_names=True)           # as the Class 331's seemed to be
        owners = set()
        for _ in range(20):
            self.assertTrue(self.sim.press("FOUR"))
            owners.add(self.sat_group().owner.address)
        self.assertEqual(owners, self.coach_views())            # never the cab, whose role is Engineer
        self.assertIn("16 passenger seats on your train", self.logs())
        self.assertIn("(by name/role: Engineer/Passenger 4, Engineer/Engineer 1)", self.logs())

    def test_a_cars_multi_seat_is_passenger_seating(self):
        self.start(speed=20 * M, multiseat=True)               # as the Class 331's, neither name nor role set
        self.sim.press("FOUR")
        self.assertIn(self.sat_group().owner.address, self.coach_views())
        self.assertIn("16 passenger seats on your train", self.logs())
        self.assertIn("(by name/role: Engineer/None multi-seat 4, Driver/None 1)", self.logs())
        self.assertRegex(self.logs(), r"in seat \d of Seats\d, a Engineer/None multi-seat group in RVV_Coach_C_1")

    def test_seats_with_neither_name_nor_role_set_are_unmarked_not_crew(self):
        self.start(speed=20 * M, unset=True)
        self.sim.press("FOUR")
        self.assertIn(self.sat_group().owner.address, self.coach_views())
        self.assertIn("16 unmarked seats on your train", self.logs())
        self.assertIn("(by name/role: Engineer/None 4, Driver/None 1)", self.logs())

    def test_without_the_games_list_of_the_train_it_asks_which_vehicles_are_the_players(self):
        self.start(speed=20 * M, formation=False, consist_lib=True)
        self.sim.press("FOUR")
        self.assertIn(self.sat_group().owner.address, self.coach_views())
        self.assertIn("16 passenger seats on your train", self.logs())
        self.assertIn("the game saying which vehicles are the player's", self.logs())
        self.assertNotIn("(vehicle", self.logs())

    def test_without_either_there_are_only_the_seats_of_your_own_vehicle(self):
        self.start(speed=20 * M, formation=False)
        self.assertTrue(self.sim.press("FOUR"))
        self.assertTrue(self.sim.viewing(self.sim.pawn))
        self.assertIsNone(self.sim.camera())
        self.assertIn("no passenger seats on your train: 6 seat groups in the world: 0 passenger, 0 unmarked and "
                      "1 crew on your train (by name/role: Driver/None 1), 5 on other trains", self.logs())
        self.assertIn("only the vehicle you drive", self.logs())
        self.sim.press("F10")                                   # the report still lists the seats there are
        self.assertIn("seats: none on your train", self.logs())
        self.assertIn("Seats1 in RVV_AABS_Class70_C_2 at ", self.logs())
        self.assertIn(": crew, Driver/None (name 1, role 0, verb ? nil, custom name nil), 1 seats", self.logs())

    def test_it_prefers_a_seat_nobody_sits_in(self):
        self.start(speed=20 * M, taken=True)
        free = self.sim.groups[4]
        free.seats[3].taken = False
        self.sim.press("FOUR")
        self.assertEqual(self.sitting(), (free.address, 3))
        self.sim.press("FOUR")                                  # all the others are taken: one of them anyway
        self.assertIsNotNone(self.sitting())
        self.assertNotEqual(self.sitting(), (free.address, 3))

    def test_if_the_game_wont_attach_the_camera_it_moves_it_each_frame(self):
        self.start(speed=30 * M, no_attach=True)
        self.sim.press("FOUR")
        seat = self.sitting()
        self.assertIsNotNone(seat)
        worst = []
        self.sim.run(3, lambda: worst.append(self.sitting() == seat))
        self.assertTrue(all(worst))
        self.assertIn("the game wouldn't attach the camera", self.logs())
        self.no_errors()

    def test_without_the_seat_functions_it_reads_the_seats_list(self):
        self.start(speed=20 * M, no_region_functions=True)
        self.sim.press("FOUR")
        self.assertIsNotNone(self.sitting())
        self.assertIn("from LocalPosition)", self.logs())

    def test_a_seat_going_away_moves_to_another_then_off(self):
        self.start(speed=20 * M)
        self.sim.press("FOUR")
        group = self.sat_group()
        group.valid = False
        self.sim.run(0.1)
        self.assertIsNotNone(self.sitting())
        self.assertNotEqual(self.sitting()[0], group.address)
        self.assertIn("the seat has gone (its vehicle unloaded?): 12 passenger seats", self.logs())
        for g in self.sim.groups.values():
            g.valid = False
        self.sim.run(0.1)
        self.assertTrue(self.sim.viewing(self.sim.pawn))
        self.assertIsNone(self.sim.camera())
        self.assertIn("off: the seat has gone, and there's no other", self.logs())

    def test_seats_at_the_worlds_origin_arent_used(self):
        self.start(speed=20 * M, start=1500 * M, seats_on_models=True)
        self.sim.press("FOUR")
        self.assertIsNone(self.sim.camera())
        self.assertIn("6 away from your train", self.logs())

    def let_go(self):
        """The game letting go of every coach's seat groups, as it does with a car's seats when the car is far off: they
        drop to the world's origin and stay there."""
        for g in self.sim.groups.values():
            if g.owner.address in self.coach_views():
                g.loose = True

    def test_seats_the_game_has_let_go_of_are_sat_in_on_their_car(self):
        self.start(speed=30 * M, start=300 * M)                # as the Rotem cab car's were in the game
        self.let_go()
        self.sim.press("FOUR")
        seat = self.sitting()
        self.assertIsNotNone(seat)                              # at the seat on its car, not under the line
        self.assertIn(self.sat_group().owner.address, self.coach_views())
        before = self.sim.camera_place(self.sim.camera())[0].X
        self.sim.run(5)
        self.assertEqual(self.sitting(), seat)                  # and riding along
        self.assertAlmostEqual(self.sim.camera_place(self.sim.camera())[0].X - before, 150 * M, delta=1 * M)
        self.assertIn("4 passenger, 0 unmarked and 1 crew on your train, 4 let go of by the game", self.logs())
        self.assertRegex(self.logs(), r"the game had let go of the group \(it's at (-600|300) 0 0\), so it goes by "
                                      r"its place on the car, (-600|300) 0 0")
        self.sim.press("F10")
        self.assertIn("(let go of by the game): passenger", self.logs())
        self.no_errors()

    def test_seats_the_game_has_let_go_of_far_from_the_worlds_origin_are_still_found(self):
        self.start(speed=20 * M, start=1500 * M)
        self.let_go()
        self.sim.press("FOUR")
        self.assertIsNotNone(self.sitting())
        self.assertIn("16 passenger seats on your train", self.logs())

    def test_the_game_letting_go_of_your_seat_while_you_sit_there(self):
        self.start(speed=30 * M, start=300 * M)
        self.sim.press("FOUR")
        seat = self.sitting()
        self.sat_group().loose = True
        self.sim.run(5)
        self.assertEqual(self.sitting(), seat)
        self.assertTrue(self.on_camera())
        self.no_errors()

    def test_report_lists_the_seats(self):
        self.start(speed=20 * M)
        self.sim.press("F10")
        self.assertIn("seats: 16 passenger seats on your train of 3 vehicles", self.logs())
        self.assertIn("Seats2 in RVV_Coach_C_13 (vehicle 2) at ", self.logs())
        self.assertIn(": passenger, UKStandardClass/Passenger (name 6, role 3, verb ? nil, custom name nil), 4 seats, "
                      "camera Z offset 60, passengers hidden within 50", self.logs())
        self.assertIn(": crew, Driver/None (name 1, role 0", self.logs())
        self.assertIn("seat 0: at 0 -60 45 (GetSeatRegionLocalPosition, LocalPosition 0 -60 45), turned 0 0 0, "
                      "camera offset 0 0 70, someone in it: false", self.logs())
        self.sim.press("FOUR")
        self.sim.press("F10")
        self.assertIn("camera in a seat", self.logs())
        self.assertIn("attached to its vehicle", self.logs())
        self.no_errors()

    # ---- the passenger's head

    def check_gaze(self, tolerance=1.0, run=1.0):
        """Presses 4 until it has sat in seats facing both ways on both sides, checking where each one looks."""
        seen = set()
        for i in range(100):
            if len(seen) == 4 and i >= 12:
                break
            self.sim.press("FOUR")
            self.sim.run(run)
            seat = self.seat()
            seen.add((seat.face, seat.pos.Y > 0))
            self.assertAlmostEqual(self.wrap(self.view()[1] - self.expected_yaw(seat)), 0, delta=tolerance)
        self.assertEqual(len(seen), 4)                          # both ways of facing, both sides
        self.no_errors()

    def test_the_passenger_looks_the_way_their_seat_faces_out_of_the_nearest_window(self):
        self.start(self.still(), speed=20 * M, start=100 * M)
        self.check_gaze()
        self.assertRegex(self.logs(), r"it faces backwards \(its back 8 cm behind\), the window on their (left|right), "
                                      r"-?60 cm from the middle of the car")
        self.assertRegex(self.logs(), r"it faces the way of travel \(its back 8 cm behind\), the window on their")

    def test_a_backward_seat_looks_back_the_way_it_faces_not_round_over_its_shoulder(self):
        import math
        self.start(self.still(), speed=20 * M, start=100 * M)
        for _ in range(30):
            self.sim.press("FOUR")
            if self.seat().face == 180:
                break
        yaw = self.view()[1]
        self.assertAlmostEqual(abs(yaw), 130, delta=1)          # back along the train, 50 degrees towards the window
        self.assertLess(math.cos(math.radians(yaw)), 0)
        self.assertEqual(math.sin(math.radians(yaw)) > 0, self.seat().pos.Y > 0)
        self.assertRegex(self.report(), r"looking [+-]130 degrees from the way of travel, the window on their "
                                        r"(left|right)")

    def test_glancing_about_a_head_never_turns_further_than_a_neck_goes(self):
        self.start({"SeatShake": 0}, speed=20 * M, start=100 * M)
        import math
        worst = []

        def each():                                             # from the way the seat faces now, round the curves
            fwd = self.sat_group().owner.fwd
            facing = math.degrees(math.atan2(fwd.Y, fwd.X)) + self.seat().face
            worst.append(abs(self.wrap(self.view()[1] - facing)))
        for _ in range(6):
            self.sim.press("FOUR")
            self.sim.run(40, each)
        self.assertLess(max(worst), 110 + 6)                    # the neck, and the gaze wandering about it
        self.assertGreater(max(worst), 80)                      # glances out of the window

    def report(self):
        self.sim.press("F10")
        return self.logs()

    def test_seats_turned_as_the_331s_are_still_face_the_right_way(self):
        self.start(self.still(), speed=20 * M, start=100 * M, socket_rotation=True)
        self.check_gaze()

    def test_on_a_bench_along_the_side_the_passenger_looks_inward_across_the_car(self):
        # Seats side by side along the car, as on a metro: whichever way the seats are turned, they face inward.
        for turned in (False, True):
            self.start(self.still(), benches=True, socket_rotation=turned, speed=20 * M, start=100 * M)
            sides = set()
            for _ in range(20):
                self.sim.press("FOUR")
                self.sim.run(1.0)
                seat = self.seat()
                sides.add(seat.pos.Y > 0)
                self.assertAlmostEqual(self.wrap(self.view()[1] - seat.face), 0, delta=1.0)
            self.assertEqual(sides, {True, False})              # both benches
            self.assertRegex(self.logs(), r"it faces inward, across the car \(the seat beside it is 50 cm along the "
                                          r"car\), the window behind them, -?130 cm from the middle of the car")
            self.assertRegex(self.report(), r"looking [+-]90 degrees from the way of travel, the window behind them")
            self.no_errors()

    def test_seats_side_by_side_in_rows_still_look_along_the_car_out_of_the_window(self):
        self.start(self.still(), pairs=True, speed=20 * M, start=100 * M)
        self.check_gaze()
        self.assertNotIn("inward", self.logs())

    def test_without_backs_to_find_it_guesses_the_way_from_the_seats_rotation(self):
        self.start(self.still(), speed=20 * M, start=100 * M, socket_rotation=True, no_backs=True)
        self.check_gaze()
        self.assertIn("(guessed from the seat's rotation)", self.logs())
        self.assertNotIn("its back", self.logs())

    def test_standing_it_looks_towards_the_front_where_the_driver_is(self):
        self.start(self.still(), speed=0, start=100 * M)
        self.check_gaze()

    def test_reversing_they_still_look_the_way_their_seats_face(self):
        self.start(self.still(), speed=-20 * M, start=1000 * M)
        self.check_gaze()
        self.assertRegex(self.logs(), r"it faces backwards \(its back 8 cm behind\), the window on their")

    def test_round_a_curve_the_gaze_turns_with_the_train(self):
        import math
        self.start(self.still(), speed=20 * M, start=2050 * M, radius=800 * M)
        self.sim.press("FOUR")
        worst = []
        coach = next(i for i, c in self.sim.coaches.items() if c.view.address == self.sat_group().owner.address)

        def each():
            _, d = self.sim.path(self.sim.s - coach * 2300)
            travel = math.degrees(math.atan2(d.Y, d.X))
            worst.append(abs(self.wrap(self.view()[1] - self.expected_yaw(self.seat(), car=travel))))
        self.sim.run(3)
        self.sim.run(10, each)
        self.assertLess(max(worst), 3)                          # it lags a little behind as the line turns
        self.assertGreater(len(worst), 500)

    def test_the_mouse_turns_the_view_and_then_it_goes_back(self):
        self.start(self.still(), speed=20 * M, start=100 * M)
        self.sim.press("FOUR")
        self.sim.run(0.5)
        pitch0, yaw0, _ = self.view()
        self.sim.mouse.dx, self.sim.mouse.dy = 1, 0.5             # the game's mouse movement, 12 frames of it
        self.sim.run(0.2)
        self.sim.mouse.dx, self.sim.mouse.dy = 0, 0
        pitch, yaw, _ = self.view()
        self.assertAlmostEqual(self.wrap(yaw - yaw0), 12 * 2.5, delta=0.5)
        self.assertAlmostEqual(pitch - pitch0, 6 * 2.5, delta=0.5)
        self.assertIn("the mouse turns the seat view (GetInputMouseDelta gave 1.00 0.50)", self.logs())
        self.sim.run(2.5)
        self.assertAlmostEqual(self.wrap(self.view()[1] - yaw0), 30, delta=0.5)  # still where you left it...
        self.sim.run(6)
        self.assertAlmostEqual(self.wrap(self.view()[1] - yaw0), 0, delta=0.5)   # ...then back to the window

    def test_the_mouse_view_can_stay_where_you_leave_it(self):
        self.start({**self.still(), "SeatMouseReturn": False}, speed=20 * M, start=100 * M)
        self.sim.press("FOUR")
        yaw0 = self.view()[1]
        self.sim.mouse.dx = -2
        self.sim.run(0.1)
        self.sim.mouse.dx = 0
        self.sim.run(20)
        self.assertAlmostEqual(self.wrap(self.view()[1] - yaw0), -6 * 2 * 2.5, delta=0.5)

    def test_the_mouse_does_nothing_while_the_cursor_shows(self):
        self.start(self.still(), speed=20 * M, start=100 * M)
        self.sim.press("FOUR")
        yaw0 = self.view()[1]
        self.sim.pc.bShowMouseCursor = True
        self.sim.mouse.dx = 3
        self.sim.run(0.5)
        self.assertAlmostEqual(self.view()[1], yaw0, delta=0.01)

    def test_the_mouse_as_return_values(self):
        self.start(self.still(), speed=20 * M, start=100 * M, mouse_returns=True)
        self.sim.press("FOUR")
        yaw0 = self.view()[1]
        self.sim.mouse.dx = 1
        self.sim.run(0.1)
        self.assertAlmostEqual(self.wrap(self.view()[1] - yaw0), 6 * 2.5, delta=0.5)

    def test_without_the_mouse_the_seat_view_still_works(self):
        self.start(self.still(), speed=20 * M, start=100 * M, no_mouse=True)
        self.sim.press("FOUR")
        self.sim.run(1)
        self.assertIsNotNone(self.sitting())
        self.assertEqual(self.logs().count("can't read the mouse"), 1)
        self.assertAlmostEqual(self.wrap(self.view()[1] - self.expected_yaw(self.seat())), 0, delta=1)

    def head_moves(self, seconds, **sim):
        """The furthest the head moves from the seat's eyes (cm) and tilts (degrees), riding for a while."""
        self.start({"SeatLookAround": False}, start=100 * M, **sim)
        self.sim.press("FOUR")
        self.sim.run(1)
        most, tilt = [0.0], [0.0]

        def each():
            most[0] = max(most[0], sum(v * v for v in self.eye_offset()) ** 0.5)
            pitch, _, roll = self.view()
            tilt[0] = max(tilt[0], abs(roll), abs(pitch))
        self.sim.run(seconds, each)
        return most[0], tilt[0]

    def test_the_head_hardly_moves_standing(self):
        moved, tilt = self.head_moves(8, speed=0)
        self.assertGreater(moved, 0.1)                          # breathing
        self.assertLess(moved, 0.6)
        self.assertLess(tilt, 0.1)

    def test_the_head_shakes_more_the_faster_the_train_goes(self):
        moved, tilt = self.head_moves(8, speed=30 * M)
        self.assertGreater(moved, 0.8)
        self.assertLess(moved, 3)
        self.assertGreater(tilt, 0.2)
        self.assertLess(tilt, 1.5)

    def test_with_shake_off_the_head_stays_put(self):
        self.start(self.still(), speed=30 * M, start=100 * M)
        self.sim.press("FOUR")
        self.sim.run(3)
        self.assertLess(max(abs(v) for v in self.eye_offset()), 1e-6)
        self.assertEqual(self.view()[2], 0)

    def test_braking_leans_the_head_forward(self):
        self.start({"SeatLookAround": False}, speed=20 * M, start=100 * M)
        self.sim.press("FOUR")
        self.sim.run(2)
        forward = []

        def brake():
            self.sim.speed = max(0, self.sim.speed - 2 * M / 60)  # 2 m/s²
            forward.append(self.eye_offset()[0])
        self.sim.run(3, brake)
        self.assertGreater(max(forward), 2)                     # 1.5 cm per m/s², a little more as it swings
        self.assertLess(max(forward), 6)
        settled = []
        self.sim.run(4, lambda: settled.append(self.eye_offset()[0]))
        self.assertLess(abs(settled[-1]), 0.6)                  # back upright once stopped

    def test_now_and_then_it_glances_elsewhere(self):
        self.start({"SeatShake": 0}, speed=20 * M, start=100 * M)
        self.sim.press("FOUR")
        off = []
        self.sim.run(90, lambda: off.append(abs(self.wrap(self.view()[1] - self.expected_yaw(self.seat())))))
        self.assertGreater(max(off), 25)                        # a glance
        self.assertGreater(sum(1 for o in off if o < 10) / len(off), 0.6)  # mostly ahead out of the window
        self.assertGreater(sum(1 for o in off if o > 0.5) / len(off), 0.5) # the gaze wanders a little

    def test_turning_by_rotators(self):
        self.start()
        fm = self.lua.eval('(require("flyby_math"))')
        r = lambda p, y, w: self.lua.table_from({"Pitch": p, "Yaw": y, "Roll": w})
        v = lambda x, y, z: self.lua.table_from({"X": x, "Y": y, "Z": z})
        vd = lambda t: (t.X, t.Y, t.Z)
        rd = lambda t: (t.Pitch, t.Yaw, t.Roll)
        close = lambda a, b: self.assertLess(sum((x - y) ** 2 for x, y in zip(a, b)) ** 0.5, 1e-6)
        close(vd(fm.turn(r(0, 90, 0), v(1, 0, 0))), (0, 1, 0))                 # yaw 90: forward is +Y
        close(vd(fm.turn(r(90, 0, 0), v(1, 0, 0))), (0, 0, 1))                 # pitch 90: forward is up
        close(rd(fm.combine(r(0, 90, 0), r(0, 90, 0))), (0, 180, 0))
        a, b = r(20, -35, 10), r(-5, 120, 30)
        close(rd(fm.combine(a, r(0, 0, 0))), rd(a))
        close(rd(fm.combine(r(0, 0, 0), b)), rd(b))
        p = v(3, -7, 11)
        close(vd(fm.turn(fm.combine(a, b), p)), vd(fm.turn(a, fm.turn(b, p))))
        close(rd(fm.uncombine(a, fm.combine(a, b))), rd(b))                    # and back
        close(rd(fm.uncombine(r(0, 90, 0), r(0, 180, 0))), (0, 90, 0))

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
