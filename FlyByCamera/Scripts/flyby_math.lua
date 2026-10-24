-- Maths for the fly-by camera. Nothing in here touches the game, so it can be tested outside it.
-- Unreal units: centimetres, X and Y flat, Z up, angles in degrees. Settings are in metres.

local M = {}

local CM = 100                  -- centimetres in a metre
local CRUMB = 5 * CM            -- keep a point of the train's path every 5 m
local MAX_CRUMBS = 40           -- 200 m of path
local CURVE_BACK = 60 * CM      -- measure the curve over the last 60 m
local MAX_CURVATURE = 1 / (150 * CM) -- tighter than a 150 m radius is taken as noise
local MAX_TURN = math.pi / 3    -- never predict more than 60 degrees round a curve
local JUMP_SPEED = 200 * CM     -- faster than 200 m/s between frames is a jump, not travel
local HEADING_STEP = 1 * CM     -- keep the vehicle's heading every metre
local MIN_HEADING_SPAN = 4 * CM -- and work out the curve once it has gone this far
local MIN_FRAME_MOVE = 0.5      -- centimetres a frame below which the way it moved isn't trusted
local MIN_SIGN_SPEED = 30       -- nor below this speed (cm/s)

function M.vec(x, y, z) return { X = x, Y = y, Z = z } end
local vec = M.vec

function M.copy(a) return vec(a.X, a.Y, a.Z) end
function M.add(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
function M.sub(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
function M.scale(a, s) return vec(a.X * s, a.Y * s, a.Z * s) end
function M.dot2(a, b) return a.X * b.X + a.Y * b.Y end
function M.len(a) return math.sqrt(a.X * a.X + a.Y * a.Y + a.Z * a.Z) end
function M.len2(a) return math.sqrt(a.X * a.X + a.Y * a.Y) end
function M.clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

-- Flat unit vector along a, or nil when a has no flat length.
function M.flat_dir(a)
    local l = M.len2(a)
    if l < 1e-6 then return nil end
    return vec(a.X / l, a.Y / l, 0)
end

-- Unreal is left-handed: with X forward, +Y is to the right.
function M.right_of(dir) return vec(-dir.Y, dir.X, 0) end

-- Turn a flat direction by `angle` radians, positive to the right.
function M.rotate(dir, angle)
    local c, s = math.cos(angle), math.sin(angle)
    return vec(dir.X * c - dir.Y * s, dir.X * s + dir.Y * c, 0)
end

local function heading(dir) return math.atan(dir.Y, dir.X) end

local function wrap(angle)
    while angle > math.pi do angle = angle - 2 * math.pi end
    while angle < -math.pi do angle = angle + 2 * math.pi end
    return angle
end

-- Rotation that points a camera at `from` towards `to`.
function M.look_at(from, to)
    local d = M.sub(to, from)
    return {
        Pitch = math.deg(math.atan(d.Z, M.len2(d))),
        Yaw = math.deg(math.atan(d.Y, d.X)),
        Roll = 0,
    }
end

-- Field of view that keeps about `width` metres in frame at `dist` centimetres away.
function M.zoom_fov(dist, s)
    local half = s.FrameWidth * CM / 2
    local fov = math.deg(2 * math.atan(half, math.max(dist, 1)))
    return M.clamp(fov, s.MinFov, s.MaxFov)
end

----------------------------------------------------------------------------------------------------
-- Following the train: speed, direction of travel, curve and gradient.
-- When the game gives the vehicle's forward direction, that is the line's direction right where the train is,
-- and how fast it turns per metre travelled gives the curve within a few metres. Otherwise both come from the
-- shape of the path behind the train (60 m of it for the curve). `dir` is the direction of travel at `dir_at`.

function M.new_tracker()
    return { crumbs = {}, headings = {}, travelled = 0, speed = 0, dir = nil, dir_at = nil,
             curvature = 0, grade = 0, last = nil, last_t = nil }
end

local function reset_path(tr, pos)
    tr.crumbs = { M.copy(pos) }
    tr.headings = {}
    tr.dir_at = nil
    tr.curvature = 0
    tr.grade = 0
end

-- A point of the path every 5 m: direction of travel, reversing, gradient, and the curve without headings.
local function add_crumb(tr, pos)
    local crumbs = tr.crumbs
    local newest = crumbs[#crumbs]
    if not newest then
        crumbs[1] = M.copy(pos)
        return nil
    end
    if M.len2(M.sub(pos, newest)) < CRUMB then return nil end

    local event = nil
    local step = M.flat_dir(M.sub(pos, newest))
    if tr.dir and step and M.dot2(step, tr.dir) < 0 then
        reset_path(tr, newest) -- the path behind no longer says anything about the way ahead
        event = "reversed"
    end
    crumbs = tr.crumbs
    crumbs[#crumbs + 1] = M.copy(pos)
    if #crumbs > MAX_CRUMBS then table.remove(crumbs, 1) end
    if step then
        tr.dir = step
        tr.dir_at = M.scale(M.add(newest, pos), 0.5)
    end

    -- Compare the latest 5 m with the stretch about 60 m further back.
    local n = #crumbs
    local back, travelled = nil, 0
    for i = n - 1, 1, -1 do
        travelled = travelled + M.len2(M.sub(crumbs[i + 1], crumbs[i]))
        if travelled >= CURVE_BACK and i >= 2 then
            back = i
            break
        end
    end
    if back then
        if #tr.headings == 0 then
            local old = M.flat_dir(M.sub(crumbs[back], crumbs[back - 1]))
            local new = M.flat_dir(M.sub(crumbs[n], crumbs[n - 1]))
            if old and new then
                local k = wrap(heading(new) - heading(old)) / travelled
                tr.curvature = M.clamp(k, -MAX_CURVATURE, MAX_CURVATURE)
            end
        end
        tr.grade = M.clamp((crumbs[n].Z - crumbs[back].Z) / travelled, -0.1, 0.1)
    end
    return event
end

-- The vehicle's forward direction `fwd`, and `moved`, the way it went this frame (nil if it hardly moved).
local function add_heading(tr, pos, fwd, moved)
    local h = M.flat_dir(fwd)
    if not h then return nil end
    local event = nil
    if moved and tr.dir and M.dot2(moved, tr.dir) < 0 then
        reset_path(tr, pos)
        event = "reversed"
    end
    local travel = moved or tr.dir
    if travel then
        -- vehicles can face backwards in a train: the line's direction is the way the train is going
        if M.dot2(h, travel) < 0 then h = vec(-h.X, -h.Y, 0) end
        tr.dir, tr.dir_at = h, M.copy(pos)
    end

    -- The curve: how far the heading has turned over the last metres travelled, up to 60 m.
    -- A vehicle facing backwards turns the same way, so its own heading will do.
    local yaw = heading(M.flat_dir(fwd))
    local hs = tr.headings
    local last = hs[#hs]
    if not last or tr.travelled - last.s >= HEADING_STEP then
        hs[#hs + 1] = { s = tr.travelled, yaw = yaw }
        while #hs > 2 and tr.travelled - hs[2].s >= CURVE_BACK do table.remove(hs, 1) end
    end
    local span = tr.travelled - hs[1].s
    if span >= MIN_HEADING_SPAN then
        tr.curvature = M.clamp(wrap(yaw - hs[1].yaw) / span, -MAX_CURVATURE, MAX_CURVATURE)
    end
    return event
end

-- Feed the train's position at game time t (seconds), and its forward direction when the game gives one.
-- Returns "jump" when the position leapt (the game shifting its world origin, or a teleport), "reversed" when
-- the train changed direction.
function M.track(tr, pos, t, fwd)
    local moved = nil
    if tr.last then
        local dt = t - tr.last_t
        if dt <= 0 then return nil end -- paused, or the same frame twice
        local delta = M.sub(pos, tr.last)
        local d = M.len2(delta)
        if d / dt > JUMP_SPEED then
            reset_path(tr, pos)
            tr.last, tr.last_t = M.copy(pos), t
            return "jump"
        end
        local blend = math.min(1, dt / 0.5) -- smooth speed over about half a second
        tr.speed = tr.speed + (d / dt - tr.speed) * blend
        tr.travelled = tr.travelled + d
        if d >= MIN_FRAME_MOVE and tr.speed >= MIN_SIGN_SPEED then moved = M.flat_dir(delta) end
    end
    tr.last, tr.last_t = M.copy(pos), t
    local event = add_crumb(tr, pos)
    if fwd then event = add_heading(tr, pos, fwd, moved) or event end
    return event
end

-- "straight" or "curving right, 3000 m radius"
function M.describe_curve(k)
    if math.abs(k) < 1 / (20000 * CM) then return "straight" end
    return string.format("curving %s, %.0f m radius", k > 0 and "right" or "left", 1 / math.abs(k) / CM)
end

----------------------------------------------------------------------------------------------------
-- Where the line goes: carry on round the current curve for `s` centimetres.
-- Returns the point and the direction of the line there.

function M.predict(origin, dir, curvature, grade, s)
    local k = curvature
    if math.abs(k * s) > MAX_TURN then s = MAX_TURN / math.abs(k) end
    local right = M.right_of(dir)
    local forward, side, out_dir
    if math.abs(k * s) < 1e-4 then
        forward, side, out_dir = s, 0, dir
    else
        forward = math.sin(k * s) / k
        side = (1 - math.cos(k * s)) / k -- positive k turns right
        local c, sn = math.cos(k * s), math.sin(k * s)
        out_dir = vec(dir.X * c + right.X * sn, dir.Y * c + right.Y * sn, 0)
    end
    local p = M.add(origin, M.add(M.scale(dir, forward), M.scale(right, side)))
    p.Z = origin.Z + grade * s
    return p, out_dir
end

-- Spots to try for the camera, best first: how much of the lead distance ahead, and how far to the side in
-- SideOffsets, or in CloseOffsets when the third is true. Further out (1.8) sees over a fence or a wall by the line;
-- closer in is for narrow places, where further out is up a bank, or looks across one, in the grass.
-- Each has `pos` (camera, before finding the ground) and `track` (the point on the line it looks across to).
-- `side` is +1 for right, -1 for left; `out` is how far from the line and `ahead` how far ahead.
local TRIES = {
    { 1.0, 1.0 }, { 1.0, -1.0 }, { 0.7, 1.0 }, { 0.7, -1.0 },
    { 1.0, 1, true }, { 1.0, -1, true }, { 1.0, 1.8 }, { 1.0, -1.8 },
    { 0.7, 1, true }, { 0.7, -1, true }, { 0.45, 1.0 }, { 0.45, -1.0 },
}

function M.lead_distance(speed, s)
    return M.clamp(speed * s.LeadSeconds, s.MinLead * CM, s.MaxLead * CM)
end

function M.candidates(origin, dir, tr, s, side)
    local lead = M.lead_distance(tr.speed, s)
    if tr.dir_at and dir == tr.dir then
        -- the line has curved a little more between the middle of the last 5 m and the train
        dir = M.rotate(dir, tr.curvature * M.len2(M.sub(origin, tr.dir_at)))
    end
    local list = {}
    for _, try in ipairs(TRIES) do
        local track, line_dir = M.predict(origin, dir, tr.curvature, tr.grade, lead * try[1])
        local sign = (try[2] > 0 and 1 or -1) * side
        local out = (try[3] and s.CloseOffset or s.SideOffset) * CM * math.abs(try[2])
        local pos = M.add(track, M.scale(M.right_of(line_dir), out * sign))
        pos.Z = track.Z + s.HeightAboveTrain * CM
        list[#list + 1] = { pos = pos, track = track, side = sign, out = out, ahead = lead * try[1] }
    end
    return list
end

-- How far out from the camera a view is looked along for the ground coming close under it (metres): closest
-- together near the camera, where grass fills more of the picture.
local LOW_VIEW_AT = { 2, 4, 7, 10, 15, 20, 30, 40, 50 }

-- Points along the view from `eye` to `target` at which to look for the ground just under it, stopping `short`
-- centimetres from the target. Each has `pos` and `at`, how far out from the camera it is.
function M.view_points(eye, target, short)
    local to = M.sub(target, eye)
    local d = M.len(to)
    local list = {}
    for _, m in ipairs(LOW_VIEW_AT) do
        local at = m * CM
        if at > d - short then break end
        list[#list + 1] = { pos = M.add(eye, M.scale(to, at / d)), at = at }
    end
    return list
end

-- How far the train is past the camera along its direction of travel (negative while coming).
function M.past_by(cam, train, dir)
    return M.dot2(M.sub(train, cam), dir)
end

-- Why the camera should move to a new spot now, or nil to stay put.
function M.needs_new_spot(cam, train, tr, placed_dir, s)
    if M.len(M.sub(train, cam)) > s.MaxDistance * CM then return "the train is too far away" end
    local dir = tr.dir
    if not dir or tr.speed < s.MovingSpeed * CM then return nil end
    local past = M.past_by(cam, train, dir)
    if past > s.PassDistance * CM then return "the train has gone by" end
    if placed_dir and M.dot2(dir, placed_dir) < -0.5 and past > 20 * CM then
        return "the train is going the other way"
    end
    return nil
end

----------------------------------------------------------------------------------------------------
-- The seat view: a seat sits turned in its seat component, which sits turned on its vehicle.

-- The forward, right and up axes of an Unreal rotator (as FRotationMatrix has them).
function M.axes(r)
    local p, y, w = math.rad(r.Pitch or 0), math.rad(r.Yaw or 0), math.rad(r.Roll or 0)
    local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(w), math.cos(w)
    return vec(cp * cy, cp * sy, sp),
        vec(sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp),
        vec(-(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp)
end

local function dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end

-- `v`, given in a frame turned by `r`, in the frame outside it.
function M.turn(r, v)
    local x, y, z = M.axes(r)
    return vec(x.X * v.X + y.X * v.Y + z.X * v.Z, x.Y * v.X + y.Y * v.Y + z.Y * v.Z,
        x.Z * v.X + y.Z * v.Y + z.Z * v.Z)
end

-- `v`, given in the frame outside, in the frame turned by `r`: M.turn backwards.
function M.unturn(r, v)
    local x, y, z = M.axes(r)
    return vec(dot(v, x), dot(v, y), dot(v, z))
end

-- The rotator with these forward, right and up axes (as FMatrix does it).
local function rotator(x, y, z)
    local pitch = math.deg(math.atan(x.Z, math.sqrt(x.X * x.X + x.Y * x.Y)))
    local yaw = math.deg(math.atan(x.Y, x.X))
    local _, flat_right = M.axes({ Pitch = pitch, Yaw = yaw, Roll = 0 })
    return { Pitch = pitch, Yaw = yaw, Roll = math.deg(math.atan(dot(z, flat_right), dot(y, flat_right))) }
end

-- The rotation of something turned by `inner` in a frame turned by `outer`.
function M.combine(outer, inner)
    local x, y, z = M.axes(inner)
    return rotator(M.turn(outer, x), M.turn(outer, y), M.turn(outer, z))
end

-- The rotation, in a frame turned by `outer`, of something turned by `r` outside it: M.combine backwards.
function M.uncombine(outer, r)
    local x, y, z = M.axes(r)
    return rotator(M.unturn(outer, x), M.unturn(outer, y), M.unturn(outer, z))
end

-- Where a seat's camera goes, in its seat component's frame: the seat's own camera offset, turned with the seat, or
-- `eye_height` centimetres straight up from the seat when it gives none.
function M.seat_eye(pos, rot, offset, eye_height)
    if offset and M.len(offset) > 0.5 then return M.add(pos, M.turn(rot, offset)) end
    return M.add(pos, vec(0, 0, eye_height))
end

return M
