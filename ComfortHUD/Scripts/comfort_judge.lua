-- How the ride feels to the passengers: the same rules as tsw-joystick's passenger comfort (tsw_comfort.py, Judge),
-- ported line for line so the two agree. No game objects in here, so it can be tried on a logged drive.
--
-- What's judged is how hard the train speeds up and slows down, not the slope. Braking over 0.9 m/s² is firm and
-- over 1.2 harsh; speeding up over 1.3 firm and over 1.5 harsh (a Class 331 does 1.3 on full power). A stop is a
-- jolt when the train braked harder than 0.7 m/s² in its last 1 m/s. Each ride from one station to the next gets a
-- mark out of 100: it loses a point a second over the firm limit, 10 for a harsh moment and 2 a second it goes on
-- past the first, and for a stop with a jolt 30 an m/s² over the jolt limit (at most 30). The service's comfort is
-- the rides' marks weighted by the passengers aboard.
--
-- Left out from tsw-joystick for now: timing how quickly each train's brake eases off (this mod doesn't read the
-- brake handle, so the warning allows 3 s for every train) and keeping the comfort with the game's saves.
--
--     local judge = J.new()
--     local said = judge:feed(now, speed, acc, passengers, clock)   -- a reading; what happened, for the log
--     judge:panel()        -- nil, or what to show: {phase = "ease" / "stopped" / "firm" / "harsh" / "lost", ...}
--     judge:new_leg(service)   -- leaving a station: the ride to it is done

local J = {}

J.STOPPED = 0.1                 -- m/s: slower than this the train has stopped
J.MOVING = 2.0                  -- m/s: it has to have gone faster than this since the last stop for a stop to count
J.LAST = 1.0                    -- m/s: the braking slower than this is what passengers feel as the train stops
J.JOLT = 0.7                    -- m/s²: braking harder than this as it stops is a jolt
J.EASE_ON = 0.6                 -- m/s²: the warning comes braking harder than this, with less than the lead to go
J.EASE_OFF = 0.45               -- ... and goes once eased off below this, or with a second more than the lead to go
J.REACTION = 1.0                -- s (wall clock) to see the warning and move the handle
J.DEFAULT_EASE = 3.0            -- s (game) a brake takes to ease off
J.LEAD_MIN, J.LEAD_MAX = 2.0, 6.0   -- s (game): the lead is reaction + ease, kept within these
J.RESULT_SECONDS = 6.0          -- how long how the stop went stays up
-- m/s² braking / speeding up, {over this, until below this}: firm is the warning's amber, harsh its red, and a harsh
-- moment of the ride once it lasts HARSH_SECONDS
J.LIMITS = { brake = { firm = { 0.9, 0.8 }, harsh = { 1.2, 1.0 } },
             power = { firm = { 1.3, 1.2 }, harsh = { 1.5, 1.3 } } }
J.HARSH_SECONDS = 1.0
J.HOLD_SECONDS = 1.0            -- the firm / harsh warning stays this long after
J.FIRM_COST = 1.0               -- a ride's mark loses this a second (game) over the firm limit,
J.HARSH_COST, J.HARSH_EXTRA = 10.0, 2.0   -- this a harsh moment and this a second it lasts past HARSH_SECONDS,
J.STOP_COST, J.STOP_MOST = 30.0, 30.0     -- and this an m/s² braking over JOLT as it stops, at most STOP_MOST a stop
J.LOSS_SECONDS = 4.0            -- what a firm / harsh stretch cost stays up this long after it
J.MAX_STEP = 0.5                -- s (game): a longer gap between readings counts as this long
J.RATIO_SECONDS = 3.0           -- game time against the wall clock over this long
J.HELD_HARDER = 0.05            -- the brake handle this much further on after the train's own holding brake came on:
                                -- what it brakes counts again

-- A ride from a station on `service` (nil: not known). `upto`: game seconds the train last moved on it.
local function new_leg(service)
    return { stop = nil, braking = nil, harsh = {}, firm = { brake = 0.0, power = 0.0 }, way = {},
             passengers = 0, judged = false, service = service, upto = nil }
end

local function smooth(leg)
    return leg.stop ~= "jolt" and #leg.harsh == 0 and #leg.way == 0
end

local function stop_cost(braking)
    return math.min(math.max(braking - J.JOLT, 0.0) * J.STOP_COST, J.STOP_MOST)
end
J.stop_cost = stop_cost

-- What a ride lost of its 100, costliest first, each {points, what, ...}: {p, "stop", braking} stopping at the
-- station with a jolt, {p, "way", braking} a jolt at a stop on the way, {p, "harsh", kind, worst m/s², seconds},
-- {p, "firm", kind, seconds}.
function J.losses(leg)
    local lost = {}
    if leg.stop == "jolt" then lost[#lost + 1] = { stop_cost(leg.braking), "stop", leg.braking } end
    for _, braking in ipairs(leg.way) do lost[#lost + 1] = { stop_cost(braking), "way", braking } end
    for _, h in ipairs(leg.harsh) do
        local kind, worst, seconds = h[1], h[2], h[3]
        lost[#lost + 1] = { J.HARSH_COST + J.HARSH_EXTRA * math.max(seconds - J.HARSH_SECONDS, 0.0), "harsh",
                            kind, worst, seconds }
    end
    for _, kind in ipairs({ "brake", "power" }) do
        local seconds = leg.firm[kind]
        if seconds > 0 then lost[#lost + 1] = { J.FIRM_COST * seconds, "firm", kind, seconds } end
    end
    local order = {}
    for i, loss in ipairs(lost) do order[loss] = i end
    table.sort(lost, function(a, b)
        if a[1] ~= b[1] then return a[1] > b[1] end
        return order[a] < order[b] -- costliest first, as found where they cost the same
    end)
    return lost
end

-- A ride's comfort out of 100.
function J.mark(leg)
    local total = 0.0
    for _, loss in ipairs(J.losses(leg)) do total = total + loss[1] end
    return math.max(0.0, 100.0 - total)
end

-- A service's comfort from its rides' marks, each weighted by the passengers aboard: how the ride felt to the
-- average passenger. With nobody aboard all the way the rides count alike. nil with no rides.
function J.score(rides)
    if #rides == 0 then return nil end
    local aboard, weighted, plain = 0, 0.0, 0.0
    for _, r in ipairs(rides) do
        aboard = aboard + r.passengers
        weighted = weighted + r.mark * r.passengers
        plain = plain + r.mark
    end
    if aboard > 0 then return weighted / aboard end
    return plain / #rides
end

local function round1(x) return math.floor(x * 10 + 0.5) / 10 end

-- A ride as it's kept: {station, mark, passengers, smooth, lost = losses(), at = game seconds it arrived}.
local function ride_of(leg, station)
    return { station = station, mark = round1(J.mark(leg)), passengers = leg.passengers, smooth = smooth(leg),
             lost = J.losses(leg), at = leg.upto }
end

----------------------------------------------------------------------------------------------------

local Judge = {}
Judge.__index = Judge

-- `ease`: seconds (game) the train's brake takes to ease off, nil: not known.
function J.new(ease)
    local self = setmetatable({}, Judge)
    self.ease = ease
    self.ratio = 1.0              -- game seconds a wall clock second
    self.clocks = {}              -- {wall, game} over the last RATIO_SECONDS
    self.accs = {}                -- the last three accelerations
    self.coach = nil              -- the stop warning, or how the stop went
    self.coach_until = 0.0
    self.alert = nil              -- firm / harsh going on
    self.alert_until = 0.0
    self.moved = false            -- faster than MOVING since the last stop
    self.v = 0.0                  -- m/s at the last reading
    self.approach = nil           -- hardest braking slower than LAST on the way into a stop
    self.braking = 0.0            -- braking at the reading before
    self.hold = false             -- the train's own holding brake on at the reading before
    self.held = nil               -- since it came on as the train stopped: {cap = the most braking counted,
                                  --   demand = brake handle then}
    self.harsh_since = nil        -- when braking or speeding up went over harsh
    self.harsh_kind = nil         -- ... which of them
    self.harsh_time = 0.0         -- ... and for how long since (game)
    self.harsh = nil              -- the harsh moment going on, once counted: {kind, worst, seconds}
    self.worst = 0.0
    self.last_time = nil          -- {game clock?, seconds} at the reading before
    self.episode = nil            -- a firm / harsh stretch going on: {cost, kind, level}
    self.loss = nil               -- what the last one cost, for a moment after
    self.loss_until = 0.0
    self.leg = new_leg()
    self.service = nil            -- the service the rides below are of
    self.done = {}                -- rides done on it (ride_of)
    self.most = 0                 -- most passengers aboard on it
    return self
end

-- What to show: the stop warning or how the stop went, else firm / harsh, else what that cost. nil: nothing.
function Judge:panel()
    return self.coach or self.alert or self.loss
end

-- Seconds (game) before the stop the warning comes: time to react, and for the brake to ease off.
function Judge:lead()
    local ease = self.ease or J.DEFAULT_EASE
    return math.min(math.max(J.REACTION * self.ratio + ease, J.LEAD_MIN), J.LEAD_MAX)
end

local function median3(list)
    local sorted = { table.unpack(list) }
    table.sort(sorted)
    return sorted[#sorted // 2 + 1]
end

-- `now`: wall clock seconds; `speed`: m/s, signed; `acc`: the change of speed in m/s² (the game's sign);
-- `passengers`: aboard (0 on an empty passenger train), nil if not a passenger train or not known; `clock`: game
-- seconds; `brake`: the brake handle, nil if not known; `power`: under power; `hold`: the train's own holding brake
-- is on, nil if it hasn't one. What happened, for the log: {"stop", jolt, braking}, {"harsh", kind, worst} once a
-- harsh moment is over, {"hold", speed, braking} the train's holding brake came on as it stopped.
function Judge:feed(now, speed, acc, passengers, clock, brake, power, hold)
    local accs = self.accs
    accs[#accs + 1] = acc
    if #accs > 3 then table.remove(accs, 1) end
    acc = median3(accs)                       -- the middle of the last three: a slow frame can read one far out
    local v = math.abs(speed)
    local along = speed >= 0 and acc or -acc  -- speeding up: positive
    local braking = -along
    local kind = along < 0 and "brake" or "power"
    local judged = passengers ~= nil          -- a passenger train
    local said = {}
    self:_time(now, clock)
    local step = self:_step(now, clock)
    braking = self:_held(v, braking, brake, hold, said)
    along = -braking
    if self.coach and self.coach.phase == "stopped" and now > self.coach_until then self.coach = nil end
    if self.loss and now > self.loss_until then self.loss = nil end
    if judged and clock ~= nil and (v >= J.STOPPED or self.moved) then self.leg.upto = clock end
    self.v = v
    if v > J.MOVING then
        self.moved = true
        if judged then
            self.leg.judged = true
            self.leg.passengers = math.max(self.leg.passengers, passengers)
            self.most = math.max(self.most, passengers)
        end
    end

    if v >= J.STOPPED then
        if v < J.LAST then
            self.approach = math.max(self.approach or 0.0, braking)
        else
            self.approach = nil               -- faster again
        end
        local seconds = braking > 0.05 and v / braking or math.huge
        local easing
        if self.coach and self.coach.phase == "ease" then
            easing = braking > J.EASE_OFF and seconds < self:lead() + 1.0
        else
            easing = braking > J.EASE_ON and seconds < self:lead()
        end
        if judged and self.moved and easing then
            self.coach = { phase = "ease", seconds = seconds / self.ratio, braking = braking }
        elseif self.coach and self.coach.phase == "ease" then
            self.coach = nil
        end
        self.braking = braking
    elseif self.moved then                    -- it has just stopped
        local hardest = self.approach ~= nil and self.approach or math.max(self.braking, 0.0)
        local jolt = hardest > J.JOLT
        if judged then
            local leg = self.leg
            if leg.stop == "jolt" then leg.way[#leg.way + 1] = leg.braking end   -- at a stop on the way
            leg.stop, leg.braking = jolt and "jolt" or "smooth", hardest
            self.coach = { phase = "stopped", jolt = jolt, braking = hardest, cost = jolt and stop_cost(hardest) or 0.0,
                           mark = J.mark(leg), score = self:live_score() }
            self.coach_until = now + J.RESULT_SECONDS
            said[#said + 1] = { "stop", jolt, hardest }
        else
            self.coach = nil
        end
        self.moved, self.approach = false, nil
    end

    local spent = self:_spent()
    local level = self:_alert(now, v, along, kind, passengers)
    local harsh, harsh_off = J.LIMITS[kind].harsh[1], J.LIMITS[kind].harsh[2]
    local limit = self.harsh_since ~= nil and harsh_off or harsh
    if judged and v >= J.STOPPED and math.abs(along) > limit then
        if self.harsh_since == nil then
            self.harsh_since, self.harsh_kind, self.harsh_time, self.worst = now, kind, 0.0, 0.0
        end
        self.worst = math.max(self.worst, math.abs(along))
        self.harsh_time = self.harsh_time + step
        if self.harsh == nil and now - self.harsh_since >= J.HARSH_SECONDS then
            self.harsh = { kind, self.worst, self.harsh_time }
            self.leg.harsh[#self.leg.harsh + 1] = self.harsh
        elseif self.harsh ~= nil then
            self.harsh[2], self.harsh[3] = self.worst, self.harsh_time
        end
    else
        if self.harsh ~= nil then
            said[#said + 1] = { "harsh", self.harsh[1], self.harsh[2] }
        elseif self.harsh_since ~= nil then  -- over harsh too briefly to be a harsh moment: firm
            self.leg.firm[self.harsh_kind] = self.leg.firm[self.harsh_kind] + self.harsh_time
        end
        self.harsh_since, self.harsh = nil, nil
        if judged and level and v >= J.STOPPED then
            self.leg.firm[kind] = self.leg.firm[kind] + step
        end
    end
    self:_episode(now, v, kind, level, passengers, self:_spent() - spent)
    return said
end

-- The braking that's down to the driver. Some trains put their brakes on by themselves in the last moments of a
-- stop and hold them there (a Class 350 at 0.62 m/s, 0.9-1.0 m/s² with the handle off). From when it comes on, no
-- more braking counts than just before, unless the brake handle is put on harder.
function Judge:_held(v, braking, demand, hold, said)
    if hold and not self.hold and self.moved and v >= J.STOPPED then
        local cap = math.max(math.min(self.braking, braking), 0.0)
        self.held = { cap = cap, demand = demand }
        said[#said + 1] = { "hold", v, cap }
    elseif not hold then
        self.held = nil
    end
    self.hold = hold and true or false
    local held = self.held
    if held ~= nil then
        if demand ~= nil and held.demand ~= nil and demand > held.demand + J.HELD_HARDER then
            self.held = nil                   -- braking harder: that's the driver's
        else
            braking = math.min(braking, held.cap)
        end
    end
    return braking
end

-- Out of the cab, or into another train: how the last one was moving is forgotten.
function Judge:lost()
    self.accs = {}
    self.hold, self.held = false, nil
    self.coach, self.alert, self.approach, self.harsh_since, self.harsh = nil, nil, nil, nil, nil
    self.episode, self.loss, self.last_time = nil, nil, nil
    self.moved, self.braking = false, 0.0
end

-- Game seconds since the reading before (by the wall clock when the game's isn't read), at most MAX_STEP.
function Judge:_step(now, clock)
    local t = { clock ~= nil, clock ~= nil and clock or now }
    local last = self.last_time
    self.last_time = t
    if last == nil or last[1] ~= t[1] then return 0.0 end
    return math.min(math.max(t[2] - last[2], 0.0), J.MAX_STEP)
end

-- Points the ride has lost to firm and harsh driving so far.
function Judge:_spent()
    local total = 0.0
    for _, loss in ipairs(J.losses(self.leg)) do
        if loss[2] == "firm" or loss[2] == "harsh" then total = total + loss[1] end
    end
    return total
end

-- The service's comfort now, with the ride going on. nil before the first ride.
function Judge:live_score()
    local rides = { table.unpack(self.done) }
    if self.leg.judged then rides[#rides + 1] = ride_of(self.leg) end
    return J.score(rides)
end

-- What a stretch of firm / harsh driving cost: shown for a moment once its warning has gone, unless the train has
-- stopped (how the stop went says it then).
function Judge:_episode(now, v, kind, level, passengers, cost)
    if level then
        self.episode = self.episode or { cost = 0.0, kind = kind, level = "firm" }
        if self.harsh ~= nil then self.episode.kind, self.episode.level = self.harsh[1], "harsh" end
    end
    if level or self.coach then self.loss = nil end
    if self.episode == nil then return end
    self.episode.cost = self.episode.cost + cost
    if self.alert == nil then
        local episode = self.episode
        self.episode = nil
        if passengers ~= nil and v >= J.STOPPED and self.coach == nil and episode.cost >= 0.5 then
            self.loss = { phase = "lost", cost = episode.cost, kind = episode.kind, level = episode.level,
                          mark = J.mark(self.leg), score = self:live_score(), passengers = passengers }
            self.loss_until = now + J.LOSS_SECONDS
        end
    end
end

-- How fast the game's time goes against the wall clock (slower below 20 fps).
function Judge:_time(now, clock)
    local clocks = self.clocks
    if clock == nil or (#clocks > 0 and clock == clocks[#clocks][2]) then return end -- paused, or the same tick
    if #clocks > 0 and (clock < clocks[#clocks][2] or now - clocks[#clocks][1] > 0.5) then
        clocks = {}                           -- another game, or back from a pause
        self.clocks = clocks
    end
    clocks[#clocks + 1] = { now, clock }
    while now - clocks[1][1] > J.RATIO_SECONDS do table.remove(clocks, 1) end
    local wall, game = now - clocks[1][1], clock - clocks[1][2]
    if wall > 1.0 and game > 0 then           -- not while paused
        self.ratio = math.min(math.max(game / wall, 0.1), 1.0)
    end
end

-- Firm (amber) or harsh (red), braking or speeding up, held for a moment after. The level now, or nil.
function Judge:_alert(now, v, along, kind, passengers)
    local size = math.abs(along)
    local was = (self.alert and self.alert.kind == kind) and self.alert.phase or nil
    local firm, firm_off = J.LIMITS[kind].firm[1], J.LIMITS[kind].firm[2]
    local harsh, harsh_off = J.LIMITS[kind].harsh[1], J.LIMITS[kind].harsh[2]
    local level = nil
    if passengers ~= nil and v >= J.STOPPED then
        if size > harsh or (was == "harsh" and size > harsh_off) then
            level = "harsh"
        elseif size > firm or (was ~= nil and size > firm_off) then
            level = "firm"
        end
    end
    if level then
        self.alert = { phase = level, kind = kind, felt = size, passengers = passengers }
        self.alert_until = now + J.HOLD_SECONDS
    elseif self.alert and (now > self.alert_until or passengers == nil or v < J.STOPPED) then
        self.alert = nil
    end
    return level
end

-- The ride going on is one on `service`: a ride on another doesn't carry into it.
function Judge:_ours(service)
    return self.leg.service == nil or self.leg.service == service
end

-- Leaving `station`: the ride to it is done. That ride as kept, or nil if it wasn't judged. `first`: the service's
-- first stop: the service starts here, and how the train went before isn't a ride of it.
function Judge:new_leg(service, station, first)
    local leg, ride = self.leg, nil
    local ours = not first and self:_ours(service) and leg.judged and leg.stop ~= nil
    if first or service ~= self.service then
        self.service, self.done, self.most = service, {}, ours and leg.passengers or 0
    end
    if ours then
        ride = ride_of(leg, station)
        self.done[#self.done + 1] = ride
    end
    self.leg = new_leg(service)
    self.harsh = nil                  -- a harsh moment going on carries on into the next ride uncounted ...
    self.harsh_time = 0.0             -- ... and what's left of it is firm there
    return ride
end

return J
