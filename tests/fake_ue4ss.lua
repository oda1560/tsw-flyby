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

local seat_back_at -- below, with the seats

local function blocked_at(p)
    if p.Z < Sim.ground(p.X, p.Y) then return true end
    if seat_back_at and seat_back_at(p) then return true end
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
    -- its root component, which its seat groups and the seat view's camera attach to
    o.K2_GetRootComponent = function(self)
        if not self.root then
            self.root = object("SceneComponent " .. self.name .. ".DefaultSceneRoot", { owner = self, is_root = true })
            self.root.K2_GetComponentLocation = function(r) return to_world((Sim.component_place(r))) end
            self.root.K2_GetComponentRotation = function(r)
                local _, y = Sim.component_place(r)
                return { Pitch = 0, Yaw = y, Roll = 0 }
            end
        end
        return self.root
    end
    -- the seat groups on it (opts.search_only: the game won't say, they can only be searched for)
    o.K2_GetComponentsByClass = function(self, class)
        if Sim.opts.search_only then error("no K2_GetComponentsByClass") end
        local out = {}
        for _, g in ipairs(Sim.groups) do
            if g.owner == self and g.classes[class.short] then out[#out + 1] = g end
        end
        return Sim.tarray(out)
    end
    return o
end

function Sim.fake_class(name)
    return object("Class /Script/Game." .. name, {
        ForEachFunction = function(self, fn) fn(object("Function GetCameraThing", { GetFName = function() return { ToString = function() return "GetCameraThing" end } end })) end,
        ForEachProperty = function(self, fn) end,
        GetSuperStruct = function(self) return object("Class /Script/Engine.Actor") end,
    })
end

----------------------------------------------------------------------------------------------------
-- Seats: groups of seats (the game's SeatComponent) on the vehicles' views, each seat with its LocalPosition,
-- LocalRotation and CameraOffset in its group's frame. Only yaw is used for turning here.

local function yaw_of(v) return math.deg(math.atan(v.Y, v.X)) end
local function turn_yaw(yaw, v)
    local c, s = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
    return vec(v.X * c - v.Y * s, v.X * s + v.Y * c, v.Z)
end
local function add(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
Sim.turn_yaw, Sim.yaw_of = turn_yaw, yaw_of

local function tarray(list)
    return { ForEach = function(self, fn)
        for i, v in ipairs(list) do fn(i, { get = function() return v end }) end
    end }
end
Sim.tarray = tarray

-- Where a seat group belongs on its vehicle, in line coordinates, and its yaw.
function Sim.group_place(g)
    local view = g.owner
    local vyaw = yaw_of(view.fwd or vec(1, 0, 0))
    return add(view.loc, turn_yaw(vyaw, g.rel)), vyaw + g.yaw
end

-- Where a component the camera can attach to is, in line coordinates, and its yaw: a seat group, or a vehicle's root.
function Sim.component_place(c)
    if c.is_root then return c.owner.loc, yaw_of(c.owner.fwd or vec(1, 0, 0)) end
    return Sim.group_place(c)
end

Sim.groups = {}
-- seats: { { pos = vec, face = yaw it faces, offset = vec or nil, taken = bool } }. Each seat's LocalRotation is the
-- way it faces, or (opts.socket_rotation) a quarter turn less, as Unreal's characters face their Y axis and the
-- Class 331's seats turned out to. A group the game has let go of (g.loose), as it does with a car's seats when the
-- car is far off, is attached to nothing and keeps its place relative to the root: it's at that place in the world.
local function seat_group(view, name, role, rel, yaw, seats, multi)
    for _, s in ipairs(seats) do s.yaw = s.face - (Sim.opts.socket_rotation and 90 or 0) end
    local g = object((multi and "MultiSeatComponent " or "SeatComponent ") .. view.name .. ".Seats" .. (#Sim.groups + 1), {
        classes = { SeatBaseComponent = true, SeatComponent = not multi, MultiSeatComponent = multi },
        owner = view, rel = rel, yaw = yaw, seats = seats,
        StandardSeatName = name, SeatRole = role, HitTestCameraZOffset = 60, MinCameraDistanceToShowCharacter = 50,
    })
    local regions = {}
    for _, s in ipairs(seats) do
        regions[#regions + 1] = { LocalPosition = s.pos, LocalRotation = { Pitch = 0, Yaw = s.yaw, Roll = 0 },
                                  CameraOffset = s.offset or vec(0, 0, 0) }
    end
    g.SeatRegions = tarray(regions)
    g.GetOwner = function(self) return self.owner end
    g.GetAttachParent = function(self) return self.loose and invalid() or self.owner:K2_GetRootComponent() end
    g.RelativeLocation, g.RelativeRotation = rel, { Pitch = 0, Yaw = yaw, Roll = 0 }
    g.K2_GetComponentLocation = function(self)
        if self.loose then return vec(self.rel.X, self.rel.Y, self.rel.Z) end
        return to_world((Sim.group_place(self)))
    end
    g.K2_GetComponentRotation = function(self)
        local _, y = Sim.group_place(self)
        return { Pitch = 0, Yaw = self.loose and self.yaw or y, Roll = 0 }
    end
    g.GetSeatRegionCount = function(self) return #self.seats end
    if not Sim.opts.no_region_functions then
        g.GetSeatRegionLocalPosition = function(self, i) return self.seats[i + 1].pos end
        g.GetPassengerModelInSeatRegion = function(self, i)
            return self.seats[i + 1].taken and object("SkeletalMeshComponent Passenger") or invalid()
        end
    end
    Sim.groups[#Sim.groups + 1] = g
    return g
end

-- Four passenger seats in two rows facing each other: the first pair give the game's camera offset, the others not.
local function passenger_seats(taken)
    return {
        { pos = vec(0, -60, 45), face = 0, offset = vec(0, 0, 70), taken = taken },
        { pos = vec(0, 60, 45), face = 0, offset = vec(0, 0, 70), taken = taken },
        { pos = vec(180, -60, 45), face = 180, taken = taken },
        { pos = vec(180, 60, 45), face = 180, taken = taken },
    }
end

-- Eight seats in two rows facing each other, two each side of the aisle, side by side 50 cm apart.
local function paired_seats(taken)
    local seats = {}
    for _, row in ipairs({ { 0, 0 }, { 180, 180 } }) do
        for _, y in ipairs({ -85, -35, 35, 85 }) do
            seats[#seats + 1] = { pos = vec(row[1], y, 45), face = row[2], taken = taken }
        end
    end
    return seats
end

-- Eight seats on two benches along the sides of the car, 50 cm apart, facing inward across it.
local function bench_seats(taken)
    local seats = {}
    for _, y in ipairs({ -130, 130 }) do
        for i = 0, 3 do
            seats[#seats + 1] = { pos = vec(-75 + 50 * i, y, 45), face = y > 0 and -90 or 90, taken = taken }
        end
    end
    return seats
end

-- Whether a point (line coordinates) is in a seat's back: a box behind where its passenger sits, up to head height.
-- None with opts.no_backs (seats the traces go through).
seat_back_at = function(p)
    if Sim.opts.no_backs then return false end
    for _, g in ipairs(Sim.groups) do
        if g.valid then
            local at, gyaw = Sim.group_place(g)
            if math.abs(p.X - at.X) < 500 and math.abs(p.Y - at.Y) < 500 then
                for _, st in ipairs(g.seats) do
                    local o = add(at, turn_yaw(gyaw, st.pos))
                    local q = turn_yaw(-(gyaw + st.face), vec(p.X - o.X, p.Y - o.Y, p.Z - o.Z))
                    if q.X >= -30 and q.X <= -8 and math.abs(q.Y) <= 25 and q.Z >= 0 and q.Z <= 110 then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- Where each seat of a group puts the eyes, in line coordinates, and which way they look: the seat's camera offset,
-- or `eye_height` cm above the seat.
function Sim.seat_eyes(g, eye_height)
    local at, yaw = Sim.group_place(g)
    local out = {}
    for i, s in ipairs(g.seats) do
        local rel = s.offset and add(s.pos, turn_yaw(s.yaw, s.offset)) or add(s.pos, vec(0, 0, eye_height))
        out[i] = { pos = add(at, turn_yaw(yaw, rel)), yaw = yaw + s.yaw }
    end
    return out
end

-- Where the camera is, in line coordinates, and its yaw: attached to something, from that.
local function camera_place(cam)
    if cam.attach then
        local at, yaw = Sim.component_place(cam.attach)
        return add(at, turn_yaw(yaw, cam.rel_loc)), yaw + cam.rel_rot.Yaw
    end
    return cam.loc, cam.rot and cam.rot.Yaw or 0
end
Sim.camera_place = camera_place

-- The camera's rotation in the world: {Pitch, Yaw (from -180 to 180), Roll}.
function Sim.camera_rot(cam)
    local _, yaw = camera_place(cam)
    local r = cam.attach and cam.rel_rot or cam.rot or { Pitch = 0, Roll = 0 }
    return { Pitch = r.Pitch, Yaw = (yaw + 180) % 360 - 180, Roll = r.Roll }
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
    cam.K2_SetActorRotation = function(self, r)
        if self.attach then -- the world rotation asked for, kept relative to what it's attached to
            local _, gyaw = Sim.component_place(self.attach)
            self.rel_rot = { Pitch = r.Pitch, Yaw = r.Yaw - gyaw, Roll = r.Roll }
        else
            self.rot = r
        end
        return true
    end
    cam.K2_DestroyActor = function(self) self.valid = false end
    cam.K2_GetActorLocation = function(self) return to_world((camera_place(self))) end
    cam.GetActorForwardVector = function(self)
        local _, yaw = camera_place(self)
        return turn_yaw(yaw, vec(1, 0, 0))
    end
    cam.K2_AttachToComponent = function(self, comp, socket, loc_rule, rot_rule, scale_rule)
        if Sim.opts.no_attach then error("attaching not allowed") end
        assert(socket ~= nil and loc_rule == 2 and rot_rule == 2, "attach: snap to it")
        self.attach, self.rel_loc, self.rel_rot = comp, vec(0, 0, 0), { Pitch = 0, Yaw = 0, Roll = 0 }
        return true
    end
    cam.K2_SetActorRelativeLocation = function(self, v) self.rel_loc = vec(v.X, v.Y, v.Z) end
    cam.K2_SetActorRelativeRotation = function(self, r)
        self.rel_rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
    end
    cam.K2_DetachFromActor = function(self)
        if not self.attach then return end
        local at, yaw = camera_place(self)
        self.loc, self.rot, self.attach = at, { Pitch = 0, Yaw = yaw, Roll = 0 }, nil
    end
    cam.GetAttachParentActor = function(self) return self.attach and self.attach.owner or invalid() end
    Sim.cameras[#Sim.cameras + 1] = cam
    return cam
end

-- A rail vehicle's model actor's RailVehicleComponent: GetFormation(2) lists the train front to back.
local function vehicle_component(models)
    return object("RailVehicleComponent RailVehiclePhysicsComponent0", {
        GetFormation = function(self, mode)
            if mode ~= 2 then error("not front to back") end
            return tarray(models)
        end,
    })
end

function Sim.setup(opts)
    opts = opts or {}
    Sim.opts = opts
    Sim.mouse = { dx = 0, dy = 0 }
    Sim.logs, Sim.time, Sim.frame_fns, Sim.cameras, Sim.keys, Sim.groups = {}, 0, {}, {}, {}, {}
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

    -- The train's coaches behind the loco (opts.coaches of them, 2 unless set), the loco's driver's seat, the
    -- coaches' passenger seats, and the AI train's own. The seats' StandardSeatName and SeatRole: by default named;
    -- opts.unmarked: Generic, no role; opts.default_names: names left at 0 (Engineer), only the roles set, as the
    -- Class 331's are; opts.unset: neither set. opts.multiseat: each coach's seats a MultiSeatComponent, as the
    -- Class 331's are, with neither set. The coaches' seats: in rows of two facing each other (passenger_seats),
    -- opts.pairs: two side by side each side of the aisle; opts.benches: on benches along the sides, facing inward.
    Sim.coaches = {}
    local train_models = { model }
    for i = 1, opts.coaches or 2 do
        local level = "/Game/Maps/Route.Route:PersistentLevel."
        local m = actor_methods(object("RVM_Coach_C " .. level .. "RVM_Coach_C_" .. (10 + 2 * i)))
        m.loc = vec(0, 0, 0)
        m.classes = { RailVehicle = true }
        local v = actor_methods(object("RVV_Coach_C " .. level .. "RVV_Coach_C_" .. (11 + 2 * i)))
        v.parent = m
        v.classes = { RailVehicleView = true }
        v.loc = vec(0, 0, 0)
        Sim.coaches[i] = { model = m, view = v }
        train_models[#train_models + 1] = m
        Sim.models[#Sim.models + 1], Sim.views[#Sim.views + 1] = m, v
    end
    Sim.train_models = train_models
    if opts.formation ~= false then model.RailVehiclePhysicsComponent = vehicle_component(train_models) end
    local cab_name, cab_role, name, role = 1, 0, 6, 3                  -- Driver; UKStandardClass, Passenger
    if opts.unmarked then name, role = 11, 0 end                       -- Generic, None
    if opts.default_names then cab_name, cab_role, name, role = 0, 1, 0, 3 end -- the names all 0 (Engineer)
    if opts.unset or opts.multiseat then name, role = 0, 0 end
    local cab_seat = { pos = vec(0, 40, 90), face = 0, offset = vec(0, 0, 70) }
    seat_group(train, cab_name, cab_role, vec(600, 0, 0), 0, { cab_seat })
    local seating = opts.benches and bench_seats or opts.pairs and paired_seats or passenger_seats
    for _, c in ipairs(Sim.coaches) do
        seat_group(c.view, name, role, vec(-600, 0, 0), 0, seating(opts.taken), opts.multiseat)
        seat_group(c.view, name, role, vec(300, 0, 0), 0, seating(opts.taken), opts.multiseat)
    end
    seat_group(other, 6, 3, vec(0, 0, 0), 0, passenger_seats())
    if opts.seats_on_models then -- every seat on a model actor at the world's origin
        for _, g in ipairs(Sim.groups) do g.owner = g.owner.parent end
    end

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
        bShowMouseCursor = false,
        -- the mouse's movement this frame (Sim.mouse), in the tables passed for it; opts.mouse_returns: returned
        -- instead; opts.no_mouse: the game won't say
        GetInputMouseDelta = function(self, out_x, out_y)
            if Sim.opts.no_mouse then error("no GetInputMouseDelta") end
            if Sim.opts.mouse_returns then return Sim.mouse.dx, Sim.mouse.dy end
            out_x.DeltaX, out_y.DeltaY = Sim.mouse.dx, Sim.mouse.dy
        end,
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
    for i, c in ipairs(Sim.coaches) do
        local cp, cd = Sim.path(Sim.s - i * 2300)
        c.view.loc = vec(cp.X, cp.Y, cp.Z + 50)
        c.view.fwd = cd
        c.view.vel = vec(cd.X * Sim.speed, cd.Y * Sim.speed, 0)
    end
end

-- The game moving its world origin: everything it reports jumps by `by`.
function Sim.shift_origin(by)
    Sim.origin = vec(Sim.origin.X + by.X, Sim.origin.Y + by.Y, Sim.origin.Z + by.Z)
end

----------------------------------------------------------------------------------------------------
-- UE4SS globals

print = function(text) Sim.logs[#Sim.logs + 1] = text end

Key = { ZERO = 48, ONE = 49, TWO = 50, THREE = 51, FOUR = 52, FIVE = 53, SIX = 54, SEVEN = 55, EIGHT = 56,
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
    local list = (name == "RailVehicle" and Sim.models) or (name == "RailVehicleView" and Sim.views) or Sim.groups
    local out = {}
    for _, v in ipairs(list) do
        if v.valid and (list ~= Sim.groups or v.classes[name]) then out[#out + 1] = v end
    end
    return #out > 0 and out or nil
end
function FindObjects() return {} end
function StaticFindObject(path)
    if path == "/Script/Engine.CameraActor" then return object("Class /Script/Engine.CameraActor") end
    if path == "/Script/TS2Prototype.RailVehicleView" and Sim.view_class_known then
        return object("Class /Script/TS2Prototype.RailVehicleView", { short = "RailVehicleView" })
    end
    if path == "/Script/TS2Prototype.RailVehicle" then
        return object("Class /Script/TS2Prototype.RailVehicle", { short = "RailVehicle" })
    end
    for _, c in ipairs({ "SeatBaseComponent", "SeatComponent", "MultiSeatComponent" }) do
        if path == "/Script/TS2Prototype." .. c then return object("Class " .. path, { short = c }) end
    end
    -- opts.consist_lib: the game's function saying whether a vehicle is in the player's train
    if Sim.opts.consist_lib then
        if path == "/Script/TS2Prototype.TS2GameplayFunctionLibrary:IsConsistPlayerDriven" then
            return object("Function IsConsistPlayerDriven")
        end
        if path == "/Script/TS2Prototype.Default__TS2GameplayFunctionLibrary" then
            return object("TS2GameplayFunctionLibrary Default__TS2GameplayFunctionLibrary", {
                IsConsistPlayerDriven = function(self, actor)
                    for _, m in ipairs(Sim.train_models) do
                        if m == actor then return true end
                    end
                    return false
                end,
            })
        end
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
