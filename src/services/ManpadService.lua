require("_header")
require("services.Services")
require("core.Constants")
require("entities.Battery")
require("services.BatteryActivationService")
require("services.MetricsService")

--[[
            ███╗   ███╗ █████╗ ███╗   ██╗██████╗  █████╗ ██████╗     ███████╗███████╗██████╗ ██╗   ██╗██╗ ██████╗███████╗
            ████╗ ████║██╔══██╗████╗  ██║██╔══██╗██╔══██╗██╔══██╗    ██╔════╝██╔════╝██╔══██╗██║   ██║██║██╔════╝██╔════╝
            ██╔████╔██║███████║██╔██╗ ██║██████╔╝███████║██║  ██║    ███████╗█████╗  ██████╔╝██║   ██║██║██║     █████╗
            ██║╚██╔╝██║██╔══██║██║╚██╗██║██╔═══╝ ██╔══██║██║  ██║    ╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██║██║     ██╔══╝
            ██║ ╚═╝ ██║██║  ██║██║ ╚████║██║     ██║  ██║██████╔╝    ███████║███████╗██║  ██║ ╚████╔╝ ██║╚██████╗███████╗
            ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝     ╚═╝  ╚═╝╚═════╝     ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚═╝ ╚═════╝╚══════╝

    What this service does
    - Autonomous detection and engagement behavior for MANPAD groups.
      Crews start dormant (ASLEEP). They wake when the IADS assigns a nearby threat,
      when they hear an aircraft within their learned omnidirectional audio range,
      or when a neighbor within doctrine's field-radio range fires. First wake takes 30s–5min; subsequent
      wakes take 10–30s. Previously alerted crews retain wider visual awareness and
      increasing audio sensitivity until doctrine-controlled decay resets them.
      Targets inside the weapon envelope and visually acquired are engaged autonomously.
      After 5–15 min HOT the crew rests for 15 min (COOLDOWN), returns to ALERT,
      and sleeps again after 15 min idle.

    How others use it
    - IadsNetwork passes explicit execution context to the evaluation, cue, refresh,
      and lifecycle operations.
    - IadsNetwork calls onShot from the shared shot event handler for HOT timer policy.
--]]

Medusa.Services.ManpadService = {}

Medusa.Services.ManpadService._batteryBuffer = {}
local _batteryBuffer = Medusa.Services.ManpadService._batteryBuffer
Medusa.Services.ManpadService._stopBuffer = {}
local _stopBuffer = Medusa.Services.ManpadService._stopBuffer

local C = Medusa.Constants
local MSWS = Medusa.Constants.Manpad.SleepWakeState
local MDM = Medusa.Constants.Manpad.DetectionMode
local MWR = Medusa.Constants.Manpad.WakeReason
local P = Medusa.Constants.Posture

-- Pre-allocated GeoGrid kind filter tables to avoid per-call allocation.
-- Shared across all queryRadius calls in this module.
local _FILTER_TRACK = { "Track" }
local _FILTER_MANPAD = { "Manpad" }
local _AIR_UNIT_CATEGORIES = {
	[Unit.Category.AIRPLANE] = true,
	[Unit.Category.HELICOPTER] = true,
}
local _INFERRED_AIRCRAFT_TYPES = {
	[C.AssessedAircraftType.FIXED_WING] = true,
	[C.AssessedAircraftType.ROTARY_WING] = true,
	[C.AssessedAircraftType.FIGHTER] = true,
	[C.AssessedAircraftType.SEAD_AIRCRAFT] = true,
}

local function randomDelay(minSec, maxSec)
	return minSec + math.random() * (maxSec - minSec)
end

function Medusa.Services.ManpadService.sampleAudioCueRange()
	return C.Manpad.AUDIO_RANGE_MIN_M + math.random() * (C.Manpad.AUDIO_RANGE_MAX_M - C.Manpad.AUDIO_RANGE_MIN_M)
end

local function completeThreatWake(battery, wakeReason, now)
	local manpad = battery.Manpad
	manpad.SleepWakeState = MSWS.ALERT
	manpad.WakeReason = wakeReason
	manpad.AlertStartTime = now
	manpad.AlertCycleCount = manpad.AlertCycleCount + 1
	manpad.LastAlertedTime = now
end

--- Rebuilds battery.Manpad.UnitHeadings from the current Units roster. Only
--- BUR.MANPAD soldiers contribute headings; non-combat roster entries are
--- skipped. Reuses existing slot tables when present so mobile-team refreshes
--- don't churn the allocator. Used at discovery (fresh empty headings table)
--- and on position-refresh ticks.
function Medusa.Services.ManpadService.rebuildHeadings(battery)
	local units = battery.Units
	if not units then
		battery.Manpad.UnitHeadingCount = 0
		return
	end
	local headings = battery.Manpad.UnitHeadings or {}
	battery.Manpad.UnitHeadings = headings
	local written = 0
	for j = 1, #units do
		local u = units[j]
		if Medusa.Entities.Battery.isAmmoBearingUnit(battery, u) and u.UnitName then
			local headingDeg = GetUnitHeading(u.UnitName)
			if headingDeg then
				local rad = math.rad(headingDeg)
				written = written + 1
				local slot = headings[written]
				if slot then
					slot.hx = math.cos(rad)
					slot.hz = math.sin(rad)
				else
					headings[written] = { hx = math.cos(rad), hz = math.sin(rad) }
				end
			end
		end
	end
	for i = #headings, written + 1, -1 do
		headings[i] = nil
	end
	battery.Manpad.UnitHeadingCount = written
end

function Medusa.Services.ManpadService.headingBearingDegrees(heading)
	local bearing = math.deg(math.atan2(heading.hx, heading.hz))
	if bearing < 0 then
		bearing = bearing + 360
	end
	return bearing
end

local function scheduleWake(ctx, battery, wakeReason, minSec, maxSec)
	if battery.Manpad.WakeTimerId then
		return false
	end

	local manpad = battery.Manpad
	if not minSec then
		minSec = manpad.AlertCycleCount == 0 and C.Manpad.FIRST_WAKE_MIN_SEC or C.Manpad.WAKE_MIN_SEC
	end
	if not maxSec then
		maxSec = manpad.AlertCycleCount == 0 and C.Manpad.FIRST_WAKE_MAX_SEC or C.Manpad.WAKE_MAX_SEC
	end
	manpad.SleepWakeState = MSWS.ALERTING
	manpad.WakeReason = wakeReason

	local batteryId = battery.BatteryId
	local manpadStore = ctx.manpadStore
	local timerId
	timerId = ScheduleOnce(function()
		local bat = manpadStore:get(batteryId)
		if not bat or bat.Manpad.WakeTimerId ~= timerId then
			return
		end
		bat.Manpad.WakeTimerId = nil
		if bat.Manpad.SleepWakeState == MSWS.ALERTING then
			completeThreatWake(bat, bat.Manpad.WakeReason, GetTime())
		end
	end, nil, randomDelay(minSec, maxSec))
	if not timerId then
		manpad.SleepWakeState = MSWS.ASLEEP
		manpad.WakeReason = MWR.NONE
		return false
	end
	manpad.WakeTimerId = timerId
	return true
end

function Medusa.Services.ManpadService.detectionMode(state, posture, alertCycleCount)
	if state == MSWS.ASLEEP then
		if posture ~= P.HOT_WAR then
			return MDM.NONE
		end
		return alertCycleCount > 0 and MDM.FULL or MDM.NARROW
	end
	if state == MSWS.ALERTING or state == MSWS.ALERT then
		return MDM.FULL
	end
	return MDM.NONE
end

function Medusa.Services.ManpadService.canDetectVisually(battery, track, posture)
	local state = battery.Manpad.SleepWakeState
	if not battery.Position then
		return false
	end

	local detectionMode = Medusa.Services.ManpadService.detectionMode(state, posture, battery.Manpad.AlertCycleCount)
	if detectionMode == MDM.NONE then
		return false
	end

	-- Relative altitude ceiling rejects targets too far above the MANPAD.
	-- Look-down (altRel <= 0) is allowed: mountain MANPAD vs valley target.
	local altRel = track.Position.y - battery.Position.y
	if altRel > C.Manpad.REL_ALT_CEIL_M then
		return false
	end

	local dx = track.Position.x - battery.Position.x
	local dz = track.Position.z - battery.Position.z
	local dist2D_sq = dx * dx + dz * dz
	local narrowRange = C.Manpad.NARROW_RANGE_M
	if dist2D_sq > narrowRange * narrowRange then
		return false
	end
	-- Coincident (directly overhead): dot-product direction math is
	-- undefined at zero distance, so treat as seen unconditionally.
	if dist2D_sq < 1 then
		return true
	end

	local dist2D = math.sqrt(dist2D_sq)
	local invDist = 1 / dist2D
	local toTrackX = dx * invDist
	local toTrackZ = dz * invDist
	local narrowOnly = detectionMode == MDM.NARROW
	local headings = battery.Manpad.UnitHeadings
	local count = battery.Manpad.UnitHeadingCount or 0
	local wideRange = narrowRange * C.Manpad.WIDE_RANGE_FACTOR

	-- Explicit count iteration: #headings is undefined when a heading probe
	-- failed at discovery and left the array shorter than the unit count.
	for j = 1, count do
		local h = headings[j]
		local dot = h.hx * toTrackX + h.hz * toTrackZ
		if dot >= C.Manpad.COS_NARROW then
			return true
		elseif not narrowOnly and dot >= C.Manpad.COS_WIDE and dist2D <= wideRange then
			return true
		end
	end
	return false
end

function Medusa.Services.ManpadService.shouldEngage(battery, track, posture)
	if battery.Manpad.SleepWakeState ~= MSWS.ALERT then
		return false
	end
	if (battery.TotalAmmoStatus or 0) <= 0 then
		return false
	end

	local dx = track.Position.x - battery.Position.x
	local dz = track.Position.z - battery.Position.z
	local dist2D_sq = dx * dx + dz * dz
	local engMax = battery.EngagementRangeMax or 0
	if dist2D_sq > engMax * engMax then
		return false
	end

	return Medusa.Services.ManpadService.canDetectVisually(battery, track, posture)
end

function Medusa.Services.ManpadService.canFire(battery)
	return battery.Manpad ~= nil
		and battery.Manpad.SleepWakeState == MSWS.HOT
		and battery.ActivationState == C.ActivationState.STATE_HOT
		and battery.OperationalStatus == C.BatteryOperationalStatus.ACTIVE
		and (battery.TotalAmmoStatus or 0) > 0
end

local function hearsAudio(battery, track)
	local dx = track.Position.x - battery.Position.x
	local dy = track.Position.y - battery.Position.y
	local dz = track.Position.z - battery.Position.z
	local range = battery.Manpad.AudioCueRangeM
	return dx * dx + dy * dy + dz * dz <= range * range
end

function Medusa.Services.ManpadService.onShot(battery, now)
	if battery.Manpad.SleepWakeState ~= MSWS.HOT then
		return
	end
	if (battery.TotalAmmoStatus or 0) > 0 then
		battery.Manpad.HotUntil = now + randomDelay(C.Manpad.HOT_MIN_SEC, C.Manpad.HOT_MAX_SEC)
	else
		battery.Manpad.HotUntil = now
	end
	battery.Manpad.AlertStartTime = now
end

function Medusa.Services.ManpadService.cancelPendingWake(battery)
	if battery.Manpad and battery.Manpad.WakeTimerId then
		local wasAlerting = battery.Manpad.SleepWakeState == MSWS.ALERTING
		CancelSchedule(battery.Manpad.WakeTimerId)
		battery.Manpad.WakeTimerId = nil
		if wasAlerting then
			battery.Manpad.SleepWakeState = MSWS.ASLEEP
			battery.Manpad.WakeReason = MWR.NONE
		end
	end
end

function Medusa.Services.ManpadService.cancelPendingWakes(manpadStore)
	local manpads = manpadStore:getAll(_stopBuffer)
	for i = 1, #manpads do
		Medusa.Services.ManpadService.cancelPendingWake(manpads[i])
	end
end

function Medusa.Services.ManpadService.onRearmed(battery, now)
	Medusa.Services.ManpadService.cancelPendingWake(battery)
	battery.Manpad.SleepWakeState = MSWS.ALERT
	battery.Manpad.WakeReason = MWR.REARM
	battery.Manpad.AlertStartTime = now
	battery.Manpad.HotUntil = nil
	battery.Manpad.CooldownUntil = nil
end

local function wakeAsleepManpadsInRadius(ctx, centerPos, radius, wakeReason, minSec, maxSec, excludeId)
	local results = ctx.geoGrid:queryRadius(centerPos, radius, _FILTER_MANPAD)
	local manpadIds = results.ManpadIds
	if not manpadIds then
		return 0
	end
	local scheduledCount = 0
	for id in pairs(manpadIds) do
		if id ~= excludeId then
			local bat = ctx.manpadStore:get(id)
			if
				bat
				and bat.Manpad.SleepWakeState == MSWS.ASLEEP
				and scheduleWake(ctx, bat, wakeReason, minSec, maxSec)
			then
				scheduledCount = scheduledCount + 1
			end
		end
	end
	return scheduledCount
end

local function onManpadGoHot(ctx, battery)
	local radioRangeM = ctx.doctrine.MANPADFieldRadioRangeM
	if radioRangeM == 0 then
		return
	end
	local scheduledCount = wakeAsleepManpadsInRadius(
		ctx,
		battery.Position,
		radioRangeM,
		MWR.NEIGHBOR,
		C.Manpad.NEIGHBOR_WAKE_MIN_SEC,
		C.Manpad.NEIGHBOR_WAKE_MAX_SEC,
		battery.BatteryId
	)
	if scheduledCount > 0 then
		Medusa.Services.MetricsService.inc("medusa_manpad_neighbor_wakes_total", scheduledCount)
	end
end

function Medusa.Services.ManpadService.cueFromIADS(ctx, trackPosition)
	if ctx.manpadStore:count() == 0 then
		return
	end
	wakeAsleepManpadsInRadius(ctx, trackPosition, C.Manpad.GEOGRID_QUERY_RADIUS_M, MWR.IADS, nil, nil, nil)
end

--- Transitions a battery to ALERT synchronously, cancelling any pending
--- scheduled wake so WakeTimerId is not left stale (which would block the
--- duplicate-wake guard on the next ASLEEP cycle). Metrics are bumped
--- at the caller so the reason string stays in the call context.
local function snapToAlert(battery, now, wakeReason)
	Medusa.Services.ManpadService.cancelPendingWake(battery)
	completeThreatWake(battery, wakeReason, now)
end

local function checkAudioWake(battery, track, now)
	local state = battery.Manpad.SleepWakeState
	if state ~= MSWS.ASLEEP and state ~= MSWS.ALERTING then
		return
	end
	if not hearsAudio(battery, track) then
		return
	end
	snapToAlert(battery, now, MWR.AUDIO)
	Medusa.Services.MetricsService.inc("medusa_manpad_audio_wakes_total")
end

local function checkVisualWake(battery, track, now, posture)
	local state = battery.Manpad.SleepWakeState
	if not ((state == MSWS.ASLEEP and posture == P.HOT_WAR) or state == MSWS.ALERTING) then
		return
	end
	if not Medusa.Services.ManpadService.canDetectVisually(battery, track, posture) then
		return
	end
	snapToAlert(battery, now, MWR.VISUAL)
	Medusa.Services.MetricsService.inc("medusa_manpad_visual_detections_total")
end

local function attemptEngagement(ctx, battery, track, now, posture)
	if not Medusa.Services.ManpadService.shouldEngage(battery, track, posture) then
		return false
	end
	if not Medusa.Services.BatteryActivationService.forceGoHot(battery, now) then
		-- forceGoHot returned false (no controller, etc.).
		-- Leave state in ALERT and retry next tick; do NOT
		-- pollute the state machine with a phantom HOT.
		return false
	end
	battery.Manpad.SleepWakeState = MSWS.HOT
	battery.Manpad.HotUntil = now + randomDelay(C.Manpad.HOT_MIN_SEC, C.Manpad.HOT_MAX_SEC)
	onManpadGoHot(ctx, battery)
	Medusa.Services.MetricsService.inc("medusa_manpad_activations_total")
	return true
end

local function processThreatCandidate(ctx, battery, target, now, posture)
	checkAudioWake(battery, target, now)
	checkVisualWake(battery, target, now, posture)
	return attemptEngagement(ctx, battery, target, now, posture)
end

local function isAircraftTrack(track)
	return _INFERRED_AIRCRAFT_TYPES[track.AssessedAircraftType] == true
end

local function processCandidateTracks(ctx, battery, trackStore, now, posture, trackIds)
	if not trackIds then
		return false
	end

	local LS = Medusa.Constants.TrackLifecycleState
	local aircraftFound = false

	for id in pairs(trackIds) do
		local track = trackStore:get(id)
		if track and track.LifecycleState == LS.ACTIVE and isAircraftTrack(track) then
			aircraftFound = true
			if processThreatCandidate(ctx, battery, track, now, posture) then
				return true
			end
		end
	end
	return aircraftFound
end

local function isHostileAircraft(unit, coalitionId)
	if not IsUnitActive(unit) then
		return false
	end
	local targetCoalition = GetUnitCoalition(unit)
	if targetCoalition == 0 or targetCoalition == coalitionId then
		return false
	end
	return _AIR_UNIT_CATEGORIES[GetUnitCategoryEx(unit)] == true
end

local function clearSet(values)
	for key in pairs(values) do
		values[key] = nil
	end
end

local function syncAutonomousScanQueue(ctx, manpads)
	local liveIds = ctx.autonomousLiveIds or {}
	ctx.autonomousLiveIds = liveIds
	clearSet(liveIds)

	local queue = ctx.autonomousScanQueue
	local queuedIds = ctx.autonomousScanQueuedIds
	local topologyChanged = not queue or not queuedIds or queue:size() ~= #manpads
	for i = 1, #manpads do
		local batteryId = manpads[i].BatteryId
		liveIds[batteryId] = true
		if not topologyChanged and not queuedIds[batteryId] then
			topologyChanged = true
		end
	end
	if not topologyChanged then
		return queue
	end

	local replacement = RingBuffer(math.max(1, #manpads), false)
	local replacementIds = {}
	if queue then
		local queuedCount = queue:size()
		for _ = 1, queuedCount do
			local batteryId = queue:pop()
			if liveIds[batteryId] and not replacementIds[batteryId] then
				replacement:push(batteryId)
				replacementIds[batteryId] = true
			end
		end
	end
	for i = 1, #manpads do
		local batteryId = manpads[i].BatteryId
		if not replacementIds[batteryId] then
			replacement:push(batteryId)
			replacementIds[batteryId] = true
		end
	end

	local cacheByBatteryId = ctx.autonomousTargetCache
	if cacheByBatteryId then
		for batteryId in pairs(cacheByBatteryId) do
			if not liveIds[batteryId] then
				cacheByBatteryId[batteryId] = nil
			end
		end
	end

	ctx.autonomousScanQueue = replacement
	ctx.autonomousScanQueuedIds = replacementIds
	return replacement
end

local function getUnitName(unit)
	local ok, unitName = pcall(unit.getName, unit)
	if ok and type(unitName) == "string" and unitName ~= "" then
		return unitName
	end
	return nil
end

local function scanAutonomousTargets(ctx, battery, now)
	local targets = RingBuffer(C.Manpad.AUTONOMOUS_TARGET_CACHE_CAPACITY, false)
	local cache = {
		ExpiresAt = now + C.Manpad.AUTONOMOUS_TARGET_CACHE_TTL_SEC,
		Processed = false,
		Targets = targets,
	}
	ctx.autonomousTargetCache[battery.BatteryId] = cache

	local searchVolume = CreateSphereVolume(battery.Position, C.Manpad.GEOGRID_QUERY_RADIUS_M)
	if not searchVolume then
		return false
	end

	local startedAt = Medusa.hpTimer()
	SearchWorldObjects(Object.Category.UNIT, searchVolume, function(unit)
		if not isHostileAircraft(unit, ctx.coalitionId) then
			return true
		end
		local unitName = getUnitName(unit)
		local position = GetUnitPosition(unit)
		if not unitName or not position then
			return true
		end
		targets:push({
			UnitName = unitName,
			Position = { x = position.x, y = position.y, z = position.z },
		})
		return not targets:isFull()
	end)
	Medusa.Services.MetricsService.inc("medusa_manpad_autonomous_scans_total")
	Medusa.Services.MetricsService.observe(
		"medusa_manpad_autonomous_scan_duration_seconds",
		Medusa.hpTimer() - startedAt
	)
	return true
end

local function replenishAutonomousScanTokens(ctx, now)
	local quota = C.Manpad.AUTONOMOUS_SCAN_QUOTA_PER_SEC
	local lastTime = ctx.autonomousScanTokenTime
	if lastTime == nil or now < lastTime then
		ctx.autonomousScanTokens = quota
	else
		ctx.autonomousScanTokens = math.min(quota, (ctx.autonomousScanTokens or quota) + (now - lastTime) * quota)
	end
	ctx.autonomousScanTokenTime = now
end

local function refreshAutonomousTargetCaches(ctx, manpads, now)
	local queue = syncAutonomousScanQueue(ctx, manpads)
	Medusa.Services.MetricsService.set("medusa_manpad_autonomous_scan_queue_depth", queue:size())
	if ctx.coalitionId == nil or queue:isEmpty() then
		return
	end

	ctx.autonomousTargetCache = ctx.autonomousTargetCache or {}
	replenishAutonomousScanTokens(ctx, now)
	local searchesRemaining = math.floor(ctx.autonomousScanTokens)
	if searchesRemaining == 0 then
		return
	end

	local queueDepth = queue:size()
	for _ = 1, queueDepth do
		local batteryId = queue:pop()
		local battery = ctx.manpadStore:get(batteryId)
		if battery then
			queue:push(batteryId)
			local state = battery.Manpad.SleepWakeState
			local cache = ctx.autonomousTargetCache[batteryId]
			if
				state ~= MSWS.HOT
				and state ~= MSWS.COOLDOWN
				and battery.Position
				and (not cache or now >= cache.ExpiresAt)
				and scanAutonomousTargets(ctx, battery, now)
			then
				ctx.autonomousScanTokens = ctx.autonomousScanTokens - 1
				searchesRemaining = searchesRemaining - 1
				if searchesRemaining == 0 then
					break
				end
			end
		end
	end
end

local function processAutonomousTargets(ctx, battery, now, posture)
	if ctx.coalitionId == nil then
		return false
	end
	local cacheByBatteryId = ctx.autonomousTargetCache
	local cache = cacheByBatteryId and cacheByBatteryId[battery.BatteryId]
	if not cache or now >= cache.ExpiresAt then
		return false
	end

	if cache.Processed then
		Medusa.Services.MetricsService.inc("medusa_manpad_autonomous_cache_reuses_total")
	else
		cache.Processed = true
	end
	local hostileAircraftFound = false
	for i = 1, cache.Targets:size() do
		local snapshot = cache.Targets:get(i)
		local unit = GetUnit(snapshot.UnitName)
		if unit and isHostileAircraft(unit, ctx.coalitionId) then
			local position = GetUnitPosition(unit)
			if position then
				hostileAircraftFound = true
				snapshot.Position.x = position.x
				snapshot.Position.y = position.y
				snapshot.Position.z = position.z
				if processThreatCandidate(ctx, battery, snapshot, now, posture) then
					local controller = GetGroupController(battery.GroupName)
					if controller then
						KnowControllerTarget(controller, unit, false, true)
					end
					return true
				end
			end
		end
	end
	return hostileAircraftFound
end

local function decayAlertnessIfExpired(battery, now, decaySec)
	local manpad = battery.Manpad
	if
		decaySec == 0
		or manpad.SleepWakeState ~= MSWS.ASLEEP
		or manpad.LastAlertedTime == nil
		or now - manpad.LastAlertedTime < decaySec
	then
		return
	end
	manpad.AlertCycleCount = 0
	manpad.LastAlertedTime = nil
	manpad.AudioCueRangeM = Medusa.Services.ManpadService.sampleAudioCueRange()
end

local function returnToSleep(battery)
	local manpad = battery.Manpad
	manpad.SleepWakeState = MSWS.ASLEEP
	manpad.WakeReason = MWR.NONE
	manpad.AlertStartTime = nil
	manpad.AudioCueRangeM = math.max(manpad.AudioCueRangeM, Medusa.Services.ManpadService.sampleAudioCueRange())
end

local function evaluateSingle(ctx, battery, trackStore, geoGrid, now, posture, alertnessDecaySec)
	decayAlertnessIfExpired(battery, now, alertnessDecaySec)
	local state = battery.Manpad.SleepWakeState

	if
		state == MSWS.HOT
		and battery.Manpad.HotUntil
		and now >= battery.Manpad.HotUntil
		and (not battery.MissileInFlightUntil or now >= battery.MissileInFlightUntil)
	then
		if Medusa.Services.BatteryActivationService.goCold(battery, now, trackStore) then
			battery.Manpad.SleepWakeState = MSWS.COOLDOWN
			battery.Manpad.HotUntil = nil
			battery.Manpad.CooldownUntil = now + C.Manpad.COOLDOWN_SEC
		end
		return
	end

	if state == MSWS.COOLDOWN and battery.Manpad.CooldownUntil and now >= battery.Manpad.CooldownUntil then
		battery.Manpad.SleepWakeState = MSWS.ALERT
		battery.Manpad.WakeReason = MWR.RECOVERY
		battery.Manpad.AlertStartTime = now
		battery.Manpad.CooldownUntil = nil
		state = MSWS.ALERT
	end

	if state == MSWS.HOT then
		return
	end

	if not battery.Position then
		return
	end

	-- Single queryRadius serves both the ALERT-idle timeout check and the
	-- candidate-track processing path below.
	local results = geoGrid:queryRadius(battery.Position, C.Manpad.GEOGRID_QUERY_RADIUS_M, _FILTER_TRACK)
	local trackIds = results.TrackIds

	local trackedAircraftFound = processCandidateTracks(ctx, battery, trackStore, now, posture, trackIds)
	if battery.Manpad.SleepWakeState == MSWS.HOT then
		return
	end
	local hostileAircraftFound = processAutonomousTargets(ctx, battery, now, posture)
	state = battery.Manpad.SleepWakeState

	if
		state == MSWS.ALERT
		and battery.Manpad.AlertStartTime
		and (now - battery.Manpad.AlertStartTime) >= C.Manpad.ALERT_TIMEOUT_SEC
		and not trackedAircraftFound
		and not hostileAircraftFound
	then
		returnToSleep(battery)
		return
	end
end

function Medusa.Services.ManpadService.evaluate(ctx)
	local manpads = ctx.manpadStore:getAll(_batteryBuffer)
	local trackStore = ctx.trackStore
	local geoGrid = ctx.geoGrid
	local now = ctx.now
	local posture = ctx.posture
	local alertnessDecaySec = ctx.doctrine.MANPADAlertnessDecaySec
	refreshAutonomousTargetCaches(ctx, manpads, now)
	for i = 1, #manpads do
		evaluateSingle(ctx, manpads[i], trackStore, geoGrid, now, posture, alertnessDecaySec)
	end
end

local function nextBatteryAfter(manpads, batteryId)
	local first = nil
	local nextBattery = nil
	for i = 1, #manpads do
		local battery = manpads[i]
		if not first or battery.BatteryId < first.BatteryId then
			first = battery
		end
		if
			batteryId
			and battery.BatteryId > batteryId
			and (not nextBattery or battery.BatteryId < nextBattery.BatteryId)
		then
			nextBattery = battery
		end
	end
	return nextBattery or first
end

--- Refreshes one MANPAD's Position from DCS, round-robin by BatteryId.
--- Skips MANPADs whose last refresh was within Manpad.POS_REFRESH_MIN_INTERVAL_SEC
--- but still advances the round-robin cursor, so this call refreshes at most
--- one MANPAD per invocation. Caller schedules every Manpad.POS_REFRESH_TICK_INTERVAL
--- ticks to hit the 2/sec per-network budget.
function Medusa.Services.ManpadService.refreshOnePosition(ctx)
	local manpads = ctx.manpadStore:getAll(_batteryBuffer)
	if #manpads == 0 then
		return
	end

	local battery = nextBatteryAfter(manpads, ctx.posRefreshBatteryId)
	ctx.posRefreshBatteryId = battery.BatteryId

	local last = battery.Manpad.LastPositionRefreshTime
	if last and (ctx.now - last) < C.Manpad.POS_REFRESH_MIN_INTERVAL_SEC then
		return
	end

	local units = battery.Units
	if not units or #units == 0 then
		return
	end
	local firstUnit = nil
	for i = 1, #units do
		if Medusa.Entities.Battery.isAmmoBearingUnit(battery, units[i]) then
			firstUnit = units[i]
			break
		end
	end
	if not firstUnit or not firstUnit.UnitName then
		return
	end

	local pos = GetUnitPosition(firstUnit.UnitName)
	if not pos then
		return
	end

	battery.Position = pos
	ctx.geoGrid:updatePosition(battery.BatteryId, pos, "Manpad")
	battery.Manpad.LastPositionRefreshTime = ctx.now

	Medusa.Services.ManpadService.rebuildHeadings(battery)

	Medusa.Services.MetricsService.inc("medusa_manpad_position_refreshes_total")
end
