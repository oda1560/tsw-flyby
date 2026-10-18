-- Comfort HUD for Train Sim World 7, as a UE4SS Lua mod.
-- Puts how many passengers are aboard and how comfortable their ride has been into the objective box of the game's
-- header bar ("Wait until 19:06:00 · 62 aboard · comfort 87"). While braking or speeding up gets firm or harsh for
-- them, or the train is about to stop with the brake still hard on, a warning takes the objective's place, then
-- how the stop went or what the ride lost. The rules are tsw-joystick's passenger comfort (comfort_judge.lua).
-- Press = to switch it off and on, F11 for a report. Everything it does is written to UE4SS.log, lines starting
-- [Comfort].
--
-- The comfort so far goes with the game's saves: each time the game writes its save or its checkpoint, the rides
-- done and the ride going on are kept in a .comfort file beside it (comfort_saves.lua), and when a save is loaded
-- (the game's time of day jumps to just after one) the comfort goes back to what was kept with it.
--
-- It reads everything from the game itself: no window over the game and no requests to the game's web API. Each
-- frame it asks the game two things, the time and the train's velocity; the rest is its own arithmetic, and the
-- objective box's text is only written when the words change. Searches through all the game's objects take
-- milliseconds, so they're only made when something changes (a drive loading), never on a timer.
--
-- The game functions it calls, and their parameters, were read from the game's own reflection tables in
-- TrainSimWorld.exe: RailVehicle GetFormation(EActorConnectionIterationMode) -> the vehicles of the train;
-- PassengerCargoModelComponent GetPassengerCount() -> int; PlayerController GetDrivenServiceName(out FName);
-- PhysicsFunctionLibrary GetSimulationNodeParameterAsBool(context, {{component, node}, {pin, name}}), the way the
-- game's own blueprints read a train's simulation (pin -1, by name); TS2GameplayFunctionLibrary GetDateTime(context,
-- local) -> the time of day, as the header bar's clock reads it.

local UEHelpers = require("UEHelpers")
local J = require("comfort_judge")
local T = require("hud_text")
local S = require("comfort_settings")
local C = require("comfort_saves")

-- The game's save files, found by install.py as it installed the mod (comfort_save_files.lua): the comfort is kept
-- beside them.
local SAVE_FILES = {}
do
    local ok, files = pcall(require, "comfort_save_files")
    if ok and type(files) == "table" then
        for _, path in ipairs(files) do
            if type(path) == "string" then SAVE_FILES[#SAVE_FILES + 1] = path end
        end
    end
end

local FEED_EVERY = 1 / 15       -- s between readings for the judge (tsw-joystick read 15 a second)
local LOOK_EVERY = 1.0          -- s between looking at the train and the objective box
local SERVICE_EVERY = 5.0       -- s between reading the service's name
local COUNT_EVERY = 5.0         -- s between counting the passengers while stopped (they don't change on the move)
local CHECK_EVERY = 2.0         -- s between checking the game hasn't written over the box without a hook seeing it
local REFIND_EVERY = 5.0        -- s at least between searches for the player or the objective box
local DEBUG_EVERY = 5.0
local SAVE_EVERY = 1.0          -- s between reading the start of the game's save files (saving and quitting, the game
                                -- is gone 2 s later)
local CLOCK_EVERY = 30.0        -- s between reading the game's time of day while the drive goes on (a new one: at once)
local JUMP_SECONDS = 30.0       -- the time of day on more than this ahead of the wall clock: it jumped
local RESUME_SECONDS = 120.0    -- a save is the one loaded if the time of day jumped to at most this after it
local COPY_SECONDS = 15.0       -- a save is kept with the comfort read up to this long (game) after it was made ...
local STOPPING_SECONDS = 10.0   -- ... once the stop going on as it was made has been judged, waiting at most this long
local PENDING_SECONDS = 60.0    -- a save the drive doesn't come to the time of in this long isn't kept with it
local MAX_CARS = 16
local WHITE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
local FRONT_TO_BACK = 0         -- EActorConnectionIterationMode::FrontToBack: GetFormation's whole train

local OBJECTIVE_CLASS = "/Script/TS2Prototype.TS2HUDObjectiveWidget"
local WIDGET_CLASSES = { "HUDObjectiveWidget_C", "HUDObjectiveWidget_Minimal_C" } -- the full and the minimal HUD
local WIDGET_HOOKS = {
    "/Game/Core/Assets/HUD/Widgets/Objectives/HUDObjectiveWidget.HUDObjectiveWidget_C:UpdateObjectiveText",
    "/Game/Core/Assets/HUD/Widgets/Objectives/HUDObjectiveWidget.HUDObjectiveWidget_C:ShowObjective",
    "/Game/Core/Assets/HUD/Widgets/Objectives/HUDObjectiveWidget_Minimal.HUDObjectiveWidget_Minimal_C:UpdateObjectiveText",
    "/Game/Core/Assets/HUD/Widgets/Objectives/HUDObjectiveWidget_Minimal.HUDObjectiveWidget_Minimal_C:ShowObjective",
}
-- The game's function libraries that have the static functions used here
local LIBRARIES = { "PhysicsFunctionLibrary", "TS2GameplayFunctionLibrary", "TS2BlueprintSupportLibrary",
                    "TSWVehicleFunctionLibrary", "TS2VehicleControlLibrary", "DTGFunctionLibrary" }
-- The simulation nodes that apply a train's own holding brake (tsw-joystick's HOLD_NODES): a Class 350's comes on
-- at 0.62 m/s with no power and brakes it 0.9-1.0 m/s² with the handle off. A train has only some of them.
local SIM_COMPONENT = "Simulation"
local HOLD_NODES = { "DirectBrakeControlPowered", "DirectBrakeControlUnpowered", "DirectBrakeControl", "EP_BrakeControl" }
local HOLD_PARAMETER = "BrakeHoldActive"

local function log(fmt, ...)
    print("[Comfort] " .. string.format(fmt, ...) .. "\n")
end

local function valid(o)
    if o == nil then return false end
    local ok, yes = pcall(function() return o:IsValid() end)
    return ok and yes == true
end

local function same(a, b)
    return valid(a) and valid(b) and a:GetAddress() == b:GetAddress()
end

local function name_of(o)
    if not valid(o) then return "nothing" end
    local ok, name = pcall(function() return o:GetFullName() end)
    return ok and name or "?"
end

-- "RVM_LIRREX_Class350_C_2147470330" instead of the class and the whole map path
local function short_name(o)
    local name = name_of(o)
    return name:match("[%.:]([^%.:]+)$") or name
end

local function class_name(o)
    local ok, name = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and name or "?"
end

-- An FText / FString / FName the game gave, as a Lua string; nil if it isn't one.
local function text_of(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    return nil
end

local text_lib = nil
local function make_text(s)
    if FText then
        local ok, t = pcall(FText, s)
        if ok and t ~= nil then return t end
    end
    text_lib = text_lib or StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    return text_lib:Conv_StringToText(s)
end

local function fname(s)
    if FName then
        local ok, n = pcall(FName, s, EFindName and EFindName.FNAME_Add or nil)
        if ok and n ~= nil then return n end
    end
    return s
end

local function attach_chain(actor)
    local chain = {}
    for _ = 1, 8 do
        local ok, parent = pcall(function() return actor:GetAttachParentActor() end)
        if not ok or not valid(parent) then break end
        chain[#chain + 1] = parent
        actor = parent
    end
    return chain
end

local function is_a(actor, class)
    if not valid(class) then return false end
    local ok, yes = pcall(function() return actor:IsA(class) end)
    return ok and yes == true
end

-- Goes through a TArray the game gave (or a Lua table), calling fn(element).
local function each_in(arr, fn)
    local ok, for_each = pcall(function() return arr.ForEach end)
    if ok and for_each then
        arr:ForEach(function(_, elem) fn(elem:get()) end)
    else
        for _, v in ipairs(arr) do fn(v) end
    end
end

-- Calls a game function whose last parameter is an out parameter: UE4SS gives that back in the table passed for it,
-- or after the return value. (ok, return value, out value), or (false, error).
local function call_out(obj, name, ...)
    local out = {}
    local args = table.pack(...)
    args.n = args.n + 1
    args[args.n] = out
    local r = table.pack(pcall(function() return obj[name](obj, table.unpack(args, 1, args.n)) end))
    if not r[1] then return false, r[2] end
    local value = r[3]
    if value == nil then
        for _, v in pairs(out) do
            value = v
            break
        end
    end
    return true, r[2], value
end

local classes = {}
local function class(path)
    local c = classes[path]
    if not valid(c) then
        c = StaticFindObject(path)
        classes[path] = c
    end
    return c
end

-- The class default object of the game's function library that has the static function `name` (called through it).
local libraries = {}
local function library_for(name)
    local lib = libraries[name]
    if lib ~= nil then return lib or nil end
    for _, cls in ipairs(LIBRARIES) do
        if valid(StaticFindObject("/Script/TS2Prototype." .. cls .. ":" .. name)) then
            local cdo = StaticFindObject("/Script/TS2Prototype.Default__" .. cls)
            if valid(cdo) then
                libraries[name] = cdo
                return cdo
            end
        end
    end
    libraries[name] = false
    return nil
end

local state = {
    on = true, loop = nil,
    pc = nil, pc_stale = true, pc_looked = -math.huge, statics = nil,
    drivable = nil, view = nil, service = nil, service_at = -math.huge, aboard = false,
    cars = nil, vehicles = nil, passenger_train = false, passengers = nil, counted_at = -math.huge,
    count_failed = false, hold_refs = nil, hold_failed = false, hold = nil,
    samples = {}, speed = 0.0, acc = nil, fed_t = nil,
    judge = J.new(),
    info = { passengers = nil, score = nil, cost = nil, panel = nil },   -- what the box shows, from the last reading
    looked_at = -math.huge, fed_at = -math.huge, checked_at = -math.huge, debug_at = -math.huge, hud_at = -math.huge,
    stop = nil,                 -- the stop the train is at: {station}
    slow_change = false,        -- the objective moved on or the passengers changed since the train last went fast
    work = { total = 0.0, frames = 0, most = 0.0 },
}

local hud = {
    widgets = {},               -- address -> {obj, visible, game_title, game_line (the game's own), title, colour,
                                --   line (what the mod put there, nil: the game's own)}
    hooks = nil,                -- hook paths registered, once the widgets' blueprint is loaded
    hook_calls = 0, dirty = false, searched_at = -math.huge, notified = false,
    game_title = nil,           -- the objective's name as the game has it, for telling a stop at a station
}

----------------------------------------------------------------------------------------------------
-- Time

-- Seconds by the wall clock, for how long things stay up (on Windows, Lua's os.clock is the time since the game
-- started, in milliseconds; the game's own real time starts again with each drive).
local function real_time()
    return os.clock()
end

-- The game's own time: it stands still while paused and goes slower than the wall clock below 20 fps.
local function game_time()
    local ok, t = pcall(function() return state.statics:GetTimeSeconds(state.pc) end)
    if ok and type(t) == "number" then return t end
    return nil
end

----------------------------------------------------------------------------------------------------
-- The train

-- The player controller. UEHelpers finds it by going through every object in the game, so it's kept, and only
-- looked for again when the game makes a new one (loading a drive) or the one kept has gone.
local function player_controller(now)
    if valid(state.pc) and not state.pc_stale then return state.pc end
    if now - state.pc_looked < REFIND_EVERY then return valid(state.pc) and state.pc or nil end
    state.pc_looked = now
    local pc = UEHelpers.GetPlayerController()
    state.pc_stale = false
    if valid(pc) then state.pc = pc else state.pc = nil end
    state.statics = UEHelpers.GetGameplayStatics()
    return state.pc
end

-- The rail vehicle you drive: the model half TSW splits each vehicle into (RVM_..., at the world's origin).
local function find_drivable(pc)
    local ok, d = pcall(function() return pc:GetCurrentLocalDrivableActor(pc:GetWorld()) end)
    if ok and valid(d) then return d end
    local rv = class("/Script/TS2Prototype.RailVehicle")
    for _, a in ipairs(attach_chain(pc.Pawn)) do
        if is_a(a, rv) then return a end
    end
    return nil
end

-- The moving half of the vehicle the driver is in (RVV_...): its velocity is the train's.
local function find_view(pc)
    local cls = class("/Script/TS2Prototype.RailVehicleView")
    for _, a in ipairs(attach_chain(pc.Pawn)) do
        if is_a(a, cls) then return a end
    end
    return nil
end

local function service_name(pc)
    local ok, _, name = call_out(pc, "GetDrivenServiceName")
    local s = ok and text_of(name) or nil
    if s == nil or s == "" or s == "None" then return nil end
    return s
end

-- The vehicles of your train, front to back (the game's GetFormation). nil and why if it won't say.
local function formation(drivable)
    local ok, arr = pcall(function() return drivable:GetFormation(FRONT_TO_BACK) end)
    if not ok or arr == nil then return nil, ok and "it gave nothing" or tostring(arr) end
    local list, mine = {}, false
    local me = drivable:GetAddress()
    local ok2, err = pcall(each_in, arr, function(v)
        if valid(v) then
            list[#list + 1] = v
            if v:GetAddress() == me then mine = true end
        end
    end)
    if not ok2 then return nil, tostring(err) end
    if not mine then return nil, string.format("its %d vehicles left out the one you drive", #list) end
    return list
end

local function cargo_of(vehicle)
    local ok, c = pcall(function()
        return vehicle:GetComponentByClass(class("/Script/TS2Prototype.PassengerCargoModelComponent"))
    end)
    if ok and valid(c) then return c end
    return nil
end

-- The passenger cars of your train: their PassengerCargoModel components. From the game's list of your train;
-- if it won't give one, every passenger car in the world is looked through (a search), keeping those the game says
-- are on the player's train, or else only the one you drive.
local function find_cars(drivable, quiet)
    local started = os.clock()
    local vehicles, why = formation(drivable)
    local cars, how = {}, nil
    if vehicles then
        for _, v in ipairs(vehicles) do
            local c = cargo_of(v)
            if c and #cars < MAX_CARS then cars[#cars + 1] = c end
        end
        how = string.format("the game's list of your train, %d vehicle%s", #vehicles, #vehicles == 1 and "" or "s")
    else
        local all = FindAllOf("PassengerCargoModelComponent") or {}
        local mine = function(o) return same(o, drivable) end
        how = string.format("only the vehicle you drive, of %d in the world: the game wouldn't list your train (%s)",
            #all, why)
        local lib = library_for("IsConsistPlayerDriven")
        if lib then
            local ok, yes = call_out(lib, "IsConsistPlayerDriven", drivable)
            if ok and yes == true then
                mine = function(o)
                    local ok2, y = call_out(lib, "IsConsistPlayerDriven", o)
                    return ok2 and y == true
                end
                how = string.format("the player's trains, of %d in the world: the game wouldn't list your train (%s)",
                    #all, why)
            end
        end
        for _, c in ipairs(all) do
            local ok, owner = pcall(function() return c:GetOwner() end)
            if ok and valid(owner) and mine(owner) and #cars < MAX_CARS then cars[#cars + 1] = c end
        end
    end
    state.vehicles = vehicles and #vehicles or nil
    if not quiet then
        log("%d passenger car%s on your train (%s); looked in %.0f ms", #cars, #cars == 1 and "" or "s", how,
            (os.clock() - started) * 1000)
    end
    return cars
end

-- The passengers aboard, nil if they can't be counted.
local function count_passengers(cars)
    local total, counted, err = 0, false, nil
    for _, c in ipairs(cars) do
        local ok, n = pcall(function() return c:GetPassengerCount() end)
        if ok and type(n) == "number" then
            total, counted = total + n, true
        else
            err = ok and ("it gave " .. type(n)) or tostring(n)
        end
    end
    if not counted and err and not state.count_failed then
        state.count_failed = true
        log("can't count the passengers (%s): comfort still judged, passengers not shown", err)
    end
    return counted and math.floor(total + 0.5) or nil
end

-- The passengers the judge goes by: how many, 0 on a passenger train that can't be counted, nil if it's not one.
local function judged_passengers()
    if state.passengers ~= nil then return state.passengers end
    return state.passenger_train and 0 or nil
end

-- The train's own holding brake, as the game's blueprints read a simulation: the parameter references for the
-- nodes this train has. Empty: it has none.
local function find_hold(drivable)
    local lib = library_for("GetSimulationNodeParameterAsBool")
    if not lib then
        log("can't read the train's own holding brake: the game's GetSimulationNodeParameterAsBool wasn't found")
        return {}
    end
    local exists = library_for("DoesSimulationNodeExist")
    local refs, names = {}, {}
    for _, node in ipairs(HOLD_NODES) do
        local has = true
        if exists then
            local ok, yes = pcall(function()
                return exists:DoesSimulationNodeExist(drivable,
                    { ComponentName = fname(SIM_COMPONENT), NodeName = fname(node) })
            end)
            has = ok and yes == true
        end
        if has then
            refs[#refs + 1] = { NodeReference = { ComponentName = fname(SIM_COMPONENT), NodeName = fname(node) },
                                ParameterReference = { PinIndex = -1, Name = fname(HOLD_PARAMETER) } }
            names[#names + 1] = node
        end
    end
    log("the train's own holding brake: %s", #names > 0 and table.concat(names, ", ") or "none")
    return refs
end

-- Whether the train's own holding brake is on (nil: it hasn't one). Only read while the train is coming to a stop or
-- moving off, slower than MOVING, where it matters: standing, it's as it was.
local function holding()
    local refs = state.hold_refs
    if refs == nil or #refs == 0 then return nil end
    if state.speed >= J.MOVING then return false end
    if state.speed < J.STOPPED and state.hold ~= nil then return state.hold end
    local lib = library_for("GetSimulationNodeParameterAsBool")
    local read = false
    for _, ref in ipairs(refs) do
        local ok, on = pcall(function() return lib:GetSimulationNodeParameterAsBool(state.drivable, ref) end)
        if ok and type(on) == "boolean" then
            read = true
            if on then return true end
        elseif not state.hold_failed then
            state.hold_failed = true
            log("can't read the train's own holding brake: %s", tostring(on))
        end
    end
    if read then return false end
    return nil
end

----------------------------------------------------------------------------------------------------
-- Speed and acceleration

-- The train's speed, read each frame with the game's time: the acceleration is the change of speed over the last
-- AccelWindow seconds (a line fitted through the readings), in the game's own time like the game's HUD.
local function sample(t, v)
    local s = state.samples
    local n = #s
    if n > 0 and t <= s[n][1] then
        if t == s[n][1] then return end    -- paused, or the same frame
        s = {}                              -- the game's time went back: another drive
        state.samples = s
    end
    s[#s + 1] = { t, v }
    while s[1][1] < t - S.AccelWindow do table.remove(s, 1) end
    state.speed = v
end

local function acceleration()
    local s = state.samples
    local n = #s
    if n < 3 or s[n][1] - s[1][1] < S.AccelWindow / 2 then return nil end
    local mt, mv = 0.0, 0.0
    for _, p in ipairs(s) do mt, mv = mt + p[1], mv + p[2] end
    mt, mv = mt / n, mv / n
    local num, den = 0.0, 0.0
    for _, p in ipairs(s) do
        num = num + (p[1] - mt) * (p[2] - mv)
        den = den + (p[1] - mt) ^ 2
    end
    if den <= 0 then return nil end
    return num / den
end

----------------------------------------------------------------------------------------------------
-- The objective box

-- The objective box on screen, not a blueprint's default or a template in the HUD blueprint's own widget tree
-- ("/Game/.../HUD_Widget.HUD_Widget_C:WidgetTree.HUDObjectiveWidget": straight under a class, a name ending _C).
-- The one on screen is under the game's player or game instance.
local function is_runtime_widget(w)
    local full = name_of(w)
    if full:find("Default__", 1, true) then return false end
    local top = full:match("^%S+ [^.:]+%.([^.:]+)")
    return top ~= nil and not top:find("_C$")
end

-- The game's own text in the box: the objective it has set (it shows it a moment later).
local function read_game_text(rec)
    local w = rec.obj
    rec.game_title, rec.game_line = text_of(w.ObjectiveTitle), text_of(w.ObjectiveDescription)
end

local function remember_widget(w)
    if not valid(w) then return end
    local cls = class_name(w)
    local known = false
    for _, c in ipairs(WIDGET_CLASSES) do
        if c == cls then known = true end
    end
    if not known or not is_runtime_widget(w) then return end
    local key = w:GetAddress()
    if not hud.widgets[key] then
        hud.widgets[key] = { obj = w, visible = true }
        log("found the objective box: %s", short_name(w))
    end
end

local function widgets()
    local list = {}
    for key, rec in pairs(hud.widgets) do
        if valid(rec.obj) then list[#list + 1] = rec else hud.widgets[key] = nil end
    end
    return list
end

local function search_widgets(now, why)
    hud.searched_at = now
    local started = os.clock()
    for _, cls in ipairs(WIDGET_CLASSES) do
        for _, w in ipairs(FindAllOf(cls) or {}) do remember_widget(w) end
    end
    log("looked for the objective box (%s): %d found in %.0f ms", why, #widgets(), (os.clock() - started) * 1000)
end

local NOTHING = {}

-- What the box should say: {title, colour, line} (nil each: the game's own). From what was read at the last
-- reading and the game's text kept in `rec`: no game calls.
local function wanted(rec)
    if not state.on or not state.aboard then return NOTHING end
    local info = state.info
    local take = S.Warnings and T.takeover(info.panel, info, S) or nil
    if take then return take end
    return { line = T.normal_line(rec.game_line, info, S) }
end

local function set_text(tb, s)
    tb:SetText(make_text(s))
end

local function set_colour(tb, c)
    tb:SetColorAndOpacity({ SpecifiedColor = c, ColorUseRule = 0 })
end

local function original_colour(tb)
    local ok, c = pcall(function()
        local sc = tb.ColorAndOpacity.SpecifiedColor
        return { R = sc.R, G = sc.G, B = sc.B, A = sc.A }
    end)
    return ok and c or WHITE
end

-- Puts what the box should say into it, writing only what changed. `force`: the game may just have written over it.
local function apply(rec, force)
    local want = rec.want or NOTHING
    if not force and want.title == rec.title and want.colour == rec.colour and want.line == rec.line then return end
    local w = rec.obj
    local name_tb, line_tb = w.Name, w.Description
    if want.title then
        if force or rec.title ~= want.title then
            set_text(name_tb, want.title)
            rec.title = want.title
        end
        if force or rec.colour ~= want.colour then
            rec.original = rec.original or original_colour(name_tb)
            set_colour(name_tb, want.colour)
            rec.colour = want.colour
        end
    else
        if rec.title then
            set_text(name_tb, rec.game_title or "")
            rec.title = nil
        end
        if rec.colour then
            set_colour(name_tb, rec.original or WHITE)
            rec.colour = nil
        end
    end
    if want.line then
        if force or rec.line ~= want.line then
            set_text(line_tb, want.line)
            rec.line = want.line
        end
    elseif rec.line then
        set_text(line_tb, rec.game_line or "")
        rec.line = nil
    end
end

-- Once the game has its objective box, the moments it writes its own text in it: put ours back straight away,
-- with the objective it has just set.
local function hook_widgets()
    if hud.hooks then return end
    hud.hooks = {}
    for _, path in ipairs(WIDGET_HOOKS) do
        local ok = pcall(RegisterHook, path, function(self)
            hud.hook_calls = hud.hook_calls + 1
            if not state.on then return end
            hud.dirty = true
            local okw, w = pcall(function() return self:get() end)
            local rec = okw and valid(w) and hud.widgets[w:GetAddress()] or nil
            if rec and rec.visible then
                local ok2, err = pcall(function()
                    read_game_text(rec)
                    rec.want = wanted(rec)
                    apply(rec, true)
                end)
                if not ok2 and not rec.hook_failed then
                    rec.hook_failed = true
                    log("can't put the text back as the game writes it: %s", tostring(err))
                end
            end
        end)
        if ok then hud.hooks[#hud.hooks + 1] = path:match(":(.*)$") .. " (" .. path:match("%.([%w_]+)_C:") .. ")" end
    end
    log("watching the objective box for the game's own text: %s",
        #hud.hooks > 0 and table.concat(hud.hooks, ", ") or "can't, checking it every 2 s instead")
end

-- Text without its "·" and "²", which may not come back from the game as they went in.
local function plain(s)
    return s and s:gsub("[\128-\255]", "") or nil
end

-- The game wrote over the box without a hook seeing it (or with no hooks): what it says isn't what was put there.
local function overwritten(rec)
    local w = rec.obj
    if rec.title and plain(text_of(w.Name:GetText())) ~= plain(rec.title) then return true end
    if rec.line and plain(text_of(w.Description:GetText())) ~= plain(rec.line) then return true end
    return false
end

local function update_hud(now)
    local check = now - state.checked_at >= CHECK_EVERY
    if check then state.checked_at = now end
    local force = hud.dirty
    hud.dirty = false
    for _, rec in pairs(hud.widgets) do
        if rec.visible then
            local ok, err = pcall(function()
                rec.want = wanted(rec)
                local redo = force or (check and (rec.title or rec.line) and overwritten(rec))
                if redo then read_game_text(rec) end
                apply(rec, redo)
            end)
            if not ok and not rec.failed then
                rec.failed = true
                log("can't write in the objective box %s: %s", short_name(rec.obj), tostring(err))
            end
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Stops and rides

local function say(event)
    local what = event[1]
    if what == "stop" then
        log("%s, braking %.1f m/s² as it stopped, %s", event[2] and "jolt on stopping" or "smooth stop", event[3],
            T.aboard(state.passengers) or "passengers not counted")
    elseif what == "harsh" then
        log("harsh %s, %.1f m/s²", event[2] == "brake" and "braking" or "acceleration", event[3])
    elseif what == "hold" then
        log("the train's own holding brake came on at %.2f m/s; braking over %.2f m/s² from there isn't counted",
            event[2], event[3])
    end
end

-- Whether a stop is at a station: as the train comes in or while it stands, the game moves the objective on (to
-- loading passengers, say) or the passengers change. Leaving a station ends the ride to it; a stop at a signal
-- doesn't. `state.stop`: {station = whether it is} from when the train stopped until it's away again.
local function follow_stops(v)
    local stop = state.stop
    if v < J.STOPPED then
        if stop == nil then
            stop = { station = state.slow_change == true }
            state.stop = stop
        end
        stop.station = stop.station or state.slow_change == true
    elseif v > J.MOVING then
        state.slow_change = false
        if stop == nil then return end
        state.stop = nil
        if stop.station then
            local judge = state.judge
            local ride = judge:new_leg(state.service)
            if ride then
                local lost = {}
                for _, loss in ipairs(ride.lost) do
                    if loss[1] >= 0.5 then lost[#lost + 1] = string.format("%s %s -%.0f", loss[2], loss[3], loss[1]) end
                end
                log("the ride to the stop marked %.0f%s, %d passengers; %s so far %.0f over %d ride%s", ride.mark,
                    #lost > 0 and (" (" .. table.concat(lost, ", ") .. ")") or "", ride.passengers,
                    tostring(state.service), J.score(judge.done) or 100, #judge.done, #judge.done == 1 and "" or "s")
            end
        end
    end
end

local function feed(now, t)
    state.fed_at = now
    if t == state.fed_t then return end       -- the game is paused: nothing to judge
    local acc = acceleration()
    if acc == nil then return end
    state.fed_t, state.acc = t, acc
    local judge = state.judge
    state.hold = holding()
    for _, event in ipairs(judge:feed(now, state.speed, acc, judged_passengers(), t, nil, false, state.hold)) do
        say(event)
    end
    follow_stops(state.speed)
    local info = state.info
    info.passengers, info.score, info.panel = state.passengers, judge:live_score(), judge:panel()
    info.cost = judge.episode and judge.episode.cost or nil
end

----------------------------------------------------------------------------------------------------
-- The game's saves: each time the game writes one, the comfort so far is kept beside it; when one is loaded, the
-- comfort goes back to what was kept with it. Which save was loaded is told by the game's time of day: it jumps to
-- just after when that save was made. The rules are tsw-joystick's (SaveCopies, ComfortWatch.saves_step).

local saves = {
    files = {},                 -- each of the game's save files: path -> {service, at} as last read
    looked = false,             -- they've been read once
    read_at = -math.huge,
    day = nil,                  -- the game's time of day less its game time (s), measured on this drive
    day_at = -math.huge,        -- ... when (wall clock)
    t = nil,                    -- the game's time at the last look
    world = true,               -- another drive (or the mod just started): its time of day not read yet
    world_at = -math.huge,      -- ... when it was first read (wall clock)
    clock = nil, clock_at = nil,  -- the time of day at the last look, and the wall clock then
    jump = nil,                 -- the time of day jumped (a save loaded, another drive, the mod just started), until
                                --   the saves are looked at: {from = the time of day before, nil at the start}
    pending = {},               -- saves the game has written, to keep the comfort with once the drive's at their
                                --   time: path -> {service, at, seen (wall clock)}
    kept = 0, restores = 0,
    clock_failed = false, write_failed = false,
}

-- The game's time of day as its clock in the header bar has it (GetDateTime, local): what's in the FDateTime it gives
-- is read with the engine's maths library, the year, the day and the seconds into it. nil and why if it can't be.
local function day_from_datetime(pc)
    local lib = library_for("GetDateTime")
    if not lib then return nil, "GetDateTime wasn't found" end
    local m = class("/Script/Engine.Default__KismetMathLibrary")
    if not valid(m) then return nil, "KismetMathLibrary wasn't found" end
    local ok, r = pcall(function()
        local dt = lib:GetDateTime(pc, true)
        return { m:GetYear(dt), m:GetDayOfYear(dt), m:GetTotalSeconds(m:GetTimeOfDay(dt)) }
    end)
    if not ok then return nil, "GetDateTime: " .. tostring(r) end
    local year, day, seconds = r[1], r[2], r[3]
    if type(year) ~= "number" or type(day) ~= "number" or type(seconds) ~= "number" or year < 1000 then
        return nil, string.format("GetDateTime gave year %s, day %s, %s s", tostring(year), tostring(day),
            tostring(seconds))
    end
    return C.day_seconds(year, day, seconds)
end

-- The same from the game's time of day written out (TimeOfDayBPLibrary GetLocalTimeOfDayAsString), to the second.
local function day_from_text()
    local lib = class("/Script/TimeOfDay.Default__TimeOfDayBPLibrary")
    if not valid(lib) then return nil, "TimeOfDayBPLibrary wasn't found" end
    local ok, s = pcall(function() return lib:GetLocalTimeOfDayAsString() end)
    if not ok then return nil, "GetLocalTimeOfDayAsString: " .. tostring(s) end
    local day = C.parse_date(text_of(s))
    if not day then return nil, string.format("GetLocalTimeOfDayAsString gave %q", tostring(text_of(s))) end
    return day
end

-- The game's time of day in seconds since the year 1, as its saves have it, and how it was read; nil and why if it
-- can't be.
local function read_day(pc)
    local day, why = day_from_datetime(pc)
    if day then return day, "GetDateTime" end
    local day2, why2 = day_from_text()
    if day2 then return day2, "GetLocalTimeOfDayAsString" end
    return nil, why .. "; " .. why2
end

-- The time of day now: the game's time and the difference measured on getting aboard and every CLOCK_EVERY seconds
-- after, so a look costs no calls in between. Notes when it jumps: back (a save loaded), on further than the wall
-- clock has gone (a later one), on another drive, or the first time it's read (the mod just started, maybe on one).
local function follow_clock(now)
    local t = game_time()
    if t == nil then return end
    if saves.t ~= nil and t < saves.t - 1.0 then                     -- another drive
        saves.world, saves.day, saves.day_at = true, nil, -math.huge
    end
    saves.t = t
    local every = CLOCK_EVERY
    if saves.day == nil then
        every = saves.clock_failed and CLOCK_EVERY or 0
    elseif now - saves.world_at < 15.0 then
        every = 5.0              -- read again soon after getting aboard, in case the game sets it a moment after
    end
    if now - saves.day_at >= every then
        saves.day_at = now
        local day, why = read_day(state.pc)
        if day then
            if saves.world then
                log("the game's time of day: %s (%s)", C.date_text(day), why)
                saves.world_at = now
            end
            saves.day, saves.clock_failed = day - t, false
        elseif not saves.clock_failed then
            saves.clock_failed = true
            log("can't read the game's time of day (%s): the comfort isn't kept with its saves", tostring(why))
        end
    end
    state.judge.day = saves.day
    if saves.day == nil then return end
    local clock, last = t + saves.day, saves.clock
    if saves.world or last == nil or clock < last - 1.0 or clock - last > now - saves.clock_at + JUMP_SECONDS then
        saves.jump = saves.jump or { from = last }
    end
    saves.world = false
    saves.clock, saves.clock_at = clock, now
end

-- ({path: {service, at}} of the save files there now, [those the game has written since the last look]).
local function read_saves()
    local found, written = {}, {}
    for _, path in ipairs(SAVE_FILES) do
        local service, at = C.read_header(path)
        local old = saves.files[path]
        if service then                  -- else being written, say: as it was until it reads
            if saves.looked and (old == nil or old.service ~= service or old.at ~= at) then
                written[#written + 1] = path
            end
            saves.files[path] = { service = service, at = at }
        end
        found[path] = saves.files[path]
    end
    saves.looked = true
    return found, written
end

local function so_far()
    local done = state.judge.done
    if #done == 0 then return "no rides done" end
    return string.format("%d ride%s done, comfort %.0f", #done, #done == 1 and "" or "s", J.score(done))
end

local function keep(path, service, at)
    local ok, err = C.keep(path, { service = service, at = at, state = state.judge:state(),
                                   station = state.stop and state.stop.station or nil,
                                   kept = os.date("%Y-%m-%d %H:%M:%S") })
    if ok then
        saves.kept = saves.kept + 1
        log("kept with the game's %s of %s at %s: %s", C.kind(path), service, C.clock_text(at), so_far())
    elseif not saves.write_failed then
        saves.write_failed = true
        log("can't keep the comfort beside the game's %s: %s", C.kind(path), tostring(err))
    end
end

-- Back to what was kept with a save that's been loaded: the rides done, the ride going on, and whether the train
-- was standing at a station (leaving it ends the ride to it).
local function restore(kept)
    local judge = state.judge
    judge:restore(kept.state)
    judge.day = saves.day
    if judge.service ~= nil then state.service = judge.service end
    state.stop = kept.station and { station = true } or nil
    state.info.score, state.info.panel = judge:live_score(), nil
    saves.restores = saves.restores + 1
end

-- The time of day jumped to `clock`. If one of the saves was made just before, that's the one loaded: the comfort
-- goes back to what was kept with it. Gone back with nothing kept for it, the rides from after it are dropped. What
-- to log, or nil.
local function resume(found, clock, jump)
    local near = {}
    for path, h in pairs(found) do
        if clock - h.at >= -2.0 and clock - h.at <= RESUME_SECONDS then near[#near + 1] = { path = path, save = h } end
    end
    table.sort(near, function(a, b) return a.save.at > b.save.at end)
    for _, n in ipairs(near) do
        local kept = C.find(n.path, n.save.service, n.save.at)
        if kept then
            restore(kept)
            return string.format("the game's %s of %s at %s loaded: back to %s", C.kind(n.path), n.save.service,
                C.clock_text(n.save.at), so_far())
        end
    end
    if jump.from ~= nil and clock < jump.from - 1.0 then
        local gone = state.judge:rewind(clock)
        saves.restores = saves.restores + 1
        return string.format("the game went back to %s, nothing kept with a save there: %d ride%s from after it "
            .. "dropped, %s", C.clock_text(clock), gone, gone == 1 and "" or "s", so_far())
    end
    if #near > 0 then
        return string.format("on the game's %s of %s at %s, nothing kept with it", C.kind(near[1].path),
            near[1].save.service, C.clock_text(near[1].save.at))
    end
    return nil
end

-- Once a look: keeps the comfort with a save the game has written, once the drive's at its time (or has gone, as
-- after saving and quitting); and once the time of day has jumped, puts the comfort back to what was kept with the
-- save it jumped to.
local function keep_with_saves(now)
    if not S.KeepWithSaves or #SAVE_FILES == 0 then return end
    if state.aboard then follow_clock(now) end
    if saves.jump == nil and now - saves.read_at < SAVE_EVERY then return end
    saves.read_at = now
    local found, written = read_saves()
    for _, path in ipairs(written) do
        local h = found[path]
        saves.pending[path] = { service = h.service, at = h.at, seen = now }
    end
    if saves.jump ~= nil then
        local jump = saves.jump
        saves.jump = nil
        local said = resume(found, saves.clock, jump)
        if said then log("%s", said) end
    end
    local judge, clock = state.judge, saves.clock
    for path, p in pairs(saves.pending) do
        if clock == nil or clock - p.at < -2.0 or clock - p.at > COPY_SECONDS then
            if now - p.seen > PENDING_SECONDS then        -- written as another save loaded, say
                saves.pending[path] = nil
            end
        elseif not (judge.moved and judge.v < J.MOVING and now - p.seen < STOPPING_SECONDS) then
            saves.pending[path] = nil                     -- (saved on arriving: once the stop is judged)
            keep(path, p.service, p.at)
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Looking at the game once a second

local function leave(why)
    if state.aboard then log("not driving: %s", why) end
    state.aboard = false
    state.drivable, state.view, state.stop, state.slow_change = nil, nil, nil, false
    state.samples, state.fed_t = {}, nil
    state.judge:lost()
    state.info = { passengers = nil, score = nil, cost = nil, panel = nil }
end

local function new_train(drivable)
    state.drivable = drivable
    state.cars, state.vehicles, state.passenger_train, state.passengers = nil, nil, false, nil
    state.count_failed, state.hold_refs, state.hold_failed, state.hold = false, nil, false, nil
    state.counted_at = -math.huge
    state.samples, state.stop, state.slow_change, state.fed_t = {}, nil, false, nil
    state.judge:lost()
    log("driving %s", short_name(drivable))
end

local function look_at_train(pc, now)
    -- the driver still in the same vehicle: nothing to look for
    local okp, parent = pcall(function() return pc.Pawn:GetAttachParentActor() end)
    if state.aboard and okp and same(parent, state.view) and valid(state.drivable) then return true end
    local drivable = find_drivable(pc)
    if not drivable then
        leave("no train")
        return false
    end
    local view = find_view(pc)
    if not view then
        leave("not aboard your train")
        return false
    end
    if not same(drivable, state.drivable) then new_train(drivable) end
    state.view, state.aboard = view, true
    return true
end

local function look_around(now)
    local pc = player_controller(now)
    if not pc then return leave("no player") end
    if not look_at_train(pc, now) then return end
    local drivable = state.drivable

    if now - state.service_at >= SERVICE_EVERY then
        state.service_at = now
        local service = service_name(pc) or short_name(drivable)
        if state.service ~= nil and service ~= state.service then
            state.judge:new_leg(service, nil, true)  -- another service: its comfort starts afresh
            log("service %s", service)
        end
        state.service = service
    end
    local slow = state.speed < J.MOVING

    if state.cars == nil then
        state.cars = find_cars(drivable)
        state.passenger_train = #state.cars > 0
        state.hold_refs = state.passenger_train and find_hold(drivable) or {}
    end
    if state.passenger_train and (state.counted_at == -math.huge
            or (state.speed < J.STOPPED and now - state.counted_at >= COUNT_EVERY)) then
        if state.counted_at ~= -math.huge and state.vehicles then
            local vehicles = formation(drivable)        -- coupled or split at this stop?
            if vehicles and #vehicles ~= state.vehicles then
                log("your train is now %d vehicles", #vehicles)
                state.cars = find_cars(drivable)
            end
        end
        local before = state.passengers
        state.counted_at = now
        state.passengers = count_passengers(state.cars)
        if before ~= nil and state.passengers ~= nil and state.passengers ~= before and slow then
            state.slow_change = true             -- people got on or off: a station
        end
    end

    if next(hud.widgets) == nil and now - hud.searched_at >= REFIND_EVERY * 3 then
        search_widgets(now, hud.notified and "the one the game made has gone" or "the game didn't say it made one")
    end
    local list = widgets()
    if #list > 0 then hook_widgets() end
    for _, rec in ipairs(list) do
        local okv, shown = pcall(function() return rec.obj:IsVisible() end)
        rec.visible = not okv or shown ~= false
        if rec.visible then
            read_game_text(rec)
            local title = rec.game_title
            if title and title ~= "" and title ~= hud.game_title then
                if hud.game_title ~= nil and slow then state.slow_change = true end  -- the objective moved on
                hud.game_title = title
            end
        end
    end
end

local function look(now)
    state.looked_at = now
    look_around(now)
    keep_with_saves(now)
end

----------------------------------------------------------------------------------------------------
-- Every frame

local function debug_line(now)
    if not S.DebugLog or now - state.debug_at < DEBUG_EVERY then return end
    state.debug_at = now
    local work = state.work
    local panel = state.info.panel
    if state.aboard then
        local hold = state.hold_refs and #state.hold_refs > 0
            and (state.hold and ", holding brake on" or ", holding brake off") or ""
        log("%.1f m/s, %s, %s%s, comfort %s, showing %s; the mod's work %.3f ms a frame on average, %.0f ms at most over %d frames",
            state.speed, state.acc and string.format("%+.2f m/s²", state.acc) or "acceleration not known yet",
            T.aboard(state.passengers) or (state.passenger_train and "passengers not counted" or "not a passenger train"),
            hold, state.info.score and string.format("%.0f", state.info.score) or "-",
            panel and panel.phase or "the objective", work.frames > 0 and work.total / work.frames * 1000 or 0,
            work.most * 1000, work.frames)
    end
    state.work = { total = 0.0, frames = 0, most = 0.0 }
end

local function frame()
    local started = os.clock()
    local now = started
    if now - state.looked_at >= LOOK_EVERY then look(now) end
    if state.aboard then
        local t = game_time()
        if t then
            local vel = state.view:GetVelocity()
            sample(t, math.sqrt(vel.X * vel.X + vel.Y * vel.Y + vel.Z * vel.Z) / 100)
            if now - state.fed_at >= FEED_EVERY then feed(now, t) end
        end
    end
    if hud.dirty or now - state.hud_at >= FEED_EVERY then
        state.hud_at = now
        update_hud(now)
    end
    local spent = os.clock() - started
    local work = state.work
    work.total, work.frames, work.most = work.total + spent, work.frames + 1, math.max(work.most, spent)
    debug_line(now)
end

local function on_frame()
    if not state.on then return end
    local ok, err = pcall(frame)
    if not ok then
        state.errors = (state.errors or 0) + 1
        if state.errors <= 5 then log("something went wrong: %s", tostring(err)) end
        state.looked_at = -math.huge             -- look at the train again
    end
end

-- Once a frame where this UE4SS has the engine tick hook, otherwise about 100 times a second.
local function start_loop()
    if EngineTickAvailable and LoopInGameThreadAfterFrames then
        return LoopInGameThreadAfterFrames(1, on_frame)
    elseif LoopInGameThreadWithDelay then
        return LoopInGameThreadWithDelay(10, on_frame)
    end
    local handle = { stopped = false }
    LoopAsync(10, function()
        if handle.stopped then return true end
        ExecuteInGameThread(on_frame)
        return false
    end)
    return handle
end

local function stop_loop(handle)
    if type(handle) == "table" then
        handle.stopped = true
    elseif handle and CancelDelayedAction then
        CancelDelayedAction(handle)
    end
end

----------------------------------------------------------------------------------------------------
-- Report (F11): what the mod can see, for working out the next steps

local function report_section(title, fn)
    local ok, err = pcall(fn)
    if not ok then log("  (%s: %s)", title, tostring(err)) end
end

-- A game function's parameters, "Name: type" each.
local function describe_function(name)
    local flags = EObjectFlags and EObjectFlags.RF_NoFlags or 0
    local found = FindObjects(5, "Function", name, flags, flags, false) or {}
    local out = {}
    for _, f in pairs(found) do
        local params = {}
        pcall(function()
            f:ForEachProperty(function(p)
                params[#params + 1] = p:GetFName():ToString() .. ": " .. p:GetClass():GetFName():ToString()
            end)
        end)
        out[#out + 1] = string.format("%s(%s)", name_of(f):match("^%S+ (.*)$") or name_of(f), table.concat(params, ", "))
    end
    return #out > 0 and table.concat(out, "; ") or "not found"
end

-- What a value from the game is: a number, a bool, text, an object.
local function describe(r)
    if type(r) == "number" or type(r) == "boolean" or type(r) == "string" then return tostring(r) end
    if r == nil then return "nothing" end
    if valid(r) then return "object " .. short_name(r) end
    local t = text_of(r)
    if t then return string.format("%q", t) end
    return type(r)
end

local function report()
    local started = os.clock()
    log("---- report ----")
    report_section("versions", function()
        log("Unreal %s.%s, engine tick hook %s, comfort HUD %s", UnrealVersion:GetMajor(), UnrealVersion:GetMinor(),
            EngineTickAvailable and "yes" or "no", state.on and "on" or "off")
    end)
    state.pc_stale = true
    state.pc_looked = -math.huge
    local pc = player_controller(real_time())
    log("player controller: %s", name_of(pc))
    if pc then
        report_section("train", function()
            local d = find_drivable(pc)
            local ok, r, out = call_out(pc, "GetDrivenServiceName")
            log("drivable: %s; view: %s; GetDrivenServiceName: %s", short_name(d), short_name(find_view(pc)),
                ok and string.format("gave %s, out %s", describe(r), describe(out)) or ("error: " .. tostring(r)))
            if d then
                local vehicles, why = formation(d)
                if vehicles then
                    local names = {}
                    for _, v in ipairs(vehicles) do
                        names[#names + 1] = short_name(v) .. (cargo_of(v) and " (passengers)" or "")
                    end
                    log("  your train, front to back: %s", table.concat(names, ", "))
                else
                    log("  the game won't list your train: %s", tostring(why))
                end
                local okv, fv = pcall(function() return d:GetForwardsVelocity() end)
                log("  GetForwardsVelocity: %s; speed read %.2f m/s, acceleration %s over %d readings",
                    okv and describe(fv) or "error", state.speed,
                    state.acc and string.format("%+.3f m/s²", state.acc) or "-", #state.samples)
                log("  holding brake nodes: %d, now %s", state.hold_refs and #state.hold_refs or 0, tostring(state.hold))
            end
        end)
    end
    report_section("passengers", function()
        for i, c in ipairs(state.cars or {}) do
            local ok, owner = pcall(function() return c:GetOwner() end)
            local okn, n = pcall(function() return c:GetPassengerCount() end)
            log("  car %d: %s on %s: %s aboard", i, short_name(c), ok and short_name(owner) or "?",
                okn and describe(n) or ("error: " .. tostring(n)))
        end
        log("passenger cars: %d, %s aboard", #(state.cars or {}), tostring(state.passengers))
    end)
    report_section("comfort", function()
        local j = state.judge
        local panel = j:panel()
        log("comfort: service %s, %d rides done, now %s; showing %s", tostring(j.service), #j.done,
            j:live_score() and string.format("%.1f", j:live_score()) or "-", panel and panel.phase or "nothing")
        local lost = {}
        for _, loss in ipairs(J.losses(j.leg)) do
            lost[#lost + 1] = string.format("%s %s -%.1f", loss[2], tostring(loss[3]), loss[1])
        end
        log("  this ride: %s", #lost > 0 and table.concat(lost, ", ") or "nothing lost")
    end)
    report_section("saves", function()
        local day, how = nil, "no player"
        if pc then day, how = read_day(pc) end
        log("the game's time of day: %s; kept with saves %d times, put back %d times", day and
            string.format("%s (%s)", C.date_text(day), how) or ("can't be read: " .. tostring(how)), saves.kept,
            saves.restores)
        local ok_t, raw = pcall(function()
            return text_of(class("/Script/TimeOfDay.Default__TimeOfDayBPLibrary"):GetLocalTimeOfDayAsString())
        end)
        log("  its time of day written out: %s", ok_t and string.format("%q", tostring(raw))
            or ("can't be read: " .. tostring(raw)))
        if not S.KeepWithSaves then log("  not kept with saves (KeepWithSaves is off)") end
        if #SAVE_FILES == 0 then log("  the game's save files aren't known") end
        for _, path in ipairs(SAVE_FILES) do
            local service, at = C.read_header(path)
            local kept = C.kept(path)
            log("  %s: %s; kept beside it: %s", path:match("[^/\\]+$"),
                service and string.format("%s at %s", service, C.date_text(at)) or ("can't be read: " .. tostring(at)),
                kept and string.format("%s at %s, %d rides done", tostring(kept.service), C.date_text(kept.at),
                    #(kept.state.done or {})) or "nothing")
        end
    end)
    report_section("objective box", function()
        search_widgets(real_time(), "report")
        for _, rec in ipairs(widgets()) do
            local w = rec.obj
            local size = "?"
            pcall(function()
                local d = w.Description:GetDesiredSize()
                size = string.format("%.0f x %.0f", d.X, d.Y)
            end)
            log("  %s, %s: name %q, line %q (%s wide x high); the game's: %q / %q", class_name(w),
                rec.visible and "shown" or "hidden", tostring(text_of(w.Name:GetText())),
                tostring(text_of(w.Description:GetText())), size, tostring(text_of(w.ObjectiveTitle)),
                tostring(text_of(w.ObjectiveDescription)))
        end
        log("  hooks: %s; the game wrote its own text %d times", hud.hooks and #hud.hooks > 0
            and table.concat(hud.hooks, ", ") or "none", hud.hook_calls)
    end)
    report_section("game functions", function()
        for _, name in ipairs({ "GetCurrentLocalDrivableActor", "GetDrivenServiceName", "GetFormation",
                                "GetPassengerCount", "IsConsistPlayerDriven", "GetSimulationNodeParameterAsBool",
                                "GetDateTime" }) do
            log("  %s", describe_function(name))
        end
    end)
    log("---- end of report (%.0f ms) ----", (os.clock() - started) * 1000)
end

----------------------------------------------------------------------------------------------------
-- Keys

-- "SHIFT+SPACE" -> Key.SPACE, { ModifierKey.SHIFT }
local function parse_key(text)
    local parts = {}
    for part in tostring(text):gmatch("[^+]+") do parts[#parts + 1] = part end
    local mods = {}
    for i = 1, #parts - 1 do
        if not ModifierKey[parts[i]] then return nil end
        mods[#mods + 1] = ModifierKey[parts[i]]
    end
    return Key[parts[#parts]], mods
end

local function on_key(name, fn)
    local key, mods = parse_key(name)
    if not key then return log("unknown key %s in comfort_settings.lua", tostring(name)) end
    local function run()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then log("%s key: %s", name, tostring(err)) end
        end)
    end
    if #mods > 0 then RegisterKeyBind(key, mods, run) else RegisterKeyBind(key, run) end
end

local function switch(on)
    if on == state.on then return end
    state.on = on
    if on then
        state.judge:lost()
        state.looked_at, state.samples, state.fed_t = -math.huge, {}, nil
        state.loop = start_loop()
        log("on")
    else
        stop_loop(state.loop)
        state.loop = nil
        for _, rec in ipairs(widgets()) do
            pcall(function()
                rec.want = NOTHING
                apply(rec, false)
            end)
        end
        log("off: the objective box is the game's own again, and the mod does nothing until = is pressed")
    end
end

on_key(S.ToggleKey, function() switch(not state.on) end)
on_key(S.ReportKey, report)

-- The game making its objective box (loading a drive) and a new player: no need to look for them.
local ok_notify = pcall(NotifyOnNewObject, OBJECTIVE_CLASS, function(w)
    hud.notified = true
    remember_widget(w)
end)
pcall(NotifyOnNewObject, "/Script/Engine.PlayerController", function()
    state.pc_stale = true
    state.pc_looked = -math.huge
    saves.world, saves.day, saves.day_at, saves.read_at = true, nil, -math.huge, -math.huge   -- another drive
end)
if not ok_notify then log("the game won't say when it makes its objective box: it'll be looked for instead") end

state.loop = start_loop()
log("loaded: %s = off / on, %s = report to UE4SS.log", S.ToggleKey, S.ReportKey)
if S.KeepWithSaves then
    local names = {}
    for _, path in ipairs(SAVE_FILES) do names[#names + 1] = path:match("[^/\\]+$") end
    if #names > 0 then
        log("keeping the comfort beside the game's saves: %s", table.concat(names, ", "))
    else
        log("the game's save files aren't known (install the comfort HUD again once the game has saved): "
            .. "the comfort isn't kept with them")
    end
end
