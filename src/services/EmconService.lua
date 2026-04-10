require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")
require("services.BatteryActivationService")

--[[
            ███████╗███╗   ███╗ ██████╗ ██████╗ ███╗   ██╗    ███████╗███████╗██████╗ ██╗   ██╗██╗ ██████╗███████╗
            ██╔════╝████╗ ████║██╔════╝██╔═══██╗████╗  ██║    ██╔════╝██╔════╝██╔══██╗██║   ██║██║██╔════╝██╔════╝
            █████╗  ██╔████╔██║██║     ██║   ██║██╔██╗ ██║    ███████╗█████╗  ██████╔╝██║   ██║██║██║     █████╗
            ██╔══╝  ██║╚██╔╝██║██║     ██║   ██║██║╚██╗██║    ╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██║██║     ██╔══╝
            ███████╗██║ ╚═╝ ██║╚██████╗╚██████╔╝██║ ╚████║    ███████║███████╗██║  ██║ ╚████╔╝ ██║╚██████╗███████╗
            ╚══════╝╚═╝     ╚═╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝    ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚═╝ ╚═════╝╚══════╝

    What this service does
    - Decides which batteries and sensors should have radars on based on doctrine EMCON policy.
    - Supports MINIMIZE, ALWAYS_ON, PERIODIC_SCAN, and COORDINATED_ROTATION schedules.
    - Manages SAM-as-EWR promotion when no dedicated EWR sensors are available.

    How others use it
    - IadsNetwork calls applyPolicy each tick to enforce EMCON across all batteries and sensor groups.
--]]

Medusa.Services.EmconService = {}

local _logger = Medusa.Logger:ns("EmconService")
Medusa.Services.EmconService._batteryBuffer = {}
local _batteryBuffer = Medusa.Services.EmconService._batteryBuffer
Medusa.Services.EmconService._sensorBuffer = {}
local _sensorBuffer = Medusa.Services.EmconService._sensorBuffer
Medusa.Services.EmconService._sensorGroupState = {}
local _sensorGroupState = Medusa.Services.EmconService._sensorGroupState
local AS = Medusa.Constants.ActivationState
local BOS = Medusa.Constants.BatteryOperationalStatus
local ECP = Medusa.Constants.EmissionControlPolicy
local C = Medusa.Constants
local BatteryActivationService = Medusa.Services.BatteryActivationService

local SENSOR_ROLES = { EWR = true, GCI = true }
local _minimizeWarned = {}

function Medusa.Services.EmconService.getDesiredState(batteryIndex, _batteryCount, doctrine, now, role)
	local policy = doctrine.EMCON and doctrine.EMCON[role] or C.EMCON_DEFAULT_POLICY_BY_ROLE[role]

	if policy == ECP.MINIMIZE and SENSOR_ROLES[role] then
		if not _minimizeWarned[role] then
			_logger:error(
				string.format(
					"EMCON MINIMIZE on %s role would disable all sensor input, making the IADS non-functional. Forcing ALWAYS_ON",
					role
				)
			)
			_minimizeWarned[role] = true
		end
		policy = ECP.ALWAYS_ON
	end

	if policy == ECP.MINIMIZE then
		return AS.STATE_COLD
	end

	if policy == ECP.ALWAYS_ON then
		return AS.STATE_WARM
	end

	if policy == ECP.PERIODIC_SCAN then
		local scanDur = doctrine.ScanSec or C.EMCON_DEFAULT_SCAN_DURATION_SEC
		local quietDur = doctrine.QuietPeriodSec or C.EMCON_DEFAULT_QUIET_PERIOD_SEC
		local cycleDur = scanDur + quietDur
		if cycleDur <= 0 then
			return AS.STATE_WARM
		end
		local cyclePos = now % cycleDur
		if cyclePos < scanDur then
			return AS.STATE_WARM
		end
		return AS.STATE_COLD
	end

	if policy == ECP.COORDINATED_ROTATION then
		local interval = doctrine.ScanSec or C.EMCON_DEFAULT_SCAN_DURATION_SEC
		local quietDur = doctrine.QuietPeriodSec or 0
		local numGroups = doctrine.EmconRotateGroups or C.EMCON_DEFAULT_ROTATION_GROUPS
		if numGroups <= 0 then
			return AS.STATE_WARM
		end
		-- Each slot = radiate + quiet. Cycle = numGroups * (interval + quiet)
		local slotDur = interval + quietDur
		local cycleDur = numGroups * slotDur
		local cyclePos = now % cycleDur
		local currentSlot = math.floor(cyclePos / slotDur)
		local posInSlot = cyclePos - currentSlot * slotDur
		-- Quiet period is the tail of each slot
		if posInSlot >= interval then
			return AS.STATE_COLD
		end
		local group = (batteryIndex - 1) % numGroups
		if group == currentSlot then
			return AS.STATE_WARM
		end
		return AS.STATE_COLD
	end

	-- INTELLIGENT_EMCON and unknown/nil policies default to WARM
	return AS.STATE_WARM
end

local function _shouldSkip(battery)
	if battery.CurrentTargetTrackId then
		return true
	end
	if battery.LastChanceTrackId then
		return true
	end
	if battery.ActivationState == AS.INITIALIZING then
		return true
	end
	if battery.OperationalStatus == BOS.DESTROYED or battery.OperationalStatus == BOS.INOPERATIVE then
		return true
	end
	if battery.HarmShutdownUntil then
		return true
	end
	return false
end

local function _isEwrEligible(battery)
	if not C.SAM_AS_EWR_ELIGIBLE_ROLES[battery.Role] then
		return false
	end
	local s = battery.OperationalStatus
	if s ~= BOS.ACTIVE and s ~= BOS.SEARCH_ONLY then
		return false
	end
	if battery.CurrentTargetTrackId or battery.HarmShutdownUntil then
		return false
	end
	return battery.Position ~= nil
end

local function _isSamAsEwrActive(doctrine, sensorStore)
	local policy = doctrine.SAMAsEWR or "DISABLED"
	if policy == "DISABLED" then
		return false
	end
	if policy == "WHEN_NO_EWR" and sensorStore and sensorStore:count() > 0 then
		return false
	end
	return true
end

--- Logs the EMCON rotation schedule so operators can verify group assignments.
function Medusa.Services.EmconService.logSchedule(ctx)
	local batteryStore = ctx.batteryStore
	local sensorStore = ctx.sensorStore
	local doctrine = ctx.doctrine
	local numGroups = doctrine.EmconRotateGroups or C.EMCON_DEFAULT_ROTATION_GROUPS
	local interval = doctrine.ScanSec or C.EMCON_DEFAULT_SCAN_DURATION_SEC
	local quietDur = doctrine.QuietPeriodSec or 0

	-- Collect sensors in COORDINATED_ROTATION by group
	local sensorGroups = sensorStore and sensorStore:getUniqueGroupNames() or {}
	local groups = {}
	for g = 0, numGroups - 1 do
		groups[g] = {}
	end
	local hasRotation = false
	for i = 1, #sensorGroups do
		local sensors = sensorStore:getByGroupName(sensorGroups[i], _sensorBuffer)
		local sensorType = sensors and sensors[1] and sensors[1].SensorType or "EWR"
		local policy = doctrine.EMCON and doctrine.EMCON[sensorType] or C.EMCON_DEFAULT_POLICY_BY_ROLE[sensorType]
		if policy == ECP.COORDINATED_ROTATION then
			local g = (i - 1) % numGroups
			groups[g][#groups[g] + 1] = sensorGroups[i]
			hasRotation = true
		end
	end

	-- Collect SAM-as-EWR batteries in COORDINATED_ROTATION
	local batteries = batteryStore:getAll(_batteryBuffer)
	for i = 1, #batteries do
		local b = batteries[i]
		if b.IsActingAsEWR then
			local policy = doctrine.EMCON and doctrine.EMCON["EWR"] or C.EMCON_DEFAULT_POLICY_BY_ROLE["EWR"]
			if policy == ECP.COORDINATED_ROTATION then
				local g = (i - 1) % numGroups
				groups[g][#groups[g] + 1] = b.GroupName
				hasRotation = true
			end
		end
	end

	if not hasRotation then
		return
	end

	local parts = {}
	for g = 0, numGroups - 1 do
		parts[#parts + 1] = string.format("  Group %d: [%s]", g, table.concat(groups[g], ", "))
	end
	local slotDur = interval + quietDur
	local cycleDur = numGroups * slotDur
	local quietStr = quietDur > 0 and string.format(", %ds quiet between groups", quietDur) or ""
	_logger:info(
		string.format(
			"COORDINATED_ROTATION schedule (%d groups, %ds radiate%s, %ds cycle):\n%s",
			numGroups,
			interval,
			quietStr,
			cycleDur,
			table.concat(parts, "\n")
		)
	)
end

function Medusa.Services.EmconService.applyPolicy(ctx, network)
	local batteryStore = ctx.batteryStore
	local sensorStore = ctx.sensorStore
	local doctrine = ctx.doctrine
	local now = ctx.now
	local batteries = batteryStore:getAll(_batteryBuffer)
	local count = #batteries
	local transitions = 0
	local ewrActive = _isSamAsEwrActive(doctrine, sensorStore)

	local sensorCount = sensorStore and sensorStore:count() or 0
	local ewrBatteryCount = 0
	for i = 1, count do
		if ewrActive and _isEwrEligible(batteries[i]) then
			ewrBatteryCount = ewrBatteryCount + 1
		end
	end
	local totalSensorCount = sensorCount + ewrBatteryCount

	if network then
		local lastCount = network._emconLastSensorCount
		if lastCount ~= nil and totalSensorCount ~= lastCount then
			_logger:info(
				string.format("sensor pool changed (%d -> %d), rebuilding rotation groups", lastCount, totalSensorCount)
			)
			Medusa.Services.EmconService.logSchedule(ctx)
		end
		network._emconLastSensorCount = totalSensorCount
	end

	for i = 1, count do
		local battery = batteries[i]

		-- SAM-as-EWR: set or clear flag based on policy and eligibility (LR_SAM and MR_SAM only)
		if ewrActive and _isEwrEligible(battery) then
			battery.IsActingAsEWR = true
		else
			battery.IsActingAsEWR = false
		end

		if not _shouldSkip(battery) then
			local desired
			if battery.IsActingAsEWR then
				desired = Medusa.Services.EmconService.getDesiredState(i, count, doctrine, now, "EWR")
			else
				desired = Medusa.Services.EmconService.getDesiredState(i, count, doctrine, now, battery.Role)
			end
			local ok = false
			if desired == AS.STATE_WARM and battery.ActivationState ~= AS.STATE_WARM then
				ok = BatteryActivationService.goWarm(battery, now)
			elseif desired == AS.STATE_COLD and battery.ActivationState ~= AS.STATE_COLD then
				ok = BatteryActivationService.goCold(battery, now)
			end
			if ok then
				transitions = transitions + 1
			end
		end
	end

	-- Sensor EMCON: control EWR/GCI groups independently by their SensorType
	-- Airborne sensors (AWACS) are exempt from EMCON and always emit
	local sensorGroups = sensorStore and sensorStore:getUniqueGroupNames() or {}
	for i = 1, #sensorGroups do
		local groupName = sensorGroups[i]
		local sensors = sensorStore:getByGroupName(groupName, _sensorBuffer)
		local isAirborne = sensors and sensors[1] and sensors[1].IsAirborne
		if isAirborne then
			_sensorGroupState[groupName] = AS.STATE_WARM
			for si = 1, #sensors do
				sensors[si].RadarStatus = "ACTIVE"
			end
		else
			local sensorType = sensors and sensors[1] and sensors[1].SensorType or "EWR"
			local desired = Medusa.Services.EmconService.getDesiredState(i, #sensorGroups, doctrine, now, sensorType)
			local currentState = _sensorGroupState[groupName] or AS.STATE_WARM
			if desired ~= currentState then
				local controller = GetGroupController(groupName)
				if controller then
					if desired == AS.STATE_WARM then
						SetControllerOnOff(controller, true)
					else
						SetControllerOnOff(controller, false)
					end
					_sensorGroupState[groupName] = desired
					transitions = transitions + 1
				end
			end
			local effectiveState = _sensorGroupState[groupName] or currentState
			local radarStatus = (effectiveState == AS.STATE_WARM) and "ACTIVE" or "DARK"
			for si = 1, #sensors do
				sensors[si].RadarStatus = radarStatus
			end
		end
	end

	if transitions > 0 then
		_logger:info(string.format("applied %d EMCON transitions", transitions))
	end
	return transitions
end
