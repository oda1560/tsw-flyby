-- Fly-by camera for Train Sim World 7, as a UE4SS Lua mod.
-- Press 7 and the view cuts to a camera standing beside the line ahead of your train. It turns to follow the
-- train as it goes by, then moves on ahead again. Press 7 again for a new spot straight away.
-- Press 4 for the view from a random passenger seat on your train, riding along with it: a passenger looking the way
-- their seat faces, out of the nearest window, their head moving with the train (seat_head.lua); the mouse turns it
-- too. 4 again for another seat.
-- Press 6, or one of the game's own camera keys, to go back.
-- You can keep driving while it's on. Everything it does is written to UE4SS.log, lines starting [FlyBy].
--
-- The seats are the game's own (SeatBaseComponent / SeatComponent, read from TrainSimWorld.exe's reflection tables):
-- each is a group of seats on a vehicle's view actor (RVV_...), listed in its SeatRegions with each seat's
-- LocalPosition, LocalRotation and CameraOffset; StandardSeatName and SeatRole say what kind of seat it is. Your
-- train's vehicles are the game's list of them (RailVehicleComponent GetFormation), which holds the model actors
-- (RVM_...) that the views are attached to.

local UEHelpers = require("UEHelpers")
local FM = require("flyby_math")
local H = require("seat_head")
local S = require("flyby_settings")

local CM = 100
local MEASURE = 0.4     -- seconds spent timing the train before cutting to the camera
local MEASURE_FRAMES = 90 -- or this many frames, for when the game is paused
local MIN_GAP = 1.0     -- seconds between moves, so a spot that can't be fixed doesn't make it jump every frame
local KEY_WINDOW = 0.5  -- a camera key or camera switch this close to the game taking the view means you did it
local LEAVE_WAIT = 0.3  -- after a camera key, how long to wait for the game to switch before going back ourselves
local GIVE_UP = 4       -- the game taking the view this many times...
local GIVE_UP_IN = 3.0  -- ...within this many seconds: stop fighting it
local DEBUG_EVERY = 2.0 -- seconds between debug lines

local MAX_SEAT_DISTANCE = 1000 * CM -- a seat further than this from your vehicle isn't where your train is
local MAX_ON_VEHICLE = 50 * CM      -- a seat group further than this from its own vehicle has been let go of
local MAX_SEATS = 2000              -- seats looked at, at most
local FRONT_TO_BACK = 2             -- EActorConnectionIterationMode::FrontToBack: GetFormation's whole train
local SNAP, KEEP_WORLD = 2, 1       -- EAttachmentRule
local MOVING = 0.5 * CM             -- cm/s: faster than this the seat view goes by the way the train moves
local MIDDLE_SEAT = 20              -- cm: a seat this close to the middle of its car is nearer neither window
local BACK_REACH = 45               -- cm traced forward and back from a seat's eyes to find its back...
local BACK_HEIGHTS = { 10, 35 }     -- ...this far below the eyes (headrest, back)...
local BACK_CLOSER = 10              -- ...which is the side hit this much closer than the other
-- The game's seat classes: a SeatComponent is a seat or two (a cab's), a MultiSeatComponent a car's passenger seating
local SEAT_CLASSES = { "SeatBaseComponent", "SeatComponent", "MultiSeatComponent" }
-- The game's seat enums, in their order from 0
local SEAT_NAMES = { [0] = "Engineer", "Driver", "Secondman", "UKFirstClass", "UKSecondClass", "UKThirdClass",
    "UKStandardClass", "USFirstClass", "USBusinessClass", "USCoachClass", "GenericPassenger", "Generic", "Steps",
    "Ladder", "InspectionHatch" }
local SEAT_ROLES = { [0] = "None", "Engineer", "Conductor", "Passenger" }
local SEAT_VERBS = { [0] = "SitIn", "SitOn", "StandOn", "ClimbUp", "ClimbDown", "GoUp", "GoDown", "LookThrough",
    "Generic" }
-- Engineer (0) is also what a seat whose name was never set reads as, so on its own it says nothing.
local CREW_SEATS = { Driver = true, Secondman = true, Steps = true, Ladder = true, InspectionHatch = true }
local PASSENGER_SEATS = { UKFirstClass = true, UKSecondClass = true, UKThirdClass = true, UKStandardClass = true,
    USFirstClass = true, USBusinessClass = true, USCoachClass = true, GenericPassenger = true }
-- The game's function libraries that might have IsConsistPlayerDriven
local LIBRARIES = { "PhysicsFunctionLibrary", "TS2GameplayFunctionLibrary", "TS2BlueprintSupportLibrary",
                    "TSWVehicleFunctionLibrary", "TS2VehicleControlLibrary", "DTGFunctionLibrary" }

local function log(fmt, ...)
    print("[FlyBy] " .. string.format(fmt, ...) .. "\n")
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

-- "RVV_AABS_Class70_C_2147470336" instead of the class and the whole map path
local function short_name(o)
    local name = name_of(o)
    return name:match("[%.:]([^%.:]+)$") or name
end

local function as_vec(v) return FM.vec(v.X, v.Y, v.Z) end
local function location(actor) return as_vec(actor:K2_GetActorLocation()) end

local function forward_of(actor)
    local ok, fwd = pcall(function() return as_vec(actor:GetActorForwardVector()) end)
    return ok and fwd or nil
end
local function where(p) return string.format("%.0f %.0f %.0f", p.X, p.Y, p.Z) end

local function game_time(pc)
    local ok, t = pcall(function() return UEHelpers.GetGameplayStatics():GetTimeSeconds(pc) end)
    if ok and type(t) == "number" then return t end
    return os.clock()
end

local state = {
    active = false, mode = nil, measuring = false, showing = false, -- mode "flyby" or "seat"; showing: the view is ours
    pc = nil, train = nil, camera = nil, previous_view = nil,
    seat = nil, attached = false,   -- the seat the camera is in, and whether it rides attached to it
    tracker = nil, loop = nil,
    started_at = 0, frames = 0, measure_from = nil,
    placed_at = 0, placed_dir = nil, next_side = 1, want_new_spot = nil, traces_broken = false,
    grabs = {}, last_grab = nil, camera_key_at = nil, leave_at = nil, game_switched = false,
    debug_at = 0, debug_from = nil,
}

----------------------------------------------------------------------------------------------------
-- Finding the train

local function camera_location(pc)
    local cm = pc.PlayerCameraManager
    if valid(cm) then return as_vec(cm:GetCameraLocation()) end
    if valid(pc.Pawn) then return location(pc.Pawn) end
    return nil
end

local function at_origin(actor)
    local ok, p = pcall(location, actor)
    return not ok or FM.len(p) < 1 -- the models sit at exactly 0 0 0
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
    if not class then return false end
    local ok, yes = pcall(function() return actor:IsA(class) end)
    return ok and yes == true
end

local function nearest(actors, from)
    local best, best_d = nil, math.huge
    for _, a in ipairs(actors or {}) do
        if valid(a) and not at_origin(a) then
            local d = FM.len(FM.sub(location(a), from))
            if d < best_d then best, best_d = a, d end
        end
    end
    return best, best_d
end

-- The vehicle to follow. TSW splits each rail vehicle in two: the model (CL70_FL_RVM_C and the like), which
-- stays at the world's origin, and the view you see (RVV_...), which moves. The driver is attached to the view.
local function find_train(pc)
    local view_class = StaticFindObject("/Script/TS2Prototype.RailVehicleView")
    if not valid(view_class) then view_class = nil end
    local chain = attach_chain(pc.Pawn)
    for _, a in ipairs(chain) do
        if is_a(a, view_class) and not at_origin(a) then return a, "the player is in it" end
    end
    for _, a in ipairs(chain) do
        if not at_origin(a) then return a, "the player is attached to it" end
    end
    if #chain > 0 and not at_origin(pc.Pawn) then
        return pc.Pawn, "the driver, as the train itself gives no position"
    end
    local from = camera_location(pc)
    if not from then return nil, "can't tell where the game's camera is" end
    local best, d = nearest(FindAllOf("RailVehicleView"), from)
    if not best then best, d = nearest(FindAllOf("RailVehicle"), from) end
    if not best then return nil, "no train found near the camera" end
    return best, string.format("nearest the camera, %.0f m away", d / CM)
end

----------------------------------------------------------------------------------------------------
-- Picking a spot

-- Where a line from `from` to `to` first hits something, or nil when it's clear.
local function trace(pc, from, to)
    local hit = {}
    local none = { R = 0, G = 0, B = 0, A = 0 }
    local blocked = UEHelpers.GetKismetSystemLibrary():LineTraceSingle(
        pc, from, to, 0, false, {}, 0, hit, true, none, none, 0.0)
    if not blocked then return nil end
    local p = hit.ImpactPoint or hit.Location
    return FM.vec(p.X, p.Y, p.Z)
end

-- Stands the spot on the ground, then scores it: 2 for a clear view across to the line, 1 for seeing the train
-- coming. Notes what it found in spot.notes.
local function rate_spot(pc, spot, train_pos)
    local up = FM.vec(0, 0, 30 * CM)
    local line_z = spot.pos.Z - S.HeightAboveTrain * CM
    local ground = trace(pc, FM.add(spot.pos, up), FM.sub(spot.pos, up))
    if ground then
        spot.pos.Z = ground.Z + S.EyeHeight * CM
        spot.notes = string.format("ground %+.1f m from the train", (ground.Z - line_z) / CM)
    else
        spot.notes = "no ground found"
    end

    local score = 0
    local across = FM.add(spot.track, FM.vec(0, 0, S.AimHeight * CM))
    if not trace(pc, spot.pos, across) then
        score = score + 2
        spot.notes = spot.notes .. ", line in view"
    else
        spot.notes = spot.notes .. ", line hidden"
    end

    local coming = FM.add(train_pos, FM.vec(0, 0, S.AimHeight * CM))
    local toward = FM.sub(coming, spot.pos)
    local d = FM.len(toward)
    if d > 20 * CM then
        local short_of_train = FM.add(spot.pos, FM.scale(toward, (d - 15 * CM) / d)) -- don't count the train itself
        if not trace(pc, spot.pos, short_of_train) then
            score = score + 1
            spot.notes = spot.notes .. ", train in view"
        else
            spot.notes = spot.notes .. ", train hidden"
        end
    end
    return score
end

local function choose_spot(pc, train_pos, dir)
    local spots = FM.candidates(train_pos, dir, state.tracker, S, state.next_side)
    if not S.CheckView or state.traces_broken then
        spots[1].notes = "not checked"
        return spots[1], 0
    end
    local best, best_score, tried = spots[1], -1, 0
    for _, spot in ipairs(spots) do
        tried = tried + 1
        local ok, score = pcall(rate_spot, pc, spot, train_pos)
        if not ok then
            log("can't check the view (%s), placing without checks from now on", tostring(score))
            state.traces_broken = true
            spots[1].notes = "not checked"
            return spots[1], tried
        end
        if score > best_score then best, best_score = spot, score end
        if score >= 3 then break end
    end
    return best, tried
end

local function place(pc, why)
    local cam, train = state.camera, state.train
    local train_pos = location(train)
    local dir = state.tracker.dir
    if not dir then
        local fwd = forward_of(train)
        dir = fwd and FM.flat_dir(fwd) or FM.vec(1, 0, 0)
    end
    local spot, tried = choose_spot(pc, train_pos, dir)
    local facing = FM.look_at(spot.pos, train_pos)
    if not cam:K2_TeleportTo(spot.pos, facing) then
        cam:K2_SetActorLocation(spot.pos, false, {}, true)
        cam:K2_SetActorRotation(facing, false)
    end
    local side = spot.side > 0 and 1 or -1
    if S.Side == "alternate" then state.next_side = -side end
    state.placed_dir = dir
    state.placed_at = game_time(pc)
    log("new spot %.0f m ahead on the %s (%s): train %.1f m/s, line %s, %s (spot %d tried)",
        FM.len2(FM.sub(spot.track, train_pos)) / CM, side > 0 and "right" or "left", why,
        state.tracker.speed / CM, FM.describe_curve(state.tracker.curvature), spot.notes or "", tried)
end

----------------------------------------------------------------------------------------------------
-- The seats on your train

local classes = {}
local function class(path)
    local c = classes[path]
    if not valid(c) then
        c = StaticFindObject(path)
        classes[path] = c
    end
    return valid(c) and c or nil
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

-- The class default object of the game's function library that has the static function `name`.
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

-- The rail vehicle you drive: its model actor (RVM_..., at the world's origin).
local function find_drivable(pc)
    local ok, d = pcall(function() return pc:GetCurrentLocalDrivableActor(pc:GetWorld()) end)
    if ok and valid(d) then return d end
    local rv = class("/Script/TS2Prototype.RailVehicle")
    for _, a in ipairs(attach_chain(pc.Pawn)) do
        if is_a(a, rv) then return a end
    end
    return nil
end

-- The vehicles of your train, front to back, from the game's GetFormation on the RailVehicleComponent of the one you
-- drive (the actor itself has none). nil and why if it won't say.
local function formation(drivable)
    local comp, how = nil, nil
    local ok, c = pcall(function() return drivable.RailVehiclePhysicsComponent end)
    if ok and valid(c) then
        comp, how = c, "its RailVehiclePhysicsComponent"
    else
        local cls = class("/Script/TS2Prototype.RailVehicleComponent")
        local ok2, c2 = pcall(function() return drivable:GetComponentByClass(cls) end)
        if cls and ok2 and valid(c2) then comp, how = c2, "its RailVehicleComponent" end
    end
    if not comp then return nil, short_name(drivable) .. " has no RailVehicleComponent" end
    local ok3, arr = pcall(function() return comp:GetFormation(FRONT_TO_BACK) end)
    if not ok3 or arr == nil then
        return nil, string.format("GetFormation of %s: %s", how, ok3 and "it gave nothing" or tostring(arr))
    end
    local list = {}
    local ok4, err = pcall(each_in, arr, function(v)
        if valid(v) then list[#list + 1] = v end
    end)
    if not ok4 then return nil, string.format("GetFormation of %s: %s", how, tostring(err)) end
    for _, v in ipairs(list) do
        if same(v, drivable) then return list, "GetFormation of " .. how end
    end
    return nil, string.format("GetFormation of %s: its %d vehicles left out the one you drive", how, #list)
end

-- Your train: a function giving, for an actor, its place in the train front to back (true when the place isn't
-- known), or nil when it isn't one of your train's vehicles; how many vehicles (nil if not known); how that was found.
local function my_train(pc, follow)
    local drivable = find_drivable(pc)
    if not drivable then
        return function(a) return same(a, follow) or nil end, 1,
            "only the vehicle you're in: the game doesn't say which one you drive"
    end
    local list, how = formation(drivable)
    if list then
        local at = {}
        for i, v in ipairs(list) do at[v:GetAddress()] = i end
        return function(a) return at[a:GetAddress()] end, #list, how
    end
    local lib = library_for("IsConsistPlayerDriven")
    if lib then
        local ok, yes = call_out(lib, "IsConsistPlayerDriven", drivable)
        if ok and yes == true then
            return function(a)
                local ok2, y = call_out(lib, "IsConsistPlayerDriven", a)
                return (ok2 and y == true) or nil
            end, nil, "the game saying which vehicles are the player's (" .. how .. ")"
        end
    end
    return function(a) return (same(a, drivable) or same(a, follow)) or nil end, 1,
        "only the vehicle you drive (" .. how .. ")"
end

-- A game FVector / FRotator as a Lua table, or nil if it isn't one.
local function vec_of(v)
    local ok, r = pcall(function() return FM.vec(v.X, v.Y, v.Z) end)
    if ok and type(r.X) == "number" and type(r.Y) == "number" and type(r.Z) == "number" then return r end
    return nil
end
local function rot_of(v)
    local ok, r = pcall(function() return { Pitch = v.Pitch, Yaw = v.Yaw, Roll = v.Roll } end)
    if ok and type(r.Pitch) == "number" and type(r.Yaw) == "number" and type(r.Roll) == "number" then return r end
    return nil
end
local function field(o, name)
    local ok, v = pcall(function() return o[name] end)
    if ok then return v end
    return nil
end

-- An FText / FString / FName the game gave, as a Lua string; nil if it isn't one.
local function text_of(v)
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    return nil
end

-- The seats of a seat component: { index (the game's, from 0), pos, rot, offset, pos_from } in its own frame. The
-- position is the game's GetSeatRegionLocalPosition where it gives one, else the seat's LocalPosition.
local function regions_of(comp, room)
    local list = {}
    local arr = field(comp, "SeatRegions")
    if arr ~= nil then
        pcall(each_in, arr, function(r)
            if #list >= room then return end
            list[#list + 1] = { index = #list, pos = vec_of(field(r, "LocalPosition")),
                rot = rot_of(field(r, "LocalRotation")), offset = vec_of(field(r, "CameraOffset")),
                pos_from = "LocalPosition" }
        end)
    end
    if #list == 0 then
        local ok, n = pcall(function() return comp:GetSeatRegionCount() end)
        if ok and type(n) == "number" then
            for i = 0, math.min(n, room) - 1 do list[#list + 1] = { index = i } end
        end
    end
    local kept = {}
    for _, r in ipairs(list) do
        local ok, p = pcall(function() return vec_of(comp:GetSeatRegionLocalPosition(r.index)) end)
        if ok and p then r.field_pos, r.pos, r.pos_from = r.pos, p, "GetSeatRegionLocalPosition" end
        if r.pos then
            r.rot = r.rot or { Pitch = 0, Yaw = 0, Roll = 0 }
            kept[#kept + 1] = r
        end
    end
    return kept
end

-- What a seat component's seats are: "passenger", "crew" (a cab seat, steps, a ladder) or "maybe" when it doesn't
-- say; and their type as the game has it, "name/role". The role goes first: it's the one a seat left with the
-- default name still has set.
local function seat_kind(comp)
    local name = SEAT_NAMES[field(comp, "StandardSeatName")]
    local role = SEAT_ROLES[field(comp, "SeatRole")]
    local multi = is_a(comp, class("/Script/TS2Prototype.MultiSeatComponent"))
    local label = (name or "?") .. "/" .. (role or "?") .. (multi and " multi-seat" or "")
    if role == "Passenger" then return "passenger", label end
    if role == "Engineer" or role == "Conductor" or CREW_SEATS[name] then return "crew", label end
    if multi or PASSENGER_SEATS[name] then return "passenger", label end
    return "maybe", label
end

-- Your vehicle's place in the train, for the actor a seat is on or what it's attached to.
local function place_in(train, actor)
    local place = train(actor)
    if place then return place end
    for _, a in ipairs(attach_chain(actor)) do
        place = train(a)
        if place then return place end
    end
    return nil
end

-- Where a seat group is on its vehicle: { root = the vehicle's root component, pos and rot = the group's place and
-- rotation in the root's frame, at = where that is in the world now, loose = true if the game has let go of it }, or
-- nil if the vehicle has no root. The game lets go of a car's seat groups when the car is far off (the Rotem cars'
-- ComponentLODManagement unregisters and detaches their MultiSeatComponent beyond 80 m), and a group it has let go
-- of stays at the world's origin while its car goes on. Its place on the car is then the one it keeps relative to
-- what it was attached to: the root, in the blueprints seen.
local function on_vehicle(comp, owner)
    local ok, root = pcall(function() return owner:K2_GetRootComponent() end)
    if not ok or not valid(root) then return nil end
    local root_pos, root_rot = as_vec(root:K2_GetComponentLocation()), rot_of(root:K2_GetComponentRotation())
    local okp, parent = pcall(function() return comp:GetAttachParent() end)
    local f = { root = root, loose = okp and not valid(parent) }
    if not f.loose then
        f.pos = FM.unturn(root_rot, FM.sub(as_vec(comp:K2_GetComponentLocation()), root_pos))
        f.rot = FM.uncombine(root_rot, rot_of(comp:K2_GetComponentRotation()))
        f.loose = FM.len(f.pos) > MAX_ON_VEHICLE
    end
    if f.loose then
        f.pos, f.rot = vec_of(field(comp, "RelativeLocation")), rot_of(field(comp, "RelativeRotation"))
        if not (f.pos and f.rot and FM.len(f.pos) <= MAX_ON_VEHICLE) then
            f.pos, f.rot = FM.vec(0, 0, 0), { Pitch = 0, Yaw = 0, Roll = 0 }
        end
    end
    f.at = FM.add(root_pos, FM.turn(root_rot, f.pos))
    return f
end

-- The seat groups on your train's vehicles: the views in the world that are attached to one of them (a view hangs
-- off its vehicle's model actor, which is what the game's list of the train has), and the seat groups on those.
local function groups_on_train(train)
    local groups = {}
    for _, view in ipairs(FindAllOf("RailVehicleView") or {}) do
        if valid(view) and place_in(train, view) then
            for _, cname in ipairs(SEAT_CLASSES) do
                local cls = class("/Script/TS2Prototype." .. cname)
                local ok, arr = pcall(function() return view:K2_GetComponentsByClass(cls) end)
                if cls and ok and arr ~= nil then
                    pcall(each_in, arr, function(c)
                        if valid(c) then groups[#groups + 1] = c end
                    end)
                end
            end
        end
    end
    return groups
end

-- Every seat group in the world: a search through all the game's objects.
local function all_groups()
    local groups = {}
    for _, cname in ipairs(SEAT_CLASSES) do
        for _, c in ipairs(FindAllOf(cname) or {}) do groups[#groups + 1] = c end
    end
    return groups
end

-- The seats of those groups that are on your train and near `here`, by kind ("passenger", "maybe"); what was found
-- of the groups; and the groups on your train, each { comp, owner, frame (see on_vehicle), kind, label, place,
-- regions }.
local function seats_in(groups, train, here)
    local found = { passenger = {}, maybe = {} }
    local seen, count = {}, { total = 0, passenger = 0, maybe = 0, crew = 0, other = 0, far = 0, unread = 0,
        loose = 0 }
    local on_train = {}
    for _, comp in ipairs(groups) do
        local addr = valid(comp) and comp:GetAddress()
        if addr and not seen[addr] then
            seen[addr] = true
            count.total = count.total + 1
            local ok, owner = pcall(function() return comp:GetOwner() end)
            local okf, frame = pcall(function() return valid(owner) and on_vehicle(comp, owner) or nil end)
            local near = ok and okf and frame and FM.len(FM.sub(frame.at, here)) <= MAX_SEAT_DISTANCE
            local place = near and place_in(train, owner)
            if not near then
                count.far = count.far + 1
            elseif not place then
                count.other = count.other + 1
            else
                local kind, label = seat_kind(comp)
                local regions = regions_of(comp, MAX_SEATS - #found.passenger - #found.maybe)
                on_train[#on_train + 1] = { comp = comp, owner = owner, frame = frame, kind = kind, label = label,
                    place = type(place) == "number" and place or nil, regions = regions }
                count[kind] = count[kind] + 1
                if frame.loose then count.loose = count.loose + 1 end
                if found[kind] then
                    if #regions == 0 then count.unread = count.unread + 1 end
                    for _, r in ipairs(regions) do
                        r.key, r.comp, r.vehicle, r.frame, r.name = addr .. ":" .. r.index, comp, owner, frame, label
                        r.place = type(place) == "number" and place or nil
                        table.insert(found[kind], r)
                    end
                end
            end
        end
    end
    return found, count, on_train
end

-- "Engineer/Passenger 11, Driver/Engineer 2": the seat groups on your train by type, most first.
local function seat_types(on_train)
    local n, labels = {}, {}
    for _, g in ipairs(on_train) do
        if not n[g.label] then labels[#labels + 1] = g.label end
        n[g.label] = (n[g.label] or 0) + 1
    end
    table.sort(labels, function(a, b) return n[a] > n[b] or (n[a] == n[b] and a < b) end)
    local parts = {}
    for _, l in ipairs(labels) do parts[#parts + 1] = l .. " " .. n[l] end
    return #parts > 0 and table.concat(parts, ", ") or "none"
end

-- The passenger seats on your train, each { key, comp, index, pos, rot, offset, vehicle, frame, place, name }; what
-- they are ("passenger", or "unmarked" when no seat on the train says), how many vehicles the train has (nil if not
-- known), how they were found, and the seat groups on your train (see seats_in). nil and why when there are none.
-- Made on a key press, not every frame: it looks through the train's vehicles and, if it finds no seats there, every
-- seat in the world.
local function find_seats(pc)
    local started = os.clock()
    local follow, why = find_train(pc)
    if not follow then return nil, why end
    local here = location(follow)
    local train, vehicles, how = my_train(pc, follow)
    local where_from = "on your train's vehicles"
    local found, count, on_train = seats_in(groups_on_train(train), train, here)
    if #found.passenger + #found.maybe == 0 then
        where_from = "in the world"
        found, count, on_train = seats_in(all_groups(), train, here)
    end
    local kind = #found.passenger > 0 and "passenger" or "maybe"
    local summary = string.format("%d seat group%s %s: %d passenger, %d unmarked and %d crew on your train%s%s "
        .. "(by name/role: %s), %d on other trains, %d away from your train; your train from %s; looked in %.0f ms",
        count.total, count.total == 1 and "" or "s", where_from, count.passenger, count.maybe, count.crew,
        count.unread > 0 and string.format(", %d with no seats the mod could read", count.unread) or "",
        count.loose > 0 and string.format(", %d let go of by the game", count.loose) or "",
        seat_types(on_train), count.other, count.far, how, (os.clock() - started) * 1000)
    if #found[kind] == 0 then return nil, summary, nil, nil, on_train end
    return found[kind], kind == "passenger" and "passenger" or "unmarked", vehicles, summary, on_train
end

-- Whether one of the game's passengers sits in the seat; nil if the game won't say.
local function taken(seat)
    local ok, m = pcall(function() return seat.comp:GetPassengerModelInSeatRegion(seat.index) end)
    if not ok then return nil end
    return valid(m)
end

-- A random seat other than the one with `current` as its key, one with nobody in it if there is one.
local function pick_seat(seats, current)
    local choices = {}
    for _, s in ipairs(seats) do
        if s.key ~= current then choices[#choices + 1] = s end
    end
    if #choices == 0 then return seats[1] end
    for i = #choices, 2, -1 do
        local j = math.random(i)
        choices[i], choices[j] = choices[j], choices[i]
    end
    for _, s in ipairs(choices) do
        if taken(s) ~= true then return s end
    end
    return choices[1]
end

local function none_name()
    if NAME_None ~= nil then return NAME_None end
    if FName then
        local ok, n = pcall(FName, "None")
        if ok and n ~= nil then return n end
    end
    return "None"
end

local function yaw_of(v) return math.deg(math.atan(v.Y, v.X)) end

-- The seat group's rotation now, the way along its vehicle (its X axis, flat), and the rotation of the vehicle's root.
-- Both go by the vehicle, so a group the game lets go of while you sit in it doesn't take you with it.
local function group_frame(seat)
    local root_rot = rot_of(seat.frame.root:K2_GetComponentRotation())
    local turned = FM.combine(root_rot, seat.frame.rot)
    return turned, FM.flat_dir(FM.turn(turned, FM.vec(1, 0, 0))) or FM.vec(1, 0, 0), root_rot
end

-- Where the seat's eyes are in the world now.
local function eye_point(seat, turned, root_rot)
    local root = seat.frame.root
    return FM.add(FM.add(as_vec(root:K2_GetComponentLocation()), FM.turn(root_rot, seat.frame.pos)),
        FM.turn(turned, seat.eye))
end

-- Which way along its vehicle a seat faces, in its group's frame, and how that was told: away from its back, found
-- by tracing a short way forward and back from the eyes at the heights of the headrest and the back; or, when that
-- tells nothing, whichever axis of the seat's own rotation runs along the vehicle (Unreal's characters face their Y
-- axis, which is how the Class 331's seats turned out).
local function seat_facing(pc, seat)
    local turned, along, root_rot = group_frame(seat)
    if not state.traces_broken then
        local eye, near = eye_point(seat, turned, root_rot), {}
        for _, way in ipairs({ 1, -1 }) do
            near[way] = math.huge
            for _, drop in ipairs(BACK_HEIGHTS) do
                local from = FM.add(eye, FM.vec(0, 0, -drop))
                local ok, hit = pcall(trace, pc, from, FM.add(from, FM.scale(along, way * BACK_REACH)))
                if ok and hit then near[way] = math.min(near[way], FM.len(FM.sub(hit, from))) end
            end
        end
        for _, way in ipairs({ 1, -1 }) do
            if near[way] + BACK_CLOSER < near[-way] then
                return FM.vec(-way, 0, 0), string.format("its back %.0f cm behind", near[way])
            end
        end
    end
    local x, y = FM.axes(seat.rot)
    local axis = math.abs(x.X) >= math.abs(y.X) and x or y
    return FM.flat_dir(FM.vec(axis.X, 0, 0)) or FM.vec(1, 0, 0), "guessed from the seat's rotation"
end

-- The way the train is going, flat, and its speed: the seat's vehicle's velocity while it moves, the way it last
-- went while it stands, or, before it has moved, towards the driver at the front.
local function travel_of(seat, along)
    local ok, v = pcall(function() return as_vec(seat.vehicle:GetVelocity()) end)
    local speed = ok and FM.len2(v) or 0
    if speed > MOVING then state.travel = FM.flat_dir(v) end
    if not state.travel then
        local okp, driver = pcall(function() return location(state.pc.Pawn) end)
        local okc, eye = pcall(function() return location(state.camera) end)
        local back = okp and okc and FM.dot2(FM.sub(driver, eye), along) < 0
        state.travel = FM.scale(along, back and -1 or 1)
    end
    return state.travel, speed
end

-- The mouse's movement this frame, as the game has it; 0, 0 while its cursor is showing or the seat view's mouse is
-- off.
local function first_number(t)
    if type(t) ~= "table" then return nil end
    for _, v in pairs(t) do
        if type(v) == "number" then return v end
    end
    return nil
end

local function mouse_delta(pc)
    if not S.SeatMouse or state.mouse_broken then return 0, 0 end
    local okc, shown = pcall(function() return pc.bShowMouseCursor end)
    if okc and shown == true then return 0, 0 end
    local out_x, out_y = {}, {}
    local ok, a, b = pcall(function() return pc:GetInputMouseDelta(out_x, out_y) end)
    if not ok then
        state.mouse_broken = true
        log("can't read the mouse (%s): turning the seat view with it is off", tostring(a))
        return 0, 0
    end
    local dx = type(a) == "number" and a or first_number(out_x) or 0
    local dy = type(b) == "number" and b or first_number(out_y) or 0
    if (dx ~= 0 or dy ~= 0) and not state.mouse_seen then
        state.mouse_seen = true
        log("the mouse turns the seat view (GetInputMouseDelta gave %.2f %.2f)", dx, dy)
    end
    return dx, dy
end

-- Points the passenger's head (seat_head.lua) and puts the camera there: at the seat's eyes, moved a little as the
-- head moves, looking where they look.
local function look(seat, t, first)
    local cam = state.camera
    local turned, along, root_rot = group_frame(seat)
    local travel, speed = travel_of(seat, along)
    local facing = FM.turn(turned, seat.facing)
    local side = 0                    -- the nearest window, as they sit: on their right (1) or left (-1)
    if math.abs(seat.lateral) >= MIDDLE_SEAT then
        side = ((seat.lateral > 0) == (FM.dot2(facing, along) >= 0)) and 1 or -1
    end
    local dx, dy = mouse_delta(state.pc)
    local rot, moved = H.step(state.head, { t = t, dt = first and 0 or t - state.look_at, travel = yaw_of(travel),
        speed = speed, side = side, facing = yaw_of(facing), mouse_dx = dx, mouse_dy = dy }, S)
    state.look_at, state.side, state.speed = t, side, speed
    local offset = FM.add(FM.add(FM.scale(travel, moved.fwd), FM.scale(FM.right_of(travel), moved.right)),
        FM.vec(0, 0, moved.up))
    if state.attached then
        cam:K2_SetActorRelativeLocation(FM.add(seat.root_eye, FM.unturn(root_rot, offset)), false, {}, true)
        cam:K2_SetActorRotation(rot, false)
    else
        local pos = FM.add(eye_point(seat, turned, root_rot), offset)
        if not cam:K2_TeleportTo(pos, rot) then
            cam:K2_SetActorLocation(pos, false, {}, true)
            cam:K2_SetActorRotation(rot, false)
        end
    end
end

local function window_side(side)
    return side > 0 and "the window on their right" or side < 0 and "the window on their left"
        or "neither window nearer"
end

-- Puts the camera at the seat's eyes, attached to the root of the seat's vehicle so it rides along with the train (or,
-- if the game won't attach it, moved there each frame), with a passenger's head looking out of it.
local function sit(seat, vehicles)
    local cam, pc = state.camera, state.pc
    local t = game_time(pc)
    seat.eye = FM.seat_eye(seat.pos, seat.rot, seat.offset, S.SeatEyeHeight * CM)
    seat.root_eye = FM.add(seat.frame.pos, FM.turn(seat.frame.rot, seat.eye)) -- in the root's frame
    local ok, err = pcall(function()
        cam:K2_AttachToComponent(seat.frame.root, none_name(), SNAP, SNAP, KEEP_WORLD, false)
        cam:K2_SetActorRelativeLocation(seat.root_eye, false, {}, true)
        cam:K2_SetActorRelativeRotation(FM.combine(seat.frame.rot, seat.rot), false, {}, true)
    end)
    local okp, parent = pcall(function() return cam:GetAttachParentActor() end)
    state.attached = ok and okp and same(parent, seat.vehicle)
    if not state.attached then
        pcall(function() cam:K2_DetachFromActor(KEEP_WORLD, KEEP_WORLD, KEEP_WORLD) end)
    end
    local turned, along, root_rot = group_frame(seat)
    local how_facing
    seat.facing, how_facing = seat_facing(pc, seat)
    local okv, middle = pcall(function() return location(seat.vehicle) end)
    seat.lateral = okv and FM.dot2(FM.sub(eye_point(seat, turned, root_rot), middle), FM.right_of(along)) or 0
    state.seat, state.head = seat, H.new(math.random, t)
    look(seat, t, true)
    local travel = state.travel
    local backwards = FM.dot2(FM.turn(turned, seat.facing), travel) < 0
    local eyes = seat.offset and FM.len(seat.offset) > 0.5
        and string.format("the seat's camera offset %s", where(seat.offset))
        or string.format("%.2f m above the seat", S.SeatEyeHeight)
    local okg, group_at = pcall(function() return where(as_vec(seat.comp:K2_GetComponentLocation())) end)
    log("in seat %d of %s, a %s group in %s (%sat %s in its group, from %s), eyes %s; it faces %s (%s), %s, "
        .. "%.0f cm from the middle of the car%s%s", seat.index, short_name(seat.comp), seat.name,
        short_name(seat.vehicle), seat.place and vehicles and string.format("vehicle %d of %d, ", seat.place, vehicles)
        or "", where(seat.pos), seat.pos_from, eyes, backwards and "backwards" or "the way of travel", how_facing,
        window_side(state.side), seat.lateral, seat.frame.loose and string.format(
            "; the game had let go of the group (it's at %s), so it goes by its place on the car, %s",
            okg and group_at or "?", where(seat.frame.pos)) or "",
        state.attached and "" or string.format(
            "; the game wouldn't attach the camera (%s), moving it there each frame",
            ok and "it stayed loose" or tostring(err)))
end

----------------------------------------------------------------------------------------------------
-- Running it

local stop -- defined below; the frame needs it

local function cut_to_camera(pc, t)
    local moved = FM.len2(FM.sub(location(state.train), state.measure_from.pos))
    local elapsed = t - state.measure_from.t
    if elapsed > 0 then state.tracker.speed = moved / elapsed end
    local vok, vel = pcall(function() return as_vec(state.train:GetVelocity()) end)
    log("timed the train at %.1f m/s over %.2f s (the game's own velocity says %s)", state.tracker.speed / CM,
        elapsed, vok and string.format("%.1f m/s", FM.len2(vel) / CM) or "nothing")
    state.measuring = false
    if state.seat then -- coming from the seat view: let go of the seat
        if state.attached then
            pcall(function() state.camera:K2_DetachFromActor(KEEP_WORLD, KEEP_WORLD, KEEP_WORLD) end)
        end
        state.seat, state.attached = nil, false
    end
    pcall(function() state.camera.CameraComponent:SetFieldOfView(S.Fov) end)
    place(pc, "switched on")
    pc:SetViewTargetWithBlend(state.camera, 0.0, 0, 0.0, false)
    state.showing = true
    state.started_at = t
    state.debug_at, state.debug_from = t, location(state.train)
end

-- The game put its own camera back on. If you asked for it (a camera key, or the game saying its camera
-- switched), hand over; otherwise take the view back, unless the game keeps doing it.
local function game_took_view(pc, cam, viewing, t)
    local asked = (state.camera_key_at and t - state.camera_key_at <= KEY_WINDOW) or state.game_switched
    if asked then
        return stop("you switched to the game's camera (" .. short_name(viewing) .. ")", true)
    end
    local recent = {}
    for _, at in ipairs(state.grabs) do
        if t - at <= GIVE_UP_IN then recent[#recent + 1] = at end
    end
    recent[#recent + 1] = t
    state.grabs = recent
    if #recent >= GIVE_UP then
        return stop(string.format("the game keeps taking the view back (%d times in %.0f s, last to %s)",
            #recent, GIVE_UP_IN, short_name(viewing)), true)
    end
    state.last_grab = { target = viewing, t = t }
    log("the game took the view (to %s), taking it back", short_name(viewing))
    pc:SetViewTargetWithBlend(cam, 0.0, 0, 0.0, false)
end

local function debug_line(t, train_pos, cam_pos)
    if not S.DebugLog or t - state.debug_at < DEBUG_EVERY then return end
    local moved = FM.len2(FM.sub(train_pos, state.debug_from))
    log("train at %s, moved %.0f m in %.1f s, tracking %.1f m/s; camera %.0f m away", where(train_pos),
        moved / CM, t - state.debug_at, state.tracker.speed / CM, FM.len(FM.sub(train_pos, cam_pos)) / CM)
    state.debug_at, state.debug_from = t, train_pos
end

-- Keeps the view on the camera, or hands it over: false once it's off.
local function hold_view(pc, cam, t)
    local viewing = pc:GetViewTarget()
    if not same(viewing, cam) then
        game_took_view(pc, cam, viewing, t)
        if not state.active then return false end
    end
    state.game_switched = false
    if state.leave_at and t >= state.leave_at then
        stop("you pressed a camera key", false)
        return false
    end
    return true
end

local function flyby_frame()
    local pc, cam, train = state.pc, state.camera, state.train
    if not (valid(pc) and valid(cam) and valid(train)) then
        return stop("the train or the camera has gone (another train, or back to the menu?)", true)
    end
    local t = game_time(pc)
    local train_pos = location(train)
    if FM.track(state.tracker, train_pos, t, state.use_heading and forward_of(train) or nil) == "jump" then
        log("the train jumped (the game moved its world origin, or the train was moved)")
    end

    if state.measuring then
        state.frames = state.frames + 1
        if state.seat and valid(state.seat.comp) and valid(state.seat.frame.root) then look(state.seat, t) end
        if t - state.measure_from.t >= MEASURE or state.frames >= MEASURE_FRAMES then cut_to_camera(pc, t) end
        return
    end

    if not hold_view(pc, cam, t) then return end

    local cam_pos = location(cam)
    if t - state.placed_at >= MIN_GAP then
        local why = state.want_new_spot
            or FM.needs_new_spot(cam_pos, train_pos, state.tracker, state.placed_dir, S)
        if why then
            state.want_new_spot = nil
            place(pc, why)
            cam_pos = location(cam)
        end
    end

    local aim = FM.add(train_pos, FM.vec(0, 0, S.AimHeight * CM))
    cam:K2_SetActorRotation(FM.look_at(cam_pos, aim), false)
    if S.Zoom then
        cam.CameraComponent:SetFieldOfView(FM.zoom_fov(FM.len(FM.sub(aim, cam_pos)), S))
    end
    debug_line(t, train_pos, cam_pos)
end

local function seat_frame()
    local pc, cam = state.pc, state.camera
    if not (valid(pc) and valid(cam)) then
        return stop("the camera has gone (another train, or back to the menu?)", true)
    end
    local t = game_time(pc)
    if not (valid(state.seat.comp) and valid(state.seat.frame.root)) then
        local seats, kind_or_why, vehicles, how = find_seats(pc)
        if not seats then return stop("the seat has gone, and there's no other: " .. kind_or_why, false) end
        log("the seat has gone (its vehicle unloaded?): %d %s seats on your train now (%s)", #seats, kind_or_why,
            how)
        sit(pick_seat(seats, nil), vehicles)
    end
    if not hold_view(pc, cam, t) then return end
    look(state.seat, t)
    if S.DebugLog and t - state.debug_at >= DEBUG_EVERY then
        local cam_pos, vehicle_pos = location(cam), location(state.seat.vehicle)
        log("seat camera at %s, %.1f m from the middle of its vehicle, which is at %s; %.1f m/s, looking %+.0f "
            .. "degrees from the way of travel, %s", where(cam_pos), FM.len(FM.sub(cam_pos, vehicle_pos))
            / CM, where(vehicle_pos), state.speed / CM, H.looking(state.head), window_side(state.side))
        state.debug_at = t
    end
end

local function on_frame()
    if not state.active then return end
    local ok, err = pcall(state.mode == "seat" and seat_frame or flyby_frame)
    if not ok then stop("something went wrong: " .. tostring(err)) end
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

local function spawn_camera(pc, at)
    local class = StaticFindObject("/Script/Engine.CameraActor")
    if not valid(class) then return nil end
    local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
    local ok, cam = pcall(function() return pc:GetWorld():SpawnActor(class, at, rot) end)
    if ok and valid(cam) then return cam end
    -- older UE4SS without UWorld:SpawnActor
    local gs = UEHelpers.GetGameplayStatics()
    local spawn_at = { Translation = at, Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    cam = gs:BeginDeferredActorSpawnFromClass(pc, class, spawn_at, 1, pc)
    if valid(cam) then gs:FinishSpawningActor(cam, spawn_at) end
    return valid(cam) and cam or nil
end

-- `game_has_view`: the game already switched to a camera of its own, so leave the view where it is.
stop = function(why, game_has_view)
    if not state.active then return end
    state.active = false
    stop_loop(state.loop)
    state.loop = nil
    local pc, cam = state.pc, state.camera
    if not game_has_view and state.showing and valid(pc) then
        local back = valid(state.previous_view) and state.previous_view or pc.Pawn
        if valid(back) then pcall(function() pc:SetViewTargetWithBlend(back, 0.0, 0, 0.0, false) end) end
    end
    state.mode, state.measuring, state.showing = nil, false, false
    if valid(cam) then pcall(function() cam:K2_DestroyActor() end) end
    state.camera, state.train, state.previous_view, state.last_grab = nil, nil, nil, nil
    state.seat, state.attached, state.head, state.travel = nil, false, nil, nil
    log("off: %s", why)
end

local hooked = {}

-- The game's own camera-switch events, so a switch you made counts as yours even before the key shows up.
local function watch_game_camera_switches()
    for _, fn in ipairs({ "/Script/TS2Prototype.DriverPawn:OnCameraSwitched",
                          "/Game/Core/Player/TS2DefaultDriverPawn.TS2DefaultDriverPawn_C:OnCameraSwitched" }) do
        if not hooked[fn] then
            local ok = pcall(RegisterHook, fn, function()
                if state.active then state.game_switched = true end
            end)
            if ok then hooked[fn] = true end
        end
    end
end

local function describe_follow(train, how)
    local p = location(train)
    return string.format("%s at %s (%s)", short_name(train), where(p), how)
end

-- The player, when there is one to take the view from.
local function player()
    local pc = state.active and state.pc or UEHelpers.GetPlayerController()
    if valid(pc) then return pc end
    log("no player yet: load into a drive first")
    return nil
end

-- A camera of the mod's own, at `at`, with the view as it was noted to go back to. false if there's none.
local function new_camera(pc, at)
    local cam = spawn_camera(pc, at)
    if not cam then
        log("the game wouldn't create a camera")
        return false
    end
    pcall(function() cam.CameraComponent.bConstrainAspectRatio = false end)
    watch_game_camera_switches()
    state.pc, state.camera = pc, cam
    state.previous_view = pc:GetViewTarget()
    state.showing, state.seat, state.attached = false, nil, false
    state.leave_at, state.camera_key_at = nil, nil
    state.grabs, state.last_grab, state.game_switched = {}, nil, false
    state.debug_at = game_time(pc)
    return true
end

local function run()
    state.active = true
    local ok, err = pcall(function() state.loop = start_loop() end)
    if not ok then stop("couldn't switch on: " .. tostring(err)) end
end

-- The fly-by camera: on, or from the seat view.
local function start_flyby()
    local pc = player()
    if not pc then return end
    local train, how = find_train(pc)
    if not train then return log("no train to follow: %s", how) end
    local train_pos = location(train)
    local was_on = state.active
    if not was_on and not new_camera(pc, FM.add(train_pos, FM.vec(0, 0, 10 * CM))) then return end

    local t = game_time(pc)
    state.mode, state.train = "flyby", train
    state.use_heading = not same(train, pc.Pawn) -- the driver's heading is where they look, not the line
    state.tracker = FM.new_tracker()
    FM.track(state.tracker, train_pos, t, state.use_heading and forward_of(train) or nil)
    state.next_side = S.Side == "left" and -1 or 1
    state.want_new_spot = nil
    state.measuring, state.frames, state.measure_from = true, 0, { pos = train_pos, t = t }
    state.started_at = t
    if was_on then return log("fly-by: following %s", describe_follow(train, how)) end
    log("on: following %s; view was %s", describe_follow(train, how), short_name(state.previous_view))
    run()
end

-- The seat view: on, from the fly-by, or another seat.
local function seat_view()
    local pc = player()
    if not pc then return end
    local seats, kind, vehicles, how = find_seats(pc)
    if not seats then return log("no passenger seats on your train: %s", kind) end
    local seat = pick_seat(seats, state.mode == "seat" and state.seat and state.seat.key or nil)
    local was_on = state.active
    if not was_on and not new_camera(pc, location(seat.vehicle)) then return end
    if was_on and state.mode == "seat" then
        log("another seat: %d %s seats on your train (%s)", #seats, kind, how)
    else
        log("%s: the view from a seat; %d %s seats on your train (%s)", was_on and "seat view" or "on", #seats, kind,
            how)
    end
    state.mode, state.measuring, state.want_new_spot = "seat", false, nil
    pcall(function() state.camera.CameraComponent:SetFieldOfView(S.SeatFov) end)
    sit(seat, vehicles)
    pc:SetViewTargetWithBlend(state.camera, 0.0, 0, 0.0, false)
    state.showing = true
    if not was_on then run() end
end

-- One of the game's camera keys: leave the fly-by or the seat for the game's camera.
local function game_camera_key()
    if not state.active then return end
    if not state.showing then return stop("you pressed a camera key", true) end
    local t = game_time(state.pc)
    state.camera_key_at = t
    if state.last_grab and t - state.last_grab.t <= KEY_WINDOW and valid(state.last_grab.target) then
        -- the game switched just before the key reached us, and the view was taken back: give it the one it chose
        state.previous_view = state.last_grab.target
        return stop("you switched to the game's camera (" .. short_name(state.last_grab.target) .. ")", false)
    end
    state.leave_at = t + LEAVE_WAIT -- if the game doesn't switch by itself, go back to the view from before
end

----------------------------------------------------------------------------------------------------
-- Report (F10): what the mod can see, for working out the next steps

local function report_section(title, fn)
    local ok, err = pcall(fn)
    if not ok then log("  (%s: %s)", title, tostring(err)) end
end

local function matches(name, words)
    local lower = name:lower()
    for _, w in ipairs(words) do
        if lower:find(w, 1, true) then return true end
    end
    return false
end

-- Functions and properties a game class adds on top of the engine, whose names contain any of `words`.
local function list_members(class, words)
    local c = class
    for _ = 1, 12 do
        if not valid(c) then return end
        local cname = name_of(c)
        if cname:find("/Script/Engine%.") or cname:find("/Script/CoreUObject%.") then return end
        local names = {}
        c:ForEachFunction(function(f)
            local n = f:GetFName():ToString()
            if matches(n, words) then names[#names + 1] = n .. "()" end
        end)
        c:ForEachProperty(function(p)
            local n = p:GetFName():ToString()
            if matches(n, words) then names[#names + 1] = n end
        end)
        log("    %s: %s", cname, #names > 0 and table.concat(names, ", ") or "-")
        c = c:GetSuperStruct()
    end
end

local function describe_chain(actor)
    local parts = {}
    for _, a in ipairs(attach_chain(actor)) do
        local ok, p = pcall(location, a)
        parts[#parts + 1] = short_name(a) .. " at " .. (ok and where(p) or "?")
    end
    return #parts > 0 and table.concat(parts, " -> ") or "nothing"
end

local function report()
    log("---- report ----")
    report_section("versions", function()
        log("Unreal %s.%s, engine tick hook %s, camera %s", UnrealVersion:GetMajor(), UnrealVersion:GetMinor(),
            EngineTickAvailable and "yes" or "no", state.mode == "seat" and "in a seat" or state.mode or "off")
    end)
    local pc = UEHelpers.GetPlayerController()
    log("player controller: %s", name_of(pc))
    if not valid(pc) then return end
    report_section("pawn", function()
        log("pawn: %s, attached to %s", short_name(pc.Pawn), describe_chain(pc.Pawn))
        log("auto-manage camera target: %s", tostring(pc.bAutoManageActiveCameraTarget))
    end)
    report_section("view", function()
        local vt = pc:GetViewTarget()
        log("view target: %s, attached to %s", short_name(vt), describe_chain(vt))
        log("camera manager: %s, camera at %s", short_name(pc.PlayerCameraManager), where(camera_location(pc)))
    end)
    report_section("trains", function()
        local views = FindAllOf("RailVehicleView")
        log("rail vehicle views loaded: %d", views and #views or 0)
        local train, how = find_train(pc)
        log("would follow: %s", train and describe_follow(train, how) or how)
    end)
    report_section("seats", function()
        local seats, kind, vehicles, how, groups = find_seats(pc)
        if seats then
            log("seats: %d %s seats on your train of %s vehicles (%s)", #seats, kind, tostring(vehicles or "?"), how)
        else
            log("seats: none on your train (%s)", kind)
        end
        for i, g in ipairs(groups or {}) do
            if i > 20 then
                log("  and %d more", #groups - 20)
                break
            end
            local c = g.comp
            local okw, at = pcall(function() return where(as_vec(c:K2_GetComponentLocation())) end)
            local verb = field(c, "StandardSeatVerb")
            log("  %s in %s%s at %s, on its vehicle at %s%s: %s, %s (name %s, role %s, verb %s, custom name %s), "
                .. "%d seats, camera Z offset %s, passengers hidden within %s", short_name(c), short_name(g.owner),
                g.place and string.format(" (vehicle %d)", g.place) or "", okw and at or "?", where(g.frame.pos),
                g.frame.loose and " (let go of by the game)" or "", g.kind, g.label,
                tostring(field(c, "StandardSeatName")), tostring(field(c, "SeatRole")),
                (SEAT_VERBS[verb] or "?") .. " " .. tostring(verb), tostring(text_of(field(c, "CustomSeatName"))),
                #g.regions, tostring(field(c, "HitTestCameraZOffset")),
                tostring(field(c, "MinCameraDistanceToShowCharacter")))
            local r = g.regions[1]
            if r then
                log("    seat %d: at %s (%s%s), turned %.0f %.0f %.0f, camera offset %s, someone in it: %s", r.index,
                    where(r.pos), r.pos_from, r.field_pos and (", LocalPosition " .. where(r.field_pos)) or "",
                    r.rot.Pitch, r.rot.Yaw, r.rot.Roll, r.offset and where(r.offset) or "none",
                    tostring(taken({ comp = c, index = r.index })))
            end
        end
    end)
    if state.mode == "seat" and state.seat then
        local okw, at = pcall(function() return where(location(state.camera)) end)
        log("in seat %d of %s (%s) in %s, camera at %s, %s; looking %+.0f degrees from the way of travel, %s",
            state.seat.index, short_name(state.seat.comp), state.seat.name, short_name(state.seat.vehicle),
            okw and at or "?",
            state.attached and "attached to its vehicle" or "moved there each frame", H.looking(state.head),
            window_side(state.side))
    end
    if state.mode == "flyby" and not state.measuring then
        local tr = state.tracker
        log("tracking: %.1f m/s, curve radius %s, grade %.3f", tr.speed / CM,
            tr.curvature ~= 0 and string.format("%.0f m", 1 / math.abs(tr.curvature) / CM) or "straight", tr.grade)
    end
    report_section("game functions", function()
        local flags = EObjectFlags and EObjectFlags.RF_NoFlags or 0
        for _, fname in ipairs({ "GetCurrentLocalDrivableActor", "OnCameraSwitched", "SwitchToFreeCamera" }) do
            local found = FindObjects(5, "Function", fname, flags, flags, false) or {}
            local names = {}
            for _, f in pairs(found) do names[#names + 1] = name_of(f) end
            log("function %s: %s", fname, #names > 0 and table.concat(names, "; ") or "not found")
        end
    end)
    report_section("pawn members", function()
        log("pawn camera / seat / drivable members:")
        list_members(pc.Pawn:GetClass(), { "camera", "seat", "drivable" })
    end)
    log("---- end of report ----")
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
    if not key then return log("unknown key %s in flyby_settings.lua", tostring(name)) end
    local function run()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then log("%s key: %s", name, tostring(err)) end
        end)
    end
    if #mods > 0 then RegisterKeyBind(key, mods, run) else RegisterKeyBind(key, run) end
end

-- Fly-by key: switch on (or over from the seat view), or once on, move to a new spot ahead.
on_key(S.FlyByKey, function()
    if state.mode ~= "flyby" then return start_flyby() end
    if not state.measuring then state.want_new_spot = "you asked for a new spot" end
end)

-- Seat key: the view from a random passenger seat on your train; pressed again, another seat.
on_key(S.SeatKey, seat_view)

on_key(S.OffKey, function()
    if state.active then stop("you switched it off") end
end)

on_key(S.ReportKey, report)

for _, name in ipairs(S.GameCameraKeys or {}) do
    on_key(name, game_camera_key)
end

log("loaded: %s = fly-by camera / new spot, %s = seat view / another seat, %s = off, %s = report to UE4SS.log",
    S.FlyByKey, S.SeatKey, S.OffKey, S.ReportKey)
