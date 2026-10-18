-- Comfort HUD for Train Sim World 7, as a UE4SS Lua mod.
-- Puts how many passengers are aboard and how comfortable their ride has been into the objective box of the game's
-- header bar ("Wait until 19:06:00 · 62 aboard · comfort 87"). While braking or speeding up gets firm or harsh for
-- them, or the train is about to stop with the brake still hard on, a warning takes the objective's place, then
-- how the stop went or what the ride lost. The rules are tsw-joystick's passenger comfort (comfort_judge.lua).
-- Press = to switch it off and on, F11 for a report. Everything it does is written to UE4SS.log, lines starting
-- [Comfort].
--
-- It reads everything from the game itself, a few calls a frame: no window over the game and no requests to the
-- game's web API. Searches through all the game's objects take milliseconds, so they're only made when something
-- changes (another train, a drive loading), never on a timer while you drive.

local UEHelpers = require("UEHelpers")
local J = require("comfort_judge")
local T = require("hud_text")
local S = require("comfort_settings")

local FEED_EVERY = 1 / 15       -- s between readings for the judge (tsw-joystick read 15 a second)
local LOOK_EVERY = 1.0          -- s between looking at the train, its service and the objective box
local COUNT_EVERY = 5.0         -- s between counting the passengers while stopped (they don't change on the move)
local CHECK_EVERY = 0.5         -- s between checking the game hasn't written over what the box says
local REFIND_EVERY = 5.0        -- s at least between searches for the player or the objective box
local DEBUG_EVERY = 5.0
local MAX_CARS = 16
local WHITE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }

local OBJECTIVE_CLASS = "/Script/TS2Prototype.TS2HUDObjectiveWidget"
local WIDGET_CLASSES = { "HUDObjectiveWidget_C", "HUDObjectiveWidget_Minimal_C" } -- the full and the minimal HUD
local WIDGET_HOOKS = {
    "/Game/Core/Assets/HUD/Widgets/Objectives/HUDObjectiveWidget.HUDObjectiveWidget_C:UpdateObjectiveText",
    "/Game/Core/Assets/HUD/Widgets/Objectives/HUDObjectiveWidget.HUDObjectiveWidget_C:ShowObjective",
    "/Game/Core/Assets/HUD/Widgets/Objectives/HUDObjectiveWidget_Minimal.HUDObjectiveWidget_Minimal_C:UpdateObjectiveText",
    "/Game/Core/Assets/HUD/Widgets/Objectives/HUDObjectiveWidget_Minimal.HUDObjectiveWidget_Minimal_C:ShowObjective",
}

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

local function count_of(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local state = {
    on = true, loop = nil,
    pc = nil, pc_stale = true, pc_looked = -math.huge,
    drivable = nil, view = nil, service = nil, aboard = false,
    cars = nil, passenger_train = false, passengers = nil, counted_at = -math.huge, count_failed = false,
    samples = {}, speed = 0.0, acc = nil,
    judge = J.new(),
    looked_at = -math.huge, fed_at = -math.huge, checked_at = -math.huge, debug_at = -math.huge,
    stop = nil,                 -- the stop the train is at: {station}
    slow_change = false,        -- the objective moved on or the passengers changed since the train last went fast
    work = { total = 0.0, frames = 0, most = 0.0 },
}

local hud = {
    widgets = {},               -- address -> {obj, title, colour, line (what the mod put there, nil: the game's own)}
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
    if valid(state.pc) then
        local ok, t = pcall(function() return UEHelpers.GetGameplayStatics():GetTimeSeconds(state.pc) end)
        if ok and type(t) == "number" then return t end
    end
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
    return state.pc
end

-- The rail vehicle you drive: the model half TSW splits each vehicle into (RVM_..., at the world's origin).
local function find_drivable(pc)
    local ok, d = pcall(function() return pc:GetCurrentLocalDrivableActor() end)
    if ok and valid(d) then return d end
    local rv = StaticFindObject("/Script/TS2Prototype.RailVehicle")
    for _, a in ipairs(attach_chain(pc.Pawn)) do
        if is_a(a, rv) then return a end
    end
    return nil
end

-- The moving half of the vehicle the driver is in (RVV_...): its velocity is the train's.
local function find_view(pc)
    local cls = StaticFindObject("/Script/TS2Prototype.RailVehicleView")
    for _, a in ipairs(attach_chain(pc.Pawn)) do
        if is_a(a, cls) then return a end
    end
    return nil
end

local function service_name(pc)
    local ok, name = pcall(function() return pc:GetDrivenServiceName() end)
    local s = ok and text_of(name) or nil
    if s == nil or s == "" or s == "None" then return nil end
    return s
end

local function gameplay_lib()
    for _, path in ipairs({ "/Script/TS2Prototype.Default__TS2GameplayFunctionLibrary",
                            "/Script/TS2Prototype.Default__TS2BlueprintSupportLibrary" }) do
        local lib = StaticFindObject(path)
        if valid(lib) then return lib end
    end
    return nil
end

local function formation_of(rv)
    local ok, f = pcall(function() return rv:GetFormation() end)
    if ok and valid(f) then return f:GetAddress() end
    return nil
end

-- How to tell a vehicle is in your train: (what it goes by, test(vehicle)).
local function membership(drivable)
    local mine = formation_of(drivable)
    if mine then
        return "same formation", function(o) return formation_of(o) == mine end
    end
    local lib = gameplay_lib()
    if lib then
        local ok, yes = pcall(function() return lib:AreRailVehiclesInSameFormation(drivable, drivable) end)
        if ok and yes == true then
            return "AreRailVehiclesInSameFormation", function(o)
                local ok2, y = pcall(function() return lib:AreRailVehiclesInSameFormation(drivable, o) end)
                return ok2 and y == true
            end
        end
        ok, yes = pcall(function() return lib:IsConsistPlayerDriven(drivable) end)
        if ok and yes == true then
            return "IsConsistPlayerDriven", function(o)
                local ok2, y = pcall(function() return lib:IsConsistPlayerDriven(o) end)
                return ok2 and y == true
            end
        end
    end
    return "only the vehicle you drive: couldn't tell which others are in your train",
        function(o) return same(o, drivable) end
end

-- The passenger cars of your train: their PassengerCargoModel components. Looked for once a train, as it's a search
-- through all the game's objects.
local function find_cars(drivable)
    local started = os.clock()
    local all = FindAllOf("PassengerCargoModelComponent") or {}
    local how, mine = membership(drivable)
    local cars = {}
    for _, c in ipairs(all) do
        if valid(c) then
            local ok, owner = pcall(function() return c:GetOwner() end)
            if ok and valid(owner) and mine(owner) then cars[#cars + 1] = c end
        end
        if #cars >= MAX_CARS then break end
    end
    log("%d passenger car%s on your train of %d in the world (%s); looked in %.0f ms", #cars, #cars == 1 and "" or "s",
        #all, how, (os.clock() - started) * 1000)
    return cars
end

-- A number a game function gives: as what it returns, or in a table for its out parameter. nil and why if neither.
local function number_from(obj, fname)
    local ok, n = pcall(function() return obj[fname](obj) end)
    if ok and type(n) == "number" then return n end
    local why = ok and ("it gave " .. type(n)) or tostring(n)
    local out = {}
    local ok2, r = pcall(function() return obj[fname](obj, out) end)
    if ok2 then
        if type(r) == "number" then return r end
        for _, v in pairs(out) do
            if type(v) == "number" then return v end
        end
    end
    return nil, why
end

-- The passengers aboard, nil if they can't be counted.
local function count_passengers(cars)
    local total, counted, err = 0, false, nil
    for _, c in ipairs(cars) do
        if valid(c) then
            local n, why = number_from(c, "GetPassengerCount")
            if n then
                total, counted = total + n, true
            else
                err = why
            end
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
        hud.widgets[key] = { obj = w }
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

local wanted, apply -- defined below; the hooks need them

-- Once the game has its objective box, the moments it writes its own text in it: put ours back straight away.
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
            if rec then
                local ok, err = pcall(function()
                    rec.want = wanted(rec)       -- with the objective the game has just set
                    apply(rec, true)
                end)
                if not ok and not rec.hook_failed then
                    rec.hook_failed = true
                    log("can't put the text back as the game writes it: %s", tostring(err))
                end
            end
        end)
        if ok then hud.hooks[#hud.hooks + 1] = path:match(":(.*)$") .. " (" .. path:match("%.([%w_]+)_C:") .. ")" end
    end
    log("watching the objective box for the game's own text: %s",
        #hud.hooks > 0 and table.concat(hud.hooks, ", ") or "can't, checking it twice a second instead")
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

-- What the box should say now: rec.want = {title, colour, line} (nil each: the game's own).
wanted = function(rec)
    local w = rec.obj
    local game_title = text_of(w.ObjectiveTitle)
    local game_line = text_of(w.ObjectiveDescription)
    rec.game_title, rec.game_line = game_title, game_line
    if not state.on or not state.aboard then return {} end
    local judge = state.judge
    local info = { passengers = state.passengers, score = judge:live_score(),
                   cost = judge.episode and judge.episode.cost or nil }
    local take = S.Warnings and T.takeover(judge:panel(), info, S) or nil
    if take then return take end
    return { line = T.normal_line(game_line, info, S) }
end

-- Puts what the box should say into it. `force`: the game may just have written over it.
apply = function(rec, force)
    local w, want = rec.obj, rec.want or {}
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
    for _, rec in ipairs(widgets()) do
        local ok, err = pcall(function()
            rec.want = wanted(rec)
            apply(rec, force or (check and overwritten(rec)))
        end)
        if not ok and not rec.failed then
            rec.failed = true
            log("can't write in the objective box %s: %s", short_name(rec.obj), tostring(err))
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
        log("the train's own holding brake came on at %.2f m/s", event[2])
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
    local acc = acceleration()
    if acc == nil then return end
    state.acc = acc
    local judge = state.judge
    for _, event in ipairs(judge:feed(now, state.speed, acc, judged_passengers(), t)) do say(event) end
    follow_stops(state.speed)
end

----------------------------------------------------------------------------------------------------
-- Looking at the game once a second

local function leave(why)
    if state.aboard then log("not driving: %s", why) end
    state.aboard = false
    state.drivable, state.view, state.stop, state.slow_change = nil, nil, nil, false
    state.samples = {}
    state.judge:lost()
end

local function new_train(drivable, now)
    state.drivable = drivable
    state.cars, state.passenger_train, state.passengers, state.count_failed = nil, false, nil, false
    state.counted_at = -math.huge
    state.samples, state.stop, state.slow_change = {}, nil, false
    state.judge:lost()
    log("driving %s", short_name(drivable))
end

local function look(now)
    state.looked_at = now
    local pc = player_controller(now)
    if not pc then return leave("no player") end
    local drivable = find_drivable(pc)
    if not drivable then return leave("no train") end
    local view = find_view(pc)
    if not view then return leave("not aboard your train") end
    if not same(drivable, state.drivable) then new_train(drivable, now) end
    state.view, state.aboard = view, true
    local service = service_name(pc) or short_name(drivable)
    if state.service ~= nil and service ~= state.service then
        state.judge:new_leg(service, nil, true)  -- another service: its comfort starts afresh
        log("service %s", service)
    end
    state.service = service
    local slow = state.speed < J.MOVING

    if state.cars == nil then
        state.cars = find_cars(drivable)
        state.passenger_train = #state.cars > 0
    end
    if state.passenger_train and (state.counted_at == -math.huge
            or (state.speed < J.STOPPED and now - state.counted_at >= COUNT_EVERY)) then
        local before = state.passengers
        state.counted_at = now
        state.passengers = count_passengers(state.cars)
        if before ~= nil and state.passengers ~= nil and state.passengers ~= before and slow then
            state.slow_change = true             -- people got on or off: a station
        end
    end

    if #widgets() == 0 and now - hud.searched_at >= REFIND_EVERY * 3 then
        search_widgets(now, hud.notified and "the one the game made has gone" or "the game didn't say it made one")
    end
    if #widgets() > 0 then hook_widgets() end
    for _, rec in ipairs(widgets()) do
        local title = text_of(rec.obj.ObjectiveTitle)
        if title and title ~= "" and title ~= hud.game_title then
            if hud.game_title ~= nil and slow then state.slow_change = true end  -- the objective moved on: a station
            hud.game_title = title
        end
    end
end

----------------------------------------------------------------------------------------------------
-- Every frame

local function debug_line(now)
    if not S.DebugLog or now - state.debug_at < DEBUG_EVERY then return end
    state.debug_at = now
    local work = state.work
    local panel = state.judge:panel()
    if state.aboard then
        log("%.1f m/s, %s, %s, comfort %s, showing %s; the mod's work %.3f ms a frame on average, %.0f ms at most over %d frames",
            state.speed, state.acc and string.format("%+.2f m/s²", state.acc) or "acceleration not known yet",
            T.aboard(state.passengers) or (state.passenger_train and "passengers not counted" or "not a passenger train"),
            state.judge:live_score() and string.format("%.0f", state.judge:live_score()) or "-",
            panel and panel.phase or "the objective", work.frames > 0 and work.total / work.frames * 1000 or 0,
            work.most * 1000, work.frames)
    end
    state.work = { total = 0.0, frames = 0, most = 0.0 }
end

local function frame()
    local started = os.clock()
    local now = real_time()
    if now - state.looked_at >= LOOK_EVERY then look(now) end
    if state.aboard and valid(state.view) then
        local t = game_time()
        if t then
            local vel = state.view:GetVelocity()
            sample(t, math.sqrt(vel.X * vel.X + vel.Y * vel.Y + vel.Z * vel.Z) / 100)
            if now - state.fed_at >= FEED_EVERY then feed(now, t) end
        end
    end
    if hud.dirty or now - (state.hud_at or -math.huge) >= FEED_EVERY then
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
local function describe_function(fname)
    local flags = EObjectFlags and EObjectFlags.RF_NoFlags or 0
    local found = FindObjects(5, "Function", fname, flags, flags, false) or {}
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

-- What a call gave: a number, a bool, text, an object, or the error.
local function try_call(obj, fname, ...)
    local args = { ... }
    local ok, r = pcall(function() return obj[fname](obj, table.unpack(args)) end)
    if not ok then return "error: " .. tostring(r) end
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
            log("drivable: %s; view: %s; service: %s", short_name(d), short_name(find_view(pc)),
                tostring(service_name(pc)))
            if d then
                log("  GetFormation: %s; GetForwardsVelocity: %s; HUD_GetAcceleration: %s; HUD_GetSpeed: %s",
                    try_call(d, "GetFormation"), try_call(d, "GetForwardsVelocity"),
                    try_call(d, "HUD_GetAcceleration"), try_call(d, "HUD_GetSpeed"))
                local how = membership(d)
                log("  your train told by: %s", how)
            end
            log("  speed %.2f m/s, acceleration %s over %d readings", state.speed,
                state.acc and string.format("%+.3f m/s²", state.acc) or "-", #state.samples)
        end)
    end
    report_section("passengers", function()
        local cars = state.cars or {}
        log("passenger cars: %d", #cars)
        for i, c in ipairs(cars) do
            local ok, owner = pcall(function() return c:GetOwner() end)
            log("  %d: %s on %s: %s aboard", i, short_name(c), ok and short_name(owner) or "?",
                try_call(c, "GetPassengerCount"))
        end
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
                try_call(w, "IsVisible") == "true" and "shown" or "hidden", tostring(text_of(w.Name:GetText())),
                tostring(text_of(w.Description:GetText())), size, tostring(text_of(w.ObjectiveTitle)),
                tostring(text_of(w.ObjectiveDescription)))
        end
        log("  hooks: %s; the game wrote its own text %d times", hud.hooks and #hud.hooks > 0
            and table.concat(hud.hooks, ", ") or "none", hud.hook_calls)
    end)
    report_section("game functions", function()
        for _, fname in ipairs({ "GetCurrentLocalDrivableActor", "GetDrivenServiceName", "GetFormation",
                                 "GetForwardsVelocity", "GetPassengerCount", "AreRailVehiclesInSameFormation",
                                 "IsConsistPlayerDriven", "HUD_GetAcceleration", "HUD_GetTrainBrakeHandle",
                                 "GetSimulationNodeParameterAsBool" }) do
            log("  %s", describe_function(fname))
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
        state.looked_at, state.samples = -math.huge, {}
        state.loop = start_loop()
        log("on")
    else
        stop_loop(state.loop)
        state.loop = nil
        for _, rec in ipairs(widgets()) do
            pcall(function()
                rec.want = {}
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
end)
if not ok_notify then log("the game won't say when it makes its objective box: it'll be looked for instead") end

state.loop = start_loop()
log("loaded: %s = off / on, %s = report to UE4SS.log", S.ToggleKey, S.ReportKey)
