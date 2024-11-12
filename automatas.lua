---@ext:basic
local car = ac.getCar(0) or error()
local sim = ac.getSim()

local lastShiftTime = os.preciseClock()
local lastShiftDownTime = os.preciseClock()
local lastShiftUpTime = os.preciseClock()
local waitTimeBetweenDownShifts = 2
local idleRPM = car.rpm -- get idle RPM during initialisation
local slipping = false
local MAX_SHIFT_RPM_MULTIPLIER = 0.95
local gasThresholds = {
  { 0,    0,   0,  0 },    -- manual
  { 0.95, 0.4, 12, 0.15 }, -- auto: normal
  { 0.8,  0.4, 24, 0.5 },  -- auto: sport
  { 1,    0.5, 6,  0 }     -- auto: eco
}

local c = {
  maxShiftRPM = car.rpmLimiter * MAX_SHIFT_RPM_MULTIPLIER,
  rpmRange = (car.rpmLimiter - idleRPM) / 3,
  rpmRangeTop = 0,
  rpmRangeBottom = 0,
  aggressiveness = 0,
  lastIncrementalAggressivenessTime = 0,
}

local controls = ac.overrideCarControls()

local BRAKING_SHIFT_TIME = 1
local ACCELERATION_SHIFT_TIME = 1.5 -- 1.5
local SHIFT_UP_MODIFIER = 0.6
local MINIMUM_FIRST_GEAR_SPEED = 50

local driveMode = 0
local modes = { "Manual", "Auto: Normal", "Auto: Sport", "Auto: Eco" }

local function changeDriveMode()
  driveMode = (driveMode or 0) + 1
  if driveMode > 3 then
    driveMode = 0
  end
end

local function shiftUp()
  controls.gearUp = true
  lastShiftTime = os.preciseClock()
  lastShiftUpTime = lastShiftTime
end

local function shiftDown()
  controls.gearDown = true
  lastShiftTime = os.preciseClock()
  lastShiftDownTime = lastShiftTime
end

local function analyzeInput(deltaT)
  local gas = car.gas
  local brake = car.brake
  local gear = car.gear

  local new_aggr = math.min(
    1,
    math.max(
      (gas - gasThresholds[driveMode + 1][2]) / (gasThresholds[driveMode + 1][1] - gasThresholds[driveMode + 1][2]),
      (brake - (gasThresholds[driveMode + 1][2] - 0.3)) /
      (gasThresholds[driveMode + 1][1] - gasThresholds[driveMode + 1][2]) * 1.6
    )
  )

  if new_aggr > c.aggressiveness and gear > 0 then
    c.aggressiveness = new_aggr
    c.lastIncrementalAggressivenessTime = os.preciseClock()
  end

  if os.preciseClock() > c.lastIncrementalAggressivenessTime + 2 then
    c.aggressiveness = c.aggressiveness - (deltaT / gasThresholds[driveMode + 1][3])
  end

  c.aggressiveness = math.max(
    c.aggressiveness,
    gasThresholds[driveMode + 1][4]
  )

  c.rpmRangeTop = idleRPM + 1000 + ((c.maxShiftRPM - idleRPM - 1000) * c.aggressiveness)
  c.rpmRangeBottom = math.max(
    idleRPM + (math.min(gear, 6) * 80),
    c.rpmRangeTop - c.rpmRange
  )
end

local function makeDecision()
  local time = os.preciseClock()
  local gas = car.gas
  local brake = car.brake
  local gear = car.gear
  local rpm = car.rpm
  waitTimeBetweenDownShifts = brake > 0 and BRAKING_SHIFT_TIME or ACCELERATION_SHIFT_TIME

  if time < lastShiftTime + 0.1 or
    gear < 1 or
    time < lastShiftUpTime + SHIFT_UP_MODIFIER or -- edit 1 for when car needs to shift up faster
    time < lastShiftDownTime + waitTimeBetweenDownShifts then -- edit waitTimeBetweenDownShifts for when car needs to shift up faster
    return
  end

  if rpm > c.rpmRangeTop and
      not slipping and
      time > lastShiftDownTime + SHIFT_UP_MODIFIER and -- modify +1 for when car needs to shift up faster
      brake == 0 and
      gas > 0 then
    shiftUp()
  elseif rpm < c.rpmRangeBottom and
      not slipping and
      gear > 1 and
      time > lastShiftDownTime + waitTimeBetweenDownShifts and
      (gear > 2 or
        (gear == 2 and ((c.aggressiveness >= 0.95 and ac.getCarSpeedKmh(0) <= MINIMUM_FIRST_GEAR_SPEED) or ac.getCarSpeedKmh(0) <= 15)) or
        (gear >= 4 and brake > 0)) then
    shiftDown()
  end
end

local function drawMaxRpmSlider()
  local value, changed = ui.slider("##maxShiftRPMSlider", MAX_SHIFT_RPM_MULTIPLIER, 0.8, 0.99, "Shift RPM: %.2f")
  if changed then
    MAX_SHIFT_RPM_MULTIPLIER = value
    c.maxShiftRPM = car.rpmLimiter * MAX_SHIFT_RPM_MULTIPLIER
  end
end

local function drawMin1stGearSpeed()
  ui.text("min km/h for 1st gear")
  local value, changed = ui.slider("##min1stGearSpeed", MINIMUM_FIRST_GEAR_SPEED, 15, 80, "KMH: %.0f")
  if changed then
    MINIMUM_FIRST_GEAR_SPEED = value
  end
end

function script.windowMain(dt)
  local notAvailable = not car.isUserControlled or sim.isReplayActive
  if notAvailable then
    ui.pushDisabled()
  end
  if driveMode > 0 then
    analyzeInput(dt)
    makeDecision()  
  end

  ui.text(string.format(
    "Aggressiveness: %.2f\nRpm Top: %.0f\nRpm Bottom: %.0f",
    c.aggressiveness,
    c.rpmRangeTop,
    c.rpmRangeBottom
  ))

  ui.text(string.format("RPM range: %.0f\nMaximum Shift RPM: %.0f\nMaximum RPM: %.0f", c.rpmRange, c.maxShiftRPM, car.rpmLimiter))
  ui.text(string.format("Time since last shift: %.3f", os.preciseClock() - lastShiftTime))

  drawMaxRpmSlider()
  drawMin1stGearSpeed()
  if ui.button(modes[driveMode + 1], vec2(-0.1, 0)) then
    changeDriveMode()
  end

  ui.text(string.format("Drive Mode: %s, %.0f", modes[driveMode + 1], driveMode))
end
