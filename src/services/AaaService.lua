require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")
require("entities.Battery")
require("services.BatteryActivationService")
require("services.LocalSearchService")
require("services.CrewPerceptionService")
require("services.NeighborPropagationService")

--[[
    AAA SERVICE

    What this service does
    - Manages local detection and response for AAA groups without a working search radar.
    - Returns radar-directed AAA groups to the normal IADS battery workflow.

    How others use it
    - IadsNetwork calls the evaluation, position refresh, and cleanup operations.
--]]

Medusa.Services.AaaService = {}

local C = Medusa.Constants
local AC = C.Aaa
local ARS = AC.ResponseState
local AM = AC.Mode
local AS = C.ActivationState
local BR = C.BatteryRole
local BUR = C.BatteryUnitRole
local BOS = C.BatteryOperationalStatus
local BAS = Medusa.Services.BatteryActivationService
local Battery = Medusa.Entities.Battery
local LocalSearchService = Medusa.Services.LocalSearchService
local CrewPerceptionService = Medusa.Services.CrewPerceptionService
local NeighborPropagationService = Medusa.Services.NeighborPropagationService
local logger = Medusa.Logger:ns("AaaService")
local DETECTION_SOURCE = {
	AUDIO = "AUDIO",
	VISUAL = "VISUAL",
}
local PRIMARY_PROFILES = { CrewPerceptionService.PRIMARY_PROFILE }
local BARRAGE_STATES = {
	[ARS.BARRAGE_FIRE] = true,
	[ARS.BARRAGE_PAUSE] = true,
}
local VISUAL_SEARCH_RADIUS_M =
	math.sqrt(C.LocalAircraftDetection.PRIMARY_RANGE_M ^ 2 + C.LocalAircraftDetection.RELATIVE_ALTITUDE_CEILING_M ^ 2)
local POSTURE_CHANCE_MULTIPLIER = {
	[C.Posture.HOT_WAR] = 1,
	[C.Posture.WARM_WAR] = 0.75,
	[C.Posture.COLD_WAR] = 0.5,
}
local batteryBuffer = {}
local independentBuffer = {}
local candidateBuffer = {}

function Medusa.Services.AaaService.newBarrageState()
	return {
		participants = {},
		limitsByNetwork = {},
	}
end

function Medusa.Services.AaaService.setBarrageLimit(state, networkId, maxGroups)
	state.limitsByNetwork[networkId] = maxGroups
end

local function clear(values)
	for i = #values, 1, -1 do
		values[i] = nil
	end
end

local function captureDetection(target)
	local velocity = target.Velocity or GetUnitVelocity(target.UnitName) or {}
	return {
		UnitName = target.UnitName,
		Position = { x = target.Position.x, y = target.Position.y, z = target.Position.z },
		Velocity = { x = velocity.x or 0, y = velocity.y or 0, z = velocity.z or 0 },
	}
end

local function resetResponse(aaa)
	aaa.ResponseState = ARS.IDLE
	aaa.ResponseAt = nil
	aaa.ResponseUntil = nil
	aaa.PendingTarget = nil
	aaa.BarrageUntil = nil
	aaa.BarragePending = nil
	aaa.FireTaskActive = false
end

local function randomDuration(minSec, maxSec)
	return minSec + math.random() * (maxSec - minSec)
end

local function registerBarrageLimit(ctx)
	Medusa.Services.AaaService.setBarrageLimit(ctx.barrageState, ctx.networkId, ctx.doctrine.AAA.MaxBarrageGroups)
end

local function barrageLimit(state)
	local limit
	for _, configured in pairs(state.limitsByNetwork) do
		if not limit or configured < limit then
			limit = configured
		end
	end
	return limit or AC.DEFAULT_MAX_BARRAGE_GROUPS
end

local function pruneBarrageParticipants(state, now)
	local count = 0
	for batteryId, battery in pairs(state.participants) do
		local aaa = battery.Aaa
		if not aaa or not aaa.BarrageUntil or aaa.BarrageUntil <= now or battery.OperationalStatus ~= BOS.ACTIVE then
			state.participants[batteryId] = nil
		else
			count = count + 1
		end
	end
	return count
end

local function reserveBarrageParticipant(state, battery, now)
	local count = pruneBarrageParticipants(state, now)
	if state.participants[battery.BatteryId] then
		return true
	end
	if count >= barrageLimit(state) then
		return false
	end
	state.participants[battery.BatteryId] = battery
	return true
end

local function releaseBarrageParticipant(state, battery)
	state.participants[battery.BatteryId] = nil
end

local function cancelPendingInfection(battery)
	return NeighborPropagationService.cancel(battery, "Aaa", "InfectionTimerId")
end

local function currentMode(battery)
	if Battery.isRadarDirectedAaa(battery) then
		return AM.RADAR_DIRECTED
	end
	return AM.INDEPENDENT
end

function Medusa.Services.AaaService.initializeMode(battery)
	battery.Aaa.Mode = currentMode(battery)
	return battery.Aaa.Mode
end

function Medusa.Services.AaaService.rebuildHeadings(battery)
	CrewPerceptionService.rebuildHeadings(battery, battery.Aaa, BUR.AAA)
end

local function stopFireTask(battery)
	local aaa = battery.Aaa
	if aaa.FireTaskActive then
		local controller = GetGroupController(battery.GroupName)
		if controller then
			PopControllerTask(controller)
		end
		aaa.FireTaskActive = false
	end
end

local function finishResponse(ctx, battery)
	local aaa = battery.Aaa
	cancelPendingInfection(battery)
	stopFireTask(battery)
	releaseBarrageParticipant(ctx.barrageState, battery)
	if battery.ActivationState ~= AS.STATE_COLD and not BAS.goCold(battery, ctx.now, ctx.trackStore) then
		return false
	end
	resetResponse(aaa)
	logger:debug(string.format("AAA %s returned to IDLE", battery.GroupName))
	return true
end

local function reconcileMode(ctx, battery)
	local aaa = battery.Aaa
	local mode = currentMode(battery)
	if aaa.Mode == mode then
		return mode
	end
	if ctx.spatialIndex then
		ctx.spatialIndex:withdrawBattery(battery.BatteryId)
	end
	if aaa.ResponseState ~= ARS.IDLE then
		if not finishResponse(ctx, battery) then
			return nil
		end
	end
	if mode == AM.INDEPENDENT then
		if battery.CurrentTargetTrackId then
			Battery.releaseTrack(battery, ctx.trackStore)
		end
		if battery.ActivationState ~= AS.STATE_COLD and not BAS.goCold(battery, ctx.now, ctx.trackStore) then
			return nil
		end
	else
		cancelPendingInfection(battery)
	end
	aaa.Mode = mode
	if ctx.spatialIndex then
		ctx.spatialIndex:syncBattery(battery)
	end
	if ctx.onModeChanged then
		ctx.onModeChanged(battery, mode)
	end
	logger:debug(string.format("AAA %s mode changed to %s", battery.GroupName, mode))
	return mode
end

local function getLocalSearch(ctx, searchRadiusM)
	local search = ctx.localSearch
	if not search then
		local D = C.LocalAircraftDetection
		search = LocalSearchService:new({
			coalitionId = ctx.coalitionId,
			searchRadiusM = searchRadiusM,
			quotaPerSec = D.SCAN_QUOTA_PER_SEC,
			cacheTtlSec = D.TARGET_CACHE_TTL_SEC,
			cacheCapacity = D.TARGET_CACHE_CAPACITY,
			metrics = {
				scansTotal = "medusa_aaa_local_searches_total",
				scanDuration = "medusa_aaa_local_search_duration_seconds",
				cacheReuses = "medusa_aaa_local_search_cache_reuses_total",
				queueDepth = "medusa_aaa_local_search_queue_depth",
			},
		})
		ctx.localSearch = search
	end
	search.coalitionId = ctx.coalitionId
	search:setSearchRadius(searchRadiusM)
	return search
end

local function squaredDistance(position, target)
	local dx = target.Position.x - position.x
	local dy = target.Position.y - position.y
	local dz = target.Position.z - position.z
	return dx * dx + dy * dy + dz * dz
end

local function collectCandidates(search, battery, now)
	clear(candidateBuffer)
	local targets = search:getTargets(battery.BatteryId, now)
	if not targets then
		return candidateBuffer
	end
	for i = 1, targets:size() do
		local _, target = search:resolve(targets:get(i))
		if target then
			candidateBuffer[#candidateBuffer + 1] = target
		end
	end
	table.sort(candidateBuffer, function(left, right)
		return squaredDistance(battery.Position, left) < squaredDistance(battery.Position, right)
	end)
	return candidateBuffer
end

local function alert(battery, target, source, now)
	local aaa = battery.Aaa
	aaa.ResponseState = ARS.ALERT
	aaa.ResponseAt = now + AC.REACTION_DELAY_SEC
	aaa.PendingTarget = captureDetection(target)
	local metricName = source == DETECTION_SOURCE.VISUAL and "medusa_aaa_visual_detections_total"
		or "medusa_aaa_audio_detections_total"
	Medusa.Services.MetricsService.inc(metricName)
	logger:debug(string.format("AAA %s detected %s by %s", battery.GroupName, target.UnitName, source))
end

local function tryDetection(ctx, search, battery, audioRangeM)
	local aaa = battery.Aaa
	local candidates = collectCandidates(search, battery, ctx.now)
	for i = 1, #candidates do
		local target = candidates[i]
		if CrewPerceptionService.canSee(battery.Position, target.Position, aaa, PRIMARY_PROFILES) then
			alert(battery, target, DETECTION_SOURCE.VISUAL, ctx.now)
			return true
		end
	end

	local lastAttempt = aaa.LastAudioAttemptTime
	if lastAttempt and ctx.now - lastAttempt < AC.AUDIO_RETRY_SEC then
		return false
	end
	aaa.LastAudioAttemptTime = ctx.now
	local chance = AC.AUDIO_DETECTION_CHANCE * (POSTURE_CHANCE_MULTIPLIER[ctx.posture] or 1)
	for i = 1, #candidates do
		local target = candidates[i]
		if CrewPerceptionService.hears(battery.Position, target.Position, audioRangeM) then
			Medusa.Services.MetricsService.inc("medusa_aaa_audio_attempts_total")
			local roll = math.random()
			if roll < chance then
				alert(battery, target, DETECTION_SOURCE.AUDIO, ctx.now)
				return true
			end
			logger:debug(
				string.format(
					"AAA %s failed audio detection of %s (roll=%.3f chance=%.3f)",
					battery.GroupName,
					target.UnitName,
					roll,
					chance
				)
			)
		end
	end
	return false
end

local function capSlantRange(battery, point)
	local dx = point.x - battery.Position.x
	local dy = point.y - battery.Position.y
	local dz = point.z - battery.Position.z
	local range = battery.WeaponRangeMax or 0
	local horizontalSquared = dx * dx + dz * dz
	local allowedHorizontalSquared = range * range - dy * dy
	if horizontalSquared <= allowedHorizontalSquared then
		return
	end
	if allowedHorizontalSquared <= 0 then
		point.x = battery.Position.x
		point.z = battery.Position.z
		return
	end
	local scale = math.sqrt(allowedHorizontalSquared / horizontalSquared)
	point.x = battery.Position.x + dx * scale
	point.z = battery.Position.z + dz * scale
end

local function beginLocalAcquisition(battery, now)
	local aaa = battery.Aaa
	aaa.ResponseState = ARS.LOCAL_ACQUISITION
	aaa.ResponseUntil = now + AC.LOCAL_ACQUISITION_DURATION_SEC
	Medusa.Services.MetricsService.inc("medusa_aaa_local_acquisition_responses_total")
	logger:debug(string.format("AAA %s selected LOCAL_ACQUISITION", battery.GroupName))
end

local function createFireAtPointTask(point)
	return {
		id = "FireAtPoint",
		params = {
			point = { x = point.x, y = point.z },
			radius = AC.AREA_FIRE_RADIUS_M,
			altitude = point.y,
			alt_type = 0,
		},
	}
end

local function selectFirePoint(battery, target, errorRadiusM)
	local leadSec = AC.AREA_FIRE_LEAD_MIN_SEC + math.random() * (AC.AREA_FIRE_LEAD_MAX_SEC - AC.AREA_FIRE_LEAD_MIN_SEC)
	local predicted = {
		x = target.Position.x + target.Velocity.x * leadSec,
		y = target.Position.y,
		z = target.Position.z + target.Velocity.z * leadSec,
	}
	local errorAngle = math.random() * 2 * math.pi
	local errorDistance = math.random() * errorRadiusM
	predicted.x = predicted.x + math.cos(errorAngle) * errorDistance
	predicted.z = predicted.z + math.sin(errorAngle) * errorDistance
	predicted.y = math.max(predicted.y, GetTerrainHeight(predicted) + AC.MIN_AIM_AGL_M)
	capSlantRange(battery, predicted)
	return predicted
end

local function pushFireTask(battery, point)
	local controller = GetGroupController(battery.GroupName)
	local task = createFireAtPointTask(point)
	PushControllerTask(controller, task)
	battery.Aaa.FireTaskActive = true
	battery.Aaa.LastFirePoint = { x = point.x, y = point.y, z = point.z }
end

local function beginAreaFire(battery, target, now)
	local predicted = selectFirePoint(battery, target, AC.AREA_FIRE_ERROR_M)
	pushFireTask(battery, predicted)
	battery.Aaa.ResponseState = ARS.AREA_FIRE
	battery.Aaa.ResponseUntil = now + AC.AREA_FIRE_DURATION_SEC
	Medusa.Services.MetricsService.inc("medusa_aaa_area_fire_responses_total")
	logger:debug(string.format("AAA %s selected AREA_FIRE", battery.GroupName))
end

local function beginBarragePause(battery, now)
	stopFireTask(battery)
	battery.Aaa.ResponseState = ARS.BARRAGE_PAUSE
	battery.Aaa.ResponseUntil = now + randomDuration(AC.BARRAGE_PAUSE_MIN_SEC, AC.BARRAGE_PAUSE_MAX_SEC)
	logger:debug(string.format("AAA %s paused barrage fire", battery.GroupName))
end

local function beginBarrage(ctx, battery)
	local aaa = battery.Aaa
	if not reserveBarrageParticipant(ctx.barrageState, battery, ctx.now) then
		logger:debug(string.format("AAA %s did not start barrage: participant limit reached", battery.GroupName))
		return false
	end
	aaa.BarrageUntil = ctx.now + AC.BARRAGE_DURATION_SEC
	aaa.BarragePending = nil
	beginBarragePause(battery, ctx.now)
	Medusa.Services.MetricsService.inc("medusa_aaa_barrage_responses_total")
	logger:debug(string.format("AAA %s started barrage fire", battery.GroupName))
	return true
end

local function beginBarrageBurst(battery, now, sourceFirePoint)
	local target = battery.Aaa.PendingTarget
	if not target then
		return false
	end
	local point
	if sourceFirePoint then
		point = { x = sourceFirePoint.x, y = sourceFirePoint.y, z = sourceFirePoint.z }
		point.y = math.max(point.y, GetTerrainHeight(point) + AC.MIN_AIM_AGL_M)
		capSlantRange(battery, point)
	else
		point = selectFirePoint(battery, target, AC.BARRAGE_ERROR_M)
	end
	pushFireTask(battery, point)
	battery.Aaa.ResponseState = ARS.BARRAGE_FIRE
	battery.Aaa.ResponseUntil = now + randomDuration(AC.BARRAGE_BURST_MIN_SEC, AC.BARRAGE_BURST_MAX_SEC)
	Medusa.Services.MetricsService.inc("medusa_aaa_barrage_bursts_total", nil, { network = battery.NetworkId })
	logger:debug(string.format("AAA %s started barrage burst", battery.GroupName))
	return true
end

local function isInfectionEligible(battery)
	if not Battery.isIndependentAaa(battery) then
		return false
	end
	local state = battery.Aaa.ResponseState
	return battery.OperationalStatus == BOS.ACTIVE
		and (battery.TotalAmmoStatus or 0) > 0
		and (state == ARS.IDLE or state == ARS.ALERT)
end

local function receiveBarrageInfection(battery, payload, now)
	if now >= payload.barrageUntil or payload.doctrine.ROE == C.ROEState.HOLD or not isInfectionEligible(battery) then
		return
	end
	if not reserveBarrageParticipant(payload.barrageState, battery, now) then
		logger:debug(string.format("AAA %s did not join barrage: participant limit reached", battery.GroupName))
		return
	end
	if battery.ActivationState ~= AS.STATE_HOT and not BAS.forceGoHot(battery, now) then
		releaseBarrageParticipant(payload.barrageState, battery)
		return
	end
	local aaa = battery.Aaa
	aaa.PendingTarget = captureDetection(payload.target)
	aaa.BarrageUntil = payload.barrageUntil
	aaa.BarragePending = nil
	beginBarrageBurst(battery, now, payload.sourceFirePoint)
	local labels = { network = battery.NetworkId }
	Medusa.Services.MetricsService.inc("medusa_aaa_barrage_responses_total", nil, labels)
	Medusa.Services.MetricsService.inc("medusa_aaa_barrage_infections_total", nil, labels)
	logger:debug(string.format("AAA %s joined barrage fire", battery.GroupName))
end

local function sourceAimTarget(ctx, battery)
	local aaa = battery.Aaa
	local firePoint = aaa.FireTaskActive and aaa.LastFirePoint or nil
	if firePoint then
		return { Position = firePoint, Velocity = {} }
	end
	if aaa.PendingTarget then
		return aaa.PendingTarget
	end
	if battery.CurrentTargetTrackId and ctx.trackStore then
		local track = ctx.trackStore:get(battery.CurrentTargetTrackId)
		if track and track.Position then
			return track
		end
	end
	local heading = aaa.UnitHeadings[1] or { hx = 1, hz = 0 }
	local rangeM = math.max(1000, math.min((battery.WeaponRangeMax or 0) * 0.5, AC.BARRAGE_PROPAGATION_RANGE_M))
	local target = {
		Position = {
			x = battery.Position.x + heading.hx * rangeM,
			y = battery.Position.y + AC.MIN_AIM_AGL_M,
			z = battery.Position.z + heading.hz * rangeM,
		},
		Velocity = { x = 0, y = 0, z = 0 },
	}
	return target
end

function Medusa.Services.AaaService.onShot(ctx, battery, unit, now)
	if battery.Role ~= BR.AAA or not battery.Position or not unit then
		return 0
	end
	registerBarrageLimit(ctx)
	local barrageUntil = battery.Aaa.BarrageUntil
	if barrageUntil and barrageUntil <= now then
		if BARRAGE_STATES[battery.Aaa.ResponseState] then
			return 0
		end
		barrageUntil = nil
	end
	local lastPropagation = unit.LastAaaPropagationTime
	if lastPropagation and now - lastPropagation < AC.BARRAGE_PROPAGATION_DEBOUNCE_SEC then
		return 0
	end
	unit.LastAaaPropagationTime = now
	local target = captureDetection(sourceAimTarget(ctx, battery))
	if not barrageUntil then
		barrageUntil = now + AC.BARRAGE_DURATION_SEC
	end
	local payload = {
		target = target,
		sourceFirePoint = { x = target.Position.x, y = target.Position.y, z = target.Position.z },
		barrageUntil = barrageUntil,
		barrageState = ctx.barrageState,
		doctrine = ctx.doctrine,
	}
	local neighbors = NeighborPropagationService.findRecipients(
		ctx.localGeoGrid or ctx.geoGrid,
		ctx.batteryStore,
		battery.Position,
		AC.BARRAGE_PROPAGATION_RANGE_M,
		"Aaa",
		battery.BatteryId
	)
	local scheduled = 0
	for i = 1, #neighbors do
		local neighbor = neighbors[i]
		if
			isInfectionEligible(neighbor)
			and NeighborPropagationService.schedule({
				recipient = neighbor,
				repository = ctx.batteryStore,
				stateField = "Aaa",
				timerField = "InfectionTimerId",
				minDelaySec = AC.BARRAGE_PROPAGATION_DELAY_MIN_SEC,
				maxDelaySec = AC.BARRAGE_PROPAGATION_DELAY_MAX_SEC,
				payload = payload,
				receive = receiveBarrageInfection,
			})
		then
			scheduled = scheduled + 1
		end
	end
	return scheduled
end

local function barrageIsActive(aaa, now)
	return aaa.BarrageUntil ~= nil and now < aaa.BarrageUntil
end

local function resumeBarrageOrFinish(ctx, battery)
	if barrageIsActive(battery.Aaa, ctx.now) then
		beginBarragePause(battery, ctx.now)
		return
	end
	finishResponse(ctx, battery)
end

local function beginResponse(ctx, search, battery)
	local aaa = battery.Aaa
	cancelPendingInfection(battery)
	aaa.ResponseAt = nil
	local detectedTarget = aaa.PendingTarget
	local unit = detectedTarget and GetUnit(detectedTarget.UnitName) or nil
	if
		not unit
		or not search:isHostileAircraft(unit)
		or (battery.ActivationState ~= AS.STATE_HOT and not BAS.forceGoHot(battery, ctx.now))
	then
		resumeBarrageOrFinish(ctx, battery)
		return
	end
	local dayChance = ctx.doctrine.AAA.AreaFireChance
	local areaFireChance = IsNightTime() and (1 - dayChance) or dayChance
	if math.random() < areaFireChance then
		beginAreaFire(battery, detectedTarget, ctx.now)
	else
		beginLocalAcquisition(battery, ctx.now)
	end
end

local function completeAreaFire(ctx, battery)
	local aaa = battery.Aaa
	stopFireTask(battery)
	if aaa.BarrageUntil then
		resumeBarrageOrFinish(ctx, battery)
		return
	end
	if aaa.BarragePending == nil then
		aaa.BarragePending = math.random() < AC.BARRAGE_ESCALATION_CHANCE
	end
	if aaa.BarragePending then
		if not beginBarrage(ctx, battery) then
			finishResponse(ctx, battery)
		end
	else
		finishResponse(ctx, battery)
	end
end

local function evaluateBarrage(ctx, search, battery, audioRangeM)
	local aaa = battery.Aaa
	if not barrageIsActive(aaa, ctx.now) then
		finishResponse(ctx, battery)
		return
	end
	if tryDetection(ctx, search, battery, audioRangeM) then
		stopFireTask(battery)
		beginResponse(ctx, search, battery)
		return
	end
	if ctx.now < aaa.ResponseUntil then
		return
	end
	if aaa.ResponseState == ARS.BARRAGE_FIRE then
		beginBarragePause(battery, ctx.now)
	elseif not beginBarrageBurst(battery, ctx.now) then
		finishResponse(ctx, battery)
	end
end

local function evaluateBattery(ctx, search, battery, audioRangeM)
	local aaa = battery.Aaa
	local state = aaa.ResponseState
	if ctx.doctrine.ROE == C.ROEState.HOLD then
		if state ~= ARS.IDLE then
			finishResponse(ctx, battery)
		end
		return
	end
	if state == ARS.IDLE then
		tryDetection(ctx, search, battery, audioRangeM)
	elseif state == ARS.ALERT and ctx.now >= aaa.ResponseAt then
		beginResponse(ctx, search, battery)
	elseif state == ARS.AREA_FIRE and ctx.now >= aaa.ResponseUntil then
		completeAreaFire(ctx, battery)
	elseif state == ARS.LOCAL_ACQUISITION and ctx.now >= aaa.ResponseUntil then
		resumeBarrageOrFinish(ctx, battery)
	elseif BARRAGE_STATES[state] then
		evaluateBarrage(ctx, search, battery, audioRangeM)
	end
end

function Medusa.Services.AaaService.evaluate(ctx)
	registerBarrageLimit(ctx)
	local allBatteries = ctx.batteryStore:getAll(batteryBuffer)
	clear(independentBuffer)
	for i = 1, #allBatteries do
		local battery = allBatteries[i]
		if battery.Role == BR.AAA then
			local mode = reconcileMode(ctx, battery)
			if
				mode == AM.INDEPENDENT
				and battery.OperationalStatus == BOS.ACTIVE
				and (battery.TotalAmmoStatus or 0) > 0
			then
				independentBuffer[#independentBuffer + 1] = battery
			elseif mode == AM.INDEPENDENT and battery.Aaa.ResponseState ~= ARS.IDLE then
				finishResponse(ctx, battery)
			end
		end
	end
	local audioRangeM = ctx.doctrine.AAA.AudioRangeM
	local searchRadiusM = math.max(audioRangeM, VISUAL_SEARCH_RADIUS_M)
	local search = getLocalSearch(ctx, searchRadiusM)
	search:refresh(independentBuffer, ctx.now, function(battery)
		local state = battery.Aaa.ResponseState
		return (state == ARS.IDLE or state == ARS.BARRAGE_FIRE or state == ARS.BARRAGE_PAUSE)
			and ctx.doctrine.ROE ~= C.ROEState.HOLD
	end)
	for i = 1, #independentBuffer do
		evaluateBattery(ctx, search, independentBuffer[i], audioRangeM)
	end
end

function Medusa.Services.AaaService.refreshOnePosition(ctx)
	local allBatteries = ctx.batteryStore:getAll(batteryBuffer)
	clear(independentBuffer)
	for i = 1, #allBatteries do
		if Battery.isIndependentAaa(allBatteries[i]) and allBatteries[i].Aaa.Mode == AM.INDEPENDENT then
			independentBuffer[#independentBuffer + 1] = allBatteries[i]
		end
	end
	local refreshed
	ctx.posRefreshBatteryId, refreshed = CrewPerceptionService.refreshOne({
		batteries = independentBuffer,
		cursorBatteryId = ctx.posRefreshBatteryId,
		now = ctx.now,
		geoGrid = ctx.localGeoGrid or ctx.geoGrid,
		geoGridType = "Aaa",
		stateField = "Aaa",
		unitRole = BUR.AAA,
	})
	if refreshed then
		Medusa.Services.MetricsService.inc("medusa_aaa_position_refreshes_total")
	end
end

function Medusa.Services.AaaService.cleanup(ctx)
	local allBatteries = ctx.batteryStore:getAll(batteryBuffer)
	for i = 1, #allBatteries do
		Medusa.Services.AaaService.cleanupBattery(ctx, allBatteries[i])
	end
	ctx.barrageState.limitsByNetwork[ctx.networkId] = nil
end

function Medusa.Services.AaaService.cleanupBattery(ctx, battery)
	if battery.Role ~= BR.AAA then
		return true
	end
	if battery.Aaa.ResponseState == ARS.IDLE then
		cancelPendingInfection(battery)
		releaseBarrageParticipant(ctx.barrageState, battery)
		return true
	end
	return finishResponse(ctx, battery)
end
