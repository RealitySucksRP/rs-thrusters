Config = {}
Config.Version = '0.1.53'

function Config.PropulsionKind(kind)
    if kind == 'left' or kind == 'right' then return 'side' end
    return kind
end

-- Open source, standalone first build. ox_inventory and ox_target are optional.
Config.ItemKit = 'rs_thruster_kit'
Config.ItemRefill = 'rs_thruster_refill'
Config.InstallDistance = 4.0
Config.MaxInstallSpeed = 1.5 -- meters per second
Config.DriverSyncInterval = 4000

-- Test commands are OFF by default. Enable with server.cfg:
-- set rs_thrusters_dev_mode 1
-- add_ace group.admin rs_thrusters.test allow
-- Then (in a car as the driver): /rstinstall and /rstrefill
Config.TestAce = 'rs_thrusters.test'

-- One normalized model+plate record per vehicle. Integrate a garage VIN for production.
Config.MaxPressure = 100.0
-- Pressure is normalized tank capacity, not calibrated real-world bar/PSI.
-- Engine thrust scales with sqrt(remaining fraction): a GAMEPLAY approximation.
Config.Pressure = {
    -- Set true to use stored gas. False gives installed cars full effective
    -- pressure for testing without changing their saved tank levels.
    ConsumptionEnabled = false,
    AllowPlayerDuration = true,
    DefaultDurationSeconds = 180,
    MinDurationSeconds = 60,
    MaxDurationSeconds = 600,
    MinOperational = 1.0,
    BurnPerNozzle = {rear = 0.75, belly = 0.68, front = 0.8, side = 0.45},
}

Config.Physics = {
    -- Continuous local forces, mass-scaled, at actual emitter offsets.
    -- These starting accelerations must be calibrated live on GTA vehicle physics.
    NozzleAcceleration = {rear = 4.2, belly = 9.5, front = 5.0, side = 3.0},
    LiftThrottle = 0.65, -- maximum manual lift
    LiftRampSeconds = 0.40,
    AssistedClimbSpeed = 3.0, -- m/s while holding lift with hover off
    JumpInputScale = 0.40, -- GTA midair steering sensitivity in Assisted with hover off (1.0 = stock)
    JumpFullSteerSpeed = 12.0, -- m/s; soften pitch and yaw above this speed
    JumpLandingMix = 0.15, -- gentle attitude trim during final descent
    JumpAirTrimMix = 0.05, -- rotation damping with hover off
    HoverFlightMix = 0.11, -- bounded airborne pitch and roll correction
    BoostThrottle = 0.65, -- maximum manual forward boost
    BoostRampSeconds = 0.40,
    BrakeThrottle = 1.0,
    MaxUpSpeed = 18.0,
    MaxForwardSpeed = 75.0,
    MaxHeightAboveGround = 600.0, -- pilot-controlled flight ceiling, no automatic fall at 40 m
    GroundProbeRange = 130.0, -- terrain sampling is advisory, not the altitude hold reference
    MaxWorldHoverZ = 1650.0, -- generous safety ceiling in GTA world coordinates
    HoverDefaultHeight = 3.2,
    HoverEngageMaxSpeed = 8.0, -- horizontal m/s; about 18 mph
    HoverTakeoffThrottle = 0.72,
    HoverLaunchContactHeight = 0.85, -- allow for only some wheels touching a slope
    HoverLaunchClearance = 1.25, -- release attitude control only above this clearance
    HoverLaunchClearMs = 180,
    HoverCatchSettledVerticalSpeed = 2.0, -- m/s; level alone does not mean a jump was caught
    HoverHeightGain = 1.4,
    HoverClimbSpeed = 2.5,
    HoverDescentSpeed = 2.0,
    HoverDamping = 3.0,
    HoverTrimGain = 1.25,
    HoverTrimMax = 14.0,
    ObstacleGuardDistance = 3.2, -- safety ahead of the commanded travel direction
    ObstacleGuardSpeedLookahead = 2.8, -- extra lookahead at speed
    ObstacleProbeHeight = 0.85, -- keep horizontal probe clear of road surface
    ObstacleProbeRadius = 0.48,
    ObstacleProbeIntervalMs = 125, -- async probe; do not raycast each frame
    ObstacleGuardHoldMs = 350,
    CollisionSpinThreshold = 2.1, -- must be an abrupt new impact, not a sticky collision flag -- radians/s, ignores normal wheel contact
    CollisionUprightThreshold = 0.90,
    CollisionQuietMs = 750,
    CollisionTorqueGain = 0.35,
    CollisionSpinTorqueGain = 0.85,
    CollisionSpinBrakeMix = 0.30,
    CollisionRecoveryMix = 0.09,
    CollisionLiftThrottle = 0.48,
    HoverMoveSpeed = 8.0, -- m/s at full forward throttle
    HoverReverseSpeed = 4.0,
    HoverDriveGain = 1.10,
    HoverPositionGain = 0.55, -- return speed per meter of drift
    HoverPositionDeadband = 0.25, -- meters
    HoverPositionMaxSpeed = 1.25, -- m/s, automatic return only
    HoverDriveAccel = 4.0,
    HoverDriveRamp = 0.75,
    HoverSlideSpeed = 4.0,
    HoverSlideAccel = 2.5,
    CollectiveClimbSpeed = 2.5,
    CollectiveDescentSpeed = 1.6,
    ControllerPitchDefault = false, -- Xbox right-stick vertical pitch in Helicopter hover
    ControllerPitchScale = 0.45, -- right-stick pitch authority in Helicopter hover
    ControllerPitchSlew = 0.70, -- pitch input per second
    HelicopterPitchDegrees = 8.0, -- only explicit right-stick Y / numpad pitch; never forward throttle
    HoverYawRate = 0.65,
    HoverYawMix = 0.24,
    HoverLevelKp = 0.65,
    HoverLevelKd = 0.82,
    HoverLevelMix = 0.16,
    HoverLevelDeadband = 0.025,
    HoverRecoveryThrottle = 0.24,
    HoverRecoveryBrakeEnter = 0.95, -- rad/s, Assisted hover brakes all rotation above this
    HoverCatchBrakeEnter = 0.65, -- rad/s, above leveling speed but below normal spin threshold
    HoverRecoveryBrakeExit = 0.40, -- rad/s, resume leveling below this
    HoverRecoveryLevelRate = 0.52, -- rad/s, max commanded rotation back toward level
    HoverRecoveryRateGain = 0.30,
    HoverRecoveryMix = 0.09,
    HoverRecoveryBrakeMix = 0.14,
    HoverRecoveryYawMix = 0.10,
    HoverSpinTripRate = 2.35, -- rad/s: automatic angular-speed braking above this
    HoverSpinExitRate = 0.65, -- rad/s: recovery hysteresis
    HoverSpinBrakeMix = 0.32,
    HoverRecoveryTorqueGain = 0.95, -- bounded corrective torque, avoid oscillation near props
    HoverRecoverySettleMs = 450, -- hold both level and low angular velocity before releasing recovery
    HoverAssistSettledUpZ = 0.985, -- about 10 degrees from upright
    HoverAssistSettledRate = 0.25, -- rad/s
    HoverResumeMs = 650, -- ease pilot input back in after Assisted recovery
    HoverRecoveryExitUpZ = 0.72, -- resume lift after the car has leveled farther
    RecoveryWheelAngle = 25.0,
    RecoveryRollRate = 0.65, -- radians/second
    HoverMaxAcceleration = 28.0,
    MaxHoverTiltZ = 0.38, -- hover disengages if up-vector is too tilted
    LandingHeight = 5.0,
    ShutdownDescentSpeed = 2.0, -- meters per second before the touchdown taper
    LandingFlareHeight = 2.2, -- Helicopter hover: gentle nose-up flare approaching ground
    LandingFlarePitchDegrees = 5.5,
    LandingFlareMaxDescent = -0.45,
    LandingDescentSpeed = -5.0,
    LandingTargetSpeed = -2.3,
    LandingGain = 3.0,
    AirborneHeight = 0.85,
    ControllerDeadzone = 0.22,
    ManualMix = 0.72,
    YawMix = 0.75,
    StuntNeutralThreshold = 0.26, -- LB must see neutral before the flick
    StuntFlickThreshold = 0.72,
    StuntSpinAbortRate = 4.2, -- rad/s safety watchdog
    StuntHardStopDegrees = 425.0, -- don't attempt a second revolution
    StuntClearance = 7.0, -- lift clearance before a full 360 (open sky, no ceiling probe)
    StuntAutoTakeoff = true, -- a J/K/Alt+arrow stunt launches and returns to hover even if H was off
    StuntClimbSpeed = 5.5,
    StuntClimbTimeoutMs = 11000,
    StuntClimbLevelMix = 0.18,
    StuntMix = 0.94, -- maximum attitude jet asymmetry while rotating
    StuntBrakeMix = 0.90, -- reverse-thrust authority to stop at one full rotation
    StuntSettleMix = 0.37, -- finish levelling and arrest angular velocity
    StuntTorqueGain = 3.1, -- stunt-only torque multiplier; hover stays exactly as before
    StuntPitchMaxRate = 1.15, -- rad/s; front/back flips only
    StuntPitchAcceleration = 1.0, -- rad/s^2; ease into the flip from rest
    StuntPitchDeceleration = 0.65, -- rad/s^2; plan braking early
    StuntPitchDriveMix = 0.36,
    StuntPitchBrakeMix = 0.44,
    StuntPitchTorqueGain = 1.2,
    StuntPitchSettleMix = 0.16,
    StuntPitchSettleRate = 0.30,
    StuntRateGain = 1.35,
    StuntRollMaxRate = 1.85, -- rad/s
    StuntRollDeceleration = 1.0, -- rad/s^2; start braking before the end of the roll
    StuntRollSettleRate = 0.40, -- rad/s; maximum spin at the start and finish
    StuntStallMs = 5000, -- surface a warning if the car fails to rotate
    StuntStallDegrees = 12.0,
    StuntSettleMs = 3500,
    StuntStableMs = 150,
    StuntCrossMix = 0.14, -- suppress rotation on the uncommanded axis
    StuntSettleTorqueGain = 1.4, -- lower than the rotating phase to limit overshoot
    StabilizeKp = 0.35,
    StabilizeKd = 0.50,
    StabilizeMix = {assisted = 0.60, sport = 0.30, manual = 0.0},
    StuntMaxMs = 14000,
    StuntTargetDegrees = 360.0,
    -- Reverse signs here if a test car rotates opposite its control label.
    PitchSign = 1.0,
    RollSign = 1.0,
}

Config.UI = {
    Enabled = true,
    HudDefault = true,
    ModeDefault = 'assisted',
    HoverStyleDefault = 'helicopter', -- 'car' or 'helicopter'
    LandingAssistDefault = true,
    ThrustDefault = 1.0, -- UI-selected output cap 25%-100%
    HoverTargetDefault = 3.2,
    RefreshMs = 130,
    VirtualMaxRpm = 12000,
}

Config.FlightCamera = {
    EnabledByDefault = true,
    Distance = 9.0,
    Height = 2.6,
    LookAhead = 3.5,
    Fov = 65.0,
    TurnResponse = 8.0, -- higher follows turns more quickly
    MaxTurnSpeed = 110.0, -- degrees per second
    MinFollowUpZ = 0.55, -- hold the previous heading through steep tumbles
    MouseSensitivity = 1.8, -- mouse orbit sensitivity in hover
}

Config.Fx = {
    Asset = 'core',
    Name = 'ent_sht_steam', -- verified built-in vapor purge effect
    Scale = 1.10,
    -- Scale each layer against the jet output. The second layer starts downstream.
    Layers = {
        {Distance = 0.0, Scale = 0.44, Alpha = 1.0, Fade = 0.75},
        {Distance = 0.90, Scale = 1.38, Alpha = 0.88, Fade = 1.45},
    },
    FadeMs = 1100, -- each jet tapers off after the thrust stops
    -- Visual placement only. Pull side exhaust inside the wheel-width bounds.
    SideInset = 0.76,
    SideScale = 0.75,
    JumpBellyScale = 0.46, -- faint belly vapor during jumps with hover off
    HoverBellyMinScale = 1.15, -- visible exhaust at each belly nozzle while airborne in hover
    HoverSteamRefreshMs = 1050, -- refresh idle steam before it thins out
    SpeedColorThreshold = 8.0, -- m/s
    OverrunThreshold = 0.90, -- actual nozzle output
    Colors = {solid='#5bdcff', slow='#5bdcff', fast='#b95cff', overrun='#ff7138'},
    RenderDistance = 85.0,
    Debug = false,
    -- Editable per-nozzle rotations in DEGREES, relative to the vehicle.
    -- Actual visual direction depends on Rockstar's PTFX asset orientation.
    Rotations = {
        rear = { 0.0, 0.0, 0.0 },
        belly = { 180.0, 0.0, 0.0 },
        front = { 0.0, 0.0, 180.0 },
        left = { 0.0, -90.0, 0.0 },
        right = { 0.0, 90.0, 0.0 },
    }
}

Config.Debug = false

-- GTA vehicle classes, client enforcement plus server-side automobile type check.
Config.AllowedClasses = {
    [0]=true, [1]=true, [2]=true, [3]=true, [4]=true,
    [5]=true, [6]=true, [7]=true, [9]=true, [10]=true,
    [11]=true, [12]=true, [17]=true, [18]=true, [19]=true,
    [20]=true, [22]=true,
}

-- Four rear boost, four underbody lift/attitude, two front braking,
-- four lateral yaw/correction jets. Normalized placement (-1..1) per model.
-- White gas vapor is a visual approximation of condensation, not exhaust smoke.
-- Visual offsets can be adjusted independently of the force geometry.
Config.Nozzles = {
    {name='rear_upper_l', bit=1,     kind='rear',  x=-0.72, y=-0.94, z= 0.45, dir={0, 1, 0}},
    {name='rear_upper_r', bit=2,     kind='rear',  x= 0.72, y=-0.94, z= 0.45, dir={0, 1, 0}},
    {name='rear_lower_l', bit=4,     kind='rear',  x=-0.72, y=-0.94, z=-0.20, dir={0, 1, 0}},
    {name='rear_lower_r', bit=8,     kind='rear',  x= 0.72, y=-0.94, z=-0.20, dir={0, 1, 0}},
    {name='belly_fl',     bit=16,    kind='belly', x=-0.70, y= 0.57, z=-0.90, dir={0, 0, 1}},
    {name='belly_fr',     bit=32,    kind='belly', x= 0.70, y= 0.57, z=-0.90, dir={0, 0, 1}},
    {name='belly_rl',     bit=64,    kind='belly', x=-0.70, y=-0.57, z=-0.90, dir={0, 0, 1}},
    {name='belly_rr',     bit=128,   kind='belly', x= 0.70, y=-0.57, z=-0.90, dir={0, 0, 1}},
    {name='front_l',     bit=256,   kind='front', x=-0.65, y= 0.93, z= 0.13, dir={0,-1, 0}},
    {name='front_r',     bit=512,   kind='front', x= 0.65, y= 0.93, z= 0.13, dir={0,-1, 0}},
    {name='side_front_l',bit=1024,  kind='left',  x=-0.95, y= 0.55, z= 0.10, dir={ 1,0,0}},
    {name='side_rear_l', bit=2048,  kind='left',  x=-0.95, y=-0.55, z= 0.10, dir={ 1,0,0}},
    {name='side_front_r',bit=4096,  kind='right', x= 0.95, y= 0.55, z= 0.10, dir={-1,0,0}},
    {name='side_rear_r', bit=8192,  kind='right', x= 0.95, y=-0.55, z= 0.10, dir={-1,0,0}},
}
