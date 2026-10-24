-- A passenger's head, for the seat view: where they look and how their head moves with the train. Nothing in here
-- touches the game, so it can be tested outside it. Angles in degrees (Unreal's: yaw clockwise from above), lengths
-- in centimetres, times in seconds.
--
-- They look the way their seat faces along the car (ahead, or back the way the train has come in a backward seat),
-- turned towards the window nearest them; on a seat along the side of the car, facing inward, straight across it. Their
-- gaze wanders a little and now and then glances elsewhere for a few seconds, no further round than a neck goes.
-- Their head leans back as the train speeds up, forward as it brakes and out on curves, with a little spring in it,
-- and shakes with the track, more the faster it goes. The mouse turns the view on top of all that; left alone, the
-- gaze goes back to what it was doing.

local H = {}

local TAU = 2 * math.pi

local function wrap(a) return (a + 180) % 360 - 180 end
local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function ease(dt, tau) return 1 - math.exp(-dt / tau) end

-- Glances, by their yaw from the way the seat faces towards the window side (either side on a seat facing inward),
-- and pitch
local GLANCES = {
    { yaw = 90, pitch = -3 },    -- straight out of the window
    { yaw = 120, pitch = -4 },   -- along the train behind them, out of the window
    { yaw = -35, pitch = -2 },   -- across the car
    { yaw = 15, pitch = -22 },   -- down: the table, a phone
}

-- Shake: { size at a standstill, size at full speed, { frequency (Hz), weight }... }
local SHAKE = {
    up = { 0.15, 1.0, { { 1.4, 0.6 }, { 2.3, 0.3 }, { 7.1, 0.1 } } },
    right = { 0.1, 0.8, { { 0.9, 0.7 }, { 1.7, 0.3 } } },
    pitch = { 0.03, 0.25, { { 1.4, 0.6 }, { 3.1, 0.4 } } },
    roll = { 0.03, 0.35, { { 0.9, 0.7 }, { 2.0, 0.3 } } },
    yaw = { 0.02, 0.15, { { 1.1, 1.0 } } },
}
local FULL_SPEED = 30 * 100      -- the shake is full size at this speed (cm/s)...
local MOST_SPEED = 1.3           -- ...and grows to this much more above it
local BREATH_HZ, BREATH = 0.23, 0.3
local LEAN_PER_ACC = 1.5         -- cm the head leans per m/s² ...
local MOST_LEAN = 5              -- ...at most this far
local LEAN_HZ, LEAN_DAMPING = 0.9, 0.45
local LEAN_PITCH, LEAN_ROLL = 0.3, 0.3 -- degrees of tilt per cm of lean
local WANDER = { yaw = { 5, { { 0.031, 0.6 }, { 0.077, 0.4 } } }, pitch = { 2, { { 0.05, 1.0 } } } }
local GLANCE_EVERY = { 12, 35 }  -- s between glances
local GLANCE_FOR = { 2, 6 }      -- s a glance lasts
local MOUSE_QUIET = 2            -- s after the mouse last moved before glances come back
local MOUSE_BACK = 1.0           -- s the gaze takes to go back once the mouse has been left alone
local MOST_PITCH = 80

-- A new head. `random()` gives numbers from 0 to 1 (math.random), for the shake's phases and the glances.
function H.new(random, t)
    local h = { random = random, yaw = nil, pitch = 0, travel = nil, mouse_yaw = 0, mouse_pitch = 0,
                mouse_at = -math.huge, glance = nil, last_speed = nil, last_travel = nil, acc = 0, lat = 0,
                lean = { fwd = { x = 0, v = 0 }, right = { x = 0, v = 0 } }, phases = {} }
    for i = 1, 16 do h.phases[i] = random() * TAU end
    h.next_glance = t + GLANCE_EVERY[1] + random() * (GLANCE_EVERY[2] - GLANCE_EVERY[1])
    return h
end

local function between(h, range) return range[1] + h.random() * (range[2] - range[1]) end

-- A sum of sines at the given frequencies, phases from `first` on: between -1 and 1.
local function waves(h, t, parts, first)
    local v = 0
    for i, p in ipairs(parts) do v = v + p[2] * math.sin(TAU * p[1] * t + h.phases[first + i]) end
    return v
end

-- A spring towards `target`: a little overshoot, as a body settles.
local function spring(s, target, dt)
    local w = TAU * LEAN_HZ
    s.v = s.v + (-(w * w) * (s.x - target) - 2 * LEAN_DAMPING * w * s.v) * dt
    s.x = s.x + s.v * dt
    return s.x
end

local function pick_glance(h, t, side)
    local g = GLANCES[math.min(#GLANCES, 1 + math.floor(h.random() * #GLANCES))]
    if side == 0 then side = h.random() < 0.5 and -1 or 1 end
    h.glance = { yaw = side * g.yaw, pitch = g.pitch, ends = t + between(h, GLANCE_FOR) }
end

-- One frame. `f`: t, dt, travel (yaw of the way the train goes, nil if not known), speed (cm/s), facing (yaw the seat
-- faces, nil if not known: then the way of travel), side (of the window nearest them, as they sit: 1 right, -1 left, 0
-- neither, or behind them), mouse_dx, mouse_dy (the game's mouse movement). `s`: the settings. Returns the view's
-- rotation {Pitch, Yaw, Roll} and how far the head has moved from where it sits: {fwd (the way of travel), right, up}.
function H.step(h, f, s)
    local t = f.t
    local dt = clamp(f.dt or 0, 0, 0.1)
    local snap = h.yaw == nil

    -- the way of travel, turning smoothly with the train
    if f.travel then h.travel = h.travel and h.travel + wrap(f.travel - h.travel) * ease(dt, 0.6) or f.travel end
    local travel = h.travel or 0
    local speed = f.speed or 0

    -- how hard the train speeds up or slows down, and pushes out on curves (cm/s²)
    if h.last_speed and dt > 0 then
        local acc = (speed - h.last_speed) / dt
        local lat = speed * math.rad(wrap(travel - h.last_travel) / dt)
        h.acc = h.acc + (acc - h.acc) * ease(dt, 0.3)
        h.lat = h.lat + (lat - h.lat) * ease(dt, 0.3)
    end
    h.last_speed, h.last_travel = speed, travel

    -- the mouse
    local moved = (f.mouse_dx or 0) ~= 0 or (f.mouse_dy or 0) ~= 0
    if s.SeatMouse then
        if moved then
            h.mouse_at = t
            h.mouse_yaw = clamp(h.mouse_yaw + f.mouse_dx * s.SeatMouseSpeed, -170, 170)
            h.mouse_pitch = clamp(h.mouse_pitch + f.mouse_dy * s.SeatMouseSpeed, -MOST_PITCH, MOST_PITCH)
        elseif s.SeatMouseReturn and t - h.mouse_at > s.SeatMouseReturn then
            local k = ease(dt, MOUSE_BACK)
            h.mouse_yaw, h.mouse_pitch = h.mouse_yaw * (1 - k), h.mouse_pitch * (1 - k)
        end
    end

    -- where they'd look: the way they face, towards the window, or a glance; with the gaze wandering a little
    local ahead = f.facing or travel
    local yaw, pitch = ahead + f.side * s.SeatWindowTurn, 0
    if s.SeatLookAround then
        if t - h.mouse_at < MOUSE_QUIET then
            h.glance, h.next_glance = nil, math.max(h.next_glance, t + GLANCE_EVERY[1])
        elseif h.glance and t >= h.glance.ends then
            h.glance, h.next_glance = nil, t + between(h, GLANCE_EVERY)
        elseif not h.glance and t >= h.next_glance then
            pick_glance(h, t, f.side)
        end
        if h.glance then yaw, pitch = ahead + h.glance.yaw, h.glance.pitch end
    end
    -- no further round than a neck goes from the way the seat faces; the gaze wanders about that
    if f.facing then yaw = f.facing + clamp(wrap(yaw - f.facing), -s.SeatNeckTurn, s.SeatNeckTurn) end
    if s.SeatLookAround then
        yaw = yaw + WANDER.yaw[1] * waves(h, t, WANDER.yaw[2], 0)
        pitch = pitch + WANDER.pitch[1] * waves(h, t, WANDER.pitch[2], 2)
    end
    if snap then
        h.yaw, h.pitch = yaw, pitch
    else
        local tau = h.glance and 0.35 or 0.8
        h.yaw = h.yaw + wrap(yaw - h.yaw) * ease(dt, tau)
        h.pitch = h.pitch + (pitch - h.pitch) * ease(dt, 0.5)
    end

    -- the body: leaning with the train's pushes, and the track's shake
    local k = s.SeatShake or 0
    local fwd = spring(h.lean.fwd, clamp(-h.acc / 100 * LEAN_PER_ACC, -MOST_LEAN, MOST_LEAN) * k, dt)
    local right = spring(h.lean.right, clamp(-h.lat / 100 * LEAN_PER_ACC, -MOST_LEAN, MOST_LEAN) * k, dt)
    local size = clamp(speed / FULL_SPEED, 0, MOST_SPEED)
    local function shake(name, first)
        local sh = SHAKE[name]
        return k * (sh[1] + (sh[2] - sh[1]) * size) * waves(h, t, sh[3], first)
    end
    local up = shake("up", 3) + k * BREATH * math.sin(TAU * BREATH_HZ * t + h.phases[16])
    right = right + shake("right", 6)

    local rot = {
        Pitch = clamp(h.pitch + h.mouse_pitch, -MOST_PITCH, MOST_PITCH) - LEAN_PITCH * fwd + shake("pitch", 8),
        Yaw = wrap(h.yaw + h.mouse_yaw + shake("yaw", 10)),
        Roll = LEAN_ROLL * right + shake("roll", 11),
    }
    return rot, { fwd = fwd, right = right, up = up }
end

-- How far round from the way of travel the head looks now (degrees, positive to the right).
function H.looking(h)
    return wrap((h.yaw or 0) + h.mouse_yaw - (h.travel or 0))
end

return H
