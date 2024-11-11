---@ext:basic

local BTN_F0 = const(ui.ButtonFlags.PressedOnClick)
local BTN_FA = const(bit.bor(ui.ButtonFlags.Active, ui.ButtonFlags.PressedOnClick))
local BTN_FN = const(function (active) return active and BTN_FA or BTN_F0 end)

local car = ac.getCar(0) or error()
local sim = ac.getSim()

if not ac.getCarGearLabel then
  ac.getCarGearLabel = function (index)
    local gear = index == 0 and car.gear or ac.getCar(index).gear
    return gear < 0 and 'R' or gear == 0 and 'N' or tostring(gear)
  end
end

local lastShiftTime = os.preciseClock()
local lastShiftDownTime = os.preciseClock()
local lastShiftUpTime = os.preciseClock()
local waitTimeBetweenDownShifts = 2
local idleRPM = car.rpm -- get idle RPM during initialisation
local slipping = false

local gasThresholds = {
  {0, 0, 0, 0},        -- manual
  {0.95, 0.4, 12, 0.15}, -- auto: normal
  {0.8, 0.4, 24, 0.5},   -- auto: sport
  {1, 0.5, 6, 0}         -- auto: eco
}

local c = {
  maxShiftRPM = car.rpmLimiter * 0.95,
  rpmRange = (car.rpmLimiter - idleRPM) / 3,
  rpmRangeTop = 0,
  rpmRangeBottom = 0,
  aggressiveness = 0,
  lastIncrementalAggressivenessTime = 0,
}

local btnAutofill = vec2(-0.1, 0)

local controls = ac.overrideCarControls()

local driveMode = 1
local modes = {"Manual", "Auto: Normal", "Auto: Sport", "Auto: Eco"}

local function changeDriveMode()
  if driveMode == 1 then
    driveMode = 0
  elseif driveMode == 0 then
    driveMode = 1
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

local function getInfoAboutCarState()
  ui.text(car.rpm)
  ui.text(car.gas)
  ui.text(car.gear)
  ui.text(car.brake)
  ui.text(ac.getCarSpeedKmh(0))
end

local function analyzeInput(deltaT)

  local gas = car.gas
  local brake = car.brake
  local gear = car.gear

  local new_aggr = math.min(
      1,
      math.max(
          (gas - gasThresholds[driveMode + 1][2]) /
          (gasThresholds[driveMode + 1][1] - gasThresholds[driveMode + 1][2]),
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

  ui.text(string.format(
    "Aggressiveness: %.2f\nRpm Top: %.0f\nRpm Bottom: %.0f",
    c.aggressiveness,
    c.rpmRangeTop,
    c.rpmRangeBottom
  ))
end

local function makeDecision()
  local gas = car.gas
  local brake = car.brake
  local gear = car.gear
  local rpm = car.rpm

  waitTimeBetweenDownShifts = brake > 0 and 1 or 2
  local time = os.preciseClock()
  if time < lastShiftTime + 0.1 or
     gear < 1 or
     time < lastShiftUpTime + 1 or
     time < lastShiftDownTime + waitTimeBetweenDownShifts then
      return
  end

  if rpm > c.rpmRangeTop and
     not slipping and
     time > lastShiftDownTime + 1 and
     brake == 0 and
     gas > 0 then
      shiftUp()
  elseif rpm < c.rpmRangeBottom and
         not slipping and
         gear > 1 and
         time > lastShiftDownTime + waitTimeBetweenDownShifts and
         (gear > 2 or
          (gear == 2 and (c.aggressiveness >= 0.95 or ac.getCarSpeedKmh(0) <= 15)) or
          (gear >= 4 and brake > 0)) then
      shiftDown()
  end
end


-- car.rpm > car.rpmLimiter

-- if w4 < 60 then
--   if ui.iconButton(ui.Icons.Down, vec2(ui.availableSpaceX() / 2 - 2, 0), 6, true, BTN_F0) then controls.gearDown = true end
--   bindingInfoTooltip('GEARDN', 'Previous gear')
--   ui.sameLine(0, 4)
--   if ui.iconButton(ui.Icons.Up, btnAutofill, 6, true, BTN_F0) then controls.gearUp = true end
--   bindingInfoTooltip('GEARUP', 'Next gear')
-- else
--   if ui.button('Previous gear', vec2(ui.availableSpaceX() / 2 - 2, 0), BTN_F0) then controls.gearDown = true end
--   bindingInfoTooltip('GEARDN', 'Previous gear')
--   ui.sameLine(0, 4)
--   if ui.button('Next gear', btnAutofill, BTN_F0) then controls.gearUp = true end
--   bindingInfoTooltip('GEARUP', 'Next gear')
-- end
-- if ui.button('Neutral gear', btnAutofill, BTN_F0) then ac.switchToNeutralGear() end
-- bindingInfoTooltip('__EXT_GEAR_NEUTRAL', 'Quickly reset to the neutral gear')
-- ui.endGroup()

local autopilot = 0
local controlsBindings = {}
local controlsConfig = ac.INIConfig.controlsConfig()

local function bindingInfoGen(section)
  local pieces = section:split(';')
  if #pieces > 1 then
    local r = {}
    for _, v in ipairs(pieces) do
      local p = string.split(v, ':', 2, true)
      local i = bindingInfoGen(p[2])
      if string.regfind(i, '^(?:Not |Keyboard:|Gamepad:)') then i = i:sub(1, 1):lower()..i:sub(2) end
      r[#r + 1] = p[1]..': '..i:replace('\n', '\n\t')
    end
    return table.concat(r, '\n')
  end

  local entries = {}
  local baseSection = section
  section = string.reggsub(section, '\\W+', '')

  if baseSection:endsWith('$') then
    return 'Keyboard: '..baseSection:sub(1, #baseSection - 1)
  end
  
  if section:startsWith('_') or sim.inputMode == ac.UserInputMode.Keyboard or controlsConfig:get('ADVANCED', 'COMBINE_WITH_KEYBOARD_CONTROL', true) then
    local k = controlsConfig:get(section, 'KEY', -1)
    if k > 0 then
      local modifiers = table.map(controlsConfig:get(section, 'KEY_MODIFICATOR', nil) or {}, function (v)
        if v == '' then return nil end
        if tonumber(v) == 16 then return 'Shift' end
        if tonumber(v) == 17 then return 'Ctrl' end
        if tonumber(v) == 18 then return 'Alt' end
        return '<'..v..'>'
      end)
      if #modifiers == 0 and baseSection:endsWith('!') then
        table.insert(modifiers, 'Ctrl')
      end

      local m
      for n, v in pairs(ac.KeyIndex) do
        if v == k then
          m = n
          break
        end
      end 

      table.insert(modifiers, m or string.char(k))
      entries[#entries + 1] = 'Keyboard: '..table.concat(modifiers, '+')
    end
  end

  if sim.inputMode == ac.UserInputMode.Gamepad then
    local x = controlsConfig:get(section, 'XBOXBUTTON', '')
    if x ~= '' and (tonumber(x) or 1) > 0 then
      entries[#entries + 1] = 'Gamepad: '..x
    end
  end

  local j = controlsConfig:get(section, 'JOY', -1)
  if j >= 0 then
    local n = controlsConfig:get('CONTROLLERS', 'CON'..j, 'Unknown device')
    local d = controlsConfig:get(section, 'BUTTON', -1)
    if d >= 0 and (tonumber(x) or 1) > 0 then
      -- if #n > 28 then n = n:sub(1, 27)..'…' end
      local m = controlsConfig:get(section, 'BUTTON_MODIFICATOR', -1)
      if m >= 0 then
        -- TODO: JOY_MODIFICATOR
        entries[#entries + 1] = n..': buttons #'..(m + 1)..'+'..(d + 1)
      else
        entries[#entries + 1] = n..': button #'..(d + 1)
      end
    else
      local p = controlsConfig:get(section, '__CM_POV', -1)
      if p >= 0 then
        local dir = {[0] = '←', [1] = '↑', [2] = '→', [3] = '↓'}
        entries[#entries + 1] = n..': D-pad #'..(p + 1)..(dir[controlsConfig:get(section, '__CM_POV_DIR', -1)] or '')
      end
    end
  end

  if #entries == 0 then
    return 'Not bound to anything'
  else
    return table.concat(entries, '\n')
  end
end

local function bindingInfo(section)
  return table.getOrCreate(controlsBindings, section, bindingInfoGen, section)
end

local function bindingInfoTooltip(section, prefix)
  if ui.itemHovered() then
    ui.tooltip(function ()
      if prefix then
        ui.pushFont(ui.Font.Main)
        ui.textWrapped(prefix, 500)
        ui.popFont()
        ui.offsetCursorY(4)
      end
      ui.pushFont(ui.Font.Small)
      ui.textWrapped(bindingInfo(section), 500)
      ui.popFont()
    end)
  end
end

function script.windowMain(dt)
  local notAvailable = not car.isUserControlled and autopilot == 0 or sim.isReplayActive
  if notAvailable then
    ui.pushDisabled()
  end
  
  if ui.iconButton(ui.Icons.Down, vec2(ui.availableSpaceX() / 2 - 2, 0), 6, true, BTN_F0) then shiftDown() end
  bindingInfoTooltip('GEARDN', 'Previous gear')
  ui.sameLine(0, 4)
  if ui.iconButton(ui.Icons.Up, btnAutofill, 6, true, BTN_F0) then shiftUp() end
  bindingInfoTooltip('GEARUP', 'Next gear')

  getInfoAboutCarState()
  analyzeInput(dt)
  makeDecision()
end
