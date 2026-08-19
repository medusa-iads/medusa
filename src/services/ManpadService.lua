require("_header")
require("services.Services")
require("core.Constants")
require("entities.Battery")
require("services.BatteryActivationService")
require("services.MetricsService")
require("services.CrewPerceptionService")
require("services.LocalSearchService")
require("services.NeighborPropagationService")

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

local _FILTER_TRACK = { "Track" }
local _INFERRED_AIRCRAFT_TYPES = {
	[C.AssessedAircraftType.FIXED_WING] = true,
	[C.AssessedAircraftType.ROTARY_WING] = true,
	[C.AssessedAircraftType.FIGHTER] = true,
	[C.AssessedAircraftType.SEAD_AIRCRAFT] = true,
}
local CrewPerceptionService = Medusa.Services.CrewPerceptionService
local LocalSearchService = Medusa.Services.LocalSearchService
local NeighborPropagationService = Medusa.Services.NeighborPropagationService
local _PRIMARY_VISUAL_PROFILES = { CrewPerceptionService.PRIMARY_PROFILE }
local _FULL_VISUAL_PROFILES = {
	CrewPerceptionService.PRIMARY_PROFILE,
	{
		RangeM = C.Manpad.NARROW_RANGE_M * C.Manpad.WIDE_RANGE_FACTOR,
		CosHalfAngle = C.Manpad.COS_WIDE,
	},
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

function Medusa.Services.ManpadService.rebuildHeadings(battery)
	CrewPerceptionService.rebuildHeadings(battery, battery.Manpad, C.BatteryUnitRole.MANPAD)
end

function Medusa.Services.ManpadService.headingBearingDegrees(heading)
	return CrewPerceptionService.headingBearingDegrees(heading)
end

local function receiveScheduledWake(battery, wakeReason, now)
	if battery.Manpad.SleepWakeState == MSWS.ALERTING then
		completeThreatWake(battery, wakeReason, now)
	end
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
	if
		not NeighborPropagationService.scheduleDelivery({
			recipient = battery,
			recipientStore = ctx.manpadStore,
			recipientStateField = "Manpad",
			pendingTimerField = "WakeTimerId",
			delayMinSec = minSec,
			delayMaxSec = maxSec,
			message = wakeReason,
			onDelivery = receiveScheduledWake,
		})
	then
		manpad.SleepWakeState = MSWS.ASLEEP
		manpad.WakeReason = MWR.NONE
		return false
	end
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

	local profiles = detectionMode == MDM.NARROW and _PRIMARY_VISUAL_PROFILES or _FULL_VISUAL_PROFILES
	return CrewPerceptionService.canSee(battery.Position, track.Position, battery.Manpad, profiles)
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
	return CrewPerceptionService.hears(battery.Position, track.Position, battery.Manpad.AudioCueRangeM)
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
		NeighborPropagationService.cancelDelivery(battery, "Manpad", "WakeTimerId")
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
	local manpads = NeighborPropagationService.findRecipients(
		ctx.localGeoGrid or ctx.geoGrid,
		ctx.manpadStore,
		centerPos,
		radius,
		"Manpad",
		excludeId
	)
	local scheduledCount = 0
	for i = 1, #manpads do
		local battery = manpads[i]
		if battery.Manpad.SleepWakeState == MSWS.ASLEEP and scheduleWake(ctx, battery, wakeReason, minSec, maxSec) then
			scheduledCount = scheduledCount + 1
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

local function getLocalSearch(ctx)
	local search = ctx.localSearch
	if not search then
		search = LocalSearchService:new({
			coalitionId = ctx.coalitionId,
			searchRadiusM = C.Manpad.GEOGRID_QUERY_RADIUS_M,
			quotaPerSec = C.Manpad.AUTONOMOUS_SCAN_QUOTA_PER_SEC,
			cacheTtlSec = C.Manpad.AUTONOMOUS_TARGET_CACHE_TTL_SEC,
			cacheCapacity = C.Manpad.AUTONOMOUS_TARGET_CACHE_CAPACITY,
			metrics = {
				scansTotal = "medusa_manpad_autonomous_scans_total",
				scanDuration = "medusa_manpad_autonomous_scan_duration_seconds",
				cacheReuses = "medusa_manpad_autonomous_cache_reuses_total",
				queueDepth = "medusa_manpad_autonomous_scan_queue_depth",
			},
		})
		ctx.localSearch = search
	end
	search.coalitionId = ctx.coalitionId
	return search
end

local function refreshAutonomousTargetCaches(ctx, manpads, now)
	local search = getLocalSearch(ctx)
	search:refresh(manpads, now, function(battery)
		local state = battery.Manpad.SleepWakeState
		return state ~= MSWS.HOT and state ~= MSWS.COOLDOWN
	end)
end

local function processAutonomousTargets(ctx, battery, now, posture)
	if ctx.coalitionId == nil then
		return false
	end
	local search = getLocalSearch(ctx)
	local targets = search:getTargets(battery.BatteryId, now)
	if not targets then
		return false
	end
	local hostileAircraftFound = false
	for i = 1, targets:size() do
		local unit, snapshot = search:resolve(targets:get(i))
		if unit then
			hostileAircraftFound = true
			if processThreatCandidate(ctx, battery, snapshot, now, posture) then
				local controller = GetGroupController(battery.GroupName)
				if controller then
					KnowControllerTarget(controller, unit, false, true)
				end
				return true
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
	local geoGrid = ctx.networkedGeoGrid or ctx.geoGrid
	local now = ctx.now
	local posture = ctx.posture
	local alertnessDecaySec = ctx.doctrine.MANPADAlertnessDecaySec
	refreshAutonomousTargetCaches(ctx, manpads, now)
	for i = 1, #manpads do
		evaluateSingle(ctx, manpads[i], trackStore, geoGrid, now, posture, alertnessDecaySec)
	end
end

function Medusa.Services.ManpadService.refreshOnePosition(ctx)
	local manpads = ctx.manpadStore:getAll(_batteryBuffer)
	local refreshed
	ctx.posRefreshBatteryId, refreshed = CrewPerceptionService.refreshOne({
		batteries = manpads,
		cursorBatteryId = ctx.posRefreshBatteryId,
		now = ctx.now,
		geoGrid = ctx.localGeoGrid or ctx.geoGrid,
		geoGridType = "Manpad",
		stateField = "Manpad",
		unitRole = C.BatteryUnitRole.MANPAD,
	})
	if refreshed then
		Medusa.Services.MetricsService.inc("medusa_manpad_position_refreshes_total")
	end
end
