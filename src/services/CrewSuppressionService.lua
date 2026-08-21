require("_header")
require("services.Services")
require("core.Constants")
require("entities.Battery")
require("services.AaaService")
require("services.BatteryActivationService")
require("services.ManpadService")
require("services.MetricsService")

Medusa.Services.CrewSuppressionService = {}

do
	local C = Medusa.Constants
	local Battery = Medusa.Entities.Battery
	local AaaService = Medusa.Services.AaaService
	local BatteryActivationService = Medusa.Services.BatteryActivationService
	local ManpadService = Medusa.Services.ManpadService
	local MetricsService = Medusa.Services.MetricsService
	local batteryBuffer = {}
	local recoverBattery

	local function labels(ctx, valueName, value)
		return { network = ctx.networkId, [valueName] = value }
	end

	local function recordDrop(ctx, reason)
		MetricsService.inc("medusa_crew_suppression_dropped_events_total", nil, labels(ctx, "reason", reason))
	end

	local function isSuppressibleBattery(battery)
		return battery
			and (battery.Role == C.BatteryRole.AAA or battery.Role == C.BatteryRole.MANPAD)
			and battery.OperationalStatus ~= C.BatteryOperationalStatus.DESTROYED
	end

	local function isEnabled(ctx)
		return ctx.doctrine.CrewSuppression.Enabled
	end

	local function getEligibilityDropReason(ctx, battery)
		if not isSuppressibleBattery(battery) then
			return C.CrewSuppressionDropReason.UNMANAGED_TARGET
		end
		local diameter = battery.GroupDiameterM
		if type(diameter) ~= "number" or diameter ~= diameter or diameter < 0 or diameter == math.huge then
			return C.CrewSuppressionDropReason.GROUP_DIAMETER_UNAVAILABLE
		end
		local maxDiameter = ctx.doctrine.CrewSuppression.MaxGroupDiameterM
		if diameter >= maxDiameter then
			return C.CrewSuppressionDropReason.GROUP_DIAMETER_EXCEEDED
		end
		return nil
	end

	local function isSuppressibleUnit(unit)
		if not unit then
			return false
		end
		return Battery.unitHasRole(unit, C.BatteryUnitRole.AAA) or Battery.unitHasRole(unit, C.BatteryUnitRole.MANPAD)
	end

	local function cancelRecovery(battery)
		if not battery.CrewSuppressionTimerId then
			return false
		end
		CancelSchedule(battery.CrewSuppressionTimerId)
		battery.CrewSuppressionTimerId = nil
		return true
	end

	local function scheduleRecovery(ctx, battery, now)
		local batteryId = battery.BatteryId
		local delay = math.max(0, battery.CrewSuppressionUntil - now)
		local timerId
		timerId = ScheduleOnce(function()
			local current = ctx.batteryRepository:get(batteryId)
			if not current or current.CrewSuppressionTimerId ~= timerId then
				return
			end
			current.CrewSuppressionTimerId = nil
			local callbackNow = GetTime()
			if callbackNow < current.CrewSuppressionUntil and scheduleRecovery(ctx, current, callbackNow) then
				return
			end
			recoverBattery(ctx, current, callbackNow)
		end, nil, delay)
		if not timerId then
			recordDrop(ctx, C.CrewSuppressionDropReason.RECOVERY_TIMER)
			return false
		end
		battery.CrewSuppressionTimerId = timerId
		return true
	end

	local function stopBatteryResponse(ctx, battery, now)
		Battery.clearLastChance(battery)
		if battery.Role == C.BatteryRole.AAA then
			AaaService.suppressBattery(ctx, battery)
		elseif battery.Role == C.BatteryRole.MANPAD then
			ManpadService.suppressBattery(battery)
		end
		if not BatteryActivationService.goCrewSuppressed(battery, now, ctx.trackStore) then
			recordDrop(ctx, C.CrewSuppressionDropReason.CONTROLLER_UNAVAILABLE)
		end
	end

	recoverBattery = function(ctx, battery, now)
		if not Battery.isCrewSuppressed(battery) then
			return false
		end
		local cause = battery.CrewSuppressionCause
		Battery.clearCrewSuppression(battery)
		if battery.Role == C.BatteryRole.MANPAD then
			ManpadService.recoverFromCrewSuppression(battery, now)
		end
		MetricsService.inc(
			"medusa_crew_suppression_recoveries_total",
			nil,
			labels(ctx, "cause", cause or C.CrewSuppressionCause.DAMAGE)
		)
		return true
	end

	function Medusa.Services.CrewSuppressionService.apply(ctx, battery, cause, durationSec)
		if not isEnabled(ctx) then
			return false
		end
		local eligibilityDropReason = getEligibilityDropReason(ctx, battery)
		if eligibilityDropReason then
			recordDrop(ctx, eligibilityDropReason)
			return false
		end
		if
			C.CrewSuppressionCause[cause] ~= cause
			or type(durationSec) ~= "number"
			or durationSec ~= durationSec
			or durationSec <= 0
			or durationSec == math.huge
			or durationSec > C.CrewSuppression.MAX_DAMAGE_DURATION_SEC
		then
			return false
		end
		local now = ctx.now or GetTime()
		local deadline = now + durationSec
		Battery.applyCrewSuppression(battery, cause, deadline)
		local effectiveDuration = battery.CrewSuppressionUntil - now
		stopBatteryResponse(ctx, battery, now)
		local active = battery.CrewSuppressionTimerId ~= nil or scheduleRecovery(ctx, battery, now)
		if not active then
			recoverBattery(ctx, battery, now)
		end
		local metricLabels = labels(ctx, "cause", cause)
		MetricsService.inc("medusa_crew_suppression_applications_total", nil, metricLabels)
		MetricsService.observe("medusa_crew_suppression_duration_seconds", effectiveDuration, metricLabels)
		return active
	end

	local function applyDamage(ctx, battery)
		return Medusa.Services.CrewSuppressionService.apply(
			ctx,
			battery,
			C.CrewSuppressionCause.DAMAGE,
			ctx.doctrine.CrewSuppression.DamageDurationSec
		)
	end

	function Medusa.Services.CrewSuppressionService.processDamage(ctx, unitId)
		if not isEnabled(ctx) then
			return false
		end
		local battery, unit = ctx.batteryRepository:getByUnitId(unitId)
		if not isSuppressibleUnit(unit) or not unit.UnitName then
			recordDrop(ctx, C.CrewSuppressionDropReason.UNMANAGED_TARGET)
			return false
		end
		local eligibilityDropReason = getEligibilityDropReason(ctx, battery)
		if eligibilityDropReason then
			recordDrop(ctx, eligibilityDropReason)
			return false
		end
		local health = GetUnitHealth(unit.UnitName)
		if not health then
			recordDrop(ctx, C.CrewSuppressionDropReason.INVALID_HEALTH)
			return false
		end
		if not health.IsAlive then
			return false
		end

		local previousLife = unit.LastKnownLife or unit.InitialLife or health.InitialLife
		unit.LastKnownLife = health.CurrentLife
		unit.InitialLife = health.InitialLife or unit.InitialLife
		unit.InitialDamagePending = false
		if unit.InitialLife and health.CurrentLife < unit.InitialLife then
			unit.OperationalStatus = C.UnitOperationalStatus.DAMAGED
		else
			unit.OperationalStatus = C.UnitOperationalStatus.ACTIVE
		end
		local damaged = previousLife ~= nil and health.CurrentLife < previousLife
		if not damaged then
			return false
		end
		return applyDamage(ctx, battery)
	end

	function Medusa.Services.CrewSuppressionService.applyInitialDamage(ctx, battery)
		if not isEnabled(ctx) then
			return false
		end
		local found = false
		for i = 1, #(battery.Units or {}) do
			local unit = battery.Units[i]
			if unit.InitialDamagePending and isSuppressibleUnit(unit) then
				unit.InitialDamagePending = false
				found = true
			end
		end
		if not found then
			return false
		end
		return applyDamage(ctx, battery)
	end

	function Medusa.Services.CrewSuppressionService.cancelRecovery(battery)
		return cancelRecovery(battery)
	end

	function Medusa.Services.CrewSuppressionService.stop(ctx)
		local batteries = ctx.batteryRepository:getAll(batteryBuffer)
		for i = 1, #batteries do
			cancelRecovery(batteries[i])
		end
	end

	function Medusa.Services.CrewSuppressionService.resume(ctx)
		local now = GetTime()
		local batteries = ctx.batteryRepository:getAll(batteryBuffer)
		for i = 1, #batteries do
			local battery = batteries[i]
			if Battery.isCrewSuppressed(battery) then
				if
					not isEnabled(ctx)
					or battery.CrewSuppressionUntil <= now
					or not scheduleRecovery(ctx, battery, now)
				then
					recoverBattery(ctx, battery, now)
				end
			end
		end
	end
end
