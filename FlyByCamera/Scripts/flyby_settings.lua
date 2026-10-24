-- Fly-by camera settings. Distances are in metres, speeds in metres per second.
-- Restart the game after changing anything here.

return {
    -- Keys, by their names in UE4SS's Key table. TSW7 binds 4, 6, 7 and F10 only with Ctrl (its DefaultInput.ini).
    FlyByKey = "SEVEN",       -- fly-by camera on; pressed again, move it to a new spot ahead
    SeatKey = "FOUR",         -- the view from a random passenger seat on your train; pressed again, another seat
    OffKey = "SIX",           -- fly-by camera or seat view off, back to the view you had
    ReportKey = "F10",        -- write what the mod can see of the game into UE4SS.log

    -- The game's own camera keys (from TSW7's input settings): cab, outside, boom, passenger, free camera,
    -- camera shortcuts and photo mode. Pressing one while the fly-by is on hands the view back to the game.
    GameCameraKeys = { "ONE", "TWO", "THREE", "FIVE", "EIGHT", "ZERO", "SHIFT+SPACE" },
    DebugLog = true,          -- a line in UE4SS.log every couple of seconds while it's on

    -- Where the camera stands
    LeadSeconds = 8,          -- this many seconds ahead of the train at its current speed...
    MinLead = 60,             -- ...but at least this far ahead
    MaxLead = 350,            -- ...and at most this far
    SideOffset = 12,          -- this far to the side of the line
    CloseOffset = 6,          -- or this close, in narrow places where further out the view is hidden or in the grass
    Side = "alternate",       -- "left", "right" or "alternate" from one spot to the next
    EyeHeight = 1.7,          -- this high above the ground, when the ground can be found
    HeightAboveTrain = 2.5,   -- otherwise this high above the train's own position
    CheckView = true,         -- look for hills, cuttings and buildings in the way before picking a spot
    GrassHeight = 1.0,        -- and count the view as in the grass where it passes closer than this over the ground
                              -- (grass doesn't stop the checks); keep it below EyeHeight

    -- When it moves on
    PassDistance = 200,       -- once the train is this far past the camera
    MaxDistance = 1500,       -- or whenever the train is this far from it
    MovingSpeed = 0.5,        -- below this speed the train counts as stopped and the camera waits

    -- What it shows
    AimHeight = 2.0,          -- aim this far above the train's position
    Zoom = true,              -- zoom in on the train while it is far away
    FrameWidth = 60,          -- when zooming, keep about this much of the scene in frame
    MinFov = 20,              -- narrowest field of view (degrees) when zoomed in
    MaxFov = 60,              -- widest field of view when the train is close
    Fov = 55,                 -- field of view when Zoom is false

    -- The seat view: a passenger looking the way their seat faces, out of the window nearest them
    SeatFov = 70,             -- field of view from a seat
    SeatEyeHeight = 1.15,     -- eyes this far above a seat that doesn't say where its camera goes
    SeatWindowTurn = 50,      -- degrees from the way the seat faces, towards the nearest window
    SeatNeckTurn = 110,       -- glancing about, at most this many degrees from the way the seat faces
    SeatLookAround = true,    -- the gaze wanders a little, and now and then glances elsewhere for a few seconds
    SeatShake = 1,            -- how much the head moves with the train: 0 holds it still, 2 is twice as much
    SeatMouse = true,         -- turn the view with the mouse as well
    SeatMouseSpeed = 2.5,     -- degrees per step of the game's mouse movement (Unreal's usual, as in the cab)
    SeatMouseReturn = 3,      -- seconds after you leave the mouse before the gaze goes back; false to leave it there
}
