require("_header")
require("services.Services")
require("observability.MetricsService")
require("services.SpatialQuery")
require("core.Constants")
require("core.Logger")
require("services.BatteryActivationService")
require("services.PointDefenseService")
require("services.HarmDetectionService")
require("entities.Battery")
require("entities.Track")

--[[
            ██╗  ██╗ █████╗ ██████╗ ███╗   ███╗    ██████╗ ███████╗███████╗██████╗  ██████╗ ███╗   ██╗███████╗███████╗
            ██║  ██║██╔══██╗██╔══██╗████╗ ████║    ██╔══██╗██╔════╝██╔════╝██╔══██╗██╔═══██╗████╗  ██║██╔════╝██╔════╝
            ███████║███████║██████╔╝██╔████╔██║    ██████╔╝█████╗  ███████╗██████╔╝██║   ██║██╔██╗ ██║███████╗█████╗
            ██╔══██║██╔══██║██╔══██╗██║╚██╔╝██║    ██╔══██╗██╔══╝  ╚════██║██╔═══╝ ██║   ██║██║╚██╗██║╚════██║██╔══╝
            ██║  ██║██║  ██║██║  ██║██║ ╚═╝ ██║    ██║  ██║███████╗███████║██║     ╚██████╔╝██║ ╚████║███████║███████╗
            ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝    ╚═╝  ╚═╝╚══════╝╚══════╝╚═╝      ╚═════╝ ╚═╝  ╚═══╝╚══════╝╚══════╝

    What this service does
    - Decides whether threatened batteries have enough viable capacity to attempt HARM defense.
    - Reports defense only from HOT batteries with an active assignment to a counted HARM.
    - Shuts a threatened battery down when committed capacity remains insufficient.
--]]

Medusa.Services.HarmResponseService = {}

local _logger = Medusa.Logger:ns("HarmResponseService")
local AAT = Medusa.Constants.AssessedAircraftType
local AS = Medusa.Constants.ActivationState
local BOS = Medusa.Constants.BatteryOperationalStatus
local C = Medusa.Constants
local HDS = Medusa.Constants.HarmDefenseState
local HRS = Medusa.Constants.HarmResponseStrategy
local LS = Medusa.Constants.TrackLifecycleState
local Battery = Medusa.Entities.Battery
local BatteryActivationService = Medusa.Services.BatteryActivationService
local PDS = Medusa.Services.PointDefenseService
local computeTrackCPA = Medusa.Services.HarmDetectionService.computeTrackCPA
local _batteryBuffer = {}
local _trackBuffer = {}
local _previousDefenseStateByBattery = {}
local _previouslyDefendingBatteryBuffer = {}

--- Captures each battery's effective HARM defense state before clearing the per-pass response values.
local function captureAndResetDefenseState(batteries)
	for i = #_previouslyDefendingBatteryBuffer, 1, -1 do
		local battery = _previouslyDefendingBatteryBuffer[i]
		_previousDefenseStateByBattery[battery] = nil
		_previouslyDefendingBatteryBuffer[i] = nil
	end
	for i = 1, #batteries do
		local battery = batteries[i]
		if battery.HarmDefenseState ~= nil then
			_previousDefenseStateByBattery[battery] = battery.HarmDefenseState
			_previouslyDefendingBatteryBuffer[#_previouslyDefendingBatteryBuffer + 1] = battery
		end
		battery.HarmDefenseState = nil
		battery.HarmDefenseAvailableCapacity = 0
		battery.HarmDefenseCommittedCapacity = 0
		battery.HarmDefenseThreats = 0
	end
end

--- Reports one battery's effective HARM defense state change and completes its prior-state comparison.
local function logDefenseStateChange(battery)
	local previousState = _previousDefenseStateByBattery[battery]
	if previousState ~= battery.HarmDefenseState then
		_logger:info(
			string.format(
				"battery %s HARM defense state %s -> %s",
				tostring(battery.GroupName or battery.BatteryId),
				tostring(previousState or "NONE"),
				tostring(battery.HarmDefenseState or "NONE")
			)
		)
	end
	_previousDefenseStateByBattery[battery] = nil
end

--- Reports transitions to NONE for batteries whose prior defense state was not replaced this pass.
local function logClearedDefenseStates()
	for i = 1, #_previouslyDefendingBatteryBuffer do
		local battery = _previouslyDefendingBatteryBuffer[i]
		if _previousDefenseStateByBattery[battery] ~= nil then
			logDefenseStateChange(battery)
		end
		_previouslyDefendingBatteryBuffer[i] = nil
	end
end

--- Reports exact nonnil partition equality for HARM response sharing.
local function sharesPartition(left, right)
	return left.PartitionKey ~= nil and left.PartitionKey == right.PartitionKey
end

--- Reports whether battery may own a localized HARM response decision.
local function isEligible(battery)
	return not Battery.isIndependentAaa(battery)
		and not battery.IsPointDefense
		and battery.OperationalStatus ~= BOS.DESTROYED
		and battery.OperationalStatus ~= BOS.INOPERATIVE
		and not battery.HarmShutdownUntil
		and battery.Position ~= nil
end

--- Returns the closest eligible battery on the HARM path within the threat radius.
local function findClosestThreatenedBattery(harmTrack, geoGrid, batteryStore, threatRadiusM)
	local velocity = harmTrack.SmoothedVelocity or harmTrack.Velocity
	local horizontalSpeed = velocity and VecLength2D(velocity) or 0
	if horizontalSpeed < 0.1 then
		return nil
	end
	local headingX = velocity.x / horizontalSpeed
	local headingZ = velocity.z / horizontalSpeed
	local batteries = Medusa.Services.SpatialQuery.batteriesInRadius(geoGrid, batteryStore, harmTrack.Position, C.HARM_MAX_RANGE_M)
	local best = nil
	local bestCpa = math.huge
	for i = 1, #batteries do
		local candidate = batteries[i]
		if isEligible(candidate) and sharesPartition(candidate, harmTrack) then
			local dx = candidate.Position.x - harmTrack.Position.x
			local dz = candidate.Position.z - harmTrack.Position.z
			local distance = math.sqrt(dx * dx + dz * dz)
			local dot = distance > 0.1 and headingX * (dx / distance) + headingZ * (dz / distance) or -1
			if dot > 0 then
				local cpa = computeTrackCPA(harmTrack, candidate.Position)
				if cpa < threatRadiusM and cpa < bestCpa then
					best = candidate
					bestCpa = cpa
				end
			end
		end
	end
	return best
end

--- Returns whether harmTrack threatens battery inside the configured response radius.
local function threatensBattery(harmTrack, battery, threatRadiusM)
	if not sharesPartition(harmTrack, battery) then
		return false
	end
	local velocity = harmTrack.SmoothedVelocity or harmTrack.Velocity
	if not velocity or not harmTrack.Position then
		return false
	end
	local cpa = computeTrackCPA(harmTrack, battery.Position)
	return cpa < threatRadiusM
end

--- Returns capacity points after optional ammunition saturation.
local function capacityFor(battery, doctrine)
	local capacity = battery.HarmDefenseCapacity or 0
	if doctrine and doctrine.HARMSaturateOnAmmo then
		capacity = math.min(capacity, battery.TotalAmmoStatus or 0)
	end
	return capacity
end

--- Adds provider once when it can engage at least one threat in this site context.
local function addAvailableDefender(site, provider, pointDefense, doctrine)
	local capacity = capacityFor(provider, doctrine)
	if site.DefenderIds[provider.BatteryId] or capacity <= 0 then
		return
	end
	if not PDS.canEngageAnyHarm(provider, site.Threats, doctrine) then
		return
	end
	site.DefenderIds[provider.BatteryId] = true
	site.Defenders[#site.Defenders + 1] = { Battery = provider, PointDefense = pointDefense == true }
	site.AvailableCapacity = site.AvailableCapacity + capacity
end

--- Collects unique available own, pooled, and proximity-derived point-defense capacity for one site.
local function collectAvailableDefenders(site, strategy, doctrine, batteryStore, geoGrid)
	local battery = site.Battery
	if strategy == HRS.SELF_DEFEND or strategy == HRS.AUTO_DEFENSE then
		addAvailableDefender(site, battery, false, doctrine)
		local poolRadius = doctrine and doctrine.PoolDefensePoints and doctrine.PoolDefensePointsRadius
		if poolRadius then
			local nearby = Medusa.Services.SpatialQuery.batteriesInRadius(geoGrid, batteryStore, battery.Position, poolRadius)
			for i = 1, #nearby do
				local provider = nearby[i]
				if provider.BatteryId ~= battery.BatteryId and not provider.IsPointDefense and PDS.isProviderViable(provider) and sharesPartition(provider, battery) then
					addAvailableDefender(site, provider, false, doctrine)
				end
			end
		end
	end
	if strategy == HRS.SHUTDOWN_UNLESS_PD or strategy == HRS.AUTO_DEFENSE then
		local nearby = Medusa.Services.SpatialQuery.batteriesInRadius(geoGrid, batteryStore, battery.Position, C.POINT_DEFENSE_SEARCH_RADIUS_M)
		for i = 1, #nearby do
			if PDS.canProtect(nearby[i], battery) then
				addAvailableDefender(site, nearby[i], true, doctrine)
			end
		end
	end
	battery.HarmDefenseAvailableCapacity = site.AvailableCapacity
	battery.HarmDefenseThreats = #site.Threats
end

--- Adds one site's threats to the defender's global nearest-HARM choice.
local function addActivationCandidates(site, doctrine, activationById, activationList)
	if site.AvailableCapacity <= #site.Threats then
		return
	end
	for i = 1, #site.Defenders do
		local defender = site.Defenders[i].Battery
		local activation = activationById[defender.BatteryId]
		if not activation then
			activation = { Battery = defender, Threats = {}, ThreatIds = {} }
			activationById[defender.BatteryId] = activation
			activationList[#activationList + 1] = activation
		end
		for j = 1, #site.Threats do
			local track = site.Threats[j]
			if not activation.ThreatIds[track.TrackId] and PDS.canEngageHarm(defender, track, doctrine) then
				activation.ThreatIds[track.TrackId] = true
				activation.Threats[#activation.Threats + 1] = track
			end
		end
	end
end

--- Returns committed capacity and whether own or point-defense capacity is committed.
local function committedCapacity(site, doctrine)
	local capacity = 0
	local ownCommitted = false
	local pointDefenseCommitted = false
	for i = 1, #site.Defenders do
		local defender = site.Defenders[i]
		local battery = defender.Battery
		if PDS.isProviderViable(battery) and battery.ActivationState == AS.STATE_HOT and battery.CurrentTargetTrackId ~= nil and site.ThreatIds[battery.CurrentTargetTrackId] then
			capacity = capacity + capacityFor(battery, doctrine)
			ownCommitted = ownCommitted or battery == site.Battery
			pointDefenseCommitted = pointDefenseCommitted or defender.PointDefense
		end
	end
	return capacity, ownCommitted, pointDefenseCommitted
end

--- Requests conservative shutdown and records success only after a returned wrapper call.
local function shutdownBattery(site, now, trackStore)
	local battery = site.Battery
	local track = site.TriggerTrack
	local distance = Distance2D(track.Position, battery.Position)
	local velocity = track.SmoothedVelocity or track.Velocity
	local speed = velocity and VecLength(velocity) or C.HARM_DEFAULT_SPEED_MPS
	if speed < 1 then
		speed = C.HARM_DEFAULT_SPEED_MPS
	end
	local shutdownUntil = now + distance / speed + C.HARM_SHUTDOWN_SAFETY_MARGIN_SEC
	local stopped = battery.ActivationState == AS.STATE_COLD or BatteryActivationService.goHarmShutdown(battery, now, trackStore)
	if not stopped then
		return false
	end
	battery.HarmDefenseState = HDS.SUPPRESSED
	battery.HarmShutdownUntil = shutdownUntil
	Medusa.Observability.MetricsService.inc("medusa_harm_shutdowns_total")
	_logger:info(
		string.format(
			"HARM shutdown: battery %s (available=%.1f, committed=%.1f, threats=%d)",
			battery.GroupName or battery.BatteryId,
			battery.HarmDefenseAvailableCapacity,
			battery.HarmDefenseCommittedCapacity,
			battery.HarmDefenseThreats
		)
	)
	return true
end

--- Applies one complete available-attempt-committed response pass for active confirmed HARMs.
function Medusa.Services.HarmResponseService.executeResponse(ctx)
	local batteryStore = ctx.batteryStore
	local trackStore = ctx.trackStore
	local doctrine = ctx.doctrine
	local strategy = doctrine.HARMResponse or HRS.AUTO_DEFENSE
	local batteries = batteryStore:getAll(_batteryBuffer)
	captureAndResetDefenseState(batteries)
	if strategy == HRS.IGNORE then
		logClearedDefenseStates()
		return 0
	end

	local allTracks = trackStore:getAll(_trackBuffer)
	local harms = {}
	for i = 1, #allTracks do
		local track = allTracks[i]
		if track.LifecycleState == LS.ACTIVE and track.AssessedAircraftType == AAT.HARM then
			harms[#harms + 1] = track
		end
	end
	PDS.reconcileProviders(ctx)
	if #harms == 0 then
		logClearedDefenseStates()
		return 0
	end
	local threatRadiusM = doctrine.HARMShutdownM or C.HARM_DEFAULT_THREAT_RADIUS_M
	local sites = {}
	local siteById = {}
	for i = 1, #harms do
		local battery = findClosestThreatenedBattery(harms[i], ctx.geoGrid, batteryStore, threatRadiusM)
		if battery and not siteById[battery.BatteryId] then
			local site = {
				Battery = battery,
				TriggerTrack = harms[i],
				Threats = {},
				ThreatIds = {},
				Defenders = {},
				DefenderIds = {},
				AvailableCapacity = 0,
			}
			siteById[battery.BatteryId] = site
			sites[#sites + 1] = site
		end
	end
	for i = 1, #sites do
		local site = sites[i]
		local shortestTti = math.huge
		for j = 1, #harms do
			local harm = harms[j]
			if threatensBattery(harm, site.Battery, threatRadiusM) then
				site.Threats[#site.Threats + 1] = harm
				site.ThreatIds[harm.TrackId] = true
				local velocity = harm.SmoothedVelocity or harm.Velocity
				local speed = velocity and VecLength(velocity) or C.HARM_DEFAULT_SPEED_MPS
				local tti = Distance2D(harm.Position, site.Battery.Position) / math.max(speed, 1)
				if tti < shortestTti then
					shortestTti = tti
					site.TriggerTrack = harm
				end
			end
		end
		collectAvailableDefenders(site, strategy, doctrine, batteryStore, ctx.geoGrid)
	end

	local activationById = {}
	local activationList = {}
	for i = 1, #sites do
		addActivationCandidates(sites[i], doctrine, activationById, activationList)
	end
	for i = 1, #activationList do
		local activation = activationList[i]
		PDS.activateClosestHarm(activation.Battery, activation.Threats, ctx.now, doctrine, trackStore)
	end

	local shutdowns = 0
	for i = 1, #sites do
		local site = sites[i]
		local committed, ownCommitted, pointDefenseCommitted = committedCapacity(site, doctrine)
		local battery = site.Battery
		battery.HarmDefenseCommittedCapacity = committed
		if committed > #site.Threats then
			if pointDefenseCommitted then
				battery.HarmDefenseState = HDS.PD_PROTECTED
			elseif ownCommitted then
				battery.HarmDefenseState = HDS.INTERCEPTING
			else
				battery.HarmDefenseState = HDS.SELF_DEFENDING
			end
		elseif shutdownBattery(site, ctx.now, trackStore) then
			shutdowns = shutdowns + 1
		end
		_logger:debug(
			string.format(
				"HARM defense %s: available=%.1f, committed=%.1f, threats=%d, state=%s",
				battery.GroupName or battery.BatteryId,
				battery.HarmDefenseAvailableCapacity,
				battery.HarmDefenseCommittedCapacity,
				battery.HarmDefenseThreats,
				tostring(battery.HarmDefenseState)
			)
		)
		logDefenseStateChange(battery)
	end
	logClearedDefenseStates()
	return shutdowns
end
