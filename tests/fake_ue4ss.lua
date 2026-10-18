-- A stand-in for UE4SS and the game, so the mod can run outside TSW7: a train driving along a line that
-- goes straight along X and then curves right, a player in the cab, ground and walls for line traces.
-- As in TSW7, each rail vehicle is two actors: the model (..._RVM_C), which stays at the world's origin, and
-- the view (RVV_...), which moves. The driver is attached to the view, and the view to the model.
-- Positions are Unreal centimetres. Sim.run(seconds) plays frames at 60 a second.

local Sim = { logs = {}, time = 0, frame_fns = {}, cameras = {}, keys = {}, next_address = 1000 }

local function vec(x, y, z) return { X = x, Y = y, Z = z } end

local function object(name, fields)
    Sim.next_address = Sim.next_address + 1
    local o = fields or {}
    o.valid = true
    o.address = Sim.next_address
    o.name = name
    o.IsValid = function(self) return self.valid end
    o.IsA = function(self, class) return self.classes ~= nil and self.classes[class.short] == true end
    o.GetAddress = function(self) return self.address end
    o.GetFullName = function(self) return self.name end
    return o
end

local function invalid()
    return { IsValid = function() return false end }
end

----------------------------------------------------------------------------------------------------
-- The line: straight for `straight` cm along +X from the origin, then a right-hand curve of `radius`.

local line = { straight = 2000 * 100, radius = 800 * 100 }

function Sim.path(s)
    if s <= line.straight then return vec(s, 0, 0), vec(1, 0, 0) end
    local th = (s - line.straight) / line.radius
    local p = vec(line.straight + line.radius * math.sin(th), line.radius - line.radius * math.cos(th), 0)
    return p, vec(math.cos(th), math.sin(th), 0)
end

-- Shortest flat distance from a point to the line (sampled every metre over the first 6 km).
function Sim.distance_to_line(p)
    local best = math.huge
    for s = 0, 6000 * 100, 100 do
        local q = Sim.path(s)
        local d = math.sqrt((p.X - q.X) ^ 2 + (p.Y - q.Y) ^ 2)
        if d < best then best = d end
    end
    return best
end

----------------------------------------------------------------------------------------------------
-- The world: ground height, walls, and a world origin the game can move.

Sim.origin = vec(0, 0, 0)       -- added to every position the game reports
Sim.ground = function(x, y) return 0 end
Sim.walls = {}                  -- boxes { min = vec, max = vec } in line coordinates

local function to_line(p) return vec(p.X - Sim.origin.X, p.Y - Sim.origin.Y, p.Z - Sim.origin.Z) end
local function to_world(p) return vec(p.X + Sim.origin.X, p.Y + Sim.origin.Y, p.Z + Sim.origin.Z) end

local function blocked_at(p)
    if p.Z < Sim.ground(p.X, p.Y) then return true end
    for _, w in ipairs(Sim.walls) do
        if p.X >= w.min.X and p.X <= w.max.X and p.Y >= w.min.Y and p.Y <= w.max.Y
            and p.Z >= w.min.Z and p.Z <= w.max.Z then
            return true
        end
    end
    return false
end

Sim.traces = 0

local function line_trace(_, _ctx, from, to, _chan, _complex, _ignore, _draw, hit)
    Sim.traces = Sim.traces + 1
    local a, b = to_line(from), to_line(to)
    local n = 400
    for i = 0, n do
        local t = i / n
        local p = vec(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t)
        if blocked_at(p) then
            if p.Z < Sim.ground(p.X, p.Y) then p.Z = Sim.ground(p.X, p.Y) end
            hit.ImpactPoint = to_world(p)
            hit.Location = to_world(p)
            return true
        end
    end
    return false
end

----------------------------------------------------------------------------------------------------
-- The game objects

local train, pawn, pc, camera_manager

local function actor_methods(o)
    o.K2_GetActorLocation = function(self) return to_world(self.loc) end
    o.GetActorForwardVector = function(self) return self.fwd or vec(1, 0, 0) end
    o.GetVelocity = function(self) return self.vel or vec(0, 0, 0) end
    o.GetAttachParentActor = function(self) return self.parent or invalid() end
    o.GetClass = function(self) return Sim.fake_class(self.name .. "_C") end
    return o
end

function Sim.fake_class(name)
    return object("Class /Script/Game." .. name, {
        ForEachFunction = function(self, fn) fn(object("Function GetCameraThing", { GetFName = function() return { ToString = function() return "GetCameraThing" end } end })) end,
        ForEachProperty = function(self, fn) end,
        GetSuperStruct = function(self) return object("Class /Script/Engine.Actor") end,
    })
end

local function new_camera(loc, rot)
    local cam = actor_methods(object("CameraActor /Game/Maps/Route.Route:PersistentLevel.CameraActor_" .. #Sim.cameras))
    cam.loc = to_line(loc)
    cam.rot = rot
    cam.fov = 90
    cam.CameraComponent = object("CameraComponent", {
        bConstrainAspectRatio = true,
        SetFieldOfView = function(self, fov) cam.fov = fov end,
    })
    cam.K2_TeleportTo = function(self, l, r) self.loc = to_line(l); self.rot = r; return true end
    cam.K2_SetActorLocation = function(self, l) self.loc = to_line(l); return true end
    cam.K2_SetActorRotation = function(self, r) self.rot = r; return true end
    cam.K2_DestroyActor = function(self) self.valid = false end
    Sim.cameras[#Sim.cameras + 1] = cam
    return cam
end

function Sim.setup(opts)
    opts = opts or {}
    Sim.logs, Sim.time, Sim.frame_fns, Sim.cameras, Sim.keys = {}, 0, {}, {}, {}
    Sim.origin = vec(0, 0, 0)
    Sim.ground = function() return 0 end
    Sim.walls = {}
    Sim.s = opts.start or 0       -- train's distance along the line
    Sim.speed = opts.speed or 0   -- cm/s, negative to go back
    Sim.has_velocity = opts.velocity ~= false -- whether the game reports the train's velocity
    Sim.flipped = opts.flipped == true        -- the vehicle faces backwards in its train
    Sim.paused = false
    if opts.straight then line.straight = opts.straight end
    if opts.radius then line.radius = opts.radius end

    local model = actor_methods(object("CL70_FL_RVM_C /Game/Maps/Route.Route:PersistentLevel.CL70_FL_RVM_C_1"))
    model.loc = vec(0, 0, 0)
    model.classes = { RailVehicle = true }
    train = actor_methods(object("RVV_AABS_Class70_C /Game/Maps/Route.Route:PersistentLevel.RVV_AABS_Class70_C_2"))
    train.parent = model
    train.classes = { RailVehicleView = true }
    local other_model = actor_methods(object("AI_RVM_C /Game/Maps/Route.Route:PersistentLevel.AI_RVM_C_3"))
    other_model.loc = vec(0, 0, 0)
    other_model.classes = { RailVehicle = true }
    local other = actor_methods(object("RVV_AI_C /Game/Maps/Route.Route:PersistentLevel.RVV_AI_C_4"))
    other.loc = vec(-900 * 100, 4000, 0)
    other.parent = other_model
    other.classes = { RailVehicleView = true }
    pawn = actor_methods(object("TS2DefaultDriverPawn_C /Game/Maps/Route.Route:PersistentLevel.TS2DefaultDriverPawn_C_0"))
    if opts.attached ~= false then pawn.parent = train end
    if opts.view_at_origin then -- the view reports no position of its own either
        train.K2_GetActorLocation = function() return to_world(vec(0, 0, 0)) end
    end
    Sim.models, Sim.views = { model, other_model }, { train, other }
    Sim.view_class_known = opts.view_class ~= false -- whether /Script/TS2Prototype.RailVehicleView can be found
    camera_manager = object("PlayerCameraManager_C /Game/Maps/Route.Route:PersistentLevel.CameraManager_0", {
        GetCameraLocation = function() return to_world(vec(train.loc.X, train.loc.Y, train.loc.Z + 300)) end,
        GetClass = function() return Sim.fake_class("PlayerCameraManager") end,
    })
    local world = object("World /Game/Maps/Route.Route", {
        SpawnActor = function(self, class, loc, rot) return new_camera(loc, rot) end,
    })
    pc = object("TS2PrototypePlayerController /Game/Maps/Route.Route:PersistentLevel.PC_0", {
        Pawn = pawn,
        PlayerCameraManager = camera_manager,
        view_target = pawn,
        GetViewTarget = function(self) return self.view_target end,
        SetViewTargetWithBlend = function(self, target) self.view_target = target end,
        GetWorld = function() return world end,
        GetClass = function() return Sim.fake_class("TS2PrototypePlayerController") end,
    })
    Sim.train, Sim.pawn, Sim.pc, Sim.model = train, pawn, pc, model
    Sim.outside = actor_methods(object("TS2DefaultDriverCameraPawn_C /Game/Maps/Route.Route:PersistentLevel.TS2DefaultDriverCameraPawn_C_5"))
    Sim.outside.loc = vec(0, 0, 0)
    Sim.move_train(0)
end

function Sim.move_train(dt)
    Sim.s = Sim.s + Sim.speed * dt
    local p, d = Sim.path(Sim.s)
    train.loc = vec(p.X, p.Y, p.Z + 50)
    train.fwd = Sim.flipped and vec(-d.X, -d.Y, 0) or d
    train.vel = Sim.has_velocity and vec(d.X * Sim.speed, d.Y * Sim.speed, 0) or nil
    Sim.model.vel = vec(d.X * Sim.speed, d.Y * Sim.speed, 0)
    Sim.outside.loc = vec(p.X - 3000, p.Y, p.Z + 500)
    pawn.loc = vec(p.X, p.Y, p.Z + 200)
end

-- The game moving its world origin: everything it reports jumps by `by`.
function Sim.shift_origin(by)
    Sim.origin = vec(Sim.origin.X + by.X, Sim.origin.Y + by.Y, Sim.origin.Z + by.Z)
end

----------------------------------------------------------------------------------------------------
-- UE4SS globals

print = function(text) Sim.logs[#Sim.logs + 1] = text end

Key = { ZERO = 48, ONE = 49, TWO = 50, THREE = 51, FIVE = 53, SIX = 54, SEVEN = 55, EIGHT = 56,
        SPACE = 32, E = 69, F10 = 121 }
ModifierKey = { SHIFT = 16, CONTROL = 17, ALT = 18 }
EngineTickAvailable = true
EObjectFlags = { RF_NoFlags = 0 }
UnrealVersion = { GetMajor = function() return 4 end, GetMinor = function() return 26 end }

-- Bound keys by "<key>" or "<key>+<modifier>..."
function RegisterKeyBind(key, a, b)
    local name = tostring(key)
    if b then
        for _, m in ipairs(a) do name = name .. "+" .. m end
    end
    Sim.keys[name] = b or a
end
Sim.hooks = {}
function RegisterHook(path, fn)
    if not path:find("^/Script/") and not Sim.blueprint_loaded then error("function not found: " .. path) end
    Sim.hooks[path] = fn
    return 1, 2
end
function ExecuteInGameThread(fn) fn() end
function LoopInGameThreadAfterFrames(n, fn)
    local h = #Sim.frame_fns + 1
    Sim.frame_fns[h] = fn
    return h
end
function CancelDelayedAction(h) Sim.frame_fns[h] = nil; return true end
function FindAllOf(name)
    local list = (name == "RailVehicle" and Sim.models) or (name == "RailVehicleView" and Sim.views) or {}
    local out = {}
    for _, v in ipairs(list) do if v.valid then out[#out + 1] = v end end
    return #out > 0 and out or nil
end
function FindObjects() return {} end
function StaticFindObject(path)
    if path == "/Script/Engine.CameraActor" then return object("Class /Script/Engine.CameraActor") end
    if path == "/Script/TS2Prototype.RailVehicleView" and Sim.view_class_known then
        return object("Class /Script/TS2Prototype.RailVehicleView", { short = "RailVehicleView" })
    end
    return invalid()
end

local statics = object("GameplayStatics", { GetTimeSeconds = function() return Sim.time end })
local kismet = object("KismetSystemLibrary", { LineTraceSingle = line_trace })

package.preload["UEHelpers"] = function()
    return {
        GetPlayerController = function() return pc end,
        GetGameplayStatics = function() return statics end,
        GetKismetSystemLibrary = function() return kismet end,
    }
end

----------------------------------------------------------------------------------------------------
-- Driving the test

-- Press a key: "SEVEN", or with modifiers "SHIFT+SPACE". Keys the mod didn't bind do nothing.
function Sim.press(name)
    local parts = {}
    for part in name:gmatch("[^+]+") do parts[#parts + 1] = part end
    local id = tostring(Key[parts[#parts]])
    for i = 1, #parts - 1 do id = id .. "+" .. ModifierKey[parts[i]] end
    local fn = Sim.keys[id]
    if fn then fn() end
    return fn ~= nil
end

-- The game switching to one of its own cameras, as it does when you press its camera keys.
function Sim.game_switches_to(target, with_event)
    pc.view_target = target
    if with_event then
        for path, fn in pairs(Sim.hooks) do
            if path:find("OnCameraSwitched") then fn() end
        end
    end
end

function Sim.run(seconds, each)
    local dt = 1 / 60
    for _ = 1, math.floor(seconds / dt + 0.5) do
        if not Sim.paused then
            Sim.time = Sim.time + dt
            Sim.move_train(dt)
        end
        for _, fn in pairs(Sim.frame_fns) do fn() end
        if each then each() end
    end
end

-- The mod's camera, while it exists.
function Sim.camera()
    local cam = Sim.cameras[#Sim.cameras]
    if cam and cam.valid then return cam end
    return nil
end

function Sim.camera_line_pos()
    local cam = Sim.camera()
    return cam and cam.loc
end

function Sim.train_line_pos() return train.loc end

-- Angle in degrees between where the camera points and where the train is.
function Sim.aim_error()
    local cam = Sim.camera()
    local d = vec(train.loc.X - cam.loc.X, train.loc.Y - cam.loc.Y, 0)
    local yaw = math.deg(math.atan(d.Y, d.X))
    local err = (cam.rot.Yaw - yaw) % 360
    if err > 180 then err = 360 - err end
    return err
end

function Sim.viewing(obj)
    return obj ~= nil and pc.view_target ~= nil and pc.view_target.address == obj.address
end

function Sim.log_count(text)
    local n = 0
    for _, l in ipairs(Sim.logs) do if l:find(text, 1, true) then n = n + 1 end end
    return n
end

function Sim.all_logs() return table.concat(Sim.logs) end

return Sim
