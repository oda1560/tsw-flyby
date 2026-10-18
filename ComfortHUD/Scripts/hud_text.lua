-- What the objective box in the game's header bar says. Most of the time it's the game's own objective, with how
-- many passengers are aboard and the comfort so far after its second line ("Wait until 19:06:00 · 62 aboard ·
-- comfort 87"). While there's something to tell the driver, a comfort warning takes the objective's place: the
-- stop coming with the brake still hard on, how the stop went, firm or harsh braking or speeding up, and what that
-- cost. The words are tsw-joystick's comfort panel's. No game objects in here.

local T = {}

-- Colours for the objective's name, as the game's linear colours: the game's own amber (its objective progress
-- bar), and a red and a green as bright as it.
T.WARN = { R = 0.930111, G = 0.584079, B = 0.0, A = 1.0 }
T.BAD = { R = 0.930111, G = 0.06, B = 0.04, A = 1.0 }
T.GOOD = { R = 0.10, G = 0.70, B = 0.16, A = 1.0 }

-- A comfort mark or score as it's shown: 94.5 -> 95.
function T.whole(x) return math.floor(x + 0.5) end

local function words(opts)
    if opts and opts.PlainText then return { sep = " / ", mss = "m/s2", minus = "-" } end
    return { sep = " · ", mss = "m/s²", minus = "-" }
end

local function join(parts, sep)
    local kept = {}
    for _, p in ipairs(parts) do
        if p and p ~= "" then kept[#kept + 1] = p end
    end
    return table.concat(kept, sep)
end

-- "62 aboard", "nobody aboard", or nil when it's not a passenger train or not counted yet.
function T.aboard(n)
    if n == nil then return nil end
    if n == 0 then return "nobody aboard" end
    return string.format("%d aboard", n)
end

local function comfort(score)
    return score and string.format("comfort %d", T.whole(score)) or nil
end

-- The objective's second line as the game has it, with the passengers and comfort after it. nil: nothing to add.
-- `info`: {passengers, score}; `opts`: the settings (ShowPassengers, ShowComfort, PlainText).
function T.normal_line(game_line, info, opts)
    local w = words(opts)
    local extra = join({ opts.ShowPassengers and T.aboard(info.passengers) or nil,
                         opts.ShowComfort and comfort(info.score) or nil }, w.sep)
    if extra == "" then return nil end
    if game_line == nil or game_line == "" then return extra end
    return game_line .. w.sep .. extra
end

-- The warning in the objective's place for the judge's panel (comfort_judge.lua: Judge:panel()), as
-- {title, colour, line}; nil: no warning. `info`: {passengers, score, cost = what the firm / harsh stretch going
-- on has cost so far}.
function T.takeover(panel, info, opts)
    if panel == nil then return nil end
    local w = words(opts)
    local aboard = opts.ShowPassengers and T.aboard(info.passengers) or nil
    local phase = panel.phase
    if phase == "ease" then
        return { title = "EASE OFF THE BRAKE", colour = T.WARN,
                 line = join({ string.format("Stopping in %d s", math.max(1, math.ceil(panel.seconds))), aboard },
                             w.sep) }
    elseif phase == "stopped" then
        local score = comfort(panel.score)
        if panel.jolt then
            local cost = T.whole(panel.cost or 0)
            return { title = "JOLT ON STOPPING", colour = T.BAD,
                     line = join({ string.format("%.1f %s as it stopped", panel.braking, w.mss),
                                   cost > 0 and (w.minus .. cost) or nil, score }, w.sep) }
        end
        return { title = "SMOOTH STOP", colour = T.GOOD, line = join({ score, aboard }, w.sep) }
    elseif phase == "lost" then
        local what = panel.kind == "brake" and "BRAKING" or "ACCELERATION"
        return { title = string.format("%s %s %s%d", panel.level:upper(), what, w.minus, T.whole(panel.cost)),
                 colour = panel.level == "harsh" and T.BAD or T.WARN,
                 line = join({ string.format("This ride %d", T.whole(panel.mark)), comfort(panel.score), aboard },
                             w.sep) }
    elseif phase == "firm" or phase == "harsh" then
        local what = panel.kind == "brake" and "BRAKING" or "ACCELERATION"
        local title = string.format("%s %s %.1f %s", phase:upper(), what, panel.felt, w.mss)
        local line
        if phase == "harsh" then
            local cost = T.whole(info.cost or 0)
            line = join({ cost > 0 and string.format("%s%d this ride", w.minus, cost) or nil, comfort(info.score),
                          aboard }, w.sep)
        else
            line = join({ panel.kind == "brake" and "Ease off a step" or "Ease off the power", comfort(info.score) },
                        w.sep)
        end
        return { title = title, colour = phase == "harsh" and T.BAD or T.WARN, line = line }
    end
    return nil
end

return T
