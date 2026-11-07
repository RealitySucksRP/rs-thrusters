local RESOURCE = GetCurrentResourceName()
local input = {lift=false, boost=false, brake=false, mod=false, pitchUp=false, pitchDown=false, rollLeft=false, rollRight=false, yawLeft=false, yawRight=false}
local enabled, hover, hoverHeight = false, false, Config.UI.HoverTargetDefault
local preset, trackedVehicle, lastFxMask = nil, 0, 0
-- Roll signs are verified per model with short right and left probes.
local rollProbe = nil
local rollCalibration = {ready=false, [1]=nil, [-1]=nil, actuation=1, feedback=1}
local lastTransmit, lastSync, lastSyncVehicle = 0, 0, 0
local emitters, dimensions = {}, {}
local assetLoaded = false
local mode = Config.UI.ModeDefault
local hoverStyle = Config.UI.HoverStyleDefault
local controllerPitchEnabled = Config.Physics.ControllerPitchDefault == true
do
    local saved = GetResourceKvpString('controllerPitchEnabled')
    if saved == 'on' or saved == 'off' then controllerPitchEnabled = saved == 'on' end
end
local landingAssist = Config.UI.LandingAssistDefault
local hudVisible = Config.UI.HudDefault
local thrustOutput = Config.UI.ThrustDefault
local menuOpen = false
local descending = false
local keyPresses, stuntPresses = {}, {}
local stickDirections, stickSeen = {}, {}
local function recordKey(key)
    keyPresses[key] = (keyPresses[key] or 0) + 1
end
local fxModes = {stock=true, solid=true, speed=true}
local fxStyle = GetResourceKvpString('fxStyle')
if not fxModes[fxStyle] then fxStyle = 'stock' end
local fxColors = {}
local function validColor(value)
    return type(value) == 'string' and value:match('^#%x%x%x%x%x%x$') ~= nil
end
for name, default in pairs(Config.Fx.Colors) do
    local saved = GetResourceKvpString('fxColor_' .. name)
    fxColors[name] = validColor(saved) and saved or default
end
local liftRamp, boostRamp, controllerPitch = 0.0, 0.0, 0.0
local hoverRecovering, assistedSpinBraking = false, false
local recoverySince, recoveryStableSince = 0, 0
local recoveryReportAt = 0
local lastContact = false
local stuntHeld, stuntArmed, stuntModifierWasHeld = false, false, false
local controlLostSince = 0
local recoveryAxis, recoverySign
local hoverTrim, hoverDrive, hoverSlide, lastCollective = 0.0, 0.0, 0.0, 0.0
local hoverFloor, groundProbe
-- Maintain a WORLD-Z hover target so terrain ray misses and high altitude
-- cannot pull the vehicle back to a 3.2 m AGL target.
local hoverWorldTarget, hoverAnchor
local catchingHover, hoverResumeAt, hoverLaunchClearSince = false, nil, nil
local lastAngularShock = 0.0
local lastPilot = {throttle=0.0,turn=0.0,slide=0.0,pitch=0.0,blocked=false,recovering=false}
local impactUntil = 0
local obstacleProbe = {vehicle=0, id=0, nextSample=0, hitUntil=0, hitDirection=nil, hitDistance=0.0}
local collisionLogAt = 0
local lastAppliedMask = 0
local lastThrust, lastTorque = 0.0, 0.0
local lastPitchTorque, lastRollTorque, lastWorldLift = 0.0, 0.0, 0.0
local previousFlightRate, previousChassis
local nozzleOutput = {}
local takeoffTrace, wasLifting, wasHovering, wasPitching = nil, false, false, false
local lastFrame = 0
local chaseEnabled = Config.FlightCamera.EnabledByDefault
local chase
local chaseAirborneSince, chaseLandedSince
local chaseYielded = false

local function notice(message)
    print('[rs-thrusters] ' .. message)
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName('~b~RS Thrusters~s~: ' .. message)
    EndTextCommandThefeedPostTicker(false, false)
end
RegisterNetEvent('rs_thrusters:notice', notice)

local function debugLog(message)
    if Config.Debug then print('[rs-thrusters] ' .. message) end
end

local function isEligible(vehicle)
    return vehicle ~= 0 and DoesEntityExist(vehicle) and GetEntityType(vehicle) == 2
        and Config.AllowedClasses[GetVehicleClass(vehicle)] == true
end

local function driverVehicle()
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if not isEligible(vehicle) or GetPedInVehicleSeat(vehicle, -1) ~= ped then return 0 end
    return vehicle
end

local function installed(vehicle)
    return vehicle ~= 0 and Entity(vehicle).state.rsThrustersInstalled == true
end

local tankDuration = Config.Pressure.DefaultDurationSeconds
local function pressure(vehicle)
    if not Config.Pressure.ConsumptionEnabled and installed(vehicle) then return Config.MaxPressure end
    return math.max(0.0, tonumber(Entity(vehicle).state.rsThrustersPressure) or 0.0)
end

local function validActiveVehicle()
    local vehicle = driverVehicle()
    return vehicle ~= 0 and installed(vehicle) and pressure(vehicle) > 0 and enabled and vehicle or 0
end

local function surfaceBelow(vehicle, pos)
    local now = GetGameTimer()
    if not groundProbe or groundProbe.vehicle ~= vehicle then
        groundProbe = {vehicle=vehicle, id=0, nextSample=0}
    end
    local probe = groundProbe
    if probe.id ~= 0 then
        local status, hit, point, normal = GetShapeTestResult(probe.id)
        if status == 2 then
            probe.z = (hit == true or hit == 1) and normal.z > 0.4 and point.z or nil
            probe.sampleAt, probe.sampleX, probe.sampleY = now, probe.x, probe.y
        end
        if status ~= 1 then probe.id = 0 end
    end
    if probe.id == 0 and now >= probe.nextSample then
        probe.x, probe.y = pos.x, pos.y
        probe.id = StartShapeTestLosProbe(pos.x, pos.y, pos.z + 0.25,
            pos.x, pos.y, pos.z - Config.Physics.GroundProbeRange, 1, vehicle, 7)
        probe.nextSample = now + 65
    end
    local nearby = probe.z and math.abs(pos.x - probe.sampleX) + math.abs(pos.y - probe.sampleY) < 3.0
    if nearby and now - probe.sampleAt < 225 then return probe.z end
    -- If world geometry is not streamed below us, do not reinterpret altitude
    -- as zero. Keep the most recent terrain reference, or a native estimate.
    if probe.z then return probe.z end
    local nativeAgl = GetEntityHeightAboveGround(vehicle)
    if nativeAgl > 0.01 then return pos.z - nativeAgl end
    return hoverFloor or (pos.z - 1.0)
end

-- An object is not terrain. World-only ground probes prevent a nearby prop
-- from abruptly changing the hover altitude; an independent horizontal probe
-- spots objects before we accelerate towards them. Asynchronous and throttled.
local function objectAhead(vehicle, position, forward, right, velocity, drive, slide, now, cfg)
    if obstacleProbe.vehicle ~= vehicle then
        obstacleProbe = {vehicle=vehicle, id=0, nextSample=0, hitUntil=0, hitDirection=nil, hitDistance=0.0}
    end
    local probe = obstacleProbe
    if probe.id ~= 0 then
        local status, hit, point, normal = GetShapeTestResult(probe.id)
        if status == 2 then
            -- Walls, cars and props count; horizontal ground/roofs do not.
            local hitDistance
            if (hit == true or hit == 1) and math.abs(normal.z) < 0.78 then
                local dx, dy, dz = point.x - probe.startX, point.y - probe.startY, point.z - probe.startZ
                local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
                local along = dx * probe.sampleDirection.x + dy * probe.sampleDirection.y
                if distance <= probe.sampleDistance + cfg.ObstacleProbeRadius
                    and along >= -cfg.ObstacleProbeRadius then
                    hitDistance = distance
                end
            end
            if hitDistance then
                probe.hitUntil = now + cfg.ObstacleGuardHoldMs
                probe.hitDirection = probe.sampleDirection
                probe.hitDistance = hitDistance
            else
                probe.hitUntil = 0
                probe.hitDirection = nil
                probe.hitDistance = 0.0
            end
        end
        if status ~= 1 then probe.id = 0 end
    end
    local dx = forward.x * drive + right.x * slide
    local dy = forward.y * drive + right.y * slide
    local length = math.sqrt(dx*dx + dy*dy)
    if length < 0.16 then
        dx,dy = velocity.x,velocity.y
        length = math.sqrt(dx*dx + dy*dy)
    end
    if length < 0.16 then return false end
    local dir = {x=dx/length,y=dy/length}
    if probe.id == 0 and now >= probe.nextSample then
        local speed = math.sqrt(velocity.x*velocity.x+velocity.y*velocity.y)
        local distance = cfg.ObstacleGuardDistance + math.min(cfg.ObstacleGuardSpeedLookahead, speed*0.22)
        local startZ = position.z + cfg.ObstacleProbeHeight
        probe.startX, probe.startY, probe.startZ = position.x, position.y, startZ
        probe.sampleDistance = distance
        probe.sampleDirection = dir
        probe.id = StartShapeTestCapsule(position.x,position.y,startZ,
            position.x+dir.x*distance,position.y+dir.y*distance,startZ,
            cfg.ObstacleProbeRadius,19,vehicle,7)
        probe.nextSample = now + cfg.ObstacleProbeIntervalMs
    end
    if now >= probe.hitUntil or not probe.hitDirection then return false end
    -- Immediately unblock reversing or sliding away from the obstacle.
    return probe.hitDirection.x*dir.x + probe.hitDirection.y*dir.y > 0.55
end

local function stopChase()
    if not chase then return end
    if GetRenderingCam() == chase.cam then
        RenderScriptCams(false, true, 180, true, true)
    end
    DestroyCam(chase.cam, false)
    chase = nil
end

local function updateChase(vehicle)
    local cfg = Config.FlightCamera
    local firstFrame = chase == nil
    if firstFrame then
        if not IsGameplayCamRendering() then return end
        local cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
        if cam == 0 then return end
        chase = {cam=cam, heading=math.rad(GetEntityHeading(vehicle)), clearance=1.0, probe=0,
            orbitYaw=0.0, orbitPitch=0.0, started=GetGameTimer()}
        SetCamFov(cam, cfg.Fov)
        SetCamNearClip(cam, 0.15)
    end

    local forward, right, up = GetEntityMatrix(vehicle)
    local pos = GetEntityCoords(vehicle)
    local dt = math.min(GetFrameTime(), 0.05)
    -- Keep the horizon and heading steady through tumbles and stunts.
    -- When the car is upright enough, ease toward its rear via the shortest arc.
    if up.z >= cfg.MinFollowUpZ and GetGameTimer() >= impactUntil and (not preset or preset.climbing) then
        local x, y = forward.x - right.y, forward.y + right.x
        local goal = math.atan(-x, y)
        local delta = math.atan(math.sin(goal - chase.heading), math.cos(goal - chase.heading))
        local step = delta * (1.0 - math.exp(-cfg.TurnResponse * dt))
        local limit = math.rad(cfg.MaxTurnSpeed) * dt
        chase.heading = chase.heading + math.max(-limit, math.min(limit, step))
    end
    local rearElevation = math.atan(cfg.Height, cfg.Distance)
    if hover and not menuOpen then
        local mouseInput, nuiFocused = IsInputDisabled(0), IsNuiFocused()
        if (mouseInput == true or mouseInput == 1) and nuiFocused ~= true and nuiFocused ~= 1 then
            -- The scripted camera owns mouse look while hovering.
            DisableControlAction(0, 1, true) -- INPUT_LOOK_LR
            DisableControlAction(0, 2, true) -- INPUT_LOOK_UD
            local yaw = chase.orbitYaw - GetDisabledControlNormal(0, 1) * cfg.MouseSensitivity
            chase.orbitYaw = math.atan(math.sin(yaw), math.cos(yaw))
            local pitch = rearElevation + chase.orbitPitch + GetDisabledControlNormal(0, 2) * cfg.MouseSensitivity
            chase.orbitPitch = math.max(math.rad(-20), math.min(math.rad(65), pitch)) - rearElevation
        end
    elseif not hover then
        local blend = math.exp(-cfg.TurnResponse * dt)
        local step = chase.orbitYaw * (1.0 - blend)
        local limit = math.rad(cfg.MaxTurnSpeed) * dt
        chase.orbitYaw = chase.orbitYaw - math.max(-limit, math.min(limit, step))
        chase.orbitPitch = chase.orbitPitch * blend
    end
    local heading = chase.heading + chase.orbitYaw
    local elevation = rearElevation + chase.orbitPitch
    local radius = math.sqrt(cfg.Distance^2 + cfg.Height^2)
    local distance, height = radius * math.cos(elevation), radius * math.sin(elevation)
    local x, y = -math.sin(heading), math.cos(heading)
    local center = pos + vector3(0.0, 0.0, 0.6)
    local arm = vector3(-x * distance, -y * distance, height)
    local ideal = center + arm
    local clear = chase.targetClearance or 1.0
    if chase.probe ~= 0 then
        local state, hit, hitPos = GetShapeTestResult(chase.probe)
        if state == 2 then
            clear = (hit == true or hit == 1)
                and math.max(0.06, math.min(1.0, (#(hitPos - chase.probeOrigin) - 0.3) / #arm)) or 1.0
            chase.targetClearance = clear
        end
        if state ~= 1 then chase.probe = 0 end
    end
    if chase.probe == 0 then
        chase.probeOrigin = center
        chase.probe = StartShapeTestLosProbe(center.x, center.y, center.z, ideal.x, ideal.y, ideal.z, 19, vehicle, 7)
    end
    -- Move in promptly near a wall, but ease out again after it clears.
    chase.clearance = math.min(clear, chase.clearance + (clear - chase.clearance) * (1.0 - math.exp(-6.0 * dt)))
    local camera = center + arm * chase.clearance
    SetCamCoord(chase.cam, camera.x, camera.y, camera.z)
    local lookAhead = cfg.LookAhead * math.cos(elevation) / math.cos(rearElevation)
    local pitch = -math.deg(math.atan(height * chase.clearance, distance * chase.clearance + lookAhead))
    SetCamRot(chase.cam, pitch, 0.0, math.deg(heading), 2)
    if firstFrame then
        RenderScriptCams(true, true, 180, true, true)
    elseif GetGameTimer() - chase.started > 350 and GetRenderingCam() == chase.cam
        and #(GetFinalRenderedCamCoord() - pos) > #arm + 20.0 then
        chaseEnabled = false
        stopChase()
        notice('Rear camera lost the car. Restored the GTA camera.')
    end
end

CreateThread(function()
    while true do
        local vehicle = chaseEnabled and validActiveVehicle() or 0
        local now = GetGameTimer()
        local inFlight = false
        if vehicle ~= 0 then
            local wheelsDown = IsVehicleOnAllWheels(vehicle)
            local minHeight = chase and 0.40 or (hover and 0.65 or Config.Physics.AirborneHeight)
            if wheelsDown ~= true and wheelsDown ~= 1 and GetEntityHeightAboveGround(vehicle) > minHeight then
                local airborne = IsEntityInAir(vehicle)
                inFlight = airborne == true or airborne == 1
                    or chase ~= nil or hover or preset ~= nil or descending
                    or input.lift or input.boost or input.padBoost == true
            end
        end
        if inFlight then
            chaseAirborneSince, chaseLandedSince = chaseAirborneSince or now, nil
        else
            chaseAirborneSince, chaseLandedSince = nil, chaseLandedSince or now
        end
        local interrupted = IsPauseMenuActive() or IsCinematicCamRendering()
        if vehicle == 0 or interrupted or (chaseLandedSince and now - chaseLandedSince >= 300) then
            stopChase()
            chaseYielded = false
        elseif chase and now - chase.started > 350 and GetRenderingCam() ~= chase.cam then
            -- Yield to a camera another script already owns until this flight ends.
            stopChase()
            chaseYielded = true
        elseif not chaseYielded and (chase or (chaseAirborneSince and now - chaseAirborneSince >= 180)) then
            updateChase(vehicle)
        end
        Wait((inFlight or chase) and 0 or 75)
    end
end)

RegisterCommand('rstcam', function()
    chaseEnabled = not chaseEnabled
    chaseYielded = false
    if not chaseEnabled then stopChase() end
    notice(chaseEnabled and 'Rear flight camera ON' or 'Rear flight camera OFF')
end, false)

local function netId(vehicle)
    if vehicle == 0 or not NetworkGetEntityIsNetworked(vehicle) then return 0 end
    return NetworkGetNetworkIdFromEntity(vehicle)
end

local function transmit(vehicle, mask, force)
    local now = GetGameTimer()
    if vehicle == 0 then return end
    if not force and mask == lastFxMask and now - lastTransmit < 210 then return end
    if not force and now - lastTransmit < 125 then return end
    local id = netId(vehicle)
    if id <= 0 then return end
    TriggerServerEvent('rs_thrusters:control', id, mask, thrustOutput, tankDuration)
    lastTransmit, lastFxMask = now, mask
end

local function clearControls(vehicle)
    if menuOpen then
        menuOpen=false
        SetNuiFocus(false,false)
        SendNUIMessage({type="panel",open=false})
    end
    if vehicle ~= 0 and DoesEntityExist(vehicle) then transmit(vehicle, 0, true) end
    descending = false
    enabled, hover, preset, hoverHeight = false, false, nil, Config.UI.HoverTargetDefault
    hoverRecovering, assistedSpinBraking = false, false
    recoverySince, recoveryStableSince = 0, 0
    recoveryAxis, recoverySign = nil, nil
    stuntHeld, stuntArmed, stuntModifierWasHeld = false, false, false
    controlLostSince = 0
    hoverTrim, hoverDrive, hoverSlide, lastCollective = 0.0, 0.0, 0.0, 0.0
    hoverFloor, groundProbe, impactUntil = nil, nil, 0
    recoveryReportAt, lastContact = 0, false
    hoverWorldTarget, hoverAnchor, lastAngularShock = nil, nil, 0.0
    catchingHover, hoverResumeAt, hoverLaunchClearSince = false, nil, nil
    obstacleProbe = {vehicle=0, id=0, nextSample=0, hitUntil=0, hitDirection=nil, hitDistance=0.0}
    collisionLogAt = 0
    liftRamp, boostRamp, controllerPitch = 0.0, 0.0, 0.0
    lastAppliedMask, lastThrust, lastTorque = 0, 0.0, 0.0
    lastPitchTorque, lastRollTorque, lastWorldLift = 0.0, 0.0, 0.0
    nozzleOutput = {}
    previousFlightRate, previousChassis = nil, nil
    rollProbe = nil
    rollCalibration = {ready=false, [1]=nil, [-1]=nil, actuation=1, feedback=1}
    wasLifting, wasHovering, wasPitching = false, false, false
    lastFxMask = 0
    for k in pairs(input) do input[k] = false end
end

local function requireEnabled()
    local veh = validActiveVehicle()
    return veh ~= 0 and veh or nil
end

local function loadRollCalibration(vehicle)
    local model = GetEntityModel(vehicle)
    if rollCalibration.model == model then return end

    -- Increment the key revision if the probe or controller changes sign conventions.
    local key = ('rollCalibration:v1:%s'):format(model)
    local saved = GetResourceKvpString(key) or Config.VerifiedRollSigns[model] or ''
    local actuation, feedback = saved:match('^([+-]?1):([+-]?1)$')
    rollCalibration = {model=model, key=key, ready=actuation ~= nil,
        actuation=tonumber(actuation) or 1, feedback=tonumber(feedback) or 1}
    if rollCalibration.ready then
        local verdict = {actuator=rollCalibration.actuation, feedback=rollCalibration.feedback}
        rollCalibration[1], rollCalibration[-1] = verdict, verdict
    end
end

local function queueStunt(axis, dir)
    local key = axis .. (dir < 0 and '-' or '+')
    stuntPresses[key] = (stuntPresses[key] or 0) + 1
    local veh = requireEnabled()
    if not veh then return end
    if preset or rollProbe then return end
    -- Native rolls command the chassis forward axis directly. Only the
    -- legacy jet-torque controller needs model-specific nozzle signs.
    if axis == 'roll' and not Config.Physics.StuntRollGovernorEnabled then
        loadRollCalibration(veh)
        if not rollCalibration.ready then
            notice('Jet-torque roll calibration required. Run /rstrollprobe and /rstrollprobeleft at a level hover.')
            return
        end
    end
    local pos = GetEntityCoords(veh)
    local height = math.max(0, pos.z - surfaceBelow(veh, pos))
    local clearance = Config.Physics.StuntClearance
    if height < clearance and not hover and not Config.Physics.StuntAutoTakeoff then
        notice(('Climb to %.0f m or enable hover before performing a stunt.'):format(clearance))
        return
    end
    local now = GetGameTimer()
    local wasHovering = hover
    if not hover and Config.Physics.StuntAutoTakeoff then
        hover = true -- preserve the original hover controller; this only arms it for the stunt
        hoverRecovering = false
        hoverTrim, hoverDrive, hoverSlide = 0.0, 0.0, 0.0
        hoverFloor = nil
        hoverWorldTarget = pos.z
    end
    local name = (axis == 'pitch' and (dir < 0 and 'FRONT FLIP' or 'BACK FLIP'))
        or (dir < 0 and 'LEFT ROLL' or 'RIGHT ROLL')
    local phase = height < clearance and 'climb' or 'ready'
    preset = {axis=axis, dir=dir, name=name, progress=0.0, started=now, lastTick=now,
        queued=now, climbing=phase ~= 'rotate', phase=phase,
        targetZ=pos.z, wasHovering=wasHovering, lastRate=0.0, lastLog=0}
    if phase == 'climb' then notice(('%s: lifting to %.0f m clearance.'):format(name, clearance))
    else notice(('%s: steadying before rotation.'):format(name)) end
    print(('[rs-thrusters][STUNT] queued %s at AGL %.2fm, hover=%s'):format(name,height,tostring(wasHovering)))
end

local function onLift(pressed) input.lift = pressed end

local function onBoost(pressed) input.boost = pressed end
local function onBrake(pressed) input.brake = pressed end

local function toggleThrusters()
    local veh = driverVehicle()
    if veh == 0 then return notice('Enter an eligible car as its driver.') end
    if not installed(veh) then
        local id = netId(veh)
        if id > 0 then TriggerServerEvent('rs_thrusters:syncVehicle', id) end
        return notice('No kit detected yet. Install one or use /rstinstall in authorized test mode.')
    end
    if descending then
        descending = false
        notice('Descent canceled. Thrusters ON.')
    elseif enabled then
        if not IsVehicleOnAllWheels(veh) and GetEntityHeightAboveGround(veh) > Config.Physics.AirborneHeight
            and pressure(veh) > 0 then
            clearControls(veh)
            enabled, descending = true, true
            notice('Thrusters shutting down after a controlled landing.')
        else
            clearControls(veh)
            notice('Thrusters OFF')
        end
    elseif pressure(veh) > 0 then
        enabled = true
        trackedVehicle = veh
        notice('Thrusters ON | SPACE lift | SHIFT / R3 boost | H hover | RB + left stick stunts')
    else
        notice('Thruster pressure empty; refill the tank.')
    end
end
RegisterCommand('rst_thr_toggle', toggleThrusters, false)
RegisterKeyMapping('rst_thr_toggle', 'RS Thrusters - On / Off', 'keyboard', 'G')

RegisterCommand('+rst_thr_lift', function() onLift(true) end, false)
RegisterCommand('-rst_thr_lift', function() onLift(false) end, false)
RegisterKeyMapping('+rst_thr_lift', 'RS Thrusters - Hold to ascend', 'keyboard', 'SPACE')

RegisterCommand('+rst_thr_boost', function() onBoost(true) end, false)
RegisterCommand('-rst_thr_boost', function() onBoost(false) end, false)
RegisterKeyMapping('+rst_thr_boost', 'RS Thrusters - Forward boost', 'keyboard', 'LSHIFT')

RegisterCommand('+rst_thr_brake', function() onBrake(true) end, false)
RegisterCommand('-rst_thr_brake', function() onBrake(false) end, false)
RegisterKeyMapping('+rst_thr_brake', 'RS Thrusters - Air brake', 'keyboard', 'Z')

local function toggleHover()
    local veh = requireEnabled()
    if not veh then return end
    local enteringFromAir = false
    local entryHeight = Config.UI.HoverTargetDefault
    if not hover then
        local velocity = GetEntityVelocity(veh)
        local speed = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
        local maxSpeed = Config.Physics.HoverEngageMaxSpeed
        local wheelsDown = IsVehicleOnAllWheels(veh)
        local inAir = IsEntityInAir(veh)
        local height = GetEntityHeightAboveGround(veh)
        enteringFromAir = wheelsDown ~= true and wheelsDown ~= 1
            and (inAir == true or inAir == 1 or height > Config.Physics.AirborneHeight)
        -- A ramp launch can engage flight-assist in midair even above the
        -- low-speed grounded takeoff limit; use braking thrust to decelerate.
        if speed > maxSpeed and not enteringFromAir then
            return notice(('Slow below %.0f mph to engage hover on the ground.'):format(maxSpeed * 2.23694))
        end
        if enteringFromAir then
            entryHeight = math.max(1.5, math.min(height, Config.Physics.MaxHeightAboveGround - 1.0))
        end
    end
    hover = not hover
    hoverAnchor = nil
    catchingHover = hover and enteringFromAir and mode == 'assisted'
    hoverResumeAt, hoverLaunchClearSince = nil, nil
    hoverRecovering, assistedSpinBraking = false, false
    recoveryAxis, recoverySign = nil, nil
    hoverTrim, hoverDrive, hoverSlide, lastCollective = 0.0, 0.0, 0.0, 0.0
    hoverFloor = nil
    hoverHeight = entryHeight
    if hover then
        local pos = GetEntityCoords(veh)
        -- Ground takeoff starts at the UI target; midair activation holds here.
        hoverWorldTarget = enteringFromAir and pos.z or (pos.z + entryHeight)
    else
        hoverWorldTarget = nil
    end
    notice(hover and ('Hover assist ON (%.1fm target%s)'):format(hoverHeight,enteringFromAir and ', airborne' or '') or 'Hover assist OFF')
end
RegisterCommand('rst_thr_hover', toggleHover, false)
RegisterKeyMapping('rst_thr_hover', 'RS Thrusters - Toggle hover', 'keyboard', 'H')

RegisterCommand('+rst_thr_mod', function() input.mod=true end, false)
RegisterCommand('-rst_thr_mod', function() input.mod=false end, false)

-- Poll GTA's Xbox controls because Enhanced rejected the old PAD_DIGITALBUTTON mappings.
CreateThread(function()
    local padLift = false
    while true do
        local vehicle = driverVehicle()
        local driving = vehicle ~= 0 and installed(vehicle) and not menuOpen and not IsPauseMenuActive()
        if driving and not IsInputDisabled(0) then
            if IsControlJustPressed(0,187) then toggleThrusters() end
            input.padBoost, input.padStunt = false, false
            if enabled then
                DisableControlAction(0, 79, true) -- Xbox R3, usually vehicle look-behind
                input.padBoost = GetDisabledControlNormal(0, 79) > 0.5
                input.mod = IsControlPressed(0,226)
                local rb = IsControlPressed(0,227)
                input.padStunt = rb == true or rb == 1
                if input.padStunt then
                    DisableControlAction(0, 69, true) -- vehicle weapon fire
                    DisableControlAction(0, 102, true) -- vehicle jump
                end
                if IsControlJustPressed(0,193) then
                    if input.padStunt then queueStunt('roll', 1) else toggleHover() end
                end
                if input.mod and IsControlJustPressed(0,172) then ExecuteCommand('rstrecover') end
            end
            local lift = enabled and IsControlPressed(0,191)
            local brake = enabled and IsControlPressed(0,225)
            if lift ~= padLift then onLift(lift) end
            input.padBrake = brake
            padLift = lift
        else
            if padLift then onLift(false) end
            input.padBrake, input.padBoost, input.padStunt = false, false, false
            padLift = false
            input.mod = false
        end
        Wait(driving and 0 or 125)
    end
end)

for _, c in ipairs({
    {name='moveForward', cmd='forward', key='W'}, {name='moveBack', cmd='back', key='S'},
    {name='moveLeft', cmd='slideleft', key='A'}, {name='moveRight', cmd='slideright', key='D'},
    {name='arrowUp', cmd='up', key='UP'}, {name='arrowDown', cmd='down', key='DOWN'},
    {name='arrowLeft', cmd='left', key='LEFT'}, {name='arrowRight', cmd='right', key='RIGHT'},
    {name='stuntKey', cmd='stuntkey', key='LMENU'},
    {name='descend', cmd='descend', key='LCONTROL'},
    {name='pitchUp', cmd='pup', key='NUMPAD8'}, {name='pitchDown', cmd='pdown', key='NUMPAD2'},
    {name='rollLeft', cmd='rleft', key='NUMPAD4'}, {name='rollRight', cmd='rright', key='NUMPAD6'},
    {name='yawLeft', cmd='yleft', key='NUMPAD7'}, {name='yawRight', cmd='yright', key='NUMPAD9'},
}) do
    RegisterCommand('+rst_thr_'..c.cmd, function()
        if not input[c.name] then recordKey(c.key) end
        input[c.name] = true
    end, false)
    RegisterCommand('-rst_thr_'..c.cmd, function() input[c.name]=false end, false)
    RegisterKeyMapping('+rst_thr_'..c.cmd, 'RS Thrusters - '..c.name, 'keyboard', c.key)
end
RegisterCommand('rstflip', function()
    recordKey('J')
    queueStunt('pitch', -1)
end, false)
RegisterCommand('rstbackflip', function() queueStunt('pitch', 1) end, false)
RegisterCommand('rstroll', function()
    recordKey('K')
    queueStunt('roll', 1)
end, false)
RegisterCommand('rstrollleft', function()
    recordKey('L')
    queueStunt('roll', -1)
end, false)
RegisterKeyMapping('rstrollleft', 'RS Thrusters - Assisted left barrel roll', 'keyboard', 'L')
RegisterKeyMapping('rstflip', 'RS Thrusters - Assisted front flip', 'keyboard', 'J')
RegisterKeyMapping('rstroll', 'RS Thrusters - Assisted barrel roll', 'keyboard', 'K')

-- NUI focus is granted ONLY for the optional settings panel, never for the flight HUD.
local function closePanel()
    if not menuOpen then return end
    menuOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({type='panel', open=false})
end

local function setMode(newMode)
    if newMode ~= 'assisted' and newMode ~= 'sport' and newMode ~= 'manual' then return end
    mode = newMode
    notice('Flight mode: '..mode:upper())
end

RegisterCommand('rststyle', function()
    hoverStyle = hoverStyle == 'car' and 'helicopter' or 'car'
    lastCollective, hoverSlide = 0.0, 0.0
    notice(hoverStyle == 'helicopter' and 'Helicopter hover controls ON' or 'Car hover controls ON')
end, false)

RegisterCommand('rstmenu', function()
    local veh = driverVehicle()
    if menuOpen then closePanel() return end
    if veh == 0 or not installed(veh) then return notice('Install a kit, then open settings from the driver seat.') end
    menuOpen = true
    for k in pairs(input) do input[k] = false end
    SetNuiFocus(true, true)
    SendNUIMessage({type='panel', open=true, mode=mode,
        consumptionEnabled=Config.Pressure.ConsumptionEnabled,
        allowTankDuration=Config.Pressure.AllowPlayerDuration,
        tankDuration=tankDuration, tankMin=Config.Pressure.MinDurationSeconds, tankMax=Config.Pressure.MaxDurationSeconds,
        landingAssist=landingAssist, hudVisible=hudVisible, chaseEnabled=chaseEnabled, hoverStyle=hoverStyle,
        controllerPitchEnabled=controllerPitchEnabled,
        thrustOutput=thrustOutput, hoverTarget=Config.UI.HoverTargetDefault, fxStyle=fxStyle, fxColors=fxColors})
end, false)
RegisterKeyMapping('rstmenu', 'RS Thrusters - Flight settings', 'keyboard', 'F7')
RegisterNUICallback('close', function(_, cb) closePanel(); cb({ok=true}) end)
RegisterNUICallback('settings', function(data, cb)
    if type(data) ~= 'table' then cb({ok=false}) return end
    if data.mode ~= nil and data.mode ~= mode then setMode(data.mode) end
    if type(data.fxStyle) == 'string' and fxModes[data.fxStyle] and data.fxStyle ~= fxStyle then
        fxStyle = data.fxStyle
        SetResourceKvp('fxStyle', fxStyle)
    end
    if type(data.fxColors) == 'table' then
        for name, color in pairs(fxColors) do
            local selected = data.fxColors[name]
            if validColor(selected) and selected ~= color then
                fxColors[name] = selected
                SetResourceKvp('fxColor_' .. name, selected)
            end
        end
    end
    if (data.hoverStyle == 'car' or data.hoverStyle == 'helicopter') and data.hoverStyle ~= hoverStyle then
        hoverStyle = data.hoverStyle
        lastCollective, hoverSlide = 0.0, 0.0
        if hover and driverVehicle() ~= 0 then hoverWorldTarget = GetEntityCoords(driverVehicle()).z end
    end
    if type(data.controllerPitchEnabled) == 'boolean' and data.controllerPitchEnabled ~= controllerPitchEnabled then
        controllerPitchEnabled = data.controllerPitchEnabled
        controllerPitch = 0.0
        SetResourceKvp('controllerPitchEnabled', controllerPitchEnabled and 'on' or 'off')
    end
    if type(data.landingAssist) == 'boolean' then landingAssist = data.landingAssist end
    if type(data.hudVisible) == 'boolean' then hudVisible = data.hudVisible end
    if type(data.chaseEnabled) == 'boolean' then
        chaseEnabled = data.chaseEnabled
        if not chaseEnabled then stopChase() end
    end
    if type(data.thrustOutput) == 'number' and data.thrustOutput == data.thrustOutput then
        thrustOutput = math.max(0.25, math.min(1.0, data.thrustOutput))
    end
    if type(data.hoverTarget) == 'number' and data.hoverTarget == data.hoverTarget then
        local target = math.max(1.5, math.min(10.0, data.hoverTarget))
        local changed = target ~= Config.UI.HoverTargetDefault
        Config.UI.HoverTargetDefault = target
        if hover and changed then
            local pos = GetEntityCoords(driverVehicle())
            hoverHeight = Config.UI.HoverTargetDefault
            hoverWorldTarget = pos.z + (hoverHeight - math.max(0.0, pos.z - surfaceBelow(driverVehicle(), pos)))
        end
    end
    if Config.Pressure.AllowPlayerDuration and type(data.tankDuration) == 'number'
        and data.tankDuration == data.tankDuration then
        tankDuration = math.max(Config.Pressure.MinDurationSeconds,
            math.min(Config.Pressure.MaxDurationSeconds, math.floor(data.tankDuration)))
    end
    cb({ok=true, mode=mode, landingAssist=landingAssist, hudVisible=hudVisible, thrustOutput=thrustOutput, hoverTarget=Config.UI.HoverTargetDefault})
end)

local function nearestCar(range)
    local ped = PlayerPedId()
    local here = GetEntityCoords(ped)
    local candidate, distance = 0, range or Config.InstallDistance
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if isEligible(veh) then
            local d = #(GetEntityCoords(veh) - here)
            if d < distance then candidate, distance = veh, d end
        end
    end
    return candidate
end

local installing = false
local function installAction(action, target, oxData)
    if installing then return end
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then return notice('Step out of the vehicle first.') end
    local veh = target and DoesEntityExist(target) and target or nearestCar(Config.InstallDistance)
    if not isEligible(veh) or #(GetEntityCoords(veh)-GetEntityCoords(ped)) > Config.InstallDistance then
        return notice('Move next to a parked automobile.')
    end
    if GetEntitySpeed(veh) > Config.MaxInstallSpeed then return notice('Park the vehicle first.') end
    if action == 'install' and installed(veh) then return notice('Already installed on this vehicle.') end
    if action == 'refill' and not installed(veh) then return notice('This vehicle has no thruster kit.') end
    local id = netId(veh)
    if id == 0 then return notice('Vehicle is not networked; cannot save an installation.') end
    installing = true

    local function proceed()
        if not DoesEntityExist(veh) or #(GetEntityCoords(veh) - GetEntityCoords(PlayerPedId())) > Config.InstallDistance then
            installing = false
            return notice('Installation cancelled: you moved away.')
        end
        TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_VEHICLE_MECHANIC', 0, true)
        Wait(2400)
        ClearPedTasks(ped)
        installing = false
        if DoesEntityExist(veh) and #(GetEntityCoords(veh) - GetEntityCoords(ped)) < Config.InstallDistance then
            TriggerServerEvent('rs_thrusters:install', id, action)
        else notice('Installation cancelled: car moved away.') end
    end

    if oxData then
        -- consume=0 item: built-in ox_inventory validates ownership; server removes item only on success.
        exports.ox_inventory:useItem(oxData, function(success)
            if not success then installing = false return end
            CreateThread(proceed)
        end)
    else
        CreateThread(proceed)
    end
end

exports('installKit', function(data, slot) installAction('install', nil, data) end)
exports('refillKit', function(data, slot) installAction('refill', nil, data) end)

local targetRegistered = false
local function registerTarget()
    if targetRegistered or GetResourceState('ox_target') ~= 'started' then return end
    exports.ox_target:addGlobalVehicle({
        { name='rs_thrusters:install', label='Install cold-gas thruster kit', icon='fa-solid fa-rocket', distance=Config.InstallDistance,
            canInteract=function(entity)
                return isEligible(entity) and not installed(entity) and GetResourceState('ox_inventory') == 'started'
                    and exports.ox_inventory:Search('count', Config.ItemKit) > 0
            end,
            onSelect=function(data) installAction('install', data.entity) end },
        { name='rs_thrusters:refill', label='Refill thruster tank', icon='fa-solid fa-gas-pump', distance=Config.InstallDistance,
            canInteract=function(entity)
                return isEligible(entity) and installed(entity) and pressure(entity) < Config.MaxPressure - 0.1
                    and GetResourceState('ox_inventory') == 'started'
                    and exports.ox_inventory:Search('count', Config.ItemRefill) > 0
            end,
            onSelect=function(data) installAction('refill', data.entity) end },
    })
    targetRegistered = true
end
CreateThread(function() Wait(1250) registerTarget() end)
AddEventHandler('onClientResourceStart', function(name)
    if name == 'ox_target' then Wait(400) targetRegistered=false registerTarget() end
end)

local function testCommand(action)
    local veh = driverVehicle()
    if veh == 0 then return notice('Test install: be seated as the driver.') end
    local id = netId(veh)
    if id > 0 then TriggerServerEvent('rs_thrusters:testAction', id, action) end
end
RegisterCommand('rstinstall', function() testCommand('install') end, false)
RegisterCommand('rstrefill', function() testCommand('refill') end, false)
local function describeNozzles(output)
    local names = {}
    for _, nozzle in ipairs(Config.Nozzles) do
        local thrust = output[nozzle.name] or 0.0
        if thrust > 0 then
            names[#names + 1] = ('%s=%.1f%%'):format(nozzle.name, thrust * 100)
        end
    end
    return #names > 0 and table.concat(names, ' ') or 'none'
end

RegisterCommand('rstdiag', function()
    local veh = driverVehicle()
    if veh == 0 then return notice('Not driving an eligible car.') end
    loadRollCalibration(veh)
    local rot = GetEntityRotation(veh, 2)
    local omega = GetEntityRotationVelocity(veh)
    print(('^3[rs-thrusters DIAG]^7 version=%s netId=%s plate=%s model=%s installed=%s mode=%s hover=%s pressure=%.1f mask=%d networkControl=%s AGL=%.2f'):format(
        Config.Version, netId(veh), GetVehicleNumberPlateText(veh), GetEntityModel(veh), tostring(installed(veh)), tostring(enabled), tostring(hover), pressure(veh), lastFxMask, tostring(NetworkHasControlOfEntity(veh)), GetEntityHeightAboveGround(veh)))
    print(('^3[rs-thrusters DIAG]^7 rot=[%.1f,%.1f,%.1f] omega=[%.3f,%.3f,%.3f]'):format(rot.x,rot.y,rot.z,omega.x,omega.y,omega.z))
    print(('[rs-thrusters DIAG] assist=%s landing=%s nozzleMask=%d thrustOutput=%d%% activeJets=%.1f'):format(mode,tostring(landingAssist),lastAppliedMask,thrustOutput*100,lastThrust))
    if preset then
        print(('[rs-thrusters][STUNT] name=%s phase=%s climb=%s progress=%.1f/%.1f deg localRate=%.2f rad/s elapsed=%d ms'):format(
            preset.name, preset.phase, tostring(preset.climbing), preset.progress,
            Config.Physics.StuntTargetDegrees, preset.lastRate or 0, GetGameTimer()-preset.queued))
    else
        print('[rs-thrusters][STUNT] idle')
    end
    local applying = enabled and not menuOpen and NetworkHasControlOfEntity(veh)
    print(('[rs-thrusters][ROLL SIGN] verified=%s right=%s left=%s actuator=%+d feedback=%+d probe=%s required=%s'):format(
        tostring(rollCalibration.ready),tostring(rollCalibration[1] ~= nil),
        tostring(rollCalibration[-1] ~= nil),rollCalibration.actuation,rollCalibration.feedback,
        rollProbe and rollProbe.phase or 'idle', tostring(not Config.Physics.StuntRollGovernorEnabled)))
    local fw, rt = GetEntityMatrix(veh)
    local nativeRollVector = GetEntityRotationVelocity(veh)
    print(('[rs-thrusters][ROLL FEEDBACK] rightZ=%+.4f matrixRate=%+.3f nativeForwardRate=%+.3f'):format(
        rt.z,previousChassis and previousChassis.rate and previousChassis.rate.y or 0,
        dot(fw,nativeRollVector)))
    print(('[rs-thrusters][FORCES] attitudeTorque=%.3f pitch=%.3f roll=%.3f worldLift=%.2f measuredMask=%d'):format(
        applying and lastTorque or 0.0, applying and lastPitchTorque or 0.0,
        applying and lastRollTorque or 0.0, applying and lastWorldLift or 0.0, applying and lastAppliedMask or 0))
    print('[rs-thrusters][NOZZLES] ' .. (applying and describeNozzles(nozzleOutput) or 'none'))
    print('[rs-thrusters][LAUNCH] clearingSurface=' .. tostring(hoverLaunchClearSince ~= nil))
    if takeoffTrace and takeoffTrace.vehicle == veh then
        print(('[rs-thrusters][TAKEOFF] %s, local omega in rad/s, commands sent after each sampled state'):format(
            takeoffTrace.trigger))
        for _, sample in ipairs(takeoffTrace.samples) do print(sample) end
    end
    print(('[rs-thrusters][OBSTACLE] approaching=%s detectedDistance=%.2f impactHold=%dms recovering=%s recoveryAge=%dms'):format(
        tostring(GetGameTimer() < obstacleProbe.hitUntil), obstacleProbe.hitDistance or 0,
        math.max(0,impactUntil-GetGameTimer()),tostring(hoverRecovering),
        recoverySince > 0 and GetGameTimer()-recoverySince or 0))
    print(('[rs-thrusters][PILOT] hoverStyle=%s lift=%s boost=%s R3=%s brake=%s collective=%s hoverWorldTarget=%s'):format(
        hoverStyle, tostring(input.lift), tostring(input.boost or input.padBoost or false),
        tostring(input.padBoost == true), tostring(input.brake),
        tostring(lastCollective), hoverWorldTarget and ('%.1f'):format(hoverWorldTarget) or 'none'))
    print(('[rs-thrusters][PILOT] move=%.2f yaw=%.2f strafe=%.2f pitch=%.2f xboxStickPitch=%s blocked=%s recovering=%s'):format(
        lastPilot.throttle, lastPilot.turn, lastPilot.slide, lastPilot.pitch,
        controllerPitchEnabled and 'ON' or 'OFF', tostring(lastPilot.blocked), tostring(lastPilot.recovering)))
    if hoverAnchor then
        local pos = GetEntityCoords(veh)
        print(('[rs-thrusters][HOLD] anchor=[%.2f,%.2f] drift=[%.2f,%.2f]'):format(
            hoverAnchor.x, hoverAnchor.y, pos.x - hoverAnchor.x, pos.y - hoverAnchor.y))
    end
    print(('[rs-thrusters][RECOVERY] stableSince=%dms active=%s lastContact=%s braking=%s catchingHover=%s nativeAttitude=%s'):format(
        recoveryStableSince > 0 and GetGameTimer() - recoveryStableSince or 0,
        tostring(hoverRecovering), tostring(lastContact), tostring(assistedSpinBraking), tostring(catchingHover),
        tostring(lastPilot.nativeAttitude == true)))
    local keys = {}
    for _, key in ipairs({'W','A','S','D','UP','DOWN','LEFT','RIGHT','LMENU','J','K','L','NUMPAD8','NUMPAD2','NUMPAD4','NUMPAD6'}) do
        keys[#keys+1] = ('%s=%d'):format(key, keyPresses[key] or 0)
    end
    print('[rs-thrusters][KEY PRESSES] ' .. table.concat(keys, ' '))
    print(('[rs-thrusters][XBOX STICK] forward=%d back=%d left=%d right=%d'):format(
        stickSeen.forward or 0, stickSeen.back or 0, stickSeen.left or 0, stickSeen.right or 0))
    print(('[rs-thrusters][STUNT INPUTS] front=%d back=%d left=%d right=%d Alt=%s RB=%s armed=%s'):format(
        stuntPresses['pitch-'] or 0, stuntPresses['pitch+'] or 0,
        stuntPresses['roll-'] or 0, stuntPresses['roll+'] or 0,
        tostring(input.stuntKey == true), tostring(input.padStunt == true), tostring(stuntArmed)))
    notice('Diagnostics printed to F8 console.')
end, false)

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function modelDimensions(vehicle)
    local model = GetEntityModel(vehicle)
    local cached = dimensions[model]
    if cached then return cached end
    local minB, maxB = GetModelDimensions(model)
    cached = {minB=minB, maxB=maxB}
    dimensions[model] = cached
    return cached
end
local function localOffset(bounds, nozzle)
    local mi, ma = bounds.minB, bounds.maxB
    return mi.x + (nozzle.x+1)*0.5*(ma.x-mi.x),
           mi.y + (nozzle.y+1)*0.5*(ma.y-mi.y),
           mi.z + (nozzle.z+1)*0.5*(ma.z-mi.z)
end

-- All maneuvering forces are created by visible, physical nozzles.
-- Each nozzle has one exhaust direction (Config.Nozzles[].dir is the force ON the car).
-- Applying its force at its own local offset creates authentic r x F torque.
local function applyNozzles(vehicle, levels, pressureFactor, driveHeading, balanceBelly, verticalLift, stuntTorqueGain, jumpLiftDemand, nativeAttitude)
    local bounds = modelDimensions(vehicle)
    local mask, thrust = 0, 0
    local output = {}
    local bellyTotal, pitchTorque, rollTorque = 0.0, 0.0, 0.0
    local bellyMean = 0.0
    if balanceBelly then
        for _, nozzle in ipairs(Config.Nozzles) do
            if nozzle.kind == 'belly' then bellyMean = bellyMean + (levels[nozzle.name] or 0.0) * 0.25 end
        end
    end
    for _, nozzle in ipairs(Config.Nozzles) do
        local level = clamp(levels[nozzle.name] or 0.0, 0.0, 1.0)
        local kind = Config.PropulsionKind(nozzle.kind)
        local isDrive = driveHeading and (kind == 'front' or kind == 'rear')
        local side = driveHeading and driveHeading.slide and driveHeading.slide[nozzle.name] or 0.0
        local centeredBelly = balanceBelly and kind == 'belly'
        if centeredBelly or level > ((isDrive or side > 0) and 0.001 or 0.055) then
            local scale = (Config.Physics.NozzleAcceleration[kind] or 0) * pressureFactor * thrustOutput
            local accel = scale * level
            if centeredBelly or accel > 0.001 then
                local x,y,z = localOffset(bounds, nozzle)
                local dir = nozzle.dir
                if centeredBelly then
                    -- The collective goes through the center of mass. Only
                    -- the difference between jets produces a turning moment.
                    local difference = (level - bellyMean) * scale
                    bellyTotal = bellyTotal + accel
                    pitchTorque = pitchTorque + y * difference
                    rollTorque = rollTorque - x * difference
                elseif isDrive then
                    -- Apply paired horizontal thrust through the center so driving cannot pitch the car.
                    ApplyForceToEntityCenterOfMass(vehicle, 0, driveHeading.x * dir[2] * accel,
                        driveHeading.y * dir[2] * accel, 0.0, 0, false, true, false)
                else
                    if side > 0 then
                        local push = dir[1] * side * scale
                        ApplyForceToEntityCenterOfMass(vehicle, 0, driveHeading.y * push,
                            -driveHeading.x * push, 0.0, 0, false, true, false)
                    end
                    local maneuver = level - side
                    if maneuver > 0.055 and not (nativeAttitude and kind == 'side') then
                        local force = maneuver * scale
                        ApplyForceToEntity(vehicle, 0, dir[1]*force, dir[2]*force, dir[3]*force,
                            x,y,z, 0, true, true, true, false, true)
                    end
                end
                if level > 0.055 then mask = mask | nozzle.bit end
                thrust = thrust + level
                if level > 0 then output[nozzle.name] = level * pressureFactor * thrustOutput end
            end
        end
    end
    if jumpLiftDemand ~= nil then
        local capacity = 4 * Config.Physics.NozzleAcceleration.belly * pressureFactor * thrustOutput
        bellyTotal = math.min(bellyTotal, jumpLiftDemand * capacity)
    end
    if bellyTotal > 0.001 then
        -- bellyTotal is calculated as acceleration (m/s^2). Scale by vehicle
        -- mass in BOTH hover and stunt phases; otherwise a heavy car gets
        -- almost no vertical acceleration and the stunt never leaves climb.
        ApplyForceToEntityCenterOfMass(vehicle, 0, 0.0, 0.0, bellyTotal, 0, false, true, false)
    end
    -- Amplify *only stunt* attitude torque. The same fired belly jets generate
    -- the signed torque. No SetEntityRotation or scripted teleport is used.
    local gain = stuntTorqueGain or 1.0
    lastPitchTorque, lastRollTorque, lastWorldLift = 0.0, 0.0, bellyTotal
    if gain > 0.0 and math.abs(pitchTorque) + math.abs(rollTorque) > 0.025 then
        lastPitchTorque, lastRollTorque = pitchTorque * gain, rollTorque * gain
        -- Use explicit world axes for the torque so an inverted or banked
        -- car gets the same body-relative correction as an upright car.
        local forward, right = GetEntityMatrix(vehicle)
        ApplyForceToEntity(vehicle, 4,
            right.x * lastPitchTorque + forward.x * lastRollTorque,
            right.y * lastPitchTorque + forward.y * lastRollTorque,
            right.z * lastPitchTorque + forward.z * lastRollTorque,
            0.0, 0.0, 0.0, 0, false, true, true, false, true)
    end
    lastTorque = math.sqrt(lastPitchTorque^2 + lastRollTorque^2)
    nozzleOutput = output
    lastAppliedMask, lastThrust = mask, thrust
    return mask
end

local function worldAngularVelocityInLocal(vehicle)
    local omega = GetEntityRotationVelocity(vehicle) -- world radians/second
    local center = GetEntityCoords(vehicle)
    -- Converting center+world angular vector to a local offset rotates axes only.
    return GetOffsetFromEntityGivenWorldCoords(vehicle,
        center.x+omega.x, center.y+omega.y, center.z+omega.z)
end

local function dot(a, b)
    return a.x*b.x + a.y*b.y + a.z*b.z
end

-- Read actual frame-to-frame rotation in the chassis axes used by the jets.
local function chassisAngularVelocity(vehicle, forward, right, up, now)
    local previous = previousChassis
    previousChassis = {vehicle=vehicle, forward=forward, right=right, up=up, at=now}
    if not previous or previous.vehicle ~= vehicle then return end
    local dt = (now - previous.at) * 0.001
    if dt <= 0 or dt > 0.10 then return end

    -- Skew terms of the relative rotation matrix give axis * sin(angle).
    local x = (dot(previous.up, forward) - dot(previous.forward, up)) * 0.5
    local y = (dot(previous.right, up) - dot(previous.up, right)) * 0.5
    local z = (dot(previous.forward, right) - dot(previous.right, forward)) * 0.5
    local cosine = (dot(previous.right, right) + dot(previous.forward, forward) + dot(previous.up, up) - 1) * 0.5
    if cosine <= 0.0 then return end -- a discontinuous transform is not a measured spin
    local sine = math.sqrt(x*x + y*y + z*z)
    local scale = sine > 0.0001 and math.atan(sine, cosine) / (sine * dt) or 1.0 / dt
    local rate = vector3(x * scale, y * scale, z * scale)
    if previous.rate then
        -- Physics can update less often than rendering. Smooth the small
        -- differences between consecutive samples before commanding the jets.
        local blend = 1.0 - math.exp(-dt / 0.025)
        rate = previous.rate + (rate - previous.rate) * blend
    end
    previousChassis.rate = rate
    return rate
end

local function scalarSign(value)
    return value < 0 and -1 or 1
end

-- A near-upright chassis supplies an INDEPENDENT observable roll direction:
-- positive roll about local +forward lowers the right wheel (right.z decreases).
-- Compare this with native angular velocity projected onto the forward vector
-- and with the matrix-derived feedback used by the stunt controller.
local function startRollProbe(dir)
    local veh = requireEnabled()
    if not veh then return end
    if preset or rollProbe then return notice('Finish the current stunt or probe first.') end
    if not hover then return notice('Enable hover (H) before the roll sign probe.') end
    local forward, right, up = GetEntityMatrix(veh)
    local now = GetGameTimer()
    local h = GetEntityHeightAboveGround(veh)
    local w = GetEntityRotationVelocity(veh)
    local nativeRoll = dot(forward, w)
    if h < Config.Physics.RollProbeMinHeight or up.z < Config.Physics.RollProbeMinUpZ
        or math.abs(nativeRoll) > Config.Physics.RollProbeStartMaxRate then
        return notice(('Probe needs steady, level hover above %.0f m (now %.1f m).'):format(
            Config.Physics.RollProbeMinHeight,h))
    end
    loadRollCalibration(veh)
    SetResourceKvp(rollCalibration.key, 'unverified')
    rollCalibration[dir] = nil
    rollCalibration.ready = false
    rollProbe = {vehicle=veh, dir=dir, phase='pulse', start=now, last=now,
        originRightZ=right.z, previousRightZ=right.z,
        startNative=nativeRoll, startMeasured=previousChassis and previousChassis.rate and previousChassis.rate.y or 0,
        command=dir * Config.Physics.RollProbeMix, observed=nil, peak=0.0,
        sampleNative=0, sampleMatrix=0, sampleGeometry=0, stopSince=nil}
    print(('[rs-thrusters][ROLL PROBE] %s BEGIN AGL=%.2fm rightZ=%.4f native=%.3f pulse=%.3f duration=%dms'):format(
        dir > 0 and 'RIGHT' or 'LEFT', h, right.z, nativeRoll,
        rollProbe.command, Config.Physics.RollProbePulseMs))
    notice(dir > 0 and 'Right roll sign probe: small pulse, then automatic braking.'
        or 'Left roll sign probe: small pulse, then automatic braking.')
end

RegisterCommand('rstrollprobe', function() startRollProbe(1) end, false)
RegisterCommand('rstrollprobeleft', function() startRollProbe(-1) end, false)

local function updateRollProbe(vehicle, forward, right, up, measured, now)
    local p = rollProbe
    if not p then return end
    if p.vehicle ~= vehicle or not hover or not NetworkHasControlOfEntity(vehicle) then
        print('[rs-thrusters][ROLL PROBE] canceled: vehicle/hover/network changed')
        rollProbe = nil
        return
    end
    local w = GetEntityRotationVelocity(vehicle)
    local native = dot(w, forward)
    local matrix = measured and measured.y or 0.0
    local dt = (now - p.last) * 0.001
    local geometry = dt > 0 and dt <= 0.10 and -((right.z - p.previousRightZ) / dt) or 0.0
    p.last, p.previousRightZ = now, right.z
    local angle = -(right.z - p.originRightZ) -- radians for a small, near-upright roll
    local nativeDelta, matrixDelta = native - p.startNative, matrix - p.startMeasured
    p.peak = math.max(p.peak,math.abs(native))
    if p.phase == 'pulse' then
        if now - p.start >= Config.Physics.RollProbePulseMs
            or math.abs(native) >= Config.Physics.RollProbeMaxRate
            or math.abs(angle) >= math.rad(Config.Physics.RollProbeMaxDegrees)
            or up.z < Config.Physics.RollProbeMinUpZ then
            p.command = 0.0
            local minAngle = math.rad(Config.Physics.RollProbeMinDegrees)
            local coherent = math.abs(angle) >= minAngle
                and math.abs(nativeDelta) >= Config.Physics.RollProbeMinImpulse
                and scalarSign(angle) == scalarSign(nativeDelta)
                and up.z >= Config.Physics.RollProbeMinUpZ
            local feedbackOK = math.abs(matrixDelta) >= Config.Physics.RollProbeMinImpulse
            if coherent and feedbackOK then
                p.observed = {dir=p.dir, actuator=p.dir * scalarSign(angle),
                    feedback=scalarSign(matrixDelta) * scalarSign(nativeDelta)}
            end
            p.phase, p.brakeStart = 'brake', now
            p.sampleNative, p.sampleMatrix, p.sampleGeometry = nativeDelta, matrixDelta, angle
            print(('[rs-thrusters][ROLL PROBE] %s PULSE deltaRightZ=%+.5f geomAngle=%+.2fdeg geomRate=%+.3f nativeDelta=%+.3f matrixDelta=%+.3f verified=%s actuation=%s feedback=%s'):format(
                p.dir > 0 and 'RIGHT' or 'LEFT', right.z-p.originRightZ, math.deg(angle), geometry,
                nativeDelta, matrixDelta, tostring(p.observed ~= nil),
                p.observed and tostring(p.observed.actuator) or '?',
                p.observed and tostring(p.observed.feedback) or '?'))
        end
    end
    if p.phase == 'brake' then
        -- Never guess the braking polarity. A confirmed pulse supplies it.
        local actuator = p.observed and p.observed.actuator
        if actuator then
            local requestedRate = clamp(-angle * Config.Physics.RollProbeLevelGain,
                -Config.Physics.RollProbeBrakeMaxRate, Config.Physics.RollProbeBrakeMaxRate)
            p.command = clamp((requestedRate - native) * Config.Physics.RollProbeBrakeGain * actuator,
                -Config.Physics.RollProbeBrakeMix, Config.Physics.RollProbeBrakeMix)
        else
            p.command = 0.0
        end
        if math.abs(native) < Config.Physics.RollProbeStopRate and math.abs(angle) < math.rad(2) then
            p.stopSince = p.stopSince or now
        else p.stopSince = nil end
        local settled = p.stopSince and now - p.stopSince >= Config.Physics.RollProbeStopMs
        local timedOut = now - p.brakeStart >= Config.Physics.RollProbeBrakeMs
        local unsafe = math.abs(native) > Config.Physics.RollProbeEmergencyRate or up.z < 0.90
        if settled or timedOut or unsafe then
            -- A correct sign is not sufficient: prove braking can reduce the
            -- spin BEFORE allowing an uninterrupted 360-degree maneuver.
            local verdict = settled and p.observed or nil
            rollCalibration[p.dir] = verdict
            rollProbe = nil
            if unsafe then hoverRecovering = true end
            print(('[rs-thrusters][ROLL PROBE] %s FINISH geom=%+.2fdeg native=%+.3f matrix=%+.3f peak=%.3f actuator=%s feedback=%s'):format(
                p.dir > 0 and 'RIGHT' or 'LEFT',math.deg(angle),native,matrix,p.peak,
                verdict and tostring(verdict.actuator) or 'UNVERIFIED',
                verdict and tostring(verdict.feedback) or (unsafe and 'UNSAFE' or timedOut and 'NO BRAKE' or 'UNVERIFIED')))
            if rollCalibration[1] and rollCalibration[-1]
                and rollCalibration[1].actuator == rollCalibration[-1].actuator
                and rollCalibration[1].feedback == rollCalibration[-1].feedback then
                rollCalibration.actuation = rollCalibration[1].actuator
                rollCalibration.feedback = rollCalibration[1].feedback
                rollCalibration.ready = true
                SetResourceKvp(rollCalibration.key, ('%d:%d'):format(
                    rollCalibration.actuation, rollCalibration.feedback))
                print(('[rs-thrusters][ROLL SIGN] CONFIRMED both directions: actuator=%+d matrixFeedback=%+d.'):format(
                    rollCalibration.actuation,rollCalibration.feedback))
                notice('Jet-torque roll signs verified in both directions.')
            else
                print('[rs-thrusters][ROLL SIGN] NOT VERIFIED: both probe directions must agree for jet-torque rolls.')
                notice('Roll probe recorded. Check F8 for the jet-torque calibration result.')
            end
        end
    end
end

local function softZero(value, deadband)
    return value > deadband and value - deadband or (value < -deadband and value + deadband or 0.0)
end

local function levelMix(error, rate, limit, cfg)
    return clamp(softZero(error, cfg.HoverLevelDeadband) * cfg.HoverLevelKp
        - softZero(rate, 0.025) * cfg.HoverLevelKd, -limit, limit)
end

local function takeControl(id)
    DisableControlAction(0, id, true)
    return GetDisabledControlNormal(0, id)
end

local function hoverInputs(cfg, guidedFlight)
    local controller = not IsInputDisabled(0)
    if not controller or not guidedFlight or hoverStyle ~= 'helicopter' then controllerPitch = 0.0 end
    local x = (input.arrowRight and 1 or 0) - (input.arrowLeft and 1 or 0)
    local y = (input.arrowUp and 1 or 0) - (input.arrowDown and 1 or 0)
    local modifier = input.stuntKey or (controller and input.padStunt)
    local holdForModifier = modifier or (controller and input.mod)
    local steer = 0.0
    if guidedFlight or holdForModifier or preset then
        local stickX, stickY = takeControl(59), takeControl(60)
        steer = stickX
        if controller then
            if x == 0 then x = stickX end
            if y == 0 then y = -stickY end
        end
        local deadzone = cfg.ControllerDeadzone
        local directions = {
            forward=controller and stickY < -deadzone, back=controller and stickY > deadzone,
            left=controller and stickX < -deadzone, right=controller and stickX > deadzone,
        }
        for name, pressed in pairs(directions) do
            if pressed and not stickDirections[name] then stickSeen[name] = (stickSeen[name] or 0) + 1 end
            stickDirections[name] = pressed
        end
    end
    if guidedFlight or holdForModifier then
        DisableControlAction(0, 27, true) -- Up arrow otherwise opens the phone.
    end
    local deflection = math.max(math.abs(x), math.abs(y))
    -- A modifier pressed while the stick is already forward must NEVER fire
    -- a flip. Require a neutral-to-flick transition after pressing RB.
    if modifier and not stuntModifierWasHeld then
        stuntArmed, stuntHeld = false, false
    end
    if modifier then
        if deflection < cfg.StuntNeutralThreshold then
            stuntArmed, stuntHeld = true, false
        elseif stuntArmed and deflection > cfg.StuntFlickThreshold and not stuntHeld and not preset then
            stuntHeld, stuntArmed = true, false
            if math.abs(y) >= math.abs(x) then
                queueStunt('pitch', y > 0 and -1 or 1)
            else
                queueStunt('roll', x > 0 and 1 or -1)
            end
        end
    else
        stuntArmed, stuntHeld = false, false
    end
    stuntModifierWasHeld = modifier
    local throttle = 0.0
    if guidedFlight then throttle = takeControl(71) - takeControl(72) end
    local keyboardDrive = (input.moveForward and 1 or 0) - (input.moveBack and 1 or 0)
    local keyboardSlide = (input.moveRight and 1 or 0) - (input.moveLeft and 1 or 0)
    if keyboardDrive ~= 0 then throttle = keyboardDrive end
    if keyboardSlide ~= 0 then steer = keyboardSlide end
    if holdForModifier then
        controllerPitch = 0.0
        return 0.0, 0.0, 0.0, 0.0
    end
    local function rescale(value)
        return softZero(value, cfg.ControllerDeadzone) / (1.0 - cfg.ControllerDeadzone)
    end
    local drive = math.abs(throttle) > math.abs(y) and throttle or rescale(y)
    if guidedFlight and hoverStyle == 'helicopter' then
        -- Forward/backward stick drives translation ONLY. It is not pitch.
        -- Pitch is deliberately controlled by vertical right stick (Xbox)
        -- or numpad 8/2 (keyboard), bounded by HelicopterPitchDegrees.
        local nose = (input.pitchUp and 1 or 0) - (input.pitchDown and 1 or 0)
        if controller then
            local stickPitch = -rescale(takeControl(2))
            local targetPitch = stickPitch * math.abs(stickPitch) * cfg.ControllerPitchScale
            if not controllerPitchEnabled or input.padBoost or preset or hoverRecovering then
                controllerPitch = 0.0
            else
                local step = cfg.ControllerPitchSlew * math.min(GetFrameTime(), 0.05)
                controllerPitch = controllerPitch + clamp(targetPitch - controllerPitch, -step, step)
            end
            return drive, rescale(takeControl(1)), keyboardSlide ~= 0 and keyboardSlide or rescale(x),
                nose ~= 0 and nose or controllerPitch
        end
        return drive, rescale(x), rescale(steer), nose
    end
    return drive, rescale(x), keyboardSlide, 0.0
end

-- nil = ordinary hover, 0 = clearing the surface, timestamp = clearance held.
local function hoverLaunchState(clearSince, eligible, contact, clear, now, settleMs)
    if not eligible then return nil end
    if clearSince == nil then return contact and 0 or nil end
    if not clear then return 0 end
    if clearSince == 0 then return now end
    if now - clearSince >= settleMs then return nil end
    return clearSince
end

local function hoverCollectiveDemand(target, h, vz, grounded, factor, dt, cfg)
    local capacity = 4 * cfg.NozzleAcceleration.belly * factor * thrustOutput
    local speedError = target - vz
    -- Adapt feed-forward to the lift the current vehicle actually needs in GTA.
    -- Stop accumulating if there is no power left to climb.
    local command = 9.81 + hoverTrim + speedError * cfg.HoverDamping
    local ceiling = math.min(cfg.HoverMaxAcceleration, capacity)
    if (command < ceiling or speedError < 0) and (command > 0 or speedError > 0) then
        hoverTrim = clamp(hoverTrim + speedError * cfg.HoverTrimGain * dt, 0.0, cfg.HoverTrimMax)
    end
    local accel = clamp(9.81 + hoverTrim + speedError * cfg.HoverDamping, 0.0, ceiling)
    local lift = accel / math.max(capacity, 0.001)
    if grounded and target > 0.7 and vz < 0.9 then
        local fade = clamp((0.95 - h) / 0.6, 0.0, 1.0)
        lift = math.max(lift, lift + math.max(0.0, cfg.HoverTakeoffThrottle - lift) * fade)
    end
    return lift
end

local function horizontalHeading(forward, right)
    local x, y = forward.x, forward.y
    local length = math.sqrt(x * x + y * y)
    if length < 0.3 then
        -- Near vertical, use the right axis to recover a horizontal heading.
        x, y = -right.y, right.x
        length = math.sqrt(x * x + y * y)
    end
    if length < 0.001 then return end
    return {x=x / length, y=y / length}
end

local function hoverForwardLimit(cfg)
    return mode == 'assisted' and cfg.AssistedHoverMoveSpeed or cfg.HoverMoveSpeed
end

local function positionHoldInputs(anchor, pos, heading, cfg)
    local dx, dy = anchor.x - pos.x, anchor.y - pos.y
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance <= cfg.HoverPositionDeadband then return 0.0, 0.0 end
    local speed = math.min((distance - cfg.HoverPositionDeadband) * cfg.HoverPositionGain, cfg.HoverPositionMaxSpeed)
    local forwardSpeed = (dx * heading.x + dy * heading.y) * speed / distance
    local sideSpeed = (dx * heading.y - dy * heading.x) * speed / distance
    return forwardSpeed / (forwardSpeed < 0 and cfg.HoverReverseSpeed or hoverForwardLimit(cfg)),
        sideSpeed / cfg.HoverSlideSpeed
end

local function driveInHover(levels, forward, right, velocity, throttle, dt, factor, cfg)
    local heading = horizontalHeading(forward, right)
    if not heading then hoverDrive = 0.0; return end
    local speed = velocity.x * heading.x + velocity.y * heading.y
    local targetSpeed = throttle * (throttle < 0 and cfg.HoverReverseSpeed or hoverForwardLimit(cfg))
    local request = clamp(softZero(targetSpeed - speed, 0.14) * cfg.HoverDriveGain, -cfg.HoverDriveAccel, cfg.HoverDriveAccel)
    local ramp = cfg.HoverDriveAccel * dt / cfg.HoverDriveRamp
    hoverDrive = hoverDrive + clamp(request - hoverDrive, -ramp, ramp)
    -- Don't keep braking through zero speed while the throttle is released.
    local output = hoverDrive
    if math.abs(throttle) < 0.001 and output * speed >= 0 then output = 0.0 end
    local forwardThrust = output > 0
    local perJet = cfg.NozzleAcceleration[forwardThrust and 'rear' or 'front']
    local level = clamp(math.abs(output) / math.max(2 * perJet * factor * thrustOutput, 0.001), 0.0, 0.55)
    if forwardThrust then
        levels.rear_lower_l, levels.rear_lower_r = level, level
    else
        levels.front_l, levels.front_r = level, level
    end
    return heading
end

local function slideInHover(levels, heading, velocity, inputSlide, dt, factor, cfg)
    local speed = velocity.x * heading.y - velocity.y * heading.x
    local request = clamp(softZero(inputSlide * cfg.HoverSlideSpeed - speed, 0.14) * cfg.HoverDriveGain,
            -cfg.HoverSlideAccel, cfg.HoverSlideAccel)
    local ramp = cfg.HoverSlideAccel * dt / cfg.HoverDriveRamp
    hoverSlide = hoverSlide + clamp(request - hoverSlide, -ramp, ramp)
    if math.abs(inputSlide) < 0.001 and hoverSlide * speed >= 0 then return end
    local front, rear = 'side_front_l', 'side_rear_l'
    if hoverSlide < 0.0 then front, rear = 'side_front_r', 'side_rear_r' end
    local a, b = levels[front] or 0.0, levels[rear] or 0.0
    local level = clamp(math.abs(hoverSlide) / math.max(2 * cfg.NozzleAcceleration.side * factor * thrustOutput, 0.001),
        0.0, math.min(0.5, 1.0 - math.max(a, b)))
    levels[front], levels[rear] = a + level, b + level
    heading.slide = {[front]=level, [rear]=level}
end

-- Allocate thrust to the four belly jets, mixing vertical acceleration and
-- pitch/roll commands. Negative levels are NOT emitted: no imaginary reverse jet.
local function mixBelly(levels, base, pitch, roll, preserveLift)
    if preserveLift then
        -- Scale both axes equally so clipping cannot change average lift.
        local demand = math.abs(pitch) + math.abs(roll)
        local headroom = math.min(base, 1.0 - base)
        if demand > headroom then
            local scale = headroom / demand
            pitch, roll = pitch * scale, roll * scale
        end
    end
    local mix = {
        belly_fl = { 1,-1}, belly_fr={ 1, 1},
        belly_rl = {-1,-1}, belly_rr={-1, 1}
    }
    for name, m in pairs(mix) do
        -- +pitch => front belly jets fire, +roll => left belly jets fire.
        levels[name] = clamp(base + pitch*m[1] - roll*m[2], 0.0, 1.0)
    end
end

-- Leave room for opposed jets at both ends of the lift range. The force
-- application caps collective at lift, so this cannot create extra climb.
local function mixAssistedHover(levels, lift, pitch, roll)
    local headroom = math.min(0.5, math.abs(pitch) + math.abs(roll))
    mixBelly(levels, clamp(lift, headroom, 1.0 - headroom), pitch, roll, true)
end

-- Recover one axis at a time. A zero base makes the mixer fire only
-- the pair that produces the requested pitch or roll torque.
local function recoverHover(levels, forward, right, up, omega, cfg, lift)
    local pitchError, rollError = -forward.z, right.z
    -- Brake runaway angular velocity before attempting level recovery.
    -- Deliberate flips never enter this branch until their preset ends.
    if math.abs(omega.x) > cfg.HoverSpinExitRate or math.abs(omega.y) > cfg.HoverSpinExitRate then
        local limit = cfg.HoverSpinBrakeMix
        local pitch = levelMix(pitchError, omega.x, limit, cfg) * cfg.PitchSign
        local roll = levelMix(rollError, omega.y, limit, cfg) * cfg.RollSign
        mixBelly(levels, lift, pitch, roll, false)
        return
    end
    if not recoveryAxis or (recoveryAxis == 'roll' and math.abs(rollError) < 0.12 and math.abs(omega.y) < 0.12 and math.abs(pitchError) > 0.3)
        or (recoveryAxis == 'pitch' and math.abs(pitchError) < 0.12 and math.abs(omega.x) < 0.12 and math.abs(rollError) > 0.3) then
        recoveryAxis = math.abs(rollError) >= math.abs(pitchError) and 'roll' or 'pitch'
        if up.z < -0.95 and math.abs(pitchError) + math.abs(rollError) < 0.15 then
            recoveryAxis = 'roll'
            recoverySign = omega.y < -0.1 and -1.0 or 1.0
        else
            recoverySign = nil
        end
    end
    local limit = cfg.HoverRecoveryThrottle
    if recoveryAxis == 'roll' then
        if recoverySign and up.z < -0.95 and math.abs(rollError) < 0.15 then rollError = 0.4 * recoverySign end
        mixBelly(levels, lift, 0, levelMix(rollError, omega.y, limit, cfg) * cfg.RollSign, false)
    else
        mixBelly(levels, lift, levelMix(pitchError, omega.x, limit, cfg) * cfg.PitchSign, 0, false)
    end
end

local function assistedRecoveryMix(forward, right, up, omega, steer, braking, limit, cfg)
    local pitchRate, rollRate = 0.0, 0.0
    if not braking then
        local pitchError, rollError = -forward.z, right.z
        if steer ~= 0 then
            rollRate = steer * cfg.HoverRecoveryLevelRate * cfg.RollSign
        else
            -- The horizontal components of world up give a single leveling
            -- axis in body space, even when both pitch and roll are off.
            local crossLength = math.sqrt(pitchError * pitchError + rollError * rollError)
            if up.z >= -0.90 then recoverySign = nil end
            if up.z < -0.99 and crossLength < 0.14 then
                recoverySign = recoverySign or ((math.abs(rollError) > 0.025 and rollError or omega.y) < 0 and -1 or 1)
            end
            local rateLimit = cfg.HoverRecoveryLevelRate
            if recoverySign then
                rollRate = rateLimit * recoverySign
            elseif crossLength > 0.025 then
                local angle = math.atan(crossLength, up.z)
                local rate = math.min(rateLimit, (angle - 0.025) * 1.25)
                pitchRate = pitchError / crossLength * rate
                rollRate = rollError / crossLength * rate
            end
        end
    end
    local gain = cfg.HoverRecoveryRateGain
    local pitch = clamp(softZero(pitchRate - omega.x, 0.025) * gain, -limit, limit)
    local roll = clamp(softZero(rollRate - omega.y, 0.025) * gain, -limit, limit)
    return pitch * cfg.PitchSign, roll * cfg.RollSign, pitchRate, rollRate
end

local function assistedHoverAttitude(forward, right, up, omega, pitchInput, speed, cfg)
    local pitchError = -forward.z
    local rollError = right.z
    local authority = clamp((up.z - 0.82) / 0.16, 0.0, 1.0)
        * math.min(1.0, cfg.JumpFullSteerSpeed / math.max(speed, 0.01))
    pitchError = pitchError + math.sin(math.rad(cfg.HelicopterPitchDegrees) * pitchInput * authority)
    local pitchRate = clamp(softZero(pitchError, cfg.HoverLevelDeadband) * 1.6, -0.4, 0.4)
    local rollRate = clamp(softZero(rollError, cfg.HoverLevelDeadband) * 1.6, -0.4, 0.4)
    local limit = cfg.HoverFlightMix
    local pitch = clamp(softZero(pitchRate - omega.x, 0.035) * cfg.HoverRecoveryRateGain, -limit, limit)
    local roll = clamp(softZero(rollRate - omega.y, 0.035) * cfg.HoverRecoveryRateGain, -limit, limit)
    return pitch * cfg.PitchSign, roll * cfg.RollSign, authority, pitchRate, rollRate
end

local function finishStunt(vehicle, successful, reason)
    if not preset then return end
    local name, progress = preset.name, preset.progress
    preset = nil
    local position = GetEntityCoords(vehicle)
    local floor = surfaceBelow(vehicle, position)
    -- Hover in place after the maneuver; don't immediately dive toward the
    -- old 3.2 m target just because the stunt climbed above it.
    hover = true
    hoverFloor = floor
    hoverHeight = clamp(position.z - floor, 1.5, Config.Physics.MaxHeightAboveGround - 1.0)
    hoverWorldTarget = position.z
    hoverTrim, hoverDrive, hoverSlide = 0.0, 0.0, 0.0
    recoverySince, recoveryStableSince = 0, 0
    -- A failed or aborted stunt returns immediately to hover recovery, not
    -- a 14-second unresponsive stunt state.
    hoverRecovering = not successful
    recoveryAxis, recoverySign = nil, nil
    if successful then
        notice(('%s completed: %.0f degrees, hover holding at %.1f m.'):format(name, progress, hoverHeight))
    else
        notice(('%s incomplete (%.0f degrees): %s. Recovering in hover.'):format(name,progress,reason or 'stopped'))
    end
    print(('[rs-thrusters][STUNT] %s %s progress=%.1f AGL=%.2f reason=%s'):format(
        name, successful and 'DONE' or 'FAILED', progress, position.z-floor, reason or 'ok'))
end

local function emergencyRecover()
    local veh = validActiveVehicle()
    if veh == 0 then return end
    if preset then finishStunt(veh, false, 'manual recovery requested') end
    hover = true
    hoverRecovering = true
    recoverySince, recoveryStableSince = 0, 0
    recoveryAxis, recoverySign = nil, nil
    hoverTrim, hoverDrive, hoverSlide = 0.0, 0.0, 0.0
    local pos = GetEntityCoords(veh)
    local floor = surfaceBelow(veh, pos)
    hoverFloor = floor
    hoverHeight = clamp(pos.z - floor, 1.5, Config.Physics.MaxHeightAboveGround - 1.0)
    hoverWorldTarget = pos.z
    notice('Stunt canceled. Stabilizing: normal hover controls will return.')
end
RegisterCommand('rstrecover', emergencyRecover, false)
RegisterKeyMapping('rstrecover', 'RS Thrusters - Cancel stunt / stabilize', 'keyboard', 'BACK')

-- During a full roll GTA can introduce pitch/yaw coupling, especially at inversion.
-- Keep the two non-roll axes damped, without applying any forced orientation.
-- Input and the usual hover controller are left untouched outside a roll.
local function rollCrossAxisDamping(omega, forward, startForwardZ, cfg)
    local limit = cfg.StuntRollCrossMix
    local pitch = clamp((startForwardZ - forward.z) * cfg.StuntRollPitchHoldGain
            - omega.x * cfg.StuntRollCrossPitchGain, -limit, limit)
    local yaw = clamp(-omega.z * cfg.StuntRollCrossYawGain,
            -cfg.StuntRollYawMix, cfg.StuntRollYawMix)
    return pitch * cfg.PitchSign, yaw
end

-- Native angular-speed setter: GTA V build >=2372 provides
-- SET_ENTITY_ANGULAR_VELOCITY (0x8339643499D1222E). Some FiveM builds do not
-- generate a Lua global for Cfx's older SET_ENTITY_ROTATION_VELOCITY, so do NOT
-- use global availability as a feature test. Prefer GTA's native, and invoke
-- by hash when the Lua wrapper is absent. Neither method teleports/rotates the car.
local ANGULAR_NATIVE = 0x8339643499D1222E
local angularSetterBackend, angularSetterFailed = nil, false
local function writeEntityAngularVelocity(vehicle, x, y, z)
    if angularSetterFailed then return false end
    if type(SetEntityRotationVelocity) == 'function' then
        local ok = pcall(SetEntityRotationVelocity, vehicle, x, y, z)
        if ok then angularSetterBackend = 'CFX SetEntityRotationVelocity'; return true end
    end
    if type(SetEntityAngularVelocity) == 'function' then
        local ok = pcall(SetEntityAngularVelocity, vehicle, x, y, z)
        if ok then angularSetterBackend = 'GTA SetEntityAngularVelocity'; return true end
    end
    if Citizen and type(Citizen.InvokeNative) == 'function' then
        local ok = pcall(Citizen.InvokeNative, ANGULAR_NATIVE, vehicle, x, y, z)
        if ok then angularSetterBackend = 'GTA Citizen.InvokeNative'; return true end
    end
    angularSetterFailed = true
    print('[rs-thrusters][ANGULAR NATIVE] Unavailable; assisted hover falls back to jet torque and native stunts stop.')
    return false
end

local function writeChassisRates(vehicle, forward, right, up, pitchRate, rollRate, yawRate)
    return writeEntityAngularVelocity(vehicle,
        right.x * pitchRate + forward.x * rollRate + up.x * yawRate,
        right.y * pitchRate + forward.y * rollRate + up.y * yawRate,
        right.z * pitchRate + forward.z * rollRate + up.z * yawRate)
end

local function nativePitchStunt(vehicle, p, measuredOmega, cfg)
    local now = GetGameTimer()
    local forward, right, up = GetEntityMatrix(vehicle)
    local omega = measuredOmega or worldAngularVelocityInLocal(vehicle)
    local elapsed = (now - p.lastTick) * 0.001
    local direction = p.dir * cfg.PitchSign
    local pitchRate = omega.x
    if p.pitchPreviousForward and elapsed > 0.0 and elapsed <= 0.12 then
        -- The nose's angle in the previous pitch plane stays continuous through inversion.
        local step = math.atan(dot(forward, p.pitchPreviousUp), dot(forward, p.pitchPreviousForward))
        if math.abs(step) <= math.rad(cfg.StuntRollGeometryMaxStepDegrees) then
            pitchRate = step / elapsed
            p.progress = math.max(-15.0, p.progress + math.deg(step) * direction)
        end
    end
    p.lastTick, p.pitchPreviousForward, p.pitchPreviousUp = now, forward, up
    p.lastRate = pitchRate * direction
    if math.max(math.abs(pitchRate), math.abs(omega.y), math.abs(omega.z)) >= cfg.StuntSpinAbortRate
        or p.progress >= cfg.StuntHardStopDegrees then
        finishStunt(vehicle, false, 'uncontrolled flip or off-axis rotation')
        return 0.0, 0.0, 0.0
    end

    local remaining = math.rad(cfg.StuntTargetDegrees - p.progress)
    if p.phase == 'rotate' and math.abs(remaining) <= math.rad(1.0) and math.abs(pitchRate) <= 0.12 then
        p.phase, p.settleUntil = 'settle', now + cfg.StuntSettleMs
    end
    local targetPitch, targetRoll = 0.0, 0.0
    if p.phase == 'settle' then
        local stable = up.z > 0.992 and math.abs(pitchRate) + math.abs(omega.y) < 0.20
            and math.abs(omega.z) < 0.20
        p.stableSince = stable and (p.stableSince or now) or nil
        if p.stableSince and now - p.stableSince >= cfg.StuntStableMs then
            finishStunt(vehicle, true)
            return 0.0, 0.0, 0.0
        elseif now >= p.settleUntil then
            finishStunt(vehicle, false, 'failed to settle level')
            return 0.0, 0.0, 0.0
        end
        local cap = cfg.StuntPitchSettleRate
        targetPitch = clamp(-forward.z * 1.6, -cap, cap)
        targetRoll = clamp(right.z * 1.6, -cap, cap)
    else
        local rotationElapsed = now - p.started
        if rotationElapsed >= cfg.StuntMaxMs or (rotationElapsed >= cfg.StuntStallMs
            and p.progress < cfg.StuntStallDegrees) then
            finishStunt(vehicle, false, 'flip did not track the requested rotation')
            return 0.0, 0.0, 0.0
        end
        local angle = math.abs(remaining)
        local startRate = rotationElapsed * 0.001 * cfg.StuntPitchAcceleration
        local stoppingRate = math.min(math.sqrt(2.0 * cfg.StuntPitchDeceleration * angle), angle * 3.0)
        targetPitch = math.min(cfg.StuntPitchMaxRate, startRate, stoppingRate) * direction
        if remaining < 0.0 then targetPitch = -targetPitch end
    end
    if not writeChassisRates(vehicle, forward, right, up, targetPitch, targetRoll, 0.0) then
        finishStunt(vehicle, false, 'angular-velocity native unavailable')
        return 0.0, 0.0, 0.0
    end
    if now - p.lastLog >= 750 then
        p.lastLog = now
        print(('[rs-thrusters][PITCH NATIVE] %s %s angle=%.1f pitch=%+.2f target=%+.2f roll=%+.2f yaw=%+.2f'):format(
            p.name, p.phase, p.progress, pitchRate, targetPitch, omega.y, omega.z))
    end
    local visualMix = clamp((targetPitch * direction - p.lastRate) * cfg.StuntRateGain,
        -cfg.StuntPitchBrakeMix, cfg.StuntPitchDriveMix) * direction
    return visualMix, 0.0, 0.0
end

RegisterCommand('rstnativecheck', function()
    local vehicle = validActiveVehicle()
    if vehicle == 0 then return notice('Enter a car with the thrusters activated first.') end
    if not NetworkHasControlOfEntity(vehicle) then return notice('No network control of this car.') end
    local velocity = GetEntityRotationVelocity(vehicle)
    if not velocity then return notice('Could not read vehicle angular velocity.') end
    local ok = writeEntityAngularVelocity(vehicle, velocity.x, velocity.y, velocity.z)
    print(('[rs-thrusters][ROLL NATIVE] success=%s backend=%s (no-op check)'):format(
        tostring(ok), angularSetterBackend or 'unavailable'))
    notice(ok and 'Angular velocity native available; check F8.' or 'Angular velocity native unavailable; native stunts disabled.')
end, false)

-- The vehicle physics engine can introduce large off-axis rates during an
-- assisted 360 roll. Cap those rates using the real GTA setter ONLY in a roll.
-- The native drives rotation during the roll. The jets still hold altitude.
local lastRollGovernorLog = 0
local function stuntRollAngularGovernor(vehicle, forward, right, up, now, cfg)
    local p = preset
    if not p or p.axis ~= 'roll' or p.climbing or not cfg.StuntRollGovernorEnabled then return end
    local world = GetEntityRotationVelocity(vehicle)
    if not world then return end
    -- Test the native once with the current angular velocity (no extra motion).
    -- A failed binding MUST NOT silently permit an ungoverned full roll.
    if not p.nativeChecked then
        p.nativeChecked = true
        p.nativeFault = not writeEntityAngularVelocity(vehicle, world.x, world.y, world.z)
        if not p.nativeFault then
            print(('[rs-thrusters][ROLL GUARD] active via %s; stunt-only angular velocity control'):format(angularSetterBackend))
        else
            return
        end
    end
    if p.nativeFault then return end
    local pitchRate, rollRate, yawRate = dot(world,right), dot(world,forward), dot(world,up)
    local safePitch, safeYaw, safeRoll = pitchRate, yawRate, rollRate
    local phase = p.phase
    if phase == 'rotate' and p.nativeRollTarget ~= nil then
        safePitch, safeRoll, safeYaw = 0.0, p.nativeRollTarget, 0.0
    elseif phase == 'settle' then
        -- Keep native attitude control through the final leveling phase.
        -- Releasing it to jet torque here can start another revolution.
        local cap = cfg.StuntRollGovernorSettleRoll
        safePitch = clamp(-forward.z * 1.6, -cap, cap)
        safeRoll = clamp(right.z * 1.6, -cap, cap)
        safeYaw = 0.0
    elseif phase == 'abort_brake' then
        -- A failed-stunt safety handoff must NOT inherit 3-6 rad/s of spin.
        -- Dampen all axes until the ordinary hover recovery can safely take over.
        local decay = math.exp(-math.min(GetFrameTime(), 0.05) * cfg.StuntRollAbortAngularDamping)
        safePitch = clamp(pitchRate * decay, -cfg.StuntRollAbortAngularCap, cfg.StuntRollAbortAngularCap)
        safeYaw = clamp(yawRate * decay, -cfg.StuntRollAbortAngularCap, cfg.StuntRollAbortAngularCap)
        safeRoll = clamp(rollRate * decay, -cfg.StuntRollAbortAngularCap, cfg.StuntRollAbortAngularCap)
    else
        -- A generous speed cap protects the inversion transition if the GTA
        -- car's handling or built-in air-control fights physical counter-thrust.
        safePitch = clamp(pitchRate, -cfg.StuntRollGovernorMaxPitch, cfg.StuntRollGovernorMaxPitch)
        safeYaw = clamp(yawRate, -cfg.StuntRollGovernorMaxYaw, cfg.StuntRollGovernorMaxYaw)
        local cap = cfg.StuntRollGovernorMaxRoll
        local remaining = math.max(0, math.rad(cfg.StuntTargetDegrees - p.progress))
        -- Limit angular momentum as the car approaches the end of a turn.
        local brakingCap = math.sqrt(2 * cfg.StuntRollGovernorDeceleration * remaining)
        if p.progress >= cfg.StuntRollGovernorSlowStart then
            cap = math.min(cap, math.max(cfg.StuntRollGovernorFinalFloor, brakingCap))
        end
        if p.progress >= cfg.StuntTargetDegrees then cap = cfg.StuntRollGovernorSettleRoll end
        safeRoll = clamp(rollRate, -cap, cap)
    end
    local changed = math.abs(safePitch-pitchRate)>0.001 or math.abs(safeYaw-yawRate)>0.001 or math.abs(safeRoll-rollRate)>0.001
    if not changed then return end
    if not writeChassisRates(vehicle, forward, right, up, safePitch, safeRoll, safeYaw) then
        p.nativeFault = true
        return
    end
    p.governorHits = (p.governorHits or 0) + 1
    if now-lastRollGovernorLog >= cfg.StuntRollGovernorLogMs then
        lastRollGovernorLog = now
        if phase == 'rotate' and p.nativeRollTarget ~= nil then
            local actual = GetEntityRotationVelocity(vehicle)
            print(('[rs-thrusters][ROLL NATIVE] angle=%.1f command=%+.3f before=%+.3f readback=%+.3f chassis=%+.3f'):format(
                p.progress, safeRoll, rollRate, dot(actual, forward), (p.geomRate or 0.0) * p.dir * cfg.RollSign))
        end
        print(('[rs-thrusters][ROLL GUARD] phase=%s progress=%.1f localBefore=[%+.2f,%+.2f,%+.2f] limited=[%+.2f,%+.2f,%+.2f] hits=%d'):format(
            phase, p.progress, pitchRate, rollRate, yawRate, safePitch, safeRoll, safeYaw, p.governorHits))
    end
end

local function rollSafeAbort(p, why, now)
    if not p or p.phase == 'abort_brake' then return end
    p.phase = 'abort_brake'
    p.abortSince = now
    p.abortStableSince = nil
    p.abortReason = why
    p.governorHits = p.governorHits or 0
    print(('[rs-thrusters][ROLL SAFETY] braking instead of handing high angular speed to hover recovery: %s, progress=%.1f'):format(
        why, p.progress))
end

local function desiredRotation(vehicle, airborne, levelAssist, turn, pitchInput, measuredOmega)
    if not airborne then
        -- Do not discard the pending command while the climb is lifting off.
        if preset and not preset.climbing then
            finishStunt(vehicle,false,'lost airborne state')
        end
        return 0.0, 0.0, 0.0
    end
    local cfg = Config.Physics
    local pitch, roll, yaw = 0.0, 0.0, 0.0
    if input.pitchUp then pitch = pitch + cfg.ManualMix end
    if input.pitchDown then pitch = pitch - cfg.ManualMix end
    if input.rollLeft then roll = roll - cfg.ManualMix end
    if input.rollRight then roll = roll + cfg.ManualMix end
    if input.yawLeft then yaw = yaw - cfg.YawMix end
    if input.yawRight then yaw = yaw + cfg.YawMix end
    if input.mod then
        local rz = takeControl(1)
        if math.abs(rz) > cfg.ControllerDeadzone then yaw = yaw - rz*cfg.YawMix end
    end
    if rollProbe then return 0.0, rollProbe.command, 0.0 end
    if preset then
        if preset.axis == 'pitch' and cfg.StuntPitchNativeEnabled then
            return nativePitchStunt(vehicle, preset, measuredOmega, cfg)
        end
        local now = GetGameTimer()
        local isPitch = preset.axis == 'pitch'
        local nativeRoll = not isPitch and cfg.StuntRollGovernorEnabled
        if nativeRoll and preset.nativeFault then
            finishStunt(vehicle, false, 'angular-velocity native unavailable')
            return 0.0, 0.0, 0.0
        end
        local elapsed = clamp((now-preset.lastTick)/1000,0,0.12)
        preset.lastTick = now
        local omega = measuredOmega or worldAngularVelocityInLocal(vehicle)
        local sign = preset.dir * (isPitch and cfg.PitchSign or cfg.RollSign)
        local rollActuation = nativeRoll and 1.0 or rollCalibration.actuation
        local forward, right, up = GetEntityMatrix(vehicle)
        local rate = isPitch and omega.x or 0.0
        local signedRate
        if isPitch then
            signedRate = rate * sign
            preset.progress = math.max(-15.0, preset.progress + math.deg(signedRate) * elapsed)
        else
            -- The chassis geometry is independent of Euler angles, which fold
            -- over at 180 degrees. A roll's relative rotation is the angle
            -- made by THIS frame's right axis in LAST frame's right/up plane.
            -- This remains continuous from 0 through 360 even when inverted.
            local nativeW = GetEntityRotationVelocity(vehicle)
            local nativeRate = dot(nativeW, forward)
            -- Use the body-space measurement. The legacy jet controller can
            -- apply a verified feedback sign, while native rolls use the axes directly.
            local feedbackSign = nativeRoll and 1.0 or rollCalibration.feedback
            rate = measuredOmega and (measuredOmega.y * feedbackSign) or nativeRate
            signedRate = rate * sign
            local priorRight, priorUp = preset.rollPreviousRight, preset.rollPreviousUp
            -- Never reuse a stale chassis sample if the current physics tick skipped.
            preset.geomRate = nil
            if priorRight and priorUp and elapsed > 0.0001 and elapsed <= 0.12 then
                local step = math.atan(-dot(right, priorUp), dot(right, priorRight))
                if math.abs(step) <= math.rad(cfg.StuntRollGeometryMaxStepDegrees) then
                    local signedStep = step * sign
                    preset.progress = math.max(-15.0, preset.progress + math.deg(signedStep))
                    preset.geomRate = signedStep / elapsed
                else
                    print(('[rs-thrusters][ROLL TRACK] rejected chassis discontinuity: step=%+.1f degrees'):format(math.deg(step)))
                end
            end
            preset.rollPreviousRight, preset.rollPreviousUp = right, up
            -- v0.1.59 reported ~3-6 rad/s of ACTUAL chassis motion while the
            -- stunt speed governor saw only ~1-4 rad/s. The controller therefore
            -- waited far too long to counter-thrust. Use the same directly
            -- observed chassis step that drives progress for the rate servo.
            -- Only accept continuous small-angle frames; do not extrapolate
            -- missing samples or infer a speed from Euler-angle wrapping.
            local projectedRate = signedRate
            if preset.geomRate and math.abs(preset.geomRate) <= cfg.StuntRollGeometrySanityRate then
                signedRate = preset.geomRate
                rate = signedRate * sign
                preset.rollSpeedSource = 'chassis'
            else
                preset.rollSpeedSource = 'matrix'
            end
            preset.nativeRate = nativeRate * sign
            preset.matrixRate = measuredOmega and (measuredOmega.y * feedbackSign * sign)
                or projectedRate
            preset.crossRate = math.max(math.abs(omega.x), math.abs(omega.z))
            if preset.crossRate > cfg.StuntRollCrossAbortRate then
                preset.crossUnsafeSince = preset.crossUnsafeSince or now
            else
                preset.crossUnsafeSince = nil
            end
            -- Track native/matrix divergence without changing the roll axis sign.
            if math.abs(preset.matrixRate - preset.nativeRate) > cfg.StuntRollRateDisagreement
                and now - (preset.lastRateWarning or 0) > 600 then
                preset.lastRateWarning = now
                print(('[rs-thrusters][ROLL TRACK] disagreement angle=%.1f upZ=%+.2f native=%+.2f matrix=%+.2f chassis=%+.2f'):format(
                    preset.progress, up.z, preset.nativeRate, preset.matrixRate, preset.geomRate or 0.0))
            end
            local checkpoint = math.floor(preset.progress / 45)
            if checkpoint > (preset.rollCheckpoint or 0) then
                preset.rollCheckpoint = checkpoint
                print(('[rs-thrusters][ROLL TRACK] angle=%.1f upZ=%+.2f native=%+.2f matrix=%+.2f chassis=%+.2f torque=%+.2f'):format(
                    preset.progress, up.z, preset.nativeRate, preset.matrixRate, preset.geomRate or 0.0, lastRollTorque))
                print(('[rs-thrusters][ROLL AXES] pitchRate=%+.2f rollRate=%+.2f yawRate=%+.2f forwardZ=%+.2f crossRate=%.2f'):format(
                    omega.x, omega.y, omega.z, forward.z, preset.crossRate))
            end
        end
        preset.lastRate = signedRate
        local remaining = math.rad(cfg.StuntTargetDegrees - preset.progress)
        if not isPitch and preset.phase == 'abort_brake' then
            -- Do not release a car spinning at 4+ rad/s into the general hover
            -- recovery controller. Brake all three angular axes with small
            -- bounded forces and hand over only after measured speeds settle.
            local brakeMix = cfg.StuntRollAbortBrakeMix
            local pitchBrake = clamp(-omega.x * cfg.StuntRollAbortGain, -brakeMix, brakeMix)
            local rollBrake = clamp(-omega.y * cfg.StuntRollAbortGain, -brakeMix, brakeMix)
                * cfg.RollSign * rollActuation
            local yawBrake = clamp(-omega.z * cfg.StuntRollAbortGain,
                -cfg.StuntRollYawMix, cfg.StuntRollYawMix)
            local angular = math.max(math.abs(omega.x), math.abs(omega.y), math.abs(omega.z))
            if angular < cfg.StuntRollAbortSafeRate then
                preset.abortStableSince = preset.abortStableSince or now
            else
                preset.abortStableSince = nil
            end
            if (preset.abortStableSince and now-preset.abortStableSince >= cfg.StuntRollAbortSettleMs)
                or now-preset.abortSince >= cfg.StuntRollAbortMaxMs then
                finishStunt(vehicle, false, preset.abortReason ..
                    (angular >= cfg.StuntRollAbortSafeRate and ' (braking timeout)' or ' (rotation slowed)'))
                return 0.0, 0.0, 0.0
            end
            return pitchBrake * cfg.PitchSign, rollBrake, yawBrake
        end
        local rotationElapsed = now - preset.started
        local invertedArc = not isPitch and (up.z < cfg.StuntRollInvertedUpZ
            or (preset.progress > 115.0 and preset.progress < 285.0))
        if not isPitch and signedRate < -cfg.StuntWrongWayRate and rotationElapsed > cfg.StuntWrongWayDelayMs then
            preset.wrongWaySince = preset.wrongWaySince or now
            if invertedArc then
                -- Near upside-down the old controller aborted immediately and
                -- its general hover recovery accelerated the spin past 6 rad/s.
                -- Keep the dedicated roll axis in control through this sector.
                if not preset.invertedAssist and now - preset.wrongWaySince >= cfg.StuntRollInvertedAssistDelayMs then
                    preset.invertedAssist = true
                    print(('[rs-thrusters][ROLL TRACK] inverted correction active angle=%.1f upZ=%+.2f native=%+.2f'):format(
                        preset.progress, up.z, signedRate))
                end
            elseif now - preset.wrongWaySince >= cfg.StuntWrongWayDelayMs then
                rollSafeAbort(preset, 'sustained wrong-way roll away from inversion', now)
                return 0.0, 0.0, 0.0
            end
        else
            preset.wrongWaySince = nil
            if not invertedArc then preset.invertedAssist = false end
        end
        if not isPitch and (math.abs(rate) >= cfg.StuntRollEmergencyRate
                or preset.progress >= cfg.StuntHardStopDegrees
                or (preset.crossUnsafeSince
                    and now-preset.crossUnsafeSince >= cfg.StuntRollCrossAbortMs)) then
            print(('[rs-thrusters][STUNT] %s watchdog: angle=%.1f signedRate=%.2f crossRate=%.2f measured=%s pitchTorque=%.2f rollTorque=%.2f'):format(
                preset.name, preset.progress, signedRate, preset.crossRate or 0.0,
                tostring(measuredOmega ~= nil), lastPitchTorque, lastRollTorque))
            rollSafeAbort(preset, 'uncontrolled roll or off-axis rotation', now)
            return 0.0, 0.0, 0.0 -- brake mode takes over next frame
        elseif isPitch and (math.abs(rate) >= cfg.StuntSpinAbortRate or preset.progress >= cfg.StuntHardStopDegrees) then
            finishStunt(vehicle, false, 'excess angular velocity / rotation overshoot')
            return 0.0, 0.0, 0.0
        end
        local settleRate = isPitch and cfg.StuntPitchSettleRate or cfg.StuntRollSettleRate
        local angleTolerance = nativeRoll and 1.0 or 4.0
        local rateTolerance = nativeRoll and 0.12 or settleRate
        local atTarget = math.abs(remaining) <= math.rad(angleTolerance) and math.abs(signedRate) <= rateTolerance
        if not preset.settleUntil and atTarget then
            preset.settleUntil = now + cfg.StuntSettleMs
            preset.phase = 'settle'
            print(('[rs-thrusters][STUNT] %s rotation target reached at %.0f degrees; braking and levelling'):format(
                preset.name, preset.progress))
        end
        if not preset.settleUntil and rotationElapsed >= (isPitch and cfg.StuntMaxMs or cfg.StuntRollMaxMs) then
            if not isPitch then rollSafeAbort(preset, 'rotation timeout', now)
            else finishStunt(vehicle, false, 'rotation timeout') end
        elseif not preset.settleUntil and rotationElapsed >= cfg.StuntStallMs
            and preset.progress < cfg.StuntStallDegrees then
            if not isPitch then rollSafeAbort(preset, 'no rotation detected', now)
            else finishStunt(vehicle, false, 'no rotation detected; verify torque and network ownership') end
        else
            if nativeRoll and preset.phase == 'rotate' then
                local cap = math.min(cfg.StuntRollMaxRate, cfg.StuntRollGovernorMaxRoll)
                local startRate = rotationElapsed * 0.001 * cfg.StuntRollGovernorDeceleration
                local stoppingRate = math.min(math.sqrt(2.0 * cfg.StuntRollGovernorDeceleration * math.abs(remaining)),
                    math.abs(remaining) * 3.0)
                local target = math.min(cap, startRate, stoppingRate)
                if remaining < 0.0 then target = -target end
                preset.nativeRollTarget = target * sign
                local visualMix = clamp((target - signedRate) * cfg.StuntRateGain,
                    -cfg.StuntRollBrakeMix, cfg.StuntRollDriveMix)
                return 0.0, visualMix * sign, 0.0
            end
            -- A trapezoidal rate profile, closing speed reduced by stopping
            -- distance. Brake with reverse jets BEFORE crossing 360 degrees.
            local targetRate
            local counterThrust = false
            if isPitch then
                local stoppingRate = math.sqrt(2 * cfg.StuntPitchDeceleration * math.abs(remaining))
                local startRate = rotationElapsed * 0.001 * cfg.StuntPitchAcceleration
                targetRate = remaining >= 0 and math.min(cfg.StuntPitchMaxRate, startRate, stoppingRate)
                    or -math.min(settleRate, stoppingRate)
            else
                -- Include response time in the stopping angle so the opposing
                -- jets start firing before the car reaches one full turn.
                local forwardRate = math.max(0.0, signedRate)
                local stoppingAngle = forwardRate^2 / (2 * cfg.StuntRollDeceleration)
                    + forwardRate * cfg.StuntRollBrakeLead
                counterThrust = signedRate > settleRate and remaining <= stoppingAngle
                local approachRate = math.sqrt(2 * cfg.StuntRollDeceleration * math.abs(remaining))
                targetRate = remaining >= 0 and math.min(cfg.StuntRollMaxRate, approachRate)
                    or -math.min(settleRate, approachRate)
                -- Reduce commanded speed BEFORE the inversion, not after the
                -- car is already above 3 rad/s at 180 degrees. A chassis-rate
                -- governor starts easing down from ~100 degrees; it keeps the
                -- rest of the roll slow enough that braking can catch it.
                if remaining > 0 and preset.progress >= cfg.StuntRollSlowStartDegrees then
                    local progress = clamp((preset.progress - cfg.StuntRollSlowStartDegrees)
                        / math.max(cfg.StuntRollSlowFullDegrees - cfg.StuntRollSlowStartDegrees, 1.0), 0.0, 1.0)
                    local cap = cfg.StuntRollMaxRate
                        + (cfg.StuntRollSlowRate - cfg.StuntRollMaxRate) * progress
                    targetRate = math.min(targetRate, cap)
                end
                if invertedArc and remaining > 0 then
                    -- Slow rather than speed up if the chassis starts to pitch
                    -- or yaw while inverted. A lower rate is more controllable
                    -- through the 150-230 degree transition.
                    local crossScale = clamp(1.0 - (preset.crossRate or 0.0)
                        / cfg.StuntRollCrossSoftRate, 0.45, 1.0)
                    targetRate = math.min(targetRate, cfg.StuntRollInvertedMaxRate) * crossScale
                    if signedRate < cfg.StuntRollInvertedMinRate and (preset.crossRate or 0.0) < 0.18
                        and math.abs(remaining) > math.rad(25.0) then
                        targetRate = math.max(targetRate, cfg.StuntRollInvertedMinRate)
                    end
                end
            end
            local yawBrake = clamp(-softZero(omega.z, 0.04) * 0.65, -cfg.HoverYawMix, cfg.HoverYawMix)
            if preset.settleUntil then
                local levelPitch, levelRoll = -forward.z, right.z
                -- The inverted singularity needs a deliberate escape direction.
                if up.z < -0.86 and math.abs(levelPitch)+math.abs(levelRoll) < 0.20 then
                    if isPitch then levelPitch = 0.5 * sign
                    else levelRoll = 0.5 * sign end
                end
                if up.z > 0.992 and math.abs(omega.x) + math.abs(omega.y) < 0.20 and math.abs(omega.z) < 0.20 then
                    preset.stableSince = preset.stableSince or now
                else
                    preset.stableSince = nil
                end
                if preset.stableSince and now - preset.stableSince >= cfg.StuntStableMs then
                    finishStunt(vehicle, true)
                elseif now >= preset.settleUntil then
                    finishStunt(vehicle, false, 'failed to settle level')
                else
                    local limit = isPitch and cfg.StuntPitchSettleMix or cfg.StuntSettleMix
                    return levelMix(levelPitch,omega.x,limit,cfg)*cfg.PitchSign,
                        levelMix(levelRoll,isPitch and omega.y or rate,limit,cfg)*cfg.RollSign
                            * (isPitch and 1 or rollActuation), yawBrake
                end
            else
                local driveMix = isPitch and cfg.StuntPitchDriveMix or cfg.StuntRollDriveMix
                local brakeMix = isPitch and cfg.StuntPitchBrakeMix or cfg.StuntRollBrakeMix
                if not isPitch and invertedArc and remaining > 0 and signedRate < cfg.StuntRollInvertedMinRate then
                    driveMix = math.max(driveMix, cfg.StuntRollInvertedDriveMix)
                end
                local correction = clamp((targetRate - signedRate) * cfg.StuntRateGain, -brakeMix, driveMix)
                -- This soft speed limiter is independent of the 360-degree
                -- stopping-distance calculation. At inversion the force/vehicle
                -- dynamics can overpower the normal brake; intervene before
                -- excessive kinetic energy builds up.
                local overSpeed = not isPitch and signedRate > cfg.StuntRollSoftBrakeRate
                if overSpeed then
                    correction = -math.min(brakeMix,
                        (signedRate - cfg.StuntRollSlowRate) * cfg.StuntRateGain)
                    counterThrust = true
                elseif counterThrust then
                    correction = -math.min(brakeMix, signedRate * cfg.StuntRateGain)
                end
                if not isPitch and counterThrust and signedRate > 0 then
                    if not preset.brakeStartedAt then
                        preset.brakeStartedAt, preset.brakeStartRate = now, signedRate
                    elseif now - preset.brakeStartedAt >= cfg.StuntRollBrakeResponseMs
                        and signedRate >= preset.brakeStartRate + cfg.StuntRollBrakeRiseLimit then
                        print(('[rs-thrusters][ROLL SAFETY] reverse thrust did not arrest spin: angle=%.1f first=%.2f now=%.2f source=%s'):format(
                            preset.progress, preset.brakeStartRate, signedRate,
                            preset.rollSpeedSource or 'unknown'))
                        rollSafeAbort(preset, 'opposing jets ineffective during rotation', now)
                        return 0.0, 0.0, 0.0
                    end
                else
                    preset.brakeStartedAt, preset.brakeStartRate = nil, nil
                end
                correction = correction * sign * (isPitch and 1 or rollActuation)
                if not isPitch and counterThrust ~= preset.counterThrust then
                    if counterThrust then
                        print(('[rs-thrusters][STUNT] %s counter-thrust at %.1f degrees, actualRate=%.2f target=%.2f source=%s'):format(
                            preset.name, preset.progress, signedRate, targetRate,
                            preset.rollSpeedSource or 'unknown'))
                    end
                    preset.counterThrust = counterThrust
                end
                if now - preset.lastLog >= 1000 then
                    preset.lastLog = now
                    print(('[rs-thrusters][STUNT] %s angle=%.0f/%d rate=%.2f target=%.2f output=%.2f source=%s'):format(
                        preset.name,preset.progress,cfg.StuntTargetDegrees,signedRate,targetRate,correction,
                        isPitch and 'pitch' or (preset.rollSpeedSource or 'unknown')))
                end
                if not isPitch then
                    -- Previously both non-roll axes were left completely free.
                    -- GTA can introduce a rapid cross-axis tumble when the car
                    -- is upside down, corrupting the roll-angle measurement.
                    -- Dampen those axes throughout the stunt; only roll is free.
                    local crossPitch, crossYaw = rollCrossAxisDamping(omega, forward,
                        preset.startForwardZ or 0.0, cfg)
                    return crossPitch, correction, crossYaw
                end
                local crossBrake = clamp(-softZero(omega.y, 0.04) * 0.45, -cfg.StuntCrossMix, cfg.StuntCrossMix)
                return correction, crossBrake * cfg.RollSign, yawBrake
            end
        end
    end
    local stabilization = cfg.StabilizeMix[mode] or 0
    if levelAssist then
        local forward, right = GetEntityMatrix(vehicle)
        local omega = worldAngularVelocityInLocal(vehicle)
        local limit = cfg.HoverLevelMix
        -- Positive chassis yaw is a left turn. Right input requests negative angular velocity.
        local turnRate = -turn * cfg.HoverYawRate
        yaw = yaw ~= 0 and yaw or clamp(softZero(turnRate - omega.z, 0.04) * 0.8, -cfg.HoverYawMix, cfg.HoverYawMix)
        local targetPitchZ = math.sin(math.rad(cfg.HelicopterPitchDegrees) * pitchInput)
        if landingAssist and math.abs(pitchInput) < 0.10 then
            local position = GetEntityCoords(vehicle)
            local agl = math.max(0.0, position.z - surfaceBelow(vehicle,position))
            local descent = GetEntityVelocity(vehicle).z
            if agl < cfg.LandingFlareHeight and descent < cfg.LandingFlareMaxDescent then
                targetPitchZ = math.max(targetPitchZ,
                    math.sin(math.rad(cfg.LandingFlarePitchDegrees))
                        * clamp((cfg.LandingFlareHeight-agl)/cfg.LandingFlareHeight,0,1))
            end
        end
        local pitchError = targetPitchZ - forward.z
        local pitch = levelMix(pitchError, omega.x, limit, cfg)
        if mode == 'assisted' and hoverStyle == 'helicopter' and not IsInputDisabled(0) then
            local targetRate = clamp(softZero(pitchError, cfg.HoverLevelDeadband) * 1.6, -0.35, 0.35)
            pitch = clamp(softZero(targetRate - omega.x, 0.03) * 0.30, -0.10, 0.10)
        end
        return pitch * cfg.PitchSign, levelMix(right.z, omega.y, limit, cfg) * cfg.RollSign, yaw
    end
    if stabilization > 0 and not preset then
        local forward, right, up = GetEntityMatrix(vehicle)
        local omega = worldAngularVelocityInLocal(vehicle)
        -- World up projected onto the car's axes gives the direction to level.
        local pitchError, rollError = -forward.z, right.z
        local kp, kd = cfg.StabilizeKp, cfg.StabilizeKd
        if up.z < -0.95 and math.abs(pitchError)+math.abs(rollError)<0.12 then pitchError=1.0 end
        if math.abs(pitch)<0.08 then pitch = clamp(softZero(pitchError, 0.04)*kp-softZero(omega.x, 0.04)*kd,-1,1)*stabilization end
        if math.abs(roll)<0.08 then roll = clamp(softZero(rollError, 0.04)*kp-softZero(omega.y, 0.04)*kd,-1,1)*stabilization end
        if math.abs(yaw)<0.06 then yaw=clamp(-omega.z*cfg.StabilizeKd,-1,1)*stabilization end
    end
    return clamp(pitch*cfg.PitchSign,-1,1), clamp(roll*cfg.RollSign,-1,1), clamp(yaw,-1,1)
end

-- Driver detection/sync. If a garage spawns a fresh vehicle with the same
-- plate and model, the server reattaches the saved upgrade state.
CreateThread(function()
    while true do
        Wait(250)
        local veh = driverVehicle()
        if veh ~= trackedVehicle then
            if trackedVehicle ~= 0 then clearControls(trackedVehicle) end
            trackedVehicle = veh
            lastSyncVehicle = 0
        end
        if veh ~= 0 and (veh ~= lastSyncVehicle or GetGameTimer()-lastSync > Config.DriverSyncInterval) then
            local id = netId(veh)
            if id > 0 then TriggerServerEvent('rs_thrusters:syncVehicle', id) end
            lastSyncVehicle, lastSync = veh, GetGameTimer()
        end
        if veh ~= 0 and enabled and (not installed(veh) or pressure(veh) <= 0) then clearControls(veh) end
    end
end)

CreateThread(function()
    while true do
        local veh = validActiveVehicle()
        if veh == 0 then
            lastAppliedMask, lastThrust, nozzleOutput = 0, 0, {}
            Wait(90)
        else
            Wait(0)
            if menuOpen and not descending then
                hoverAnchor = nil
                liftRamp, boostRamp = 0.0, 0.0
                transmit(veh,0,false)
            elseif NetworkHasControlOfEntity(veh) then
                controlLostSince = 0
                DisableControlAction(0,76,true) -- space/handbrake, only while active
                local cfg = Config.Physics
                local v = GetEntityVelocity(veh)
                local pos = GetEntityCoords(veh)
                local floor = surfaceBelow(veh, pos)
                local wheelsDown = IsVehicleOnAllWheels(veh)
                local grounded = wheelsDown == true or wheelsDown == 1
                local airFlag = IsEntityInAir(veh)
                local inAir = airFlag == true or airFlag == 1
                if grounded and pos.z - floor > 1.5 then floor = pos.z - 0.4 end
                local settledOnWheels = grounded and math.abs(v.z) <= cfg.HoverCatchSettledVerticalSpeed
                if settledOnWheels or not hover or preset or mode ~= 'assisted' then
                    catchingHover, hoverResumeAt = false, nil
                end
                local h = math.max(0, pos.z - floor)
                if hover then
                    hoverFloor = hoverFloor or floor
                    hoverWorldTarget = hoverWorldTarget or (pos.z + (grounded and hoverHeight or 0.0))
                else
                    hoverFloor, hoverWorldTarget = nil, nil
                end
                local forward, right, up = GetEntityMatrix(veh)
                local measuredOmega = chassisAngularVelocity(veh, forward, right, up, GetGameTimer())
                if rollProbe then updateRollProbe(veh, forward, right, up, measuredOmega, GetGameTimer()) end
                local fwd = GetEntityForwardVector(veh)
                local forwardSpeed = v.x*fwd.x + v.y*fwd.y + v.z*fwd.z
                local factor = math.sqrt(clamp(pressure(veh)/Config.MaxPressure,0,1))
                local levels = {}
                local airborne = (h > cfg.AirborneHeight and (not grounded or preset ~= nil))
                    or (not grounded and h > 0.5 and inAir)
                if descending then
                    hoverLaunchClearSince = nil
                    if grounded or (h < 0.65 and not inAir) then
                        clearControls(veh)
                        notice('Landed. Thrusters OFF.')
                    else
                        local targetVz = -clamp(h * 0.35, 0.45, cfg.ShutdownDescentSpeed)
                        local dt = math.min(GetFrameTime(), 0.05)
                        local lift = math.min(0.90, hoverCollectiveDemand(targetVz, h, v.z, false, factor, dt, cfg))
                        local omega = worldAngularVelocityInLocal(veh)
                        if up.z < cfg.MaxHoverTiltZ then
                            recoverHover(levels, forward, right, up, omega, cfg, lift)
                        else
                            local limit = cfg.HoverLevelMix
                            mixBelly(levels, lift, levelMix(-forward.z, omega.x, limit, cfg) * cfg.PitchSign,
                                levelMix(right.z, omega.y, limit, cfg) * cfg.RollSign, true)
                        end
                        transmit(veh, applyNozzles(veh, levels, factor, nil, true, true, 1.0), false)
                    end
                    goto nextFlightFrame
                end
                local throttle, turn, slide, pitchInput = 0.0, 0.0, 0.0, 0.0
                local controlsAvailable = not IsPauseMenuActive()
                local horizontalSpeed = math.sqrt(v.x * v.x + v.y * v.y)
                local jumpAirborne = mode == 'assisted' and not preset and not rollProbe and not grounded
                    and (airborne or inAir)
                if preset or rollProbe then
                    -- GTA has built-in midair steering/roll and handbrake+steer
                    -- yaw. Prevent a *second* physics controller from fighting
                    -- the thruster stunt. The player's normal driving and
                    -- assisted hover input processing remain unchanged.
                    for control = 59, 64 do DisableControlAction(0, control, true) end
                    DisableControlAction(0, 76, true)
                elseif hover and mode == 'assisted' and not grounded then
                    -- Hover handles these flight axes itself; do not double-drive.
                    for control = 61, 64 do DisableControlAction(0, control, true) end
                elseif not hover and jumpAirborne and controlsAvailable and not input.mod and not input.padStunt and not input.stuntKey then
                    -- Retain GTA's own midair steering, with lower keyboard and stick authority.
                    for control = 59, 64 do
                        local value = GetControlNormal(0, control)
                        if value ~= 0.0 then SetControlNormal(0, control, value * cfg.JumpInputScale) end
                    end
                end
                local jumpTrim = not hover and jumpAirborne and not input.mod and not input.padStunt and not input.stuntKey
                local jumpLanding = not hover and jumpAirborne and landingAssist
                    and h < cfg.LandingHeight and v.z < cfg.LandingFlareMaxDescent
                local jumpLiftDemand
                if controlsAvailable then throttle, turn, slide, pitchInput = hoverInputs(cfg, hover) end
                lastPilot.throttle, lastPilot.turn, lastPilot.slide, lastPilot.pitch = throttle, turn, slide, pitchInput or 0.0
                local driveHeading, nativeRates
                local verticalLift = false
                local helicopter = hover and hoverStyle == 'helicopter'
                -- In Helicopter hover B descends; LB+B requests air braking.
                local braking = input.brake or (input.padBrake and (not helicopter or input.mod))
                local collective = 0.0
                if helicopter and not preset and controlsAvailable then
                    collective = (input.lift and 1 or 0) - ((input.descend or (input.padBrake and not input.mod)) and 1 or 0)
                    if collective ~= 0 then
                        -- On a fresh climb/descent command start from the ACTUAL
                        -- world altitude. Never snap the target back to 3.2 m.
                        if lastCollective ~= collective then hoverWorldTarget = pos.z end
                        local rate = collective > 0 and cfg.CollectiveClimbSpeed or cfg.CollectiveDescentSpeed
                        hoverWorldTarget = clamp((hoverWorldTarget or pos.z) + collective * rate * GetFrameTime(),
                            -100.0, cfg.MaxWorldHoverZ)
                        hoverHeight = math.max(0.3, hoverWorldTarget - (hoverFloor or floor))
                        if collective < 0 and h < 0.55 and math.abs(v.z) < 1.2 then
                            hover, helicopter, collective = false, false, 0.0
                            hoverWorldTarget = nil
                            hoverTrim = 0.0
                            notice('Landed. Hover assist OFF.')
                        end
                    elseif lastCollective ~= 0 then
                        -- Pilot released A/B: maintain the present altitude.
                        hoverWorldTarget = pos.z
                        hoverHeight = math.max(0.3, pos.z - (hoverFloor or floor))
                    end
                end
                lastCollective = collective
                local now = GetGameTimer()
                local wasClearingSurface = hoverLaunchClearSince ~= nil
                local launchEligible = hover and mode == 'assisted' and not preset and collective >= 0 and up.z > 0.55
                -- A near-ground flag can flicker during an airborne catch.
                -- Keep attitude recovery until the car settles on its wheels.
                local launchContact = settledOnWheels or (not grounded and not inAir and not catchingHover
                    and not hoverRecovering and h < cfg.HoverLaunchContactHeight
                    and math.abs(v.z) <= cfg.HoverCatchSettledVerticalSpeed)
                local launchClear = not grounded and inAir and h >= cfg.HoverLaunchClearance
                hoverLaunchClearSince = hoverLaunchState(hoverLaunchClearSince, launchEligible,
                    launchContact, launchClear, now, cfg.HoverLaunchClearMs)
                local clearingSurface = hoverLaunchClearSince ~= nil
                if clearingSurface and not wasClearingSurface then
                    hoverTrim, hoverDrive, hoverSlide = 0.0, 0.0, 0.0
                    print(('[rs-thrusters][LAUNCH] symmetric lift; AGL=%.2f upZ=%.2f'):format(h, up.z))
                elseif wasClearingSurface and not clearingSurface and launchEligible then
                    hoverResumeAt = now
                    print(('[rs-thrusters][LAUNCH] clear of surface; AGL=%.2f upZ=%.2f'):format(h, up.z))
                end
                if clearingSurface then throttle, turn, slide, pitchInput = 0.0, 0.0, 0.0, 0.0 end
                local resumeBlend = hoverResumeAt and clamp((now - hoverResumeAt) / cfg.HoverResumeMs, 0.0, 1.0) or 1.0
                throttle, turn, slide = throttle * resumeBlend, turn * resumeBlend, slide * resumeBlend
                local nativeOmega = worldAngularVelocityInLocal(veh)
                local omegaForGuard = mode == 'assisted' and not preset and (measuredOmega or nativeOmega) or nativeOmega
                local angularShock = math.max(math.abs(nativeOmega.x), math.abs(nativeOmega.y))
                -- Collision flags alone are sticky (and wheels touch the road).
                -- Require an actual upset or a nearby obstruction before reacting.
                -- Collision flags can stay true through repeated wheel/prop
                -- contact. Only react to a NEW angular impulse, not a tilt
                -- or a collision flag persisting across frames.
                local suddenSpin = angularShock > cfg.CollisionSpinThreshold
                    and angularShock - lastAngularShock > 0.33
                lastAngularShock = angularShock
                local collisionFlag = HasEntityCollidedWithAnything(veh)
                local touched = collisionFlag == true or collisionFlag == 1
                local freshContact = touched and not lastContact
                lastContact = touched
                local holdingPosition = hover and mode == 'assisted' and not grounded and h > 0.45
                    and controlsAvailable and resumeBlend >= 1.0 and not preset and not clearingSurface and not catchingHover and not hoverRecovering and not freshContact
                    and now >= impactUntil and not input.boost and not input.padBoost and not braking
                    and not (input.lift and not helicopter)
                    and math.abs(throttle) < 0.001 and math.abs(slide) < 0.001
                if holdingPosition then
                    local heading = horizontalHeading(forward, right)
                    if heading then
                        hoverAnchor = hoverAnchor or pos
                        throttle, slide = positionHoldInputs(hoverAnchor, pos, heading, cfg)
                    end
                else
                    hoverAnchor = nil
                end
                -- Guard the direction of pilot thrust or automatic return.
                local obstacle = hover and objectAhead(veh, pos, forward, right, v,
                    throttle, slide, now, cfg) or false
                if obstacle and holdingPosition then hoverAnchor = nil end
                -- The native collision flag can remain set for many frames, so
                -- require a fresh impact and angular impulse. An active nearby
                -- obstacle also counts, but neither a tilted car nor existing
                -- spin alone constitutes a new collision.
                local collisionUpset = not grounded and suddenSpin
                    and (freshContact or obstacle)
                    and now >= impactUntil
                if collisionUpset then
                    impactUntil = now + cfg.CollisionQuietMs
                    if preset then finishStunt(veh, false, 'collision / object while performing stunt') end
                    if now - collisionLogAt > 1200 then
                        collisionLogAt = now
                        print(('[rs-thrusters][COLLISION] flight upset; rate=%.2f tiltUp=%.2f height=%.2f vz=%.2f contact=%s obstacle=%s; thrust limiting'):format(
                            angularShock, up.z, h, v.z, tostring(freshContact), tostring(obstacle)))
                    end
                end
                if obstacle and rollProbe then
                    print('[rs-thrusters][ROLL PROBE] canceled: obstacle ahead')
                    rollProbe = nil
                end
                if obstacle and preset then
                    finishStunt(veh, false, 'obstacle ahead during stunt')
                end
                local impact = now < impactUntil
                local impactBraking = impact and not grounded and not preset and not clearingSurface and mode == 'assisted'
                    and angularShock > cfg.HoverSpinExitRate
                -- Never let hover translation drive toward a prop or wall.
                -- Neutral still allows counter-thrust to reduce existing speed.
                lastPilot.blocked = obstacle
                if obstacle then
                    -- Guard only thrust INTO a confirmed obstruction; do not
                    -- remove movement after a collision or while climbing.
                    throttle, slide = 0.0, 0.0
                    hoverDrive, hoverSlide = 0.0, 0.0
                end
                local recoverySteer = 0.0
                if hover and not preset and up.z < 0.0 then
                    recoverySteer = GetControlNormal(0, 59)
                    if recoverySteer == 0 then recoverySteer = GetDisabledControlNormal(0, 59) end
                    if input.rollLeft then recoverySteer = -1.0 end
                    if input.rollRight then recoverySteer = 1.0 end
                    if input.arrowLeft and not input.stuntKey then recoverySteer = -1.0 end
                    if input.arrowRight and not input.stuntKey then recoverySteer = 1.0 end
                    if math.abs(recoverySteer) < cfg.ControllerDeadzone then recoverySteer = 0.0 end
                    SetVehicleSteeringAngle(veh, -recoverySteer * cfg.RecoveryWheelAngle)
                end
                -- Latched recovery, not a repeating 4.8-second pause/retry loop.
                -- Never disable altitude hold just because the chassis is tilted.
                -- Leave recovery only after BOTH tilt and angular speed settle,
                -- continuously for a short hysteresis window.
                local angularRate = math.max(math.abs(omegaForGuard.x), math.abs(omegaForGuard.y))
                local fullRate = math.max(angularRate, math.abs(omegaForGuard.z))
                local assistedHover = hover and mode == 'assisted'
                local assistedUpset = assistedHover and not grounded
                    and (fullRate > 1.6 or (up.z < 0.85 and angularRate > 0.85))
                local stable = up.z > cfg.HoverRecoveryExitUpZ and angularRate < cfg.HoverSpinExitRate
                if assistedHover then
                    stable = up.z > cfg.HoverAssistSettledUpZ and fullRate < cfg.HoverAssistSettledRate
                        and (not catchingHover or (math.abs(v.z) <= cfg.HoverCatchSettledVerticalSpeed and not impact))
                end
                local previousRecovery = hoverRecovering
                if not hover or preset or clearingSurface then
                    hoverRecovering = false
                    recoverySince, recoveryStableSince = 0, 0
                elseif not hoverRecovering then
                    if catchingHover or assistedUpset or up.z < cfg.MaxHoverTiltZ or angularRate > cfg.HoverSpinTripRate then
                        hoverRecovering = true
                        hoverResumeAt = nil
                        recoverySince, recoveryStableSince = now, 0
                        -- Reset integral windup when taking over an upside-down
                        -- vehicle; preserve the requested world-height target.
                        hoverTrim = 0.0
                    end
                else
                    if stable then
                        recoveryStableSince = recoveryStableSince ~= 0 and recoveryStableSince or now
                        if now - recoveryStableSince >= cfg.HoverRecoverySettleMs then
                            hoverRecovering, catchingHover = false, false
                            if assistedHover then
                                hoverResumeAt, resumeBlend = now, 0.0
                                throttle, turn, slide = 0.0, 0.0, 0.0
                            end
                            recoverySince, recoveryStableSince = 0, 0
                        end
                    else
                        recoveryStableSince = 0
                    end
                end
                if hoverRecovering ~= previousRecovery and not preset and not clearingSurface then
                    recoveryAxis, recoverySign = nil, nil
                    if hoverRecovering then
                        local action = catchingHover and 'catching jump' or 'stabilizing'
                        print(('[rs-thrusters][RECOVERY] %s tilt=%.2f angular=%.2f vz=%.2f'):format(
                            action, up.z, fullRate, v.z))
                    else
                        print('[rs-thrusters][RECOVERY] stable; full hover control restored')
                    end
                elseif hoverRecovering and now - recoverySince > 10000 and now - recoveryReportAt > 10000 then
                    -- One diagnostic per 10 seconds, not one every timeout.
                    recoveryReportAt = now
                    print(('[rs-thrusters][RECOVERY] still stabilizing tilt=%.2f angular=%.2f vz=%.2f'):format(up.z, fullRate, v.z))
                end
                local recovering = hover and (hoverRecovering or (recoverySteer ~= 0 and up.z < 0.0))
                local assistedRecovery = assistedHover and recovering
                if recovering and holdingPosition then
                    hoverAnchor = nil
                    throttle, slide = 0.0, 0.0
                end
                local brakeThreshold = assistedSpinBraking and cfg.HoverRecoveryBrakeExit or cfg.HoverRecoveryBrakeEnter
                if catchingHover and not assistedSpinBraking then brakeThreshold = cfg.HoverCatchBrakeEnter end
                assistedSpinBraking = assistedRecovery and fullRate > brakeThreshold
                if assistedRecovery then impactBraking = false end
                lastPilot.recovering = recovering
                local dt = math.min(GetFrameTime(), 0.05)
                local manualLift = input.lift and not helicopter
                liftRamp = manualLift and not recovering and math.min(resumeBlend, liftRamp + dt / cfg.LiftRampSeconds) or 0.0
                local boostPressed = input.boost or input.padBoost
                boostRamp = boostPressed and not recovering and not obstacle and math.min(resumeBlend, boostRamp + dt / cfg.BoostRampSeconds) or 0.0
                if preset and preset.climbing then
                    if not hover then
                        finishStunt(veh, false, 'hover switched off')
                    elseif now - preset.started > cfg.StuntClimbTimeoutMs then
                        local reason = h < cfg.StuntClearance
                            and ('climb stopped at %.1f m; needs %.0f m'):format(h, cfg.StuntClearance)
                            or 'vehicle did not steady before rotation'
                        finishStunt(veh, false, reason)
                    else
                        local ready = h >= cfg.StuntClearance and not grounded and not impact and up.z > 0.92 and v.z > -1.0
                        local settleRate = preset.axis == 'pitch' and cfg.StuntPitchSettleRate or cfg.StuntRollSettleRate
                        local steady = ready and up.z > 0.97 and fullRate <= settleRate
                        preset.stableSince = steady and (preset.stableSince or now) or nil
                        ready = preset.stableSince and now - preset.stableSince >= cfg.StuntStableMs
                        if ready then
                            preset.climbing = false
                            preset.started, preset.lastTick = now, now
                            preset.targetZ = pos.z
                            preset.phase = 'rotate'
                            preset.stableSince = nil
                            if preset.axis == 'roll' then
                                -- Initialize a chassis-motion angle accumulator at the
                                -- actual rotation start, NOT at the climb command.
                                preset.rollPreviousRight, preset.rollPreviousUp = right, up
                                preset.geomRate, preset.nativeRate, preset.matrixRate = 0.0, 0.0, 0.0
                                preset.wrongWaySince, preset.invertedAssist = nil, false
                                preset.rollCheckpoint = 0
                                preset.startForwardZ = forward.z
                                preset.crossUnsafeSince = nil
                            end
                            notice(('%s: rotating.'):format(preset.name))
                            print(('[rs-thrusters][STUNT] %s ROTATE at AGL %.2f rate=%.2f'):format(preset.name,h,fullRate))
                        end
                    end
                end
                if clearingSurface then
                    -- Let the chassis rise clear of the slope before applying pitch, roll or yaw.
                    -- This is world-up force through the center of mass, with equal belly jets.
                    local targetZ = math.max(hoverWorldTarget or pos.z, floor + cfg.HoverLaunchClearance + 0.35)
                    local targetVz = clamp((targetZ - pos.z) * cfg.HoverHeightGain, 0.0, cfg.HoverClimbSpeed)
                    local lift = hoverCollectiveDemand(targetVz, h, v.z, grounded or launchContact, factor, dt, cfg)
                    mixBelly(levels, lift, 0.0, 0.0, true)
                    verticalLift = true
                elseif preset and preset.climbing then
                    verticalLift = true
                    local targetZ = floor + cfg.StuntClearance + 2.0
                    if preset.phase == 'ready' then targetZ = math.max(preset.targetZ, floor + cfg.StuntClearance + 0.3) end
                    local targetVz = clamp((targetZ - pos.z) * cfg.HoverHeightGain, 0.0, cfg.StuntClimbSpeed)
                    local lift = math.min(0.90, hoverCollectiveDemand(targetVz, h, v.z, grounded, factor, dt, cfg))
                    local omega = worldAngularVelocityInLocal(veh)
                    if not grounded then
                        local pitch, roll, pitchRate, rollRate = assistedRecoveryMix(forward, right, up, omega, 0.0,
                            fullRate > cfg.HoverRecoveryBrakeExit, cfg.StuntClimbLevelMix, cfg)
                        nativeRates = vector3(pitchRate, rollRate, 0.0)
                        mixAssistedHover(levels, lift, pitch, roll)
                        jumpLiftDemand = lift
                        local yaw = clamp(-omega.z * cfg.HoverRecoveryRateGain, -cfg.HoverYawMix, cfg.HoverYawMix)
                        if yaw > 0.06 then
                            levels.side_rear_l, levels.side_front_r = yaw, yaw
                        elseif yaw < -0.06 then
                            levels.side_front_l, levels.side_rear_r = -yaw, -yaw
                        end
                    else
                        mixBelly(levels, lift, 0.0, 0.0, true)
                    end
                elseif recovering then
                    local omega = omegaForGuard
                    local lift = 0.0
                    if hover then
                        local targetVz = clamp(((hoverWorldTarget or pos.z) - pos.z) * cfg.HoverHeightGain,
                            -cfg.HoverDescentSpeed, cfg.HoverClimbSpeed)
                        lift = math.min(0.85,
                            hoverCollectiveDemand(targetVz, h, v.z, false, factor, dt, cfg))
                        verticalLift = true
                    end
                    if assistedRecovery then
                        local limit = assistedSpinBraking and cfg.HoverRecoveryBrakeMix or cfg.HoverRecoveryMix
                        if obstacle then limit = math.min(limit, cfg.CollisionRecoveryMix) end
                        local pitch, roll, pitchRate, rollRate = assistedRecoveryMix(forward, right, up, omega,
                            catchingHover and 0.0 or recoverySteer,
                            assistedSpinBraking, limit, cfg)
                        nativeRates = vector3(pitchRate, rollRate, 0.0)
                        mixAssistedHover(levels, lift, pitch, roll)
                        jumpLiftDemand = lift
                    elseif recoverySteer ~= 0 then
                        local targetRate = recoverySteer * cfg.RecoveryRollRate * cfg.RollSign
                        local limit = (impact or obstacle) and cfg.CollisionRecoveryMix or cfg.HoverRecoveryThrottle
                        local roll = clamp((targetRate - omega.y) * cfg.HoverLevelKd, -limit, limit)
                        mixBelly(levels, lift, 0, roll, false)
                    else
                        recoverHover(levels, forward, right, up, omega, cfg, lift)
                        if impact or obstacle then
                            -- Cap correction asymmetry as well as total gain;
                            -- avoid pinning the vehicle against a nearby prop.
                            local base = lift
                            for _, name in ipairs({'belly_fl','belly_fr','belly_rl','belly_rr'}) do
                                levels[name] = clamp(levels[name] or 0, math.max(0,base-cfg.CollisionRecoveryMix),
                                    math.min(1,base+cfg.CollisionRecoveryMix))
                            end
                        end
                    end
                    local targetYaw = (assistedRecovery or assistedSpinBraking) and 0.0 or -turn * cfg.HoverYawRate
                    local yawGain = assistedRecovery and cfg.HoverRecoveryRateGain or 0.8
                    local yawLimit = assistedRecovery and cfg.HoverRecoveryYawMix or cfg.HoverYawMix
                    local yaw = clamp((targetYaw - omega.z) * yawGain, -yawLimit, yawLimit)
                    if yaw > 0.06 then
                        levels.side_rear_l, levels.side_front_r = yaw, yaw
                    elseif yaw < -0.06 then
                        levels.side_front_l, levels.side_rear_r = -yaw, -yaw
                    end
                    if not obstacle and not assistedRecovery then
                        driveHeading = driveInHover(levels, forward, right, v, throttle, dt, factor, cfg)
                        if driveHeading then
                            slideInHover(levels, driveHeading, v, slide, dt, factor, cfg)
                        end
                    end
                else
                    local liftDemand = 0.0
                    if not preset and manualLift and h < cfg.MaxHeightAboveGround and v.z < cfg.MaxUpSpeed then
                        liftDemand = cfg.LiftThrottle * liftRamp
                        verticalLift = up.z >= cfg.MaxHoverTiltZ
                        if not hover and mode == 'assisted' then
                            -- While held, lift requests a gentle climb rate; release removes the climb request.
                            local capacity = 4 * cfg.NozzleAcceleration.belly * factor * thrustOutput
                            local accel = 9.81 + (cfg.AssistedClimbSpeed - v.z) * cfg.HoverDamping
                            liftDemand = clamp(accel / math.max(capacity, 0.001), 0.0, cfg.LiftThrottle) * liftRamp
                            verticalLift = true
                        end
                    end
                    if not preset and boostPressed and not obstacle and forwardSpeed < cfg.MaxForwardSpeed then
                        local boost = cfg.BoostThrottle * boostRamp
                        levels.rear_upper_l, levels.rear_upper_r = boost, boost
                        levels.rear_lower_l, levels.rear_lower_r = boost, boost
                    end
                    if not preset and braking and airborne and forwardSpeed > 1.0 then
                        local brakeOutput = cfg.BrakeThrottle * resumeBlend
                        levels.front_l, levels.front_r = brakeOutput, brakeOutput
                    end
                    local hoverHold = hover and not preset and (not manualLift or resumeBlend < 1.0)
                    local hoverCollective = hoverHold and up.z >= cfg.MaxHoverTiltZ
                    if preset then
                        -- Keep collective world-up through the flip. Belly jet differences supply torque.
                        verticalLift = true
                        local targetZ = math.max(preset.targetZ, floor + cfg.StuntClearance)
                        local targetVz = clamp((targetZ - pos.z) * cfg.HoverHeightGain, -cfg.HoverDescentSpeed, cfg.StuntClimbSpeed)
                        liftDemand = math.min(0.85, hoverCollectiveDemand(targetVz, h, v.z, grounded, factor, dt, cfg))
                    elseif hoverCollective then
                        verticalLift = true
                        local floorMargin = helicopter and (input.descend or input.padBrake) and 0.3 or 0.80
                        local targetZ = hoverWorldTarget or ((hoverFloor or floor) + hoverHeight)
                        if h < 0.75 then targetZ = math.max(targetZ, floor + floorMargin) end
                        local targetVz = clamp((targetZ - pos.z) * cfg.HoverHeightGain, -cfg.HoverDescentSpeed, cfg.HoverClimbSpeed)
                        liftDemand = math.max(liftDemand, hoverCollectiveDemand(targetVz, h, v.z, grounded, factor, dt, cfg))
                    end
                    local guidedTravel = hoverCollective and not grounded
                        and not preset and not boostPressed and not braking and up.z > 0.42 and h > 0.45
                    if guidedTravel then
                        driveHeading = driveInHover(levels, forward, right, v, throttle, dt, factor, cfg)
                    elseif (airborne or jumpAirborne) and not preset and (boostPressed or braking) then
                        -- Keep boost and braking from pulling the nose up or down.
                        driveHeading = horizontalHeading(forward, right)
                        hoverDrive, hoverSlide = 0.0, 0.0
                    end
                    if not preset and landingAssist and mode ~= 'manual' and airborne and up.z >= cfg.MaxHoverTiltZ and
                        h < cfg.LandingHeight and v.z < cfg.LandingDescentSpeed then
                        local arrest = clamp(9.81+(cfg.LandingTargetSpeed-v.z)*cfg.LandingGain,0,cfg.HoverMaxAcceleration)
                        local maxBelly = 4*cfg.NozzleAcceleration.belly*math.max(factor,0.01)*(jumpLanding and 1.0 or up.z)
                        liftDemand = math.max(liftDemand,clamp(arrest/(maxBelly*thrustOutput),0,1))
                    end
                    local pitch, roll, yaw = 0.0, 0.0, 0.0
                    if assistedHover and jumpAirborne then
                        local authority, pitchRate, rollRate
                        pitch, roll, authority, pitchRate, rollRate = assistedHoverAttitude(forward, right, up, omegaForGuard,
                            pitchInput or 0.0, horizontalSpeed, cfg)
                        local yawRate = -turn * cfg.HoverYawRate * authority
                        yaw = clamp(softZero(yawRate - omegaForGuard.z, 0.04) * 0.65,
                            -cfg.HoverYawMix, cfg.HoverYawMix)
                        nativeRates = vector3(pitchRate, rollRate, yawRate)
                    elseif hover or preset or rollProbe or mode ~= 'assisted' then
                        pitch, roll, yaw = desiredRotation(veh, airborne, hoverHold, turn, pitchInput or 0.0, measuredOmega)
                    elseif jumpLanding then
                        local limit = cfg.JumpLandingMix
                        local blend = clamp((cfg.LandingHeight - h) / cfg.LandingHeight, 0.0, 1.0)
                        pitch = levelMix(-forward.z, omegaForGuard.x, limit, cfg) * cfg.PitchSign * blend
                        roll = levelMix(right.z, omegaForGuard.y, limit, cfg) * cfg.RollSign * blend
                        jumpLiftDemand = liftDemand
                    elseif jumpTrim then
                        -- Stock air steering keeps control. The jets only damp
                        -- excess rotation and contribute no collective lift.
                        local limit = cfg.JumpAirTrimMix
                        pitch = clamp(-softZero(omegaForGuard.x, 0.25) * 0.18, -limit, limit) * cfg.PitchSign
                        roll = clamp(-softZero(omegaForGuard.y, 0.25) * 0.18, -limit, limit) * cfg.RollSign
                    end
                    if resumeBlend < 1.0 then
                        local levelPitch, levelRoll = assistedRecoveryMix(forward, right, up, omegaForGuard,
                            0.0, false, cfg.HoverRecoveryMix, cfg)
                        pitch = levelPitch + (pitch - levelPitch) * resumeBlend
                        roll = levelRoll + (roll - levelRoll) * resumeBlend
                    end
                    -- Pitch/roll fire ONLY actual belly jets at real mounting locations.
                    -- A small bias allows opposite sides to make both rotation directions.
                    local maneuverBias = not preset and (math.abs(pitch)>0.08 or math.abs(roll)>0.08) and 0.12 or 0.0
                    local balanceHover = verticalLift and liftDemand > 0
                    if balanceHover and math.abs(pitch) + math.abs(roll) > 0.05 then
                        liftDemand = math.min(liftDemand, 0.90)
                    end
                    if (assistedHover and hoverCollective) or jumpTrim or preset then
                        mixAssistedHover(levels, liftDemand, pitch, roll)
                        jumpLiftDemand = liftDemand
                    else
                        mixBelly(levels, math.max(liftDemand, maneuverBias), pitch, roll,
                            balanceHover and not jumpLanding)
                    end
                    -- Equal and opposite side pushes at fore/aft points create pure yaw torque.
                    if yaw > 0.06 then
                        levels.side_rear_l,levels.side_front_r = yaw,yaw
                    elseif yaw < -0.06 then
                        levels.side_front_l,levels.side_rear_r = -yaw,-yaw
                    end
                    if guidedTravel and driveHeading and not obstacle then
                        slideInHover(levels, driveHeading, v, slide, dt, factor, cfg)
                    end
                end
                if impactBraking then
                    -- Brake the spin first. Once it slows, hand off to normal flight or hover recovery.
                    local limit = obstacle and cfg.CollisionRecoveryMix or cfg.CollisionSpinBrakeMix
                    local pitch = clamp(-omegaForGuard.x * cfg.HoverLevelKd, -limit, limit) * cfg.PitchSign
                    local roll = clamp(-omegaForGuard.y * cfg.HoverLevelKd, -limit, limit) * cfg.RollSign
                    local lift = ((levels.belly_fl or 0.0) + (levels.belly_fr or 0.0)
                        + (levels.belly_rl or 0.0) + (levels.belly_rr or 0.0)) * 0.25
                    if not hover and not input.lift then lift = jumpLiftDemand or 0.0 end
                    jumpLiftDemand = math.min(lift, cfg.CollisionLiftThrottle)
                    mixBelly(levels, jumpLiftDemand, pitch, roll, false)
                    nativeRates = vector3(0.0, 0.0, 0.0)
                end
                if not driveHeading then hoverDrive, hoverSlide = 0.0, 0.0 end
                local recoveryGain = hoverRecovering and cfg.HoverRecoveryTorqueGain or 1.0
                if assistedSpinBraking or impactBraking then
                    -- A wall can block translation while the jets still brake the spin.
                    recoveryGain = math.min(recoveryGain, cfg.CollisionSpinTorqueGain)
                elseif obstacle or impact then
                    -- Keep leveling gentle while pinned or after angular braking.
                    recoveryGain = math.min(recoveryGain, cfg.CollisionTorqueGain)
                end
                local stuntGain = recoveryGain
                local nativeAttitude = preset ~= nil and preset.axis == 'roll'
                    and not preset.climbing and cfg.StuntRollGovernorEnabled
                if preset and not preset.climbing then
                    if preset.axis == 'pitch' then
                        stuntGain = preset.settleUntil and 1.0 or cfg.StuntPitchTorqueGain
                        if cfg.StuntPitchNativeEnabled then stuntGain = 0.0 end
                    else
                        stuntGain = preset.settleUntil and cfg.StuntSettleTorqueGain or cfg.StuntTorqueGain
                        if nativeAttitude then stuntGain = 0.0 end
                    end
                end
                if nativeRates and (not preset or preset.climbing) and not rollProbe and not grounded
                    and h >= cfg.HoverLaunchClearance then
                    local response = (assistedSpinBraking or impactBraking)
                        and cfg.HoverNativeBrakeResponse or cfg.HoverNativeResponse
                    local rate = omegaForGuard + (nativeRates - omegaForGuard) * (1.0 - math.exp(-dt * response))
                    nativeAttitude = writeChassisRates(veh, forward, right, up, rate.x, rate.y, rate.z)
                    if nativeAttitude then stuntGain = 0.0 end
                end
                lastPilot.nativeAttitude = nativeAttitude
                local priorPitchTorque, priorRollTorque = lastPitchTorque, lastRollTorque
                local priorRate = previousFlightRate or omegaForGuard
                previousFlightRate = omegaForGuard
                local mask = applyNozzles(veh, levels, factor, driveHeading,
                    hover or jumpTrim or jumpLanding or impactBraking or preset ~= nil or verticalLift,
                    verticalLift or jumpLanding or impactBraking, stuntGain, jumpLiftDemand, nativeAttitude)
                -- Apply the assisted roll safety envelope AFTER the nozzle forces,
                -- so an unstable force response cannot accumulate across ticks.
                if preset and preset.axis == 'roll' and not preset.climbing then
                    stuntRollAngularGovernor(veh, forward, right, up, now, cfg)
                end
                local liftPressed = input.lift and not wasLifting
                local hoverEngaged = hover and not wasHovering and not preset
                local pitching = math.abs(controllerPitch) > 0.025
                local pitchStarted = pitching and not wasPitching and not preset
                wasLifting, wasHovering, wasPitching = input.lift, hover, pitching
                local lateRecovery = hoverRecovering and not previousRecovery and not catchingHover
                    and (not takeoffTrace or now - takeoffTrace.start >= 4000)
                if hoverEngaged or lateRecovery or (not catchingHover and (liftPressed or pitchStarted)) then
                    local trigger = hoverEngaged and (catchingHover and 'Airborne hover catch' or 'Hover engaged')
                        or (lateRecovery and 'Hover upset' or (liftPressed and 'Lift (Space / Xbox A)' or 'Xbox right-stick pitch'))
                    takeoffTrace = {vehicle=veh, start=now, nextSample=now, airborne=airborne,
                        trigger=trigger, samples={}}
                end
                if takeoffTrace and takeoffTrace.vehicle == veh and now - takeoffTrace.start <= 4000
                    and #takeoffTrace.samples < 30 and (now >= takeoffTrace.nextSample or airborne ~= takeoffTrace.airborne) then
                    takeoffTrace.nextSample, takeoffTrace.airborne = now + 150, airborne
                    local samples = takeoffTrace.samples
                    samples[#samples + 1] = ('[rs-thrusters][TAKEOFF] +%dms agl=%.2f vz=%.2f speed=%.2f ground=%s air=%s launch=%s upZ=%.2f omega=[%.2f,%.2f,%.2f] nativeOmega=[%.2f,%.2f,%.2f] measured=%s contact=%s impact=%s recovery=%s catch=%s blend=%.2f lift=%s hover=%s input=[%.2f,%.2f,%.2f,%.2f] torque=[%.2f,%.2f] prevTorque=[%.2f,%.2f] dOmega=[%.3f,%.3f,%.3f] worldLift=%.2f %s'):format(
                        now - takeoffTrace.start, h, v.z, horizontalSpeed, tostring(grounded), tostring(airborne), tostring(clearingSurface), up.z,
                        omegaForGuard.x, omegaForGuard.y, omegaForGuard.z, nativeOmega.x, nativeOmega.y, nativeOmega.z,
                        tostring(mode == 'assisted' and not preset and measuredOmega ~= nil), tostring(touched), tostring(impact),
                        tostring(recovering), tostring(catchingHover), resumeBlend, tostring(input.lift), tostring(hover),
                        throttle, turn, slide, pitchInput or 0.0,
                        lastPitchTorque, lastRollTorque, priorPitchTorque, priorRollTorque,
                        omegaForGuard.x - priorRate.x, omegaForGuard.y - priorRate.y, omegaForGuard.z - priorRate.z,
                        lastWorldLift, describeNozzles(nozzleOutput))
                end
                transmit(veh,mask,false)
                ::nextFlightFrame::
            else
                hoverAnchor = nil
                liftRamp, boostRamp = 0.0, 0.0
                transmit(veh,0,false)
                lastAppliedMask,lastThrust,nozzleOutput=0,0,{}
                if preset then
                    controlLostSince = controlLostSince ~= 0 and controlLostSince or GetGameTimer()
                    if GetGameTimer() - controlLostSince > 1200 then
                        finishStunt(veh, false, 'vehicle network control lost')
                    end
                end
            end
        end
    end
end)

local function stopEffects(vehicle)
    local entry = emitters[vehicle]
    if not entry then return end
    for _, handle in pairs(entry.handles) do
        if handle and handle ~= 0 then StopParticleFxLooped(handle, false) end
    end
    emitters[vehicle] = nil
end
local function loadAsset()
    if assetLoaded then return true end
    RequestNamedPtfxAsset(Config.Fx.Asset)
    local deadline = GetGameTimer() + 4000
    while not HasNamedPtfxAssetLoaded(Config.Fx.Asset) and GetGameTimer() < deadline do Wait(50) end
    assetLoaded = HasNamedPtfxAssetLoaded(Config.Fx.Asset)
    if not assetLoaded then debugLog('Particle asset failed to load: ' .. Config.Fx.Asset) end
    return assetLoaded
end
local function exhaustColor(speed, output)
    if fxStyle == 'stock' then return '#ffffff' end
    if output >= Config.Fx.OverrunThreshold then return fxColors.overrun end
    if fxStyle == 'solid' then return fxColors.solid end
    return speed >= Config.Fx.SpeedColorThreshold and fxColors.fast or fxColors.slow
end

local function setEffects(vehicle, mask, intensity, ownVehicle, hoverExhaust, jumpExhaust)
    local entry = emitters[vehicle]
    if not entry then
        if mask == 0 or not assetLoaded then return end
        entry = {handles={}, fadeStarted={}, refreshAt={}, mask=0, intensity=-1}
        emitters[vehicle] = entry
    end
    intensity = clamp(tonumber(intensity) or 1.0, 0.0, 1.0)
    if not ownVehicle and entry.mask == mask and math.abs(entry.intensity-intensity) < 0.07
        and not entry.ownVehicle and next(entry.fadeStarted) == nil then return end
    local now = GetGameTimer()
    local speed = ownVehicle and GetEntitySpeed(vehicle) or 0.0
    local baseScale = Config.Fx.Scale * (0.38 + intensity*0.62)
    local bounds = modelDimensions(vehicle)
    local bellyIndex = 0
    for _, nozzle in ipairs(Config.Nozzles) do
        local side = Config.PropulsionKind(nozzle.kind) == 'side'
        local fxScale = baseScale * (side and Config.Fx.SideScale or 1.0)
        local liftJet = (hoverExhaust or jumpExhaust) and nozzle.kind == 'belly'
        if liftJet then
            bellyIndex = bellyIndex + 1
            if jumpExhaust then
                fxScale = Config.Fx.JumpBellyScale + (nozzleOutput[nozzle.name] or 0.0) * fxScale
            else
                fxScale = math.max(fxScale, Config.Fx.HoverBellyMinScale)
            end
        else
            entry.refreshAt[nozzle.name] = nil
        end
        local active = (mask & nozzle.bit) ~= 0
        local x, y, z = localOffset(bounds, nozzle)
        if side then
            local centerX = (bounds.minB.x + bounds.maxB.x) * 0.5
            x = centerX + (x - centerX) * Config.Fx.SideInset
        end
        local rot = Config.Fx.Rotations[nozzle.kind]
        local color = ownVehicle and exhaustColor(speed, nozzleOutput[nozzle.name] or 0.0) or '#ffffff'
        local red = tonumber(color:sub(2,3), 16) / 255
        local green = tonumber(color:sub(4,5), 16) / 255
        local blue = tonumber(color:sub(6,7), 16) / 255
        if liftJet and not entry.refreshAt[nozzle.name] then
            entry.refreshAt[nozzle.name] = now + Config.Fx.HoverSteamRefreshMs + (bellyIndex - 1) * 210
        end
        -- Refresh the layers together while staggering different nozzles.
        local refresh = liftJet and now >= entry.refreshAt[nozzle.name]
        for index, layer in ipairs(Config.Fx.Layers) do
            local key = nozzle.name .. ':' .. index
            local handle = entry.handles[key]
            local scale = fxScale * layer.Scale
            if active then
                if liftJet and handle then
                    local exists = DoesParticleFxLoopedExist(handle)
                    if exists ~= true and exists ~= 1 then
                        entry.handles[key] = nil
                        handle = nil
                    end
                end
                local starting = not handle or refresh
                if starting then
                    -- Exhaust travels in the opposite direction to the force on the car.
                    local offset = layer.Distance * math.min(fxScale, 1.2)
                    local dir = nozzle.dir
                    UseParticleFxAssetNextCall(Config.Fx.Asset)
                    local newHandle = StartParticleFxLoopedOnEntity(Config.Fx.Name, vehicle,
                        x - dir[1] * offset, y - dir[2] * offset, z - dir[3] * offset,
                        rot[1], rot[2], rot[3], scale, false, false, false)
                    if newHandle and newHandle ~= 0 then
                        if handle then StopParticleFxLooped(handle, false) end
                        handle, entry.handles[key] = newHandle, newHandle
                    elseif Config.Fx.Debug then
                        print('[rs-thrusters] FX failed at ' .. key)
                    end
                end
                if handle then
                    SetParticleFxLoopedScale(handle, scale)
                    if starting or entry.fadeStarted[key] then
                        SetParticleFxLoopedAlpha(handle, layer.Alpha)
                        entry.fadeStarted[key] = nil
                    end
                    SetParticleFxLoopedColour(handle, red, green, blue, true)
                end
            elseif handle then
                local fadeStarted = entry.fadeStarted[key] or now
                entry.fadeStarted[key] = fadeStarted
                local remaining = 1.0 - (now - fadeStarted) / math.max(1, Config.Fx.FadeMs * layer.Fade)
                if remaining > 0.0 then
                    SetParticleFxLoopedAlpha(handle, layer.Alpha * remaining * remaining)
                else
                    StopParticleFxLooped(handle, false)
                    entry.handles[key], entry.fadeStarted[key] = nil, nil
                end
            end
        end
        if refresh then entry.refreshAt[nozzle.name] = now + Config.Fx.HoverSteamRefreshMs end
    end
    entry.mask, entry.intensity, entry.ownVehicle = mask, intensity, ownVehicle
    if mask == 0 and next(entry.handles) == nil then emitters[vehicle] = nil end
end

-- Every client locally renders visible nozzles from SERVER-validated statebag.
-- This avoids broadcasting permanent PTFX handles or applying physics twice.
CreateThread(function()
    loadAsset()
    while true do
        Wait(210)
        local seen = {}
        local here = GetEntityCoords(PlayerPedId())
        local own = validActiveVehicle()
        for _, veh in ipairs(GetGamePool('CVehicle')) do
            local ownVehicle = veh == own
            local mask = ownVehicle and lastAppliedMask or (tonumber(Entity(veh).state.rsThrustersFx) or 0)
            local hoverExhaust, jumpExhaust = false, false
            if ownVehicle then
                local wheelsDown = IsVehicleOnAllWheels(veh)
                local inAir = IsEntityInAir(veh)
                local clearOfGround = wheelsDown ~= true and wheelsDown ~= 1
                hoverExhaust = clearOfGround and (hover or descending)
                jumpExhaust = clearOfGround and not hoverExhaust and mode == 'assisted'
                    and (inAir == true or inAir == 1)
            end
            if hoverExhaust or jumpExhaust then
                for _, nozzle in ipairs(Config.Nozzles) do
                    if nozzle.kind == 'belly' then mask = mask | nozzle.bit end
                end
            end
            if (mask > 0 or emitters[veh]) and #(GetEntityCoords(veh) - here) <= Config.Fx.RenderDistance then
                if not assetLoaded then loadAsset() end
                if assetLoaded then
                    local intensity = tonumber(Entity(veh).state.rsThrustersIntensity) or 1.0
                    setEffects(veh, mask, intensity, ownVehicle, hoverExhaust, jumpExhaust)
                end
                seen[veh] = true
            end
        end
        for vehicle in pairs(emitters) do
            if not seen[vehicle] or not DoesEntityExist(vehicle) then stopEffects(vehicle) end
        end
    end
end)

-- Compact NUI HUD sends data at ~8 Hz; no focus and no gameplay blocking.
CreateThread(function()
    while true do
        Wait(Config.UI.RefreshMs)
        if Config.UI.Enabled then
            local veh = driverVehicle()
            if veh ~= 0 and installed(veh) then
                local _,_,up = GetEntityMatrix(veh)
                local omega = GetEntityRotationVelocity(veh)
                local vel = GetEntityVelocity(veh)
                local h = GetEntityHeightAboveGround(veh)
                local tilt = math.deg(math.acos(clamp(up.z,-1,1)))
                local rate = math.deg(math.sqrt(omega.x^2+omega.y^2+omega.z^2))
                local gas = pressure(veh)
                local warning, severity = 'STABLE', 'ok'
                if enabled then
                    if h > Config.Physics.AirborneHeight and tilt >= 65 then warning,severity='SEVERE TILT','critical'
                    elseif h > Config.Physics.AirborneHeight and tilt >= 35 then warning,severity='HIGH TILT','warn'
                    elseif h > Config.Physics.AirborneHeight and rate >= 95 and not preset then warning,severity='HIGH ROTATION','warn'
                    elseif h > Config.Physics.AirborneHeight and vel.z < -5 then warning,severity='FAST DESCENT','warn'
                    elseif descending then warning='SOFT LANDING'
                    elseif gas < Config.MaxPressure*.2 then warning,severity='LOW GAS','warn'
                    elseif preset then warning=('%s %s %.0f/360'):format(preset.name,preset.phase,preset.progress)
                    elseif h <= Config.Physics.AirborneHeight then warning='ON GROUND' end
                else warning='STANDBY' end
                local nozzles, total, maxTotal = {}, 0, 0
                for i,nozzle in ipairs(Config.Nozzles) do
                    local fraction = enabled and not menuOpen and (nozzleOutput[nozzle.name] or 0) or 0
                    local capacity = Config.Physics.NozzleAcceleration[Config.PropulsionKind(nozzle.kind)] or 0
                    total,maxTotal = total+fraction*capacity,maxTotal+capacity
                    nozzles[i] = {name=nozzle.name, thrust=math.floor(fraction*100+.5),
                        rpm=math.floor(fraction*Config.UI.VirtualMaxRpm+.5)}
                end
                SendNUIMessage({type='hud', visible=hudVisible, enabled=enabled,
                    nozzles=nozzles, warning=warning, severity=severity, tilt=tilt, rotationRate=rate,
                    pressure=pressure(veh), capacity=Config.MaxPressure,
                    height=GetEntityHeightAboveGround(veh), hover=hover,
                    mode=mode, landingAssist=landingAssist,
                    thrust=maxTotal>0 and total/maxTotal or 0, mask=lastAppliedMask, thrustOutput=thrustOutput, open=menuOpen})
            else
                SendNUIMessage({type='hud',visible=false})
                if menuOpen then closePanel() end
            end
        end
    end
end)

AddEventHandler('onClientResourceStop', function(name)
    if name ~= RESOURCE then return end
    stopChase()
    if menuOpen then closePanel() end
    for vehicle in pairs(emitters) do stopEffects(vehicle) end
    local veh = driverVehicle()
    if veh ~= 0 then transmit(veh, 0, true) end
    if targetRegistered and GetResourceState('ox_target') == 'started' then
        exports.ox_target:removeGlobalVehicle({'rs_thrusters:install','rs_thrusters:refill'})
    end
end)

print(('[rs-thrusters] client v%s loaded | /rstdiag for live diagnostics'):format(Config.Version))
