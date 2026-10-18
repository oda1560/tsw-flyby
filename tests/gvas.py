"""
The start of a Train Sim World 7 save file, made up for the tests: the GVAS header and the top-level tagged
properties the game writes ahead of its compressed data, in the order seen in its own saves (TSWSaveGame and
TSWCheckpointSaveGame, 2026-10-18). Also a reader for them that doesn't share code with the mod's.
"""

import struct

TICKS = 10_000_000


def fstr(s, wide=False):
    if wide:
        b = s.encode("utf-16-le") + b"\0\0"
        return struct.pack("<i", -(len(b) // 2)) + b
    b = s.encode("ascii") + b"\0"
    return struct.pack("<i", len(b)) + b


def tag(name, typ, value, extra=b""):
    return fstr(name) + fstr(typ) + struct.pack("<ii", len(value), 0) + extra + b"\0" + value


def struct_tag(name, struct_name, value):
    return tag(name, "StructProperty", value, fstr(struct_name) + b"\0" * 16)


def save(service, at, wide_service=False, padding=40_000, extra=b""):
    """A save made on `service` at `at` (seconds since the year 1, the game's time of day). `extra`: more tagged
    properties ahead of the service."""
    header = (b"GVAS" + struct.pack("<ii", 2, 522) + struct.pack("<HHHI", 4, 26, 1, 0) + fstr("++UE4+Release-4.26")
              + struct.pack("<ii", 3, 3) + b"\x11" * 60 + fstr("/Script/TS2Prototype.TS2SaveGame"))
    tod = (struct_tag("LocalDateTime", "DateTime", struct.pack("<q", round(at * TICKS)))
           + tag("Temperature", "FloatProperty", struct.pack("<f", 11.5))
           + tag("bForceTODAndWeatherSettings", "BoolProperty", b"", b"\x01")
           + fstr("None"))
    props = (tag("TSWSaveGameVersionNumber", "IntProperty", struct.pack("<i", 7))
             + tag("RouteDefinition", "StrProperty", fstr("/Route/RouteDefinition/Route.Route"))
             + tag("PlayerControllerName", "NameProperty", fstr("TS2DefaultPlayerController_C_2147481667"))
             + struct_tag("TODSettings", "TimeOfDaySettings", tod)
             + struct_tag("WorldOrigin", "IntVector", struct.pack("<iii", 0, 0, 0))
             + tag("InitialTimetableService", "NameProperty", fstr(service))
             + struct_tag("InitialTODSettings", "TimeOfDaySettings", tod)
             + tag("PlayerGameMode", "EnumProperty", fstr("EPlayerMode::Timetable"), fstr("EPlayerMode"))
             + extra
             + tag("CurrentTimetableService", "NameProperty", fstr(service, wide_service))
             + tag("RequiredAssetPathsAndVersions", "MapProperty", struct.pack("<ii", 0, 0),
                   fstr("StrProperty") + fstr("UInt32Property"))
             + tag("CompressedSaveData", "ArrayProperty", struct.pack("<i", padding) + bytes(range(256)) * (padding // 256)
                   + b"\0" * (padding % 256), fstr("ByteProperty"))
             + fstr("None"))
    return header + props


def write_save(path, service, at, **kw):
    with open(path, "wb") as f:
        f.write(save(service, at, **kw))


def read(data):
    """(service, at) from a save's start, read by walking its tagged properties."""
    pos = 4 + 8 + 10
    n = struct.unpack_from("<i", data, pos)[0]
    pos += 4 + n
    fmt, count = struct.unpack_from("<ii", data, pos)
    assert fmt == 3
    pos += 8 + 20 * count
    pos += 4 + struct.unpack_from("<i", data, pos)[0]

    def string(p):
        n = struct.unpack_from("<i", data, p)[0]
        if n >= 0:
            return data[p + 4:p + 4 + n - 1].decode("latin-1"), p + 4 + n
        return data[p + 4:p + 4 - 2 * n - 2].decode("utf-16-le"), p + 4 - 2 * n

    def props(p):
        while True:
            name, p = string(p)
            if name == "None":
                return
            typ, p = string(p)
            size = struct.unpack_from("<i", data, p)[0]
            p += 8
            sub = None
            if typ == "StructProperty":
                sub, p = string(p)
                p += 16
            elif typ == "BoolProperty":
                p += 1
            elif typ in ("ByteProperty", "EnumProperty", "ArrayProperty", "SetProperty"):
                _, p = string(p)
            elif typ == "MapProperty":
                _, p = string(p)
                _, p = string(p)
            p += 1 + (16 if data[p] else 0)
            yield name, typ, sub, p
            p += size

    service = at = None
    for name, typ, sub, p in props(pos):
        if name == "CurrentTimetableService":
            service = string(p)[0]
        elif name == "TODSettings":
            for n2, _, s2, p2 in props(p):
                if n2 == "LocalDateTime" and s2 == "DateTime":
                    at = struct.unpack_from("<q", data, p2)[0] / TICKS
        if service is not None and at is not None:
            return service, at
    return service, at
