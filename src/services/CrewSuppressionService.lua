require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")
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
	local logger = Medusa.Logger:ns("CrewSuppressionService")
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

	local function sampleDuration(ctx)
		local policy = ctx.doctrine.CrewSuppression
		local random = ctx.random or math.random
		return policy.DurationMinSec + random() * (policy.DurationMaxSec - policy.DurationMinSec)
	end

	local function skillMultiplier(policy, unit)
		local skill = unit and unit.CrewSkill or policy.DefaultCrewSkill
		local level = C.CrewSkillLevel[skill]
		if level == nil then
			level = C.CrewSkillLevel[C.CrewSuppression.DEFAULT_CREW_SKILL]
		end
		local resistance = policy.SkillResistancePerLevel
		if type(resistance) ~= "number" then
			resistance = C.CrewSuppression.DEFAULT_SKILL_RESISTANCE_PER_LEVEL
		end
		return 1 - level * resistance
	end

	local function adjustedDuration(ctx, unit)
		return math.max(1, sampleDuration(ctx) * skillMultiplier(ctx.doctrine.CrewSuppression, unit))
	end

	local function distanceProbability(effectiveness, radiusM, distanceM)
		return math.max(0, math.min(1, effectiveness * (1 - distanceM / radiusM)))
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
			logger:debug(
				string.format(
					"battery %s recovery cancellation skipped: no timer",
					battery.GroupName or battery.BatteryId
				)
			)
			return false
		end
		local timerId = battery.CrewSuppressionTimerId
		CancelSchedule(battery.CrewSuppressionTimerId)
		battery.CrewSuppressionTimerId = nil
		logger:debug(
			string.format(
				"battery %s recovery timer cancelled: timerId=%s",
				battery.GroupName or battery.BatteryId,
				tostring(timerId)
			)
		)
		return true
	end

	local function scheduleRecovery(ctx, battery, now)
		local batteryId = battery.BatteryId
		local delay = math.max(0, battery.CrewSuppressionUntil - now)
		local timerId
		timerId = ScheduleOnce(function()
			local current = ctx.batteryRepository:get(batteryId)
			if not current then
				logger:debug(string.format("battery %s recovery callback ignored: battery unavailable", batteryId))
				return
			end
			if current.CrewSuppressionTimerId ~= timerId then
				logger:debug(
					string.format(
						"battery %s recovery callback ignored: stale timerId=%s",
						current.GroupName or current.BatteryId,
						tostring(timerId)
					)
				)
				return
			end
			current.CrewSuppressionTimerId = nil
			local callbackNow = GetTime()
			if callbackNow < current.CrewSuppressionUntil then
				logger:debug(
					string.format(
						"battery %s recovery callback early: remaining=%.3fs",
						current.GroupName or current.BatteryId,
						current.CrewSuppressionUntil - callbackNow
					)
				)
				if scheduleRecovery(ctx, current, callbackNow) then
					return
				end
			end
			recoverBattery(ctx, current, callbackNow)
		end, nil, delay)
		if not timerId then
			recordDrop(ctx, C.CrewSuppressionDropReason.RECOVERY_TIMER)
			logger:debug(string.format("battery %s recovery scheduling failed", battery.GroupName or battery.BatteryId))
			return false
		end
		battery.CrewSuppressionTimerId = timerId
		logger:debug(
			string.format(
				"battery %s recovery scheduled: timerId=%s delay=%.3fs",
				battery.GroupName or battery.BatteryId,
				tostring(timerId),
				delay
			)
		)
		return true
	end

	local function stopBatteryResponse(ctx, battery, now)
		logger:debug(
			string.format("battery %s stopping response for crew suppression", battery.GroupName or battery.BatteryId)
		)
		Battery.clearLastChance(battery)
		if battery.Role == C.BatteryRole.AAA then
			AaaService.suppressBattery(ctx, battery)
		elseif battery.Role == C.BatteryRole.MANPAD then
			ManpadService.suppressBattery(battery)
		end
		if not BatteryActivationService.goCrewSuppressed(battery, now, ctx.trackStore) then
			recordDrop(ctx, C.CrewSuppressionDropReason.CONTROLLER_UNAVAILABLE)
			logger:debug(
				string.format(
					"battery %s controller unavailable during crew suppression",
					battery.GroupName or battery.BatteryId
				)
			)
		end
	end

	recoverBattery = function(ctx, battery, now)
		if not Battery.isCrewSuppressed(battery) then
			logger:debug(
				string.format(
					"battery %s recovery ignored: suppression is clear",
					battery.GroupName or battery.BatteryId
				)
			)
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
		logger:info(
			string.format(
				"battery %s crew suppression recovered: cause=%s",
				battery.GroupName or battery.BatteryId,
				cause or C.CrewSuppressionCause.DAMAGE
			)
		)
		return true
	end

	function Medusa.Services.CrewSuppressionService.apply(ctx, battery, cause, durationSec)
		if not isEnabled(ctx) then
			logger:debug("crew suppression application ignored: doctrine disabled")
			return false
		end
		local eligibilityDropReason = getEligibilityDropReason(ctx, battery)
		if eligibilityDropReason then
			recordDrop(ctx, eligibilityDropReason)
			logger:debug(
				string.format(
					"battery %s crew suppression rejected: reason=%s",
					battery and (battery.GroupName or battery.BatteryId) or "unknown",
					eligibilityDropReason
				)
			)
			return false
		end
		if
			C.CrewSuppressionCause[cause] ~= cause
			or type(durationSec) ~= "number"
			or durationSec ~= durationSec
			or durationSec <= 0
			or durationSec == math.huge
			or durationSec > C.CrewSuppression.MAX_DURATION_SEC
		then
			logger:debug(
				string.format(
					"battery %s crew suppression rejected: invalid cause or duration",
					battery.GroupName or battery.BatteryId
				)
			)
			return false
		end
		local now = ctx.now or GetTime()
		local deadline = now + durationSec
		local wasSuppressed = Battery.isCrewSuppressed(battery)
		local previousDeadline = battery.CrewSuppressionUntil
		Battery.applyCrewSuppression(battery, cause, deadline)
		local effectiveDuration = battery.CrewSuppressionUntil - now
		local batteryName = battery.GroupName or battery.BatteryId
		if not wasSuppressed then
			logger:info(
				string.format(
					"battery %s crew suppressed: cause=%s, duration=%.0fs",
					batteryName,
					cause,
					effectiveDuration
				)
			)
		elseif previousDeadline and battery.CrewSuppressionUntil > previousDeadline then
			logger:info(
				string.format(
					"battery %s crew suppression extended: cause=%s, duration=%.0fs",
					batteryName,
					cause,
					effectiveDuration
				)
			)
		else
			logger:info(
				string.format(
					"battery %s crew suppression reapplied: cause=%s, remaining=%.0fs",
					batteryName,
					cause,
					effectiveDuration
				)
			)
		end
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

	local function applyDamage(ctx, battery, unit)
		return Medusa.Services.CrewSuppressionService.apply(
			ctx,
			battery,
			C.CrewSuppressionCause.DAMAGE,
			adjustedDuration(ctx, unit)
		)
	end

	function Medusa.Services.CrewSuppressionService.processMemberDestruction(ctx, battery, unit)
		if not isSuppressibleUnit(unit) then
			logger:debug(
				string.format(
					"battery %s member destruction ignored: unitId=%s is not suppressible",
					battery and (battery.GroupName or battery.BatteryId) or "unknown",
					tostring(unit and unit.UnitId)
				)
			)
			return false
		end
		logger:debug(
			string.format(
				"battery %s processing suppressible member destruction: unitId=%s",
				battery.GroupName or battery.BatteryId,
				tostring(unit.UnitId)
			)
		)
		return applyDamage(ctx, battery, unit)
	end

	function Medusa.Services.CrewSuppressionService.processDamage(ctx, unitId)
		if not isEnabled(ctx) then
			logger:debug(string.format("damage evaluation ignored: unitId=%s doctrine disabled", tostring(unitId)))
			return false
		end
		local battery, unit = ctx.batteryRepository:getByUnitId(unitId)
		if not isSuppressibleUnit(unit) or not unit.UnitName then
			recordDrop(ctx, C.CrewSuppressionDropReason.UNMANAGED_TARGET)
			logger:debug(string.format("damage evaluation rejected: unitId=%s is not managed", tostring(unitId)))
			return false
		end
		local eligibilityDropReason = getEligibilityDropReason(ctx, battery)
		if eligibilityDropReason then
			recordDrop(ctx, eligibilityDropReason)
			logger:debug(
				string.format(
					"battery %s damage evaluation rejected: unitId=%s reason=%s",
					battery.GroupName or battery.BatteryId,
					tostring(unitId),
					eligibilityDropReason
				)
			)
			return false
		end
		local health = GetUnitHealth(unit.UnitName)
		if not health then
			recordDrop(ctx, C.CrewSuppressionDropReason.INVALID_HEALTH)
			logger:debug(
				string.format(
					"battery %s damage evaluation: unitId=%s health unavailable",
					battery.GroupName or battery.BatteryId,
					tostring(unitId)
				)
			)
			return false
		end
		if not health.IsAlive then
			logger:debug(
				string.format(
					"battery %s damage evaluation: unitId=%s is not alive",
					battery.GroupName or battery.BatteryId,
					tostring(unitId)
				)
			)
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
			logger:debug(
				string.format(
					"battery %s damage evaluation unchanged: unitId=%s previousLife=%s currentLife=%s",
					battery.GroupName or battery.BatteryId,
					tostring(unitId),
					tostring(previousLife),
					tostring(health.CurrentLife)
				)
			)
			return false
		end
		logger:debug(
			string.format(
				"battery %s new damage detected: unitId=%s previousLife=%s currentLife=%s",
				battery.GroupName or battery.BatteryId,
				tostring(unitId),
				tostring(previousLife),
				tostring(health.CurrentLife)
			)
		)
		return applyDamage(ctx, battery, unit)
	end

	function Medusa.Services.CrewSuppressionService.applyInitialDamage(ctx, battery)
		if not isEnabled(ctx) then
			logger:debug("initial damage evaluation ignored: doctrine disabled")
			return false
		end
		local found = false
		local duration = 0
		for i = 1, #(battery.Units or {}) do
			local unit = battery.Units[i]
			if unit.InitialDamagePending and isSuppressibleUnit(unit) then
				unit.InitialDamagePending = false
				found = true
				duration = math.max(duration, adjustedDuration(ctx, unit))
			end
		end
		if not found then
			logger:debug(
				string.format(
					"battery %s initial damage evaluation: no pending damage",
					battery.GroupName or battery.BatteryId
				)
			)
			return false
		end
		logger:debug(
			string.format("battery %s processing pending initial damage", battery.GroupName or battery.BatteryId)
		)
		return Medusa.Services.CrewSuppressionService.apply(ctx, battery, C.CrewSuppressionCause.DAMAGE, duration)
	end

	function Medusa.Services.CrewSuppressionService.explosiveRadius(policy, effectiveExplosiveMassKg)
		if
			type(policy) ~= "table"
			or type(effectiveExplosiveMassKg) ~= "number"
			or effectiveExplosiveMassKg ~= effectiveExplosiveMassKg
			or effectiveExplosiveMassKg <= 0
			or effectiveExplosiveMassKg == math.huge
		then
			return nil
		end
		local scale = policy.ExplosiveRadiusScaleM
		local maximum = policy.ExplosiveRadiusMaxM
		if
			type(scale) ~= "number"
			or scale ~= scale
			or scale <= 0
			or scale == math.huge
			or type(maximum) ~= "number"
			or maximum ~= maximum
			or maximum <= 0
			or maximum == math.huge
		then
			return nil
		end
		return math.min(maximum, scale * effectiveExplosiveMassKg ^ (1 / 3))
	end

	function Medusa.Services.CrewSuppressionService.explosiveProbability(policy, radiusM, distanceM)
		if
			type(policy) ~= "table"
			or type(radiusM) ~= "number"
			or radiusM <= 0
			or type(distanceM) ~= "number"
			or distanceM < 0
			or distanceM >= radiusM
		then
			return 0
		end
		local effectiveness = policy.ExplosiveEffectiveness
		if
			type(effectiveness) ~= "number"
			or effectiveness ~= effectiveness
			or effectiveness <= 0
			or effectiveness == math.huge
		then
			return 0
		end
		return distanceProbability(effectiveness, radiusM, distanceM)
	end

	function Medusa.Services.CrewSuppressionService.crewSkillMultiplier(policy, unit)
		return skillMultiplier(policy, unit)
	end

	local function validTerminalEvent(terminalEvent)
		if type(terminalEvent) ~= "table" or terminalEvent.TerminalEventId == nil then
			return false
		end
		local position = terminalEvent.Position
		return type(position) == "table"
			and type(position.x) == "number"
			and type(position.y) == "number"
			and type(position.z) == "number"
			and C.CrewSuppressionTerminalKindBySource[terminalEvent.Source] == terminalEvent.Kind
	end

	local function terminalPolicy(policy, terminalEvent)
		if terminalEvent.Kind == C.CrewSuppressionTerminalKind.EXPLOSIVE then
			local radius =
				Medusa.Services.CrewSuppressionService.explosiveRadius(policy, terminalEvent.EffectiveExplosiveMassKg)
			return radius, policy.ExplosiveEffectiveness, C.CrewSuppressionCause.EXPLOSIVE
		end
		return policy.CannonRadiusM, policy.CannonEffectiveness, C.CrewSuppressionCause.CANNON
	end

	local function evaluateTerminalCandidate(ctx, work, unitId, random)
		local terminalEvent = work.TerminalEvent
		local battery, unit = ctx.batteryRepository:getByUnitId(unitId)
		if
			not unit
			or unit.LastTerminalEventId == terminalEvent.TerminalEventId
			or unit.OperationalStatus == C.UnitOperationalStatus.DESTROYED
			or not isSuppressibleUnit(unit)
		then
			return false, false
		end
		unit.LastTerminalEventId = terminalEvent.TerminalEventId
		if battery.LastTerminalEventId == terminalEvent.TerminalEventId then
			return true, false
		end
		local distance = Distance3D(terminalEvent.Position, unit.Position)
		local probability = distanceProbability(work.Effectiveness, work.RadiusM, distance)
		probability = probability * skillMultiplier(ctx.doctrine.CrewSuppression, unit)
		if not (probability > 0 and random() < probability) then
			return true, false
		end
		local applied =
			Medusa.Services.CrewSuppressionService.apply(ctx, battery, work.Cause, adjustedDuration(ctx, unit))
		if not applied then
			return true, false
		end
		battery.LastTerminalEventId = terminalEvent.TerminalEventId
		return true, true
	end

	function Medusa.Services.CrewSuppressionService.beginTerminalEvent(ctx, terminalEvent)
		if not isEnabled(ctx) or not validTerminalEvent(terminalEvent) or not ctx.suppressibleUnitGeoGrid then
			return nil
		end
		local radius, effectiveness, cause = terminalPolicy(ctx.doctrine.CrewSuppression, terminalEvent)
		if type(radius) ~= "number" or radius <= 0 or type(effectiveness) ~= "number" or effectiveness < 0 then
			return nil
		end
		local cursor = ctx.suppressibleUnitGeoGrid:beginQuery(terminalEvent.Position, radius)
		if not cursor then
			return nil
		end
		logger:debug(
			string.format(
				"terminal-event evaluation started: id=%s kind=%s source=%s radius=%.3fm",
				tostring(terminalEvent.TerminalEventId),
				terminalEvent.Kind,
				terminalEvent.Source,
				radius
			)
		)
		return {
			TerminalEvent = terminalEvent,
			RadiusM = radius,
			Effectiveness = effectiveness,
			Cause = cause,
			Cursor = cursor,
		}
	end

	function Medusa.Services.CrewSuppressionService.continueTerminalEvent(ctx, work, visitBudget, output)
		if type(work) ~= "table" or not work.Cursor then
			return 0, true, 0, 0
		end
		local written, visited, complete = ctx.suppressibleUnitGeoGrid:continueQuery(work.Cursor, visitBudget, output)
		local candidates = 0
		local applications = 0
		local terminalEvent = work.TerminalEvent
		local random = ctx.random or math.random
		for i = 1, written do
			local candidate, applied = evaluateTerminalCandidate(ctx, work, output[i], random)
			if candidate then
				candidates = candidates + 1
			end
			if applied then
				applications = applications + 1
			end
		end
		logger:debug(
			string.format(
				"terminal-event evaluation: id=%s kind=%s visited=%d candidates=%d applications=%d complete=%s nearestIndexedUnitDistance=%s",
				tostring(terminalEvent.TerminalEventId),
				terminalEvent.Kind,
				visited,
				candidates,
				applications,
				tostring(complete),
				work.Cursor.NearestVisitedDistanceSquared
						and string.format("%.1fm", math.sqrt(work.Cursor.NearestVisitedDistanceSquared))
					or "unavailable"
			)
		)
		return visited, complete, candidates, applications
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
