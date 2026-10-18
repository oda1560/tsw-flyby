-- A stand-in for UE4SS and the game, so the comfort HUD can run outside TSW7: a passenger train of a few cars (each
-- rail vehicle split in two as in TSW7, the model at the world's origin and the view that moves, the driver attached
-- to the view), an AI train with passengers of its own, and the HUD's objective box (the minimal one, as on the
-- user's screen) that the game writes its objective into. Sim.run(seconds) plays frames at 60 a second; the train's
-- speed follows Sim.acc (m/s²) or a driving function Sim.drive(t, v) -> acceleration.

local Sim = { logs = {}, frame_fns = {}, keys = {}, hooks = {}, notify = {}, next_address = 1000 }

local function vec(x, y, z) return { X = x, Y = y, Z = z } end

-- Game calls made, by name (UE4SS's own checks, IsValid and the like, aren't calls into the game).
Sim.calls = {}
local function call(name) Sim.calls[name] = (Sim.calls[name] or 0) + 1 end
function Sim.total_calls()
    local n = 0
    for _, c in pairs(Sim.calls) do n = n + c end
    return n
end

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

-- An FText, FName: UE4SS gives these with ToString.
local function text(s) return { s = s, ToString = function(self) return self.s end } end
function FText(s) return text(s) end
function FName(s) return text(s) end
local function str(v) return type(v) == "table" and v:ToString() or v end

local function text_block(name, default)
    local tb = object("TextBlock", name, { shown = default,
        ColorAndOpacity = { SpecifiedColor = { R = 1, G = 1, B = 1, A = 1 }, ColorUseRule = 0 } })
    tb.SetText = function(self, t)
        call("SetText")
        self.shown = t:ToString()
        Sim.set_texts = Sim.set_texts + 1
    end
    tb.GetText = function(self)
        call("GetText")
        return text(self.shown)
    end
    tb.SetColorAndOpacity = function(self, c)
        self.ColorAndOpacity = { SpecifiedColor = c.SpecifiedColor, ColorUseRule = c.ColorUseRule }
    end
    tb.GetDesiredSize = function(self) return { X = 7 * #self.shown, Y = 14 } end
    return tb
end

----------------------------------------------------------------------------------------------------
-- The game objects

local pc, pawn, view, drivable, statics

-- The objective box: its Name and Description text blocks, and the objective the game has set (ObjectiveTitle,
-- ObjectiveDescription: blueprint variables, each read a call).
local function new_widget(class, path)
    local w = object(class, path)
    w.Name = text_block(path .. ".WidgetTree.Name", "OBJECTIVE NAME")
    w.Description = text_block(path .. ".WidgetTree.Description", "Description")
    w.vars = { ObjectiveTitle = text(""), ObjectiveDescription = text("") }
    w.hidden = false
    w.IsVisible = function(self)
        call("IsVisible")
        return not self.hidden
    end
    return setmetatable(w, { __index = function(self, k)
        local v = rawget(self, "vars")[k]
        if v ~= nil then call("read " .. k) end
        return v
    end })
end

local function cargo(owner, n)
    local c = object("PassengerCargoModelComponent", owner.path .. ".PassengerCargoModel", { owner = owner, n = n })
    c.GetOwner = function(self) return self.owner end
    c.GetPassengerCount = function(self)
        call("GetPassengerCount")
        if Sim.count_breaks then error("bad call") end
        return self.n
    end
    owner.cargo = c
    return c
end

-- A TArray as UE4SS gives it: ForEach(fn(index, element)), each element with get().
local function tarray(list)
    return { ForEach = function(self, fn)
        for i, v in ipairs(list) do fn(i, { get = function() return v end }) end
    end }
end

function Sim.setup(opts)
    opts = opts or {}
    Sim.calls = {}
    Sim.logs, Sim.frame_fns, Sim.keys, Sim.hooks, Sim.notify = {}, {}, {}, {}, {}
    Sim.time, Sim.wall = 0.0, 100.0          -- game time, and the wall clock (os.clock)
    Sim.v, Sim.acc, Sim.drive = opts.speed or 0.0, 0.0, nil
    Sim.searches, Sim.set_texts, Sim.pc_searches = {}, 0, 0
    Sim.paused, Sim.count_breaks = false, false
    Sim.blueprint_loaded = false
    Sim.service = opts.service or "1M56"

    local level = "/Game/Routes/Route/Maps/Route.Route:PersistentLevel"
    local train, ai_train = {}, {}
    local function vehicle(name, consist)
        local rv = object(name, level .. "." .. name .. "_1", { consist = consist, kinds = { RailVehicle = true } })
        rv.GetFormation = function(self, mode)
            call("GetFormation")
            if opts.no_formation or mode ~= 0 then error("bad call") end
            return tarray(self.consist)
        end
        rv.GetComponentByClass = function(self, cls)
            call("GetComponentByClass")
            if cls.short == "PassengerCargoModelComponent" and self.cargo then return self.cargo end
            return invalid()
        end
        rv.GetAttachParentActor = function() return invalid() end
        table.insert(consist, rv)
        return rv
    end
    drivable = vehicle("RVM_Class150_DMS", train)
    local cars = { drivable, vehicle("RVM_Class150_DMSL", train) }
    local loco = vehicle("RVM_Class66", train)
    local ai = vehicle("RVM_AI_Class323", ai_train)
    Sim.train = train
    -- the train's own holding brake, a simulation node that a Class 350 has
    Sim.hold_node, Sim.hold_on = opts.hold and "DirectBrakeControlPowered" or nil, false
    Sim.cargo = {}
    if opts.passengers ~= false then
        local counts = opts.passengers or { 40, 22 }
        for i, car in ipairs(cars) do Sim.cargo[#Sim.cargo + 1] = cargo(car, counts[i] or 0) end
    end
    Sim.cargo[#Sim.cargo + 1] = cargo(ai, 99)
    Sim.drivable, Sim.loco = drivable, loco

    view = object("RVV_Class150_DMS_C", level .. ".RVV_Class150_DMS_C_2", { kinds = { RailVehicleView = true } })
    view.GetAttachParentActor = function() return drivable end
    view.GetVelocity = function()
        call("GetVelocity")
        return vec(Sim.v * 100 * 0.6, Sim.v * 100 * 0.8, 0)
    end
    pawn = object("TS2DefaultDriverPawn_C", level .. ".TS2DefaultDriverPawn_C_0")
    pawn.GetAttachParentActor = function()
        call("GetAttachParentActor")
        if Sim.walked_off then return invalid() end
        return view
    end
    local world = object("World", level)
    pc = object("TS2PrototypePlayerController_C", level .. ".TS2PrototypePlayerController_C_0", { Pawn = pawn })
    pc.GetWorld = function() return world end
    pc.GetCurrentLocalDrivableActor = function(self, w)
        call("GetCurrentLocalDrivableActor")
        if Sim.no_drivable or w ~= world then return invalid() end
        return drivable
    end
    -- the service's name comes back in its out parameter: UE4SS writes it into the table passed for it
    pc.GetDrivenServiceName = function(self, out)
        call("GetDrivenServiceName")
        if type(out) ~= "table" then error("out parameter missing") end
        if Sim.service_returned then return true, FName(Sim.service) end
        out.ServiceName = FName(Sim.service)
        return true
    end
    statics = object("GameplayStatics", "/Script/Engine.Default__GameplayStatics")
    statics.GetTimeSeconds = function()
        call("GetTimeSeconds")
        return Sim.time
    end
    -- the game's function library for reading a train's simulation, as its blueprints do
    Sim.physics = object("PhysicsFunctionLibrary", "/Script/TS2Prototype.Default__PhysicsFunctionLibrary")
    Sim.physics.DoesSimulationNodeExist = function(self, ctx, node)
        call("DoesSimulationNodeExist")
        return ctx == drivable and str(node.ComponentName) == "Simulation" and str(node.NodeName) == Sim.hold_node
    end
    Sim.physics.GetSimulationNodeParameterAsBool = function(self, ctx, p)
        call("GetSimulationNodeParameterAsBool")
        local node = p.NodeReference
        if ctx ~= drivable or str(node.ComponentName) ~= "Simulation" or str(node.NodeName) ~= Sim.hold_node
            or str(p.ParameterReference.Name) ~= "BrakeHoldActive" or p.ParameterReference.PinIndex ~= -1 then
            return false
        end
        return Sim.hold_on
    end
    Sim.player_trains = opts.player_trains   -- IsConsistPlayerDriven in the gameplay library
    Sim.gameplay = object("TS2GameplayFunctionLibrary", "/Script/TS2Prototype.Default__TS2GameplayFunctionLibrary")
    Sim.gameplay.IsConsistPlayerDriven = function(self, actor, out)
        call("IsConsistPlayerDriven")
        if type(out) ~= "table" then error("out parameter missing") end
        for _, v in ipairs(train) do
            if v == actor then return true end
        end
        return false
    end
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
    w.vars.ObjectiveTitle, w.vars.ObjectiveDescription = text(title), text(line)
    w.Name.shown, w.Description.shown = title, line
    Sim.call_hooks("ShowObjective", w)
end

-- The game rewriting the objective's text (UpdateObjectiveText), with or without telling the hooks.
function Sim.objective_text(title, line, quietly)
    local w = Sim.widget
    w.vars.ObjectiveTitle, w.vars.ObjectiveDescription = text(title), text(line)
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
    local cls = path:match("^/Script/TS2Prototype%.([%w_]+)$")
    if cls == "RailVehicleView" or cls == "RailVehicle" or cls == "PassengerCargoModelComponent" then
        return object("Class", path, { short = cls })
    end
    if path == "/Script/TS2Prototype.Default__PhysicsFunctionLibrary" then return Sim.physics end
    if path == "/Script/TS2Prototype.PhysicsFunctionLibrary:GetSimulationNodeParameterAsBool"
        or path == "/Script/TS2Prototype.PhysicsFunctionLibrary:DoesSimulationNodeExist" then
        return object("Function", path)
    end
    if Sim.player_trains then
        if path == "/Script/TS2Prototype.Default__TS2GameplayFunctionLibrary" then return Sim.gameplay end
        if path == "/Script/TS2Prototype.TS2GameplayFunctionLibrary:IsConsistPlayerDriven" then
            return object("Function", path)
        end
    end
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
