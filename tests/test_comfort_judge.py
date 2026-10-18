"""
Tests for the comfort HUD's judging (ComfortHUD/Scripts/comfort_judge.lua): it's a port of tsw-joystick's passenger
comfort (tsw_comfort.Judge), so the two are run side by side on the drives logged in the game there (a Class 150
on 1M56, a Class 350 stop with its own holding brake on 2W09) and on made-up services, and have to agree.

    python -m unittest discover tests

The side-by-side tests need tsw-joystick in C:\\code\\tsw-joystick (or TSW_JOYSTICK set to where it is); without it
they're skipped and only the tests of the Lua alone run.
"""

import csv
import math
import os
import random
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "ComfortHUD", "Scripts").replace("\\", "/")
JOYSTICK = os.environ.get("TSW_JOYSTICK", r"C:\code\tsw-joystick")

try:
    from lupa import lua54
except ImportError:
    sys.path.insert(0, os.environ.get("FLYBY_PYLIB", r"F:\TSW mod downloads\pylib"))
    try:
        from lupa import lua54
    except ImportError:
        lua54 = None

try:
    sys.path.insert(0, JOYSTICK)
    os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
    import tsw_comfort
except ImportError:
    tsw_comfort = None
finally:
    if sys.path and sys.path[0] == JOYSTICK:
        sys.path.pop(0)

DRIVE_150 = os.path.join(JOYSTICK, "tests", "data", "class150_1M56.csv")
DRIVE_350 = os.path.join(JOYSTICK, "tests", "data", "class350_2W09.csv")


def new_lua():
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f'package.path = "{SCRIPTS}/?.lua;" .. package.path')
    return lua, lua.eval('(require("comfort_judge"))')


def plain(value):
    """A Lua table as Python lists / dicts, for comparing."""
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    keys = list(value.keys())
    if not keys:
        return []
    if all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
        return [plain(value[k]) for k in sorted(keys)]
    return {k: plain(value[k]) for k in keys}


def close(a, b, places=6):
    """The same value, floats to `places` decimals; Python's None is Lua's nil, infinity alike."""
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool):
        return a == b or (math.isfinite(a) and abs(a - b) < 10 ** -places)
    if isinstance(a, dict) and isinstance(b, dict):
        keys = set(a) | set(b)
        return all(close(a.get(k), b.get(k), places) for k in keys)
    if isinstance(a, (list, tuple)) and isinstance(b, (list, tuple)):
        return len(a) == len(b) and all(close(x, y, places) for x, y in zip(a, b))
    return a == b


class SideBySide:
    """A Python Judge and a Lua one fed the same readings; check() says where they first differ."""

    def __init__(self, testcase):
        self.t = testcase
        self.lua, self.J = new_lua()
        self.py = tsw_comfort.Judge()
        self.lj = self.J.new()
        self.steps = 0

    def feed(self, now, speed, acc, passengers, clock=None, brake=None, power=False, hold=None):
        said_py = [e for e in self.py.feed(now, speed, acc, passengers, clock, brake, power, hold) if e[0] != "ease"]
        said_lua = plain(self.lj.feed(self.lj, now, speed, acc, passengers, clock, brake, power, hold)) or []
        self.steps += 1
        where = f"reading {self.steps} (t {now:.3f}, speed {speed:.3f}, acc {acc:.3f})"
        self.t.assertTrue(close([list(e) for e in said_py], said_lua), f"said differs at {where}: "
                                                                        f"{said_py} / {said_lua}")
        panel_py, panel_lua = self.py.panel, plain(self.lj.panel(self.lj))
        self.t.assertTrue(close(panel_py, panel_lua), f"panel differs at {where}: {panel_py} / {panel_lua}")
        return panel_py

    def new_leg(self, service, station=None, first=False):
        ride_py = self.py.new_leg(service, station, first)
        ride_lua = plain(self.lj.new_leg(self.lj, service, station, first))
        if ride_py is not None:
            ride_py = dict(ride_py, at=ride_py.get("at"))
        self.t.assertTrue(close(ride_py, ride_lua, 1), f"ride differs: {ride_py} / {ride_lua}")
        return ride_py

    def lost(self):
        self.py.lost()
        self.lj.lost(self.lj)

    def check_scores(self):
        self.t.assertTrue(close(self.py.live_score(), self.lj.live_score(self.lj), 3))
        self.t.assertTrue(close(tsw_comfort.losses(self.py.leg), plain(self.J.losses(self.lj.leg)) or []))


@unittest.skipIf(lua54 is None, "needs lupa: pip install lupa")
@unittest.skipIf(tsw_comfort is None or not os.path.isfile(DRIVE_150), "needs tsw-joystick beside this repo")
class SameAsTswJoystick(unittest.TestCase):
    def test_class_150_logged_drive(self):
        both, phases = SideBySide(self), []
        with open(DRIVE_150) as f:
            for r in csv.DictReader(f):
                t = float(r["t"])
                panel = both.feed(t, float(r["speed"]), float(r["acc"]), 15, None, float(r["brake"]),
                                  float(r["power"]) > 0)
                phase = panel and panel["phase"]
                if not phases or phases[-1] != phase:
                    phases.append(phase)
        both.check_scores()
        self.assertEqual([p for p in phases if p], ["firm", "harsh", "ease", "stopped"])

    def test_class_350_stop_with_its_holding_brake(self):
        both, stopped = SideBySide(self), None
        with open(DRIVE_350) as f:
            for r in csv.DictReader(f):
                t = float(r["t"])
                panel = both.feed(t, float(r["speed"]), float(r["acc"]), 140, t, float(r["brake"]),
                                  r["power"] == "1", r["hold"] == "1")
                if panel and panel["phase"] == "stopped":
                    stopped = stopped or panel
        both.check_scores()
        self.assertFalse(stopped["jolt"])

    def test_made_up_services(self):
        """Services of a few stops each: speeding up and braking at random rates, stops at stations and signals,
        passengers changing at stations, a train change and the game's time standing still."""
        rnd = random.Random(7)
        for service_no in range(6):
            both = SideBySide(self)
            service = f"1A{service_no:02d}"
            t, clock, v, passengers = 0.0, 1000.0, 0.0, rnd.choice([None, 0, 40])
            for stop in range(5):
                top = rnd.uniform(8, 35)
                rate_up = rnd.choice([0.5, 1.0, 1.4, 1.6])
                rate_down = rnd.choice([0.5, 0.85, 1.1, 1.3])
                ease_at = rnd.choice([0.0, 2.0, 4.0])   # speed the driver eases the brake off below
                phase = "up"
                while True:
                    dt = rnd.choice([0.033, 0.066, 0.1])
                    if phase == "up":
                        acc = rate_up + rnd.gauss(0, 0.05)
                        if v >= top:
                            phase = "down"
                    else:
                        acc = -(rate_down if v > ease_at else 0.35) + rnd.gauss(0, 0.05)
                    v = max(0.0, v + acc * dt)
                    t += dt
                    if rnd.random() > 0.02:            # now and then the game's clock stands still a reading
                        clock += dt
                    both.feed(t, v, acc if v > 0 else 0.0, passengers, clock if service_no % 2 else None)
                    if phase == "down" and v == 0.0:
                        break
                for _ in range(rnd.randint(30, 120)):  # stood at the stop
                    t += 0.066
                    clock += 0.066
                    both.feed(t, 0.0, 0.0, passengers, clock if service_no % 2 else None)
                if stop == 2 and service_no == 3:
                    both.lost()                        # into the other cab
                if rnd.random() < 0.7:                 # a station, not a signal: the ride ends as it leaves
                    if passengers is not None:
                        passengers = max(0, passengers + rnd.randint(-15, 25))
                    both.new_leg(service, f"Station {stop}", first=stop == 0)
                both.check_scores()


@unittest.skipIf(lua54 is None, "needs lupa: pip install lupa")
class OnItsOwn(unittest.TestCase):
    def setUp(self):
        self.lua, self.J = new_lua()
        self.j = self.J.new()
        self.t = 0.0

    def run_at(self, seconds, speed, acc, passengers=20, dt=1 / 15):
        last = None
        for _ in range(int(seconds / dt)):
            self.t += dt
            self.j.feed(self.j, self.t, speed, acc, passengers, self.t)
            last = plain(self.j.panel(self.j))
        return last

    def test_braking_firm_then_harsh(self):
        self.assertIsNone(self.run_at(2, 20, -0.5))
        self.assertEqual(self.run_at(1, 20, -1.0)["phase"], "firm")
        panel = self.run_at(2, 20, -1.3)
        self.assertEqual((panel["phase"], panel["kind"]), ("harsh", "brake"))

    def test_freight_says_nothing(self):
        self.assertIsNone(self.run_at(3, 20, -1.4, passengers=None))

    def test_what_a_firm_stretch_cost_shows_once_it_ends(self):
        self.run_at(3, 20, -1.0)
        panel = self.run_at(1.2, 20, -0.3)
        self.assertEqual(panel["phase"], "lost")
        self.assertAlmostEqual(panel["cost"], 3.0, delta=0.2)
        self.assertAlmostEqual(panel["score"], 97.0, delta=0.2)

    def ride(self, top=10.0, rate=0.5, station="A"):
        """Speeds up to `top`, brakes to a stand at `rate` and leaves the station: a ride done."""
        v = 0.0
        while v < top:
            self.t += 1 / 15
            v += 0.5 / 15
            self.j.feed(self.j, self.t, v, 0.5, 20, self.t)
        while v > 0:
            self.t += 1 / 15
            v = max(0.0, v - rate / 15)
            self.j.feed(self.j, self.t, v, -rate if v > 0 else 0.0, 20, self.t)
        self.run_at(2, 0.0, 0.0)
        return plain(self.j.new_leg(self.j, "1M56", station))

    def test_rides_timed_by_the_day(self):
        self.j.day = 63876798000.0                        # the time of day less the game time fed
        ride = self.ride()
        self.assertAlmostEqual(ride["at"], 63876798000.0 + self.t - 2.0, delta=0.2)

    def test_kept_and_put_back(self):
        self.ride(rate=0.5, station="A")
        self.ride(rate=1.2, station="B")                  # a jolt
        kept = self.j.state(self.j)
        score = self.j.live_score(self.j)
        self.ride(rate=1.2, station="C")
        self.assertNotAlmostEqual(self.j.live_score(self.j), score)
        self.j.restore(self.j, kept)
        self.assertAlmostEqual(self.j.live_score(self.j), score)
        self.assertEqual([r["station"] for r in plain(self.j.done)], ["A", "B"])
        kept.done[1].mark = 0                             # what was kept is a copy, both ways
        self.assertNotEqual(plain(self.j.done)[0]["mark"], 0)

    def test_gone_back_drops_the_rides_after(self):
        self.ride(station="A")
        middle = self.t
        self.ride(station="B")
        self.ride(station="C")
        self.assertEqual(self.j.rewind(self.j, middle + 1), 2)
        self.assertEqual([r["station"] for r in plain(self.j.done)], ["A"])
        self.assertEqual(self.j.rewind(self.j, middle - 100), 1)

    def test_a_hard_stop_is_a_jolt(self):
        self.run_at(1, 10, 0.0)
        v = 10.0
        while v > 0:
            self.t += 1 / 15
            v = max(0.0, v - 1.0 / 15)
            self.j.feed(self.j, self.t, v, -1.0 if v > 0 else 0.0, 20, self.t)
        panel = plain(self.j.panel(self.j))
        self.assertEqual(panel["phase"], "stopped")
        self.assertTrue(panel["jolt"])
        self.assertAlmostEqual(panel["cost"], 9.0, delta=0.01)


if __name__ == "__main__":
    unittest.main()
