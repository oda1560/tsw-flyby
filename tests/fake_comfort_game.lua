-- A stand-in for UE4SS and the game, so the comfort HUD can run outside TSW7: a passenger train of a few cars (each
-- rail vehicle split in two as in TSW7, the model at the world's origin and the view that moves, the driver attached
-- to the view), an AI train with passengers of its own, and the HUD's objective box (the minimal one, as on the
-- user's screen) that the game writes its objective into. Sim.run(seconds) plays frames at 60 a second; the train's
-- speed follows Sim.acc (m/s²) or a driving function Sim.drive(t, v) -> acceleration.

local Sim = { logs = {}, frame_fns = {}, keys = {}, hooks = {}, notify = {}, next_address = 1000 }

local function vec(x, y, z) return { X = x, Y = y, Z = z } end

local function object(class, path, fields)
    Sim.next_address = Sim.next_address + 1
    local o = fields or {}
    o.valid = true
    o.address = Sim.next_address
    o.class = class
    o.path = path
    o.IsValid = function(self) return self.valid end
    o.GetAddress = function(self) return self.address end
    o.GetFullName = function(self) return self.class .. " " .. self.path end
    o.GetClass = function(self)
        local cls = self.class
        return { GetFName = function() return { ToString = function() return cls end } end }
    end
    o.IsA = function(self, class_obj) return self.kinds ~= nil and self.kinds[class_obj.short] == true end
    return o
end

local function invalid() return { IsValid = function() return false end } end

-- An FText: UE4SS gives these with ToString.
local function text(s) return { s = s, ToString = function(self) return self.s end } end
function FText(s) return text(s) end

local function text_block(name, default)
    local tb = object("TextBlock", name, { shown = default,
        ColorAndOpacity = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0 } })
    tb.SetText = function(self, t)
        self.shown = t:ToString()
        Sim.set_texts = Sim.set_texts + 1
    end
    tb.GetText = function(self) return text(self.shown) end
    tb.SetColorAndOpacity = function(self, c)
        self.ColorAndOpacity = { SpecifiedColor = c.SpecifiedColor, ColorUseRule = c.ColorUseRule }
    end
    tb.GetDesiredSize = function(self) return { X = 7 * #self.shown, Y = 14 } end
    return tb
end

----------------------------------------------------------------------------------------------------
-- The game objects

local pc, pawn, view, drivable, statics

local function new_widget(class, path)
    local w = object(class, path)
    w.Name = text_block(path .. ".WidgetTree.Name", "OBJECTIVE NAME")
    w.Description = text_block(path .. ".WidgetTree.Description", "Description")
    w.ObjectiveTitle = text("")
    w.ObjectiveDescription = text("")
    w.IsVisible = function() return true end
    return w
end

local function cargo(owner, n)
    local c = object("PassengerCargoModelComponent", owner.path .. ".PassengerCargoModel", { owner = owner, n = n })
    c.GetOwner = function(self) return self.owner end
    c.GetPassengerCount = function(self)
        if Sim.count_breaks then error("bad call") end
        return self.n
    end
    return c
end

function Sim.setup(opts)
    opts = opts or {}
    Sim.logs, Sim.frame_fns, Sim.keys, Sim.hooks, Sim.notify = {}, {}, {}, {}, {}
    Sim.time, Sim.wall = 0.0, 100.0          -- game time, and the wall clock (os.clock)
    Sim.v, Sim.acc, Sim.drive = opts.speed or 0.0, 0.0, nil
    Sim.searches, Sim.set_texts, Sim.pc_searches = {}, 0, 0
    Sim.paused, Sim.count_breaks = false, false
    Sim.blueprint_loaded = false
    Sim.service = opts.service or "1M56"

    local level = "/Game/Routes/Route/Maps/Route.Route:PersistentLevel"
    local formation = object("TrainFormation", level .. ".TrainFormation_0")
    local ai_formation = object("TrainFormation", level .. ".TrainFormation_1")
    local function vehicle(name, f)
        local rv = object(name, level .. "." .. name .. "_1", { formation = f, kinds = { RailVehicle = true } })
        rv.GetFormation = function(self)
            if opts.no_formation then error("no such function") end
            return self.formation
        end
        rv.GetAttachParentActor = function() return invalid() end
        return rv
    end
    drivable = vehicle("RVM_Class150_DMS", formation)
    local cars = { drivable, vehicle("RVM_Class150_DMSL", formation) }
    local loco = vehicle("RVM_Class66", formation)
    local ai = vehicle("RVM_AI_Class323", ai_formation)
    Sim.cargo = {}
    if opts.passengers ~= false then
        local counts = opts.passengers or { 40, 22 }
        for i, car in ipairs(cars) do Sim.cargo[#Sim.cargo + 1] = cargo(car, counts[i] or 0) end
    end
    Sim.cargo[#Sim.cargo + 1] = cargo(ai, 99)
    Sim.drivable, Sim.loco = drivable, loco

    view = object("RVV_Class150_DMS_C", level .. ".RVV_Class150_DMS_C_2", { kinds = { RailVehicleView = true } })
    view.GetAttachParentActor = function() return drivable end
    view.GetVelocity = function() return vec(Sim.v * 100 * 0.6, Sim.v * 100 * 0.8, 0) end
    pawn = object("TS2DefaultDriverPawn_C", level .. ".TS2DefaultDriverPawn_C_0")
    pawn.GetAttachParentActor = function()
        if Sim.walked_off then return invalid() end
        return view
    end
    pc = object("TS2PrototypePlayerController_C", level .. ".TS2PrototypePlayerController_C_0", { Pawn = pawn })
    pc.GetCurrentLocalDrivableActor = function()
        if Sim.no_drivable then return invalid() end
        return drivable
    end
    pc.GetDrivenServiceName = function() return text(Sim.service) end
    statics = object("GameplayStatics", "/Script/Engine.Default__GameplayStatics")
    statics.GetTimeSeconds = function() return Sim.time end
    Sim.pc = pc

    -- the HUD: the objective box on screen, and the templates in the HUD blueprint the game made it from
    Sim.widget_on_screen = opts.widget ~= false
    Sim.widget = new_widget("HUDObjectiveWidget_Minimal_C",
        "/Engine/Transient.GameEngine_0:BP_TS2GameInstance_C_0.HUD_Widget_C_0.WidgetTree.HUDObjectiveWidget_Minimal_1")
    Sim.template = new_widget("HUDObjectiveWidget_Minimal_C",
        "/Game/Core/Assets/HUD/Widgets/HUD_Widget.HUD_Widget_C:WidgetTree.HUDObjectiveWidget_Minimal_1")
end

-- The game showing an objective, as its HUD does: SetObjective, then ShowObjective (Name and Description written).
function Sim.objective(title, line)
    local w = Sim.widget
    w.ObjectiveTitle, w.ObjectiveDescription = text(title), text(line)
    w.Name.shown, w.Description.shown = title, line
    Sim.call_hooks("ShowObjective", w)
end

-- The game rewriting the objective's text (UpdateObjectiveText), with or without telling the hooks.
function Sim.objective_text(title, line, quietly)
    local w = Sim.widget
    w.ObjectiveTitle, w.ObjectiveDescription = text(title), text(line)
    w.Name.shown, w.Description.shown = title, line
    if not quietly then Sim.call_hooks("UpdateObjectiveText", w) end
end

function Sim.call_hooks(fname, w)
    for path, fn in pairs(Sim.hooks) do
        if path:find(":" .. fname, 1, true) and path:find(w.class, 1, true) then
            fn({ get = function() return w end })
        end
    end
end

-- The game loading the drive: the HUD made (and the mod told, if it's listening), the blueprint's functions there.
function Sim.load_hud()
    Sim.blueprint_loaded = true
    for class, fns in pairs(Sim.notify) do
        if class == "/Script/TS2Prototype.TS2HUDObjectiveWidget" then
            for _, fn in ipairs(fns) do
                fn(Sim.template)
                if Sim.widget_on_screen then fn(Sim.widget) end
            end
        end
    end
end

----------------------------------------------------------------------------------------------------
-- UE4SS globals

print = function(s) Sim.logs[#Sim.logs + 1] = s end
os.clock = function() return Sim.wall end

Key = { F11 = 122, OEM_PLUS = 187, F10 = 121 }
ModifierKey = { SHIFT = 16, CONTROL = 17, ALT = 18 }
EngineTickAvailable = true
EObjectFlags = { RF_NoFlags = 0 }
UnrealVersion = { GetMajor = function() return 4 end, GetMinor = function() return 26 end }

function RegisterKeyBind(key, a, b) Sim.keys[tostring(key)] = b or a end
function RegisterHook(path, fn)
    if not Sim.blueprint_loaded then error("function not found: " .. path) end
    Sim.hooks[path] = fn
    return 1, 2
end
function NotifyOnNewObject(class, fn)
    Sim.notify[class] = Sim.notify[class] or {}
    table.insert(Sim.notify[class], fn)
end
function ExecuteInGameThread(fn) fn() end
function LoopInGameThreadAfterFrames(_, fn)
    local h = #Sim.frame_fns + 1
    Sim.frame_fns[h] = fn
    return h
end
function CancelDelayedAction(h) Sim.frame_fns[h] = nil; return true end

function FindAllOf(name)
    Sim.searches[#Sim.searches + 1] = name
    local list = {}
    if name == "PassengerCargoModelComponent" then
        list = Sim.cargo
    elseif name == "HUDObjectiveWidget_Minimal_C" and Sim.blueprint_loaded then
        list = { Sim.template }
        if Sim.widget_on_screen then list[2] = Sim.widget end
    elseif name == "PlayerController" then
        Sim.pc_searches = Sim.pc_searches + 1
        list = { pc }
    end
    local out = {}
    for _, o in ipairs(list) do if o.valid then out[#out + 1] = o end end
    return #out > 0 and out or nil
end
function FindObjects() return {} end
function StaticFindObject(path)
    if path == "/Script/TS2Prototype.RailVehicleView" then return object("Class", path, { short = "RailVehicleView" }) end
    if path == "/Script/TS2Prototype.RailVehicle" then return object("Class", path, { short = "RailVehicle" }) end
    return invalid()
end

package.preload["UEHelpers"] = function()
    return {
        GetPlayerController = function()
            local found = FindAllOf("PlayerController")
            return found and found[1] or invalid()
        end,
        GetGameplayStatics = function() return statics end,
    }
end

----------------------------------------------------------------------------------------------------
-- Driving the test

function Sim.press(name)
    local fn = Sim.keys[tostring(Key[name])]
    if fn then fn() end
    return fn ~= nil
end

-- Plays `seconds` of frames at 60 a second; `each(t)` after each frame.
function Sim.run(seconds, each)
    local dt = 1 / 60
    for _ = 1, math.floor(seconds / dt + 0.5) do
        Sim.wall = Sim.wall + dt
        if not Sim.paused then
            Sim.time = Sim.time + dt
            local acc = Sim.drive and Sim.drive(Sim.time, Sim.v) or Sim.acc
            Sim.v = math.max(0.0, Sim.v + acc * dt)
        end
        for _, fn in pairs(Sim.frame_fns) do fn() end
        if each then each(Sim.time) end
    end
end

function Sim.shown()
    return Sim.widget.Name.shown, Sim.widget.Description.shown
end

function Sim.name_colour() return Sim.widget.Name.ColorAndOpacity.SpecifiedColor end

function Sim.log_count(s)
    local n = 0
    for _, l in ipairs(Sim.logs) do if l:find(s, 1, true) then n = n + 1 end end
    return n
end

function Sim.all_logs() return table.concat(Sim.logs) end

function Sim.searched(name)
    local n = 0
    for _, s in ipairs(Sim.searches) do if s == name then n = n + 1 end end
    return n
end

return Sim
