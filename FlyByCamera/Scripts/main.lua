-- Fly-by camera for Train Sim World 7, as a UE4SS Lua mod.
-- Press 7 and the view cuts to a camera standing beside the line ahead of your train. It turns to follow the
-- train as it goes by, then moves on ahead again. Press 7 again for a new spot straight away. Press 6, or one of
-- the game's own camera keys, to go back.
-- You can keep driving while it's on. Everything it does is written to UE4SS.log, lines starting [FlyBy].

local UEHelpers = require("UEHelpers")
local FM = require("flyby_math")
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
    active = false, measuring = false,
    pc = nil, train = nil, camera = nil, previous_view = nil,
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
    place(pc, "switched on")
    pc:SetViewTargetWithBlend(state.camera, 0.0, 0, 0.0, false)
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

local function frame()
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
        if t - state.measure_from.t >= MEASURE or state.frames >= MEASURE_FRAMES then cut_to_camera(pc, t) end
        return
    end

    local viewing = pc:GetViewTarget()
    if not same(viewing, cam) then
        game_took_view(pc, cam, viewing, t)
        if not state.active then return end
    end
    state.game_switched = false
    if state.leave_at and t >= state.leave_at then
        return stop("you pressed a camera key", false)
    end

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

local function on_frame()
    if not state.active then return end
    local ok, err = pcall(frame)
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
    if not game_has_view and not state.measuring and valid(pc) then
        local back = valid(state.previous_view) and state.previous_view or pc.Pawn
        if valid(back) then pcall(function() pc:SetViewTargetWithBlend(back, 0.0, 0, 0.0, false) end) end
    end
    state.measuring = false
    if valid(cam) then pcall(function() cam:K2_DestroyActor() end) end
    state.camera, state.train, state.previous_view, state.last_grab = nil, nil, nil, nil
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

local function start()
    local pc = UEHelpers.GetPlayerController()
    if not valid(pc) then return log("no player yet: load into a drive first") end
    local train, how = find_train(pc)
    if not train then return log("no train to follow: %s", how) end
    local train_pos = location(train)
    local cam = spawn_camera(pc, FM.add(train_pos, FM.vec(0, 0, 10 * CM)))
    if not cam then return log("the game wouldn't create a camera") end
    pcall(function() cam.CameraComponent.bConstrainAspectRatio = false end)
    pcall(function() cam.CameraComponent:SetFieldOfView(S.Fov) end)
    watch_game_camera_switches()

    local t = game_time(pc)
    state.pc, state.train, state.camera = pc, train, cam
    state.previous_view = pc:GetViewTarget()
    state.use_heading = not same(train, pc.Pawn) -- the driver's heading is where they look, not the line
    state.tracker = FM.new_tracker()
    FM.track(state.tracker, train_pos, t, state.use_heading and forward_of(train) or nil)
    state.next_side = S.Side == "left" and -1 or 1
    state.want_new_spot, state.leave_at, state.camera_key_at = nil, nil, nil
    state.grabs, state.last_grab, state.game_switched = {}, nil, false
    state.measuring, state.frames, state.measure_from = true, 0, { pos = train_pos, t = t }
    state.started_at = t
    state.active = true
    log("on: following %s; view was %s", describe_follow(train, how), short_name(state.previous_view))
    local ok, err = pcall(function() state.loop = start_loop() end)
    if not ok then stop("couldn't switch on: " .. tostring(err)) end
end

-- One of the game's camera keys: leave the fly-by for the game's camera.
local function game_camera_key()
    if not state.active then return end
    if state.measuring then return stop("you pressed a camera key", true) end
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
        log("Unreal %s.%s, engine tick hook %s, fly-by %s", UnrealVersion:GetMajor(), UnrealVersion:GetMinor(),
            EngineTickAvailable and "yes" or "no", state.active and "on" or "off")
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
    if state.active and not state.measuring then
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

-- Fly-by key: switch on, or once on, move to a new spot ahead.
on_key(S.FlyByKey, function()
    if not state.active then return start() end
    if not state.measuring then state.want_new_spot = "you asked for a new spot" end
end)

on_key(S.OffKey, function()
    if state.active then stop("you switched it off") end
end)

on_key(S.ReportKey, report)

for _, name in ipairs(S.GameCameraKeys or {}) do
    on_key(name, game_camera_key)
end

log("loaded: %s = fly-by camera / new spot, %s = off, %s = report to UE4SS.log", S.FlyByKey, S.OffKey, S.ReportKey)
