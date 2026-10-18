"""
Installs the fly-by camera and comfort HUD mods into Train Sim World 7.

    python install.py                      copy both mods into the game (UE4SS must be installed)
    python install.py --mod ComfortHUD     just that one (FlyByCamera or ComfortHUD)
    python install.py --ue4ss UE4SS.zip    install UE4SS from its release zip first, then the mods
    python install.py --uninstall          take the mods out of the game (with --mod, just that one)
    python install.py --remove-ue4ss       take UE4SS and every UE4SS mod out of the game

The game is found through Steam; --game-dir points at its Binaries\\Win64 folder instead.
UE4SS is set up so it opens no windows over the game (its log is ue4ss\\UE4SS.log) and doesn't
reload mods on Ctrl+R. The comfort HUD is told where the game's save files are, to keep the comfort
beside them (it can't look through a folder from inside the game).
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import zipfile
import winreg

HERE = os.path.dirname(os.path.abspath(__file__))
MODS = {"FlyByCamera": "Fly-by camera", "ComfortHUD": "Comfort HUD"}   # folder: what it's called
GAME_WIN64 = os.path.join("steamapps", "common", "Train Sim World 7", "WindowsNoEditor",
                          "TS2Prototype", "Binaries", "Win64")
GAME_EXE = "TrainSimWorld.exe"
# The game's saves, in Documents: a folder for each Steam account, each with the game's own save and checkpoint.
SAVE_GAMES = os.path.join("My Games", "TrainSimWorld7", "Saved", "SaveGames")
SAVE_PATTERNS = ("TSWSaveGame_*.sav", "TSWCheckpointSaveGame_*.sav")
SAVE_LIST = os.path.join("Scripts", "comfort_save_files.lua")   # in the installed comfort HUD

# UE4SS-settings.ini changes: no console or GUI windows over the game, no hot reload on Ctrl+R.
SETTINGS = {
    "ConsoleEnabled": "0",
    "GuiConsoleEnabled": "0",
    "GuiConsoleVisible": "0",
    "EnableHotReloadSystem": "0",
}

# UE4SS's sample mods, switched off: the mods here need none of them, and Keybinds puts object dumps
# on Ctrl+J, Ctrl+H and Ctrl+number pad keys. Turn any back on in ue4ss\Mods\mods.txt.
SAMPLE_MODS_OFF = ("CheatManagerEnablerMod", "ConsoleCommandsMod", "ConsoleEnablerMod",
                   "BPML_GenericFunctions", "BPModLoaderMod", "Keybinds")


def steam_libraries():
    """Every Steam library folder on this PC, from Steam's own list."""
    roots = []
    for hive, key in ((winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam"),
                      (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam")):
        try:
            with winreg.OpenKey(hive, key) as k:
                for name in ("SteamPath", "InstallPath"):
                    try:
                        roots.append(os.path.normpath(winreg.QueryValueEx(k, name)[0]))
                    except OSError:
                        pass
        except OSError:
            pass
    roots.append(r"C:\Program Files (x86)\Steam")
    libraries = []
    for steam in dict.fromkeys(roots):
        try:
            with open(os.path.join(steam, "steamapps", "libraryfolders.vdf"), encoding="utf-8") as f:
                text = f.read()
        except OSError:
            continue
        libraries.append(steam)
        for path in re.findall(r'"path"\s+"([^"]+)"', text):
            libraries.append(os.path.normpath(path.replace("\\\\", "\\")))
    return list(dict.fromkeys(libraries))


def find_game():
    for library in steam_libraries():
        folder = os.path.join(library, GAME_WIN64)
        if os.path.isfile(os.path.join(folder, GAME_EXE)):
            return folder
    return None


def game_running():
    out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {GAME_EXE}", "/NH"],
                         capture_output=True, text=True).stdout
    return GAME_EXE.lower() in out.lower()


def ue4ss_dir(win64):
    return os.path.join(win64, "ue4ss")


def has_ue4ss(win64):
    return (os.path.isfile(os.path.join(win64, "dwmapi.dll"))
            and os.path.isfile(os.path.join(ue4ss_dir(win64), "UE4SS.dll")))


def install_ue4ss(zip_path, win64):
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
        if "dwmapi.dll" not in names or "ue4ss/UE4SS.dll" not in names:
            sys.exit(f"{zip_path} doesn't look like a UE4SS release (no dwmapi.dll and ue4ss/UE4SS.dll).")
        for name in names:
            target = os.path.normpath(os.path.join(win64, name))
            if not target.startswith(os.path.normpath(win64) + os.sep):
                sys.exit(f"{zip_path} has a file that would land outside the game folder: {name}")
        # On an update, keep the settings and mod list already there.
        keep = [n for n in ("ue4ss/UE4SS-settings.ini", "ue4ss/Mods/mods.txt")
                if os.path.isfile(os.path.join(win64, *n.split("/")))]
        z.extractall(win64, members=[n for n in names if n not in keep])
    print(f"UE4SS installed into {win64}")


def set_ini_values(text, values):
    """Sets `Key = value` lines in an ini file's text, keeping everything else as it was."""
    for key, value in values.items():
        text, n = re.subn(rf"(?m)^(\s*{re.escape(key)}\s*=).*$", rf"\g<1> {value}", text)
        if n == 0:
            print(f"  note: {key} isn't in UE4SS-settings.ini, left as UE4SS's default")
    return text


def set_mod_line(text, mod, enabled):
    """Sets `mod : 1` / `mod : 0` in mods.txt where its line is, or removes it (enabled=None).
    A new line goes above UE4SS's built-in Keybinds entry, which has to stay last."""
    lines = text.splitlines()
    mine = re.compile(rf"\s*{re.escape(mod)}\s*:")
    at = next((i for i, l in enumerate(lines) if mine.match(l)), None)
    if enabled is None:
        if at is not None:
            del lines[at]
    elif at is not None:
        lines[at] = f"{mod} : {1 if enabled else 0}"
    else:
        at = next((i for i, l in enumerate(lines) if re.match(r"\s*Keybinds\s*:", l)), len(lines))
        while at > 0 and lines[at - 1].lstrip().startswith(";"):
            at -= 1 # keep the "do not move up!" comment with Keybinds
        lines.insert(at, f"{mod} : {1 if enabled else 0}")
    return "\n".join(lines) + "\n"


def edit_file(path, change):
    with open(path, encoding="utf-8-sig") as f:
        old = f.read()
    new = change(old)
    if new != old:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new)


def set_up_ue4ss(win64):
    settings = os.path.join(ue4ss_dir(win64), "UE4SS-settings.ini")
    original = settings + ".original"
    if os.path.isfile(settings) and not os.path.isfile(original):
        shutil.copy2(settings, original)
    if os.path.isfile(settings):
        edit_file(settings, lambda t: set_ini_values(t, SETTINGS))
    mods_txt = os.path.join(ue4ss_dir(win64), "Mods", "mods.txt")
    if os.path.isfile(mods_txt):
        def samples_off(text):
            for mod in SAMPLE_MODS_OFF:
                if re.search(rf"(?m)^\s*{re.escape(mod)}\s*:", text):
                    text = set_mod_line(text, mod, False)
            return text
        edit_file(mods_txt, samples_off)


def documents_folder():
    """The user's Documents folder, wherever Windows has put it (OneDrive moves it)."""
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                            r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders") as k:
            return os.path.expandvars(winreg.QueryValueEx(k, "Personal")[0])
    except OSError:
        return os.path.join(os.path.expanduser("~"), "Documents")


def save_folder():
    """The game's SaveGames folder, or None if it isn't there (the game not run yet)."""
    folder = os.path.join(documents_folder(), SAVE_GAMES)
    return folder if os.path.isdir(folder) else None


def save_files(folder):
    """The game's save files: its own save and its checkpoint for each Steam account that has played."""
    found = []
    for pattern in SAVE_PATTERNS:
        found += glob.glob(os.path.join(folder, "*", pattern))
    return sorted(found)


def write_save_list(target, files):
    """Tells the installed comfort HUD where the game's save files are (comfort_save_files.lua). Written in
    Windows' own code page, which is what Lua's io.open takes a path in."""
    usable = []
    for path in files:
        try:
            path.encode("mbcs", errors="strict")
            usable.append(path.replace("\\", "/"))
        except UnicodeEncodeError:
            print(f"  note: the comfort HUD can't open {path} (characters it can't take in its name)")
    lines = ["-- Written by install.py: the game's save files, to keep the comfort beside. Install the comfort HUD",
             "-- again if the game starts saving somewhere new (another Steam account or player name).",
             "return {"]
    lines += [f'    "{path}",' for path in usable]
    lines.append("}")
    with open(os.path.join(target, SAVE_LIST), "w", encoding="mbcs", errors="replace") as f:
        f.write("\n".join(lines) + "\n")
    return usable


def install_mod(win64, mod):
    mods = os.path.join(ue4ss_dir(win64), "Mods")
    target = os.path.join(mods, mod)
    if os.path.isdir(target):
        shutil.rmtree(target)
    shutil.copytree(os.path.join(HERE, mod), target)
    mods_txt = os.path.join(mods, "mods.txt")
    if os.path.isfile(mods_txt):
        edit_file(mods_txt, lambda t: set_mod_line(t, mod, True))
    print(f"{MODS[mod]} installed into {target}")
    if mod == "ComfortHUD":
        folder = save_folder()
        files = write_save_list(target, save_files(folder) if folder else [])
        if files:
            print(f"  the comfort is kept beside the game's saves: {', '.join(os.path.basename(f) for f in files)}")
        else:
            print("  no saves of the game's found yet: once it has saved, install again to keep the comfort with them")


def uninstall_mod(win64, mod):
    mods = os.path.join(ue4ss_dir(win64), "Mods")
    target = os.path.join(mods, mod)
    if os.path.isdir(target):
        shutil.rmtree(target)
    mods_txt = os.path.join(mods, "mods.txt")
    if os.path.isfile(mods_txt):
        edit_file(mods_txt, lambda t: set_mod_line(t, mod, None))
    print(f"{MODS[mod]} removed from the game.")


def remove_ue4ss(win64):
    dll = os.path.join(win64, "dwmapi.dll")
    if os.path.isfile(dll):
        os.remove(dll)
    if os.path.isdir(ue4ss_dir(win64)):
        shutil.rmtree(ue4ss_dir(win64))
    print("UE4SS removed from the game.")


def main():
    p = argparse.ArgumentParser(description="Install the fly-by camera and comfort HUD mods into Train Sim World 7.")
    p.add_argument("--mod", action="append", choices=list(MODS), help="just this mod (both without it)")
    p.add_argument("--ue4ss", metavar="ZIP", help="install UE4SS from this release zip first")
    p.add_argument("--uninstall", action="store_true", help="take the mods out of the game")
    p.add_argument("--remove-ue4ss", action="store_true", help="take UE4SS and all its mods out of the game")
    p.add_argument("--game-dir", help="the game's Binaries\\Win64 folder, if Steam can't find it")
    args = p.parse_args()

    win64 = args.game_dir or find_game()
    if not win64 or not os.path.isfile(os.path.join(win64, GAME_EXE)):
        sys.exit("Train Sim World 7 not found. Use --game-dir with its Binaries\\Win64 folder.")
    if game_running():
        sys.exit("Train Sim World 7 is running. Close it first, then run this again.")

    if args.remove_ue4ss:
        return remove_ue4ss(win64)
    mods = args.mod or list(MODS)
    if args.uninstall:
        for mod in mods:
            uninstall_mod(win64, mod)
        return
    if args.ue4ss:
        install_ue4ss(args.ue4ss, win64)
    if not has_ue4ss(win64):
        sys.exit("UE4SS isn't installed in the game yet. Run again with --ue4ss and its release zip.")
    set_up_ue4ss(win64)
    for mod in mods:
        install_mod(win64, mod)
    if "FlyByCamera" in mods:
        print("Fly-by camera: load a drive and press 7.")
    if "ComfortHUD" in mods:
        print("Comfort HUD: load a drive; the objective box at the top shows the passengers and comfort.")


if __name__ == "__main__":
    main()
