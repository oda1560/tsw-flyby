-- Comfort HUD settings. Restart the game after changing anything here.

return {
    -- Keys, by their names in UE4SS's Key table. TSW7 leaves = and F11 unbound (the fly-by camera has 4, 6, 7 and F10).
    ToggleKey = "OEM_PLUS",   -- the = key: switch the comfort HUD off (the objective box goes back to the game's own)
                              -- and on again. Off, the mod does no work at all, for comparing the framerate.
    ReportKey = "F11",        -- write what the mod can see of the game into UE4SS.log

    -- What the objective box shows
    ShowPassengers = true,    -- "62 aboard" after the objective's second line
    ShowComfort = true,       -- "comfort 87": the service's comfort so far, once the first ride has begun
    Warnings = true,          -- comfort warnings in the objective's place: ease off before the stop, how the stop
                              -- went, firm / harsh braking or speeding up and what it cost
    PlainText = false,        -- " / " and "m/s2" instead of " · " and "m/s²", if the game shows those oddly

    -- The comfort so far kept beside each of the game's saves (a .comfort file next to the .sav), and put back when
    -- the save is loaded: a service saved one evening and finished the next keeps its comfort
    KeepWithSaves = true,

    -- How the train's acceleration is worked out from its speed, read every frame
    AccelWindow = 0.3,        -- seconds of game time the change of speed is measured over

    DebugLog = true,          -- a line in UE4SS.log every 5 seconds while driving, and how long the mod's work takes
}
