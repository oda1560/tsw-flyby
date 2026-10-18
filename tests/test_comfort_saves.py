"""
Tests for reading the game's save files and keeping the comfort beside them (ComfortHUD/Scripts/comfort_saves.lua):
on save files made up here (tests/gvas.py) and, where they're on this PC, on the game's own.

    python -m unittest discover tests
"""

import datetime
import glob
import math
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "ComfortHUD", "Scripts").replace("\\", "/")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import gvas  # noqa: E402
import install  # noqa: E402

try:
    from lupa import lua54
except ImportError:
    sys.path.insert(0, os.environ.get("FLYBY_PYLIB", r"F:\TSW mod downloads\pylib"))
    try:
        from lupa import lua54
    except ImportError:
        lua54 = None

YEAR_1 = datetime.datetime(1, 1, 1)


def seconds(d):
    """A datetime as the game's saves time it: seconds since the year 1."""
    return (d - YEAR_1).total_seconds()


def plain(value):
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    keys = list(value.keys())
    if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
        return [plain(value[k]) for k in sorted(keys)]
    return {k: plain(value[k]) for k in keys}


@unittest.skipIf(lua54 is None, "needs lupa: pip install lupa")
class SaveFiles(unittest.TestCase):
    def setUp(self):
        self.lua = lua54.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(f'package.path = "{SCRIPTS}/?.lua;" .. package.path')
        self.C = self.lua.eval('(require("comfort_saves"))')
        self.dir = tempfile.mkdtemp()

    def path(self, name="TSWCheckpointSaveGame_abc.sav"):
        return os.path.join(self.dir, name).replace("\\", "/")

    # ---- the start of a save

    def test_service_and_time(self):
        at = seconds(datetime.datetime(2025, 3, 5, 19, 6, 42, 500000))
        gvas.write_save(self.path(), "2P18", at)
        service, read_at = self.C.read_header(self.path())
        self.assertEqual(service, "2P18")
        self.assertAlmostEqual(read_at, at, places=4)

    def test_a_service_name_in_utf16(self):
        gvas.write_save(self.path(), "1A64", 1000.0, wide_service=True)
        self.assertEqual(self.C.read_header(self.path())[0], "1A64")

    def test_half_written_or_missing(self):
        data = gvas.save("2P18", 1000.0)
        with open(self.path(), "wb") as f:
            f.write(data[:data.find(b"CurrentTimetableService") + 30])
        service, why = self.C.read_header(self.path())
        self.assertIsNone(service)
        self.assertTrue(why)
        self.assertIsNone(self.C.read_header(self.path("nothing.sav"))[0])
        self.assertEqual(self.C.header(b"PNG\0" * 10), (None, "not a save game"))

    def test_a_start_longer_than_16_kb(self):
        extra = b"".join(gvas.tag(f"Asset{i}", "StrProperty", gvas.fstr(f"/Game/Some/Asset/Path_{i:04d}" + "x" * 40))
                         for i in range(400))
        gvas.write_save(self.path(), "2P18", 1000.0, extra=extra)
        with open(self.path(), "rb") as f:
            self.assertGreater(f.read().find(b"CurrentTimetableService"), 16384)
        self.assertEqual(self.C.read_header(self.path()), ("2P18", 1000.0))

    def test_the_game_s_own_saves(self):
        folder = install.save_folder()
        files = sorted(glob.glob(os.path.join(folder or "", "*", "TSW*SaveGame_*.sav")))
        if not files:
            self.skipTest("no saves of the game's on this PC")
        for path in files:
            with open(path, "rb") as f:
                want = gvas.read(f.read(65536))
            service, at = self.C.read_header(path.replace("\\", "/"))
            self.assertEqual(service, want[0], path)
            self.assertAlmostEqual(at, want[1], places=4)

    # ---- time

    def test_days_as_the_game_counts_them(self):
        for d in (datetime.datetime(2025, 3, 5, 8, 24, 28), datetime.datetime(2024, 12, 31, 23, 59, 59),
                  datetime.datetime(2000, 2, 29, 12, 0, 0), datetime.datetime(1900, 3, 1, 0, 0, 1),
                  datetime.datetime(2026, 1, 1, 0, 0, 0)):
            tod = d.hour * 3600 + d.minute * 60 + d.second
            self.assertEqual(self.C.day_seconds(d.year, d.timetuple().tm_yday, tod), seconds(d), d)
            self.assertEqual(self.C.date_text(seconds(d)), d.strftime("%Y-%m-%d %H:%M:%S"))
        self.assertEqual(self.C.clock_text(seconds(datetime.datetime(2025, 3, 5, 19, 6, 42, 900000))), "19:06:42")

    def test_a_date_and_time_written_out(self):
        d = datetime.datetime(2024, 3, 5, 19, 6, 42)
        for text in ("2024.03.05-19.06.42", "2024-03-05T19:06:42Z", "2024/3/5 19:06:42"):
            self.assertEqual(self.C.parse_date(text), seconds(d), text)
        self.assertAlmostEqual(self.C.parse_date("2024-03-05T19:06:42.250Z"), seconds(d) + 0.25)
        for text in ("19:06:42", "", "nothing", "2024.13.05-19.06.42", "5.3.2024-19.06.42"):
            self.assertIsNone(self.C.parse_date(text), text)

    # ---- the comfort kept beside a save

    def record(self, service="2P18", at=63876759868.105713):
        return self.lua.table_from({
            "service": service, "at": at, "station": True, "kept": "2026-10-18 12:16:03",
            "state": self.lua.table_from({
                "service": service, "most": 62,
                "done": self.lua.table_from([self.lua.table_from({
                    "station": "Shipley", "mark": 96.8, "passengers": 62, "smooth": False, "at": 63876759000.25,
                    "lost": self.lua.table_from([self.lua.table_from([3.17, "stop", 0.81])])})]),
                "leg": self.lua.table_from({"stop": "smooth", "braking": 0.4, "passengers": 40, "judged": True,
                                            "harsh": self.lua.table_from([]), "way": self.lua.table_from([]),
                                            "firm": self.lua.table_from({"brake": 1.5, "power": 0.0}),
                                            "upto": 63876759860.5}),
            }),
        })

    def test_kept_beside_the_save_and_read_back(self):
        save = self.path()
        self.assertTrue(self.C.keep(save, self.record()))
        self.assertTrue(os.path.isfile(os.path.join(self.dir, "TSWCheckpointSaveGame_abc.comfort")))
        self.assertFalse(os.path.exists(os.path.join(self.dir, "TSWCheckpointSaveGame_abc.comfort.new")))
        kept = plain(self.C.find(save, "2P18", 63876759868.2))
        self.assertEqual(kept["state"]["done"][0]["lost"], [[3.17, "stop", 0.81]])
        self.assertEqual(kept["state"]["leg"]["firm"], {"brake": 1.5, "power": 0.0})
        self.assertEqual(kept["at"], 63876759868.105713)
        self.assertTrue(kept["station"])

    def test_only_for_the_save_it_was_kept_with(self):
        save = self.path()
        self.C.keep(save, self.record())
        self.assertIsNone(self.C.find(save, "2P18", 63876759868.105713 + 30))   # the game's next save there
        self.assertIsNone(self.C.find(save, "1A64", 63876759868.105713))
        self.assertIsNone(self.C.find(self.path("TSWSaveGame_abc.sav"), "2P18", 63876759868.105713))

    def test_kept_again_over_the_last(self):
        save = self.path()
        self.C.keep(save, self.record(at=1000.0))
        self.C.keep(save, self.record(at=2000.0))
        self.assertIsNotNone(self.C.find(save, "2P18", 2000.0))
        self.assertIsNone(self.C.find(save, "2P18", 1000.0))

    def test_odd_numbers_and_names_survive(self):
        r = self.lua.eval('{ service = "1A\\"64\\n", at = 1.5, state = { done = {}, leg = { braking = 1/0 },'
                          ' ["odd key"] = -1/0, nan = 0/0, n = 3 } }')
        back = plain(self.C.parse(self.C.text(r)))
        self.assertEqual(back["service"], '1A"64\n')
        self.assertEqual(back["state"]["leg"]["braking"], math.inf)
        self.assertEqual(back["state"]["odd key"], -math.inf)
        self.assertTrue(math.isnan(back["state"]["nan"]))
        self.assertEqual(back["state"]["n"], 3)

    def test_a_broken_file_is_nothing_kept(self):
        save = self.path()
        with open(os.path.join(self.dir, "TSWCheckpointSaveGame_abc.comfort"), "w") as f:
            f.write("return { service = ")
        self.assertIsNone(self.C.kept(save))
        with open(os.path.join(self.dir, "TSWCheckpointSaveGame_abc.comfort"), "w") as f:
            f.write("return os.exit()")             # no globals to call
        self.assertIsNone(self.C.kept(save))


if __name__ == "__main__":
    unittest.main()
