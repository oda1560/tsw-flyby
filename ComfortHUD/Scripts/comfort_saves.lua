-- The game's save files, and the comfort kept beside them. No game objects in here, so it can be tried on the
-- save files themselves.
--
-- The game writes its own save (Save in the menu) and a checkpoint on arriving at and leaving each stop, each time
-- over the same file: Saved\SaveGames\<Steam ID>\TSWSaveGame_<...>.sav and TSWCheckpointSaveGame_<...>.sav. Near
-- the start of each, ahead of the compressed rest, are the service it was saved on (CurrentTimetableService) and
-- the game's time of day then (TODSettings.LocalDateTime): those two are all that's read, from the first 16 KB.
-- The comfort kept with a save goes in a file beside it, TSWSaveGame_<...>.comfort, with the service and time of
-- the save it was kept with, so it's only taken for that save and not for the next one the game writes there.
--
--     local service, at = C.read_header(path)   -- at: seconds since the year 1; nil and why if it can't be read
--     C.keep(path, record)                       -- record: {service, at, state, ...} beside that save; nil, why
--     C.find(path, service, at)                  -- the record kept beside that save for that service and time
--     C.day_seconds(year, day_of_year, seconds)  -- a time of day as the saves have it

local C = {}

C.HEAD = 16384                  -- bytes read from the start of a save
C.TICKS = 1e7                   -- the game's time is in ticks of 100 ns
C.SAME = 0.5                    -- s: a record is for a save made within this of its time

----------------------------------------------------------------------------------------------------
-- Reading a save's start (Unreal's GVAS: a header, then tagged properties, each name and type written out)

-- An FString at `pos`: the string (ASCII of a UTF-16 one) and the position after it.
local function fstring(s, pos)
    local n
    n, pos = string.unpack("<i4", s, pos)
    if n == 0 then return "", pos end
    if n > 0 then
        if n > 4096 or pos + n - 1 > #s then error("past the end") end
        return s:sub(pos, pos + n - 2), pos + n
    end
    n = -n
    if n > 4096 or pos + 2 * n - 1 > #s then error("past the end") end
    local chars = {}
    for i = 0, n - 2 do
        local c = string.unpack("<I2", s, pos + 2 * i)
        chars[#chars + 1] = c < 128 and string.char(c) or "?"
    end
    return table.concat(chars), pos + 2 * n
end

-- The tagged property at `pos`: {name, type, struct (a struct's type), size, value = where its value starts} and
-- the position after it; nil at the "None" that ends a list of them.
local function tag(s, pos)
    local name
    name, pos = fstring(s, pos)
    if name == "None" then return nil, pos end
    local t = { name = name }
    t.type, pos = fstring(s, pos)
    t.size, pos = string.unpack("<i4", s, pos)
    pos = pos + 4                                         -- array index
    local ty, _ = t.type, nil
    if ty == "StructProperty" then
        t.struct, pos = fstring(s, pos)
        pos = pos + 16                                    -- the struct's guid
    elseif ty == "BoolProperty" then
        pos = pos + 1                                     -- its value
    elseif ty == "ByteProperty" or ty == "EnumProperty" or ty == "ArrayProperty" or ty == "SetProperty" then
        _, pos = fstring(s, pos)
    elseif ty == "MapProperty" then
        _, pos = fstring(s, pos)
        _, pos = fstring(s, pos)
    end
    local has_guid = s:byte(pos)
    if has_guid == nil or t.size < 0 then error("past the end") end
    pos = pos + 1 + (has_guid ~= 0 and 16 or 0)
    t.value = pos
    return t, pos + t.size
end

-- (service, time of day it was saved at) from the start of a save; nil and why if they aren't there.
function C.header(s)
    if s:sub(1, 4) ~= "GVAS" then return nil, "not a save game" end
    local ok, service, at = pcall(function()
        local pos = 5 + 4 + 4 + 2 + 2 + 2 + 4             -- save and package versions, the engine's version
        local _, format, count
        _, pos = fstring(s, pos)                          -- ... and branch
        format, count, pos = string.unpack("<i4i4", s, pos)
        if format ~= 3 then error("custom versions in format " .. format) end
        pos = pos + 20 * count                            -- custom versions: a guid and a number each
        _, pos = fstring(s, pos)                          -- the save's class
        local service, at
        while true do
            local t
            t, pos = tag(s, pos)
            if t == nil then break end
            if t.name == "CurrentTimetableService" and t.type == "NameProperty" then
                service = fstring(s, t.value)
            elseif t.name == "TODSettings" and t.type == "StructProperty" then
                local p, u = t.value, nil
                repeat
                    u, p = tag(s, p)
                    if u and u.name == "LocalDateTime" and u.struct == "DateTime" then
                        at = string.unpack("<i8", s, u.value) / C.TICKS
                    end
                until u == nil
            end
            if service and at then return service, at end
        end
        error("no service and time in it")
    end)
    if not ok then return nil, (tostring(service):gsub("^.-:%d+: ", "")) end
    return service, at
end

-- (service, time of day) of a save file; nil and why if it can't be read (the game writing it, say).
function C.read_header(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local s = f:read(C.HEAD) or ""
    local service, at = C.header(s)
    if not service and #s == C.HEAD then                 -- its start longer than usual
        s = s .. (f:read(C.HEAD * 3) or "")
        service, at = C.header(s)
    end
    f:close()
    return service, at
end

-- What kind of save a file is, for the log.
function C.kind(path)
    return path:find("Checkpoint", 1, true) and "checkpoint" or "save"
end

----------------------------------------------------------------------------------------------------
-- Time

local function days_before(year)
    local y = year - 1
    return 365 * y + y // 4 - y // 100 + y // 400
end

-- Seconds since the year 1 (as the game's saves time things) of `seconds` into day `day_of_year` (1 = 1 January).
function C.day_seconds(year, day_of_year, seconds)
    return (days_before(math.floor(year)) + math.floor(day_of_year) - 1) * 86400.0 + seconds
end

-- Seconds since the year 1 from a date and time written out ("2025.03.05-19.06.42", "2025-03-05T19:06:42.105Z":
-- the numbers in it in that order); nil if it isn't one.
function C.parse_date(text)
    local n = {}
    for digits in tostring(text):gmatch("%d+") do n[#n + 1] = digits end
    if #n < 6 then return nil end
    local y, mo, d, h, mi, s = tonumber(n[1]), tonumber(n[2]), tonumber(n[3]), tonumber(n[4]), tonumber(n[5]),
        tonumber(n[6])
    if y < 1000 or mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or s > 60 then return nil end
    local leap = (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
    local before = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 }
    local day = before[mo] + d + ((leap and mo > 2) and 1 or 0)
    local frac = n[7] and tonumber("0." .. n[7]) or 0
    return C.day_seconds(y, day, h * 3600 + mi * 60 + s + frac)
end

-- "19:06:42"
function C.clock_text(at)
    local s = math.floor(at % 86400)
    return string.format("%02d:%02d:%02d", s // 3600, s // 60 % 60, s % 60)
end

-- "2025-03-05 19:06:42"
function C.date_text(at)
    local days = math.floor(at / 86400)
    local y = math.floor(days / 365.2425) + 1
    while days_before(y) > days do y = y - 1 end
    while days_before(y + 1) <= days do y = y + 1 end
    local day = days - days_before(y)
    local leap = (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
    local months = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    local m = 1
    while m < 12 and day >= months[m] do
        day = day - months[m]
        m = m + 1
    end
    return string.format("%04d-%02d-%02d %s", y, m, day + 1, C.clock_text(at))
end

----------------------------------------------------------------------------------------------------
-- The comfort kept beside a save: a Lua table in a file of its own

local function is_name(k)
    return type(k) == "string" and k:match("^[%a_][%w_]*$") ~= nil
end

local function literal(v, indent)
    local t = type(v)
    if t == "number" then
        if v ~= v then return "0/0" end
        if v == math.huge then return "1/0" end
        if v == -math.huge then return "-1/0" end
        if math.type(v) == "integer" then return tostring(v) end
        return string.format("%.17g", v)
    elseif t == "string" then
        return string.format("%q", v)
    elseif t == "boolean" then
        return tostring(v)
    elseif t ~= "table" then
        return "nil"
    end
    local n = #v
    local keys = {}
    for k in pairs(v) do
        if not (math.type(k) == "integer" and k >= 1 and k <= n) then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts, nested = {}, false
    for i = 1, n do
        parts[#parts + 1] = literal(v[i], indent .. "    ")
        nested = nested or type(v[i]) == "table"
    end
    for _, k in ipairs(keys) do
        local key = is_name(k) and k or ("[" .. literal(k, "") .. "]")
        parts[#parts + 1] = key .. " = " .. literal(v[k], indent .. "    ")
        nested = nested or type(v[k]) == "table"
    end
    if #parts == 0 then return "{}" end
    if not nested then return "{ " .. table.concat(parts, ", ") .. " }" end
    local inner = indent .. "    "
    return "{\n" .. inner .. table.concat(parts, ",\n" .. inner) .. ",\n" .. indent .. "}"
end

-- A record as its file's text, and back (nil if it isn't one).
function C.text(record)
    return "-- The comfort HUD's comfort so far, kept with the game's save beside it.\nreturn " .. literal(record, "")
        .. "\n"
end

function C.parse(text)
    local fn = load(text, "=comfort", "t", {})
    if not fn then return nil end
    local ok, r = pcall(fn)
    if ok and type(r) == "table" and type(r.state) == "table" and type(r.at) == "number" and r.service ~= nil then
        return r
    end
    return nil
end

-- The file beside a save that the comfort is kept in.
function C.comfort_path(path)
    return (path:gsub("%.sav$", "")) .. ".comfort"
end

-- Keeps `record` beside the save at `path`. true, or nil and why.
function C.keep(path, record)
    local target = C.comfort_path(path)
    local new = target .. ".new"
    local f, err = io.open(new, "wb")
    if not f then return nil, err end
    local ok, werr = f:write(C.text(record))
    f:close()
    if not ok then return nil, werr end
    os.remove(target)                                    -- Windows won't rename over a file
    local renamed, rerr = os.rename(new, target)
    if not renamed then return nil, rerr end
    return true
end

-- The record kept beside the save at `path`, whatever it's for; nil if there's none.
function C.kept(path)
    local f = io.open(C.comfort_path(path), "rb")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return text and C.parse(text) or nil
end

-- The record kept beside that save, if it's for the save there now: made on `service` at `at`.
function C.find(path, service, at)
    local r = C.kept(path)
    if r and r.service == service and math.abs(r.at - at) < C.SAME then return r end
    return nil
end

return C
