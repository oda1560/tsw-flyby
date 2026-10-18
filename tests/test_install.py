"""
Tests for install.py: editing UE4SS's mods.txt and settings, and installing into a stand-in game folder.

    python -m unittest discover tests
"""

import os
import sys
import tempfile
import unittest
import zipfile
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import install  # noqa: E402

# mods.txt as UE4SS ships it
MODS_TXT = """CheatManagerEnablerMod : 1
ConsoleCommandsMod : 1
ConsoleEnablerMod : 1
SplitScreenMod : 0
LineTraceMod : 0
BPML_GenericFunctions : 1
BPModLoaderMod : 1




; Built-in keybinds, do not move up!
Keybinds : 1
"""


class ModsTxt(unittest.TestCase):
    def test_a_new_mod_goes_above_the_keybinds_comment(self):
        lines = install.set_mod_line(MODS_TXT, "FlyByCamera", True).splitlines()
        self.assertEqual(lines[-3:], ["FlyByCamera : 1", "; Built-in keybinds, do not move up!", "Keybinds : 1"])

    def test_an_existing_line_changes_where_it_is(self):
        text = install.set_mod_line(MODS_TXT, "ConsoleEnablerMod", False)
        self.assertEqual(text.splitlines()[2], "ConsoleEnablerMod : 0")
        self.assertEqual(len(text.splitlines()), len(MODS_TXT.splitlines()))

    def test_keybinds_can_be_switched_off_and_stays_last(self):
        text = install.set_mod_line(MODS_TXT, "Keybinds", False)
        self.assertEqual(text.splitlines()[-1], "Keybinds : 0")

    def test_removing(self):
        text = install.set_mod_line(install.set_mod_line(MODS_TXT, "FlyByCamera", True), "FlyByCamera", None)
        self.assertEqual(text, MODS_TXT)


class Settings(unittest.TestCase):
    def test_only_the_named_values_change(self):
        text = "[Debug]\nConsoleEnabled = 1\nGuiConsoleEnabled = 1\nGraphicsAPI = opengl\n"
        out = install.set_ini_values(text, {"ConsoleEnabled": "0", "GuiConsoleEnabled": "0"})
        self.assertEqual(out, "[Debug]\nConsoleEnabled = 0\nGuiConsoleEnabled = 0\nGraphicsAPI = opengl\n")


class Installing(unittest.TestCase):
    def setUp(self):
        self.win64 = tempfile.mkdtemp()
        open(os.path.join(self.win64, install.GAME_EXE), "w").close()
        self.zip = os.path.join(tempfile.mkdtemp(), "UE4SS.zip")
        with zipfile.ZipFile(self.zip, "w") as z:
            z.writestr("dwmapi.dll", "")
            z.writestr("ue4ss/UE4SS.dll", "")
            z.writestr("ue4ss/UE4SS-settings.ini", "[Debug]\nConsoleEnabled = 1\n[General]\nEnableHotReloadSystem = 1\n")
            z.writestr("ue4ss/Mods/mods.txt", MODS_TXT)

    saves = None                    # the game's SaveGames folder, None: the game hasn't saved yet

    def install(self, *args):
        argv = ["install.py", "--game-dir", self.win64, *args]
        with mock.patch.object(sys, "argv", argv), mock.patch.object(install, "game_running", return_value=False), \
                mock.patch.object(install, "save_folder", return_value=self.saves), mock.patch("builtins.print"):
            install.main()

    def read(self, *parts):
        with open(os.path.join(self.win64, *parts), encoding="utf-8") as f:
            return f.read()

    def test_ue4ss_and_the_mod(self):
        self.install("--ue4ss", self.zip)
        self.assertTrue(os.path.isfile(os.path.join(self.win64, "ue4ss", "Mods", "FlyByCamera", "Scripts", "main.lua")))
        mods = self.read("ue4ss", "Mods", "mods.txt")
        self.assertIn("FlyByCamera : 1", mods)
        self.assertIn("Keybinds : 0", mods)
        self.assertIn("ConsoleEnablerMod : 0", mods)
        settings = self.read("ue4ss", "UE4SS-settings.ini")
        self.assertIn("ConsoleEnabled = 0", settings)
        self.assertIn("EnableHotReloadSystem = 0", settings)
        self.assertIn("ConsoleEnabled = 1", self.read("ue4ss", "UE4SS-settings.ini.original"))

    def test_both_mods_by_default(self):
        self.install("--ue4ss", self.zip)
        mods = self.read("ue4ss", "Mods", "mods.txt")
        self.assertIn("ComfortHUD : 1", mods)
        for mod in ("FlyByCamera", "ComfortHUD"):
            self.assertTrue(os.path.isfile(os.path.join(self.win64, "ue4ss", "Mods", mod, "enabled.txt")))
        self.assertTrue(os.path.isfile(os.path.join(self.win64, "ue4ss", "Mods", "ComfortHUD", "Scripts",
                                                    "comfort_judge.lua")))

    def test_the_comfort_hud_is_told_where_the_saves_are(self):
        self.saves = tempfile.mkdtemp()
        account = os.path.join(self.saves, "76561197994196168")
        os.makedirs(account)
        for name in ("TSWSaveGame_cb06.sav", "TSWCheckpointSaveGame_cb06.sav", "PP_cb06.sav", "dovetaillive.sav"):
            open(os.path.join(account, name), "w").close()
        self.install("--ue4ss", self.zip, "--mod", "ComfortHUD")
        listed = self.read("ue4ss", "Mods", "ComfortHUD", "Scripts", "comfort_save_files.lua")
        folder = account.replace("\\", "/")
        self.assertIn(f'"{folder}/TSWSaveGame_cb06.sav",', listed)
        self.assertIn(f'"{folder}/TSWCheckpointSaveGame_cb06.sav",', listed)
        self.assertNotIn("PP_", listed)
        self.assertNotIn("\\", listed)

    def test_before_the_game_has_saved(self):
        self.install("--ue4ss", self.zip, "--mod", "ComfortHUD")
        listed = self.read("ue4ss", "Mods", "ComfortHUD", "Scripts", "comfort_save_files.lua")
        self.assertTrue(listed.rstrip().endswith("return {\n}"), listed)

    def test_one_mod(self):
        self.install("--ue4ss", self.zip, "--mod", "ComfortHUD")
        self.assertTrue(os.path.isdir(os.path.join(self.win64, "ue4ss", "Mods", "ComfortHUD")))
        self.assertFalse(os.path.exists(os.path.join(self.win64, "ue4ss", "Mods", "FlyByCamera")))
        self.assertNotIn("FlyByCamera", self.read("ue4ss", "Mods", "mods.txt"))

    def test_uninstall_one_leaves_the_other(self):
        self.install("--ue4ss", self.zip)
        self.install("--uninstall", "--mod", "ComfortHUD")
        mods = self.read("ue4ss", "Mods", "mods.txt")
        self.assertNotIn("ComfortHUD", mods)
        self.assertIn("FlyByCamera : 1", mods)
        self.assertTrue(os.path.isdir(os.path.join(self.win64, "ue4ss", "Mods", "FlyByCamera")))

    def test_updating_ue4ss_keeps_the_settings_and_mod_list(self):
        self.install("--ue4ss", self.zip)
        with open(os.path.join(self.win64, "ue4ss", "Mods", "mods.txt"), "a", encoding="utf-8") as f:
            f.write("SomeOtherMod : 1\n")
        self.install("--ue4ss", self.zip)
        self.assertIn("SomeOtherMod : 1", self.read("ue4ss", "Mods", "mods.txt"))

    def test_without_ue4ss_it_stops(self):
        with self.assertRaises(SystemExit):
            self.install()

    def test_uninstall_leaves_ue4ss(self):
        self.install("--ue4ss", self.zip)
        self.install("--uninstall")
        self.assertFalse(os.path.exists(os.path.join(self.win64, "ue4ss", "Mods", "FlyByCamera")))
        self.assertNotIn("FlyByCamera", self.read("ue4ss", "Mods", "mods.txt"))
        self.assertTrue(os.path.isfile(os.path.join(self.win64, "dwmapi.dll")))

    def test_remove_ue4ss(self):
        self.install("--ue4ss", self.zip)
        self.install("--remove-ue4ss")
        self.assertFalse(os.path.exists(os.path.join(self.win64, "dwmapi.dll")))
        self.assertFalse(os.path.exists(os.path.join(self.win64, "ue4ss")))

    def test_a_zip_reaching_outside_the_game_folder_is_refused(self):
        bad = os.path.join(tempfile.mkdtemp(), "bad.zip")
        with zipfile.ZipFile(bad, "w") as z:
            z.writestr("dwmapi.dll", "")
            z.writestr("ue4ss/UE4SS.dll", "")
            z.writestr("../evil.dll", "")
        with self.assertRaises(SystemExit):
            self.install("--ue4ss", bad)
        self.assertFalse(os.path.exists(os.path.join(self.win64, "dwmapi.dll")))


if __name__ == "__main__":
    unittest.main()
