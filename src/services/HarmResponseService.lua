require("_header")
require("services.Services")
require("services.SpatialQuery")
require("core.Constants")
require("core.Logger")
require("services.BatteryActivationService")
require("services.PointDefenseService")
require("services.HarmDetectionService")

--[[
            ██╗  ██╗ █████╗ ██████╗ ███╗   ███╗    ██████╗ ███████╗███████╗██████╗  ██████╗ ███╗   ██╗███████╗███████╗
            ██║  ██║██╔══██╗██╔══██╗████╗ ████║    ██╔══██╗██╔════╝██╔════╝██╔══██╗██╔═══██╗████╗  ██║██╔════╝██╔════╝
            ███████║███████║██████╔╝██╔████╔██║    ██████╔╝█████╗  ███████╗██████╔╝██║   ██║██╔██╗ ██║███████╗█████╗
            ██╔══██║██╔══██║██╔══██╗██║╚██╔╝██║    ██╔══██╗██╔══╝  ╚════██║██╔═══╝ ██║   ██║██║╚██╗██║╚════██║██╔══╝
            ██║  ██║██║  ██║██║  ██║██║ ╚═╝ ██║    ██║  ██║███████╗███████║██║     ╚██████╔╝██║ ╚████║███████║███████╗
            ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝    ╚═╝  ╚═╝╚══════╝╚══════╝╚═╝      ╚═════╝ ╚═╝  ╚═══╝╚══════╝╚══════╝

    What this service does
    - Reacts to tracks classified as probable or confirmed HARMs by HarmDetectionService.
    - Decides per battery whether to shut down, self-defend, or rely on point defense based on doctrine.
    - Clears HARM defense state when threats expire or are no longer inbound.

    How others use it
    - IadsNetwork calls executeResponse each tick after HARM detection scoring completes.
    - PointDefenseService checks HARM defense state to activate nearby SHORAD for protection.
--]]

Medusa.Services.HarmResponseService = {}

local _logger = Medusa.Logger:ns("HarmResponseService")
local AAT = Medusa.Constants.AssessedAircraftType
local HDS = Medusa.Constants.HarmDefenseState
--- @type table Reusable buffer for track iteration
Medusa.Services.HarmResponseService._trackBuffer = {}
local _trackBuffer = Medusa.Services.HarmResponseService._trackBuffer
--- @type table Reusable buffer for battery iteration in executeResponse clear loop
Medusa.Services.HarmResponseService._batteryResetBuffer = {}
local _batteryResetBuffer = Medusa.Services.HarmResponseService._batteryResetBuffer
local AS = Medusa.Constants.ActivationState
local BOS = Medusa.Constants.BatteryOperationalStatus
local BatteryActivationService = Medusa.Services.BatteryActivationService
local C = Medusa.Constants
local HRS = Medusa.Constants.HarmResponseStrategy
--- @type fun(px:number,py:number,pz:number,vx:number,vy:number,vz:number,ex:number,ey:number,ez:number):number,number Local alias for CPA computation
local computeCPA3D = Medusa.Services.HarmDetectionService.computeCPA3D

local function computeTTI(harmTrack, battery)
	local dist = Distance2D(harmTrack.Position, battery.Position)
	local vel = harmTrack.SmoothedVelocity or harmTrack.Velocity
	if not vel then
		return dist / C.HARM_DEFAULT_SPEED_MPS
	end
	local speed = VecLength(vel)
	if speed < 1.0 then
		return dist / C.HARM_DEFAULT_SPEED_MPS
	end
	return dist / speed
end

--- Is the battery eligible to be evaluated for HARM response?
local function isEligible(battery)
	if battery.IsPointDefense then
		return false
	end
	if battery.OperationalStatus == BOS.DESTROYED or battery.OperationalStatus == BOS.INOPERATIVE then
		return false
	end
	if battery.HarmShutdownUntil then
		return false
	end
	if not battery.Position then
		return false
	end
	return true
end

local function getHeading(harmTrack)
	local vel = harmTrack.SmoothedVelocity or harmTrack.Velocity
	if not vel then
		return nil, nil, nil
	end
	local mag = VecLength2D(vel)
	if mag < 0.1 then
		return nil, nil, nil
	end
	return vel.x / mag, vel.z / mag, vel
end

--- Computes the dot product of a battery's position relative to the harm track's heading.
--- Returns nil if the battery is not eligible for HARM response.
local function computeBatteryDot(battery, hx, hz, harmPos)
	if not isEligible(battery) then
		return nil
	end
	local dx = battery.Position.x - harmPos.x
	local dz = battery.Position.z - harmPos.z
	local dmag = math.sqrt(dx * dx + dz * dz)
	if dmag < 0.1 then
		return nil
	end
	return hx * (dx / dmag) + hz * (dz / dmag)
end

local computeTrackCPA = Medusa.Services.HarmDetectionService.computeTrackCPA

local function findClosestThreatenedBattery(harmTrack, geoGrid, batteryStore, threatRadiusM)
	local hx, hz = getHeading(harmTrack)
	if not hx then
		return nil
	end
	local batteries =
		Medusa.Services.SpatialQuery.batteriesInRadius(geoGrid, batteryStore, harmTrack.Position, C.HARM_MAX_RANGE_M)
	local best, bestCpa = nil, math.huge
	for i = 1, #batteries do
		local dot = computeBatteryDot(batteries[i], hx, hz, harmTrack.Position)
		if dot and dot > 0 then
			local cpaDist = computeTrackCPA(harmTrack, batteries[i].Position)
			if cpaDist < threatRadiusM and cpaDist < bestCpa then
				best = batteries[i]
				bestCpa = cpaDist
			end
		end
	end
	return best
end

local function computePdDefenders(battery, batteryStore)
	local provider = batteryStore:get(battery.PointDefenseProviderId)
	if not provider or provider.HarmCapableUnitCount == 0 then
		return 0
	end
	return provider.HarmCapableUnitCount
end

--- Returns effective defense points for a battery, accounting for ammo saturation and pooling.
local function defensePointsForBattery(battery, saturateOnAmmo)
	local pts = battery.HarmCapableUnitCount
	if saturateOnAmmo then
		pts = math.min(pts, battery.TotalAmmoStatus or 0)
	end
	return pts
end

--- Computes total defense points: own battery + pooled neighbors (if doctrine enables it).
local function computeDefensePoints(battery, doctrine, batteryStore, geoGrid)
	local saturateOnAmmo = doctrine and doctrine.HARMSaturateOnAmmo
	local defenders = defensePointsForBattery(battery, saturateOnAmmo)

	local poolRadius = doctrine and doctrine.PoolDefensePoints and doctrine.PoolDefensePointsRadius
	if poolRadius and geoGrid and battery.Position then
		local nearby =
			Medusa.Services.SpatialQuery.batteriesInRadius(geoGrid, batteryStore, battery.Position, poolRadius)
		for i = 1, #nearby do
			local nb = nearby[i]
			if nb.BatteryId ~= battery.BatteryId and nb.HarmCapableUnitCount > 0 and not nb.IsPointDefense then
				defenders = defenders + defensePointsForBattery(nb, saturateOnAmmo)
			end
		end
	end

	return defenders
end

local function canSelfDefend(battery, tracks, batteryStore, threatRadiusM, includePd, doctrine, geoGrid)
	if battery.HarmCapableUnitCount == 0 then
		return false
	end

	local harmCount = 0
	local LS = Medusa.Constants.TrackLifecycleState
	for i = 1, #tracks do
		local t = tracks[i]
		if t.LifecycleState == LS.ACTIVE and t.AssessedAircraftType == AAT.HARM then
			local vel = t.SmoothedVelocity or t.Velocity
			if vel then
				local cpaDist = computeCPA3D(
					t.Position.x,
					t.Position.y,
					t.Position.z,
					vel.x,
					vel.y,
					vel.z,
					battery.Position.x,
					battery.Position.y,
					battery.Position.z
				)
				if cpaDist < threatRadiusM then
					harmCount = harmCount + 1
				end
			end
		end
	end

	local defenders = computeDefensePoints(battery, doctrine, batteryStore, geoGrid)

	if includePd and battery.PointDefenseProviderId then
		defenders = defenders + computePdDefenders(battery, batteryStore)
	end

	local pdProtected = includePd and battery.PointDefenseProviderId ~= nil
	local ratio = harmCount > 0 and (defenders / harmCount) or 0
	local result = harmCount == 0 or ratio > 1

	battery.HarmDefenseDefenders = defenders
	battery.HarmDefenseThreats = harmCount
	battery.HarmDefenseRatio = ratio

	_logger:debug(
		string.format(
			"canSelfDefend %s: own=%d, total=%d, pdIncluded=%s, pdProtected=%s, harmsInRange=%d, ratio=%.1f, result=%s",
			battery.GroupName or battery.BatteryId,
			battery.HarmCapableUnitCount,
			defenders,
			tostring(includePd),
			tostring(pdProtected),
			harmCount,
			ratio,
			tostring(result)
		)
	)

	return result
end

local function shutdownBattery(
	battery,
	harmTrack,
	now,
	batteryStore,
	trackStore,
	tracks,
	threatRadiusM,
	strategy,
	doctrine,
	geoGrid
)
	-- Battery activated for HARM intercept this tick: don't shut it down
	if Medusa.Services.PointDefenseService._harmActivationBuffer[battery.BatteryId] then
		return false
	end
	-- A battery engaging any HARM gets INTERCEPTING state but still checks saturation
	local engagingHarm = false
	if battery.CurrentTargetTrackId then
		local engagedTrack = trackStore:get(battery.CurrentTargetTrackId)
		engagingHarm = engagedTrack and engagedTrack.AssessedAircraftType == AAT.HARM
	end
	if strategy == HRS.SHUTDOWN_UNLESS_PD or strategy == HRS.AUTO_DEFENSE then
		if battery.PointDefenseProviderId then
			local provider = batteryStore:get(battery.PointDefenseProviderId)
			if Medusa.Services.PointDefenseService.isProviderViable(provider) and provider.HarmCapableUnitCount > 0 then
				battery.HarmDefenseState = HDS.PD_PROTECTED
				_logger:debug(
					string.format(
						"battery %s protected by PD %s, skipping HARM shutdown",
						battery.BatteryId,
						provider.BatteryId
					)
				)
				return false
			end
		end
	end
	if strategy == HRS.SELF_DEFEND or strategy == HRS.AUTO_DEFENSE then
		local includePd = (strategy == HRS.AUTO_DEFENSE)
		if canSelfDefend(battery, tracks, batteryStore, threatRadiusM, includePd, doctrine, geoGrid) then
			battery.HarmDefenseState = engagingHarm and HDS.INTERCEPTING or HDS.SELF_DEFENDING
			return false
		end
	end
	-- Engaging a HARM but saturated, still shut down
	if engagingHarm then
		_logger:info(
			string.format(
				"battery %s engaging HARM but saturated (defenders=%d, threats=%d), shutting down",
				battery.GroupName or battery.BatteryId,
				battery.HarmDefenseDefenders,
				battery.HarmDefenseThreats
			)
		)
	end
	battery.HarmDefenseState = HDS.SUPPRESSED
	local shutdownUntil = now + computeTTI(harmTrack, battery) + C.HARM_SHUTDOWN_SAFETY_MARGIN_SEC
	if battery.ActivationState == AS.STATE_COLD then
		battery.HarmShutdownUntil = shutdownUntil
		Medusa.Services.MetricsService.inc("medusa_harm_shutdowns_total")
		return true
	end
	local ok = BatteryActivationService.goHarmShutdown(battery, now, trackStore)
	if ok then
		battery.HarmShutdownUntil = shutdownUntil
		Medusa.Services.MetricsService.inc("medusa_harm_shutdowns_total")
	end
	return ok
end

local function applyLocalizedShutdown(
	track,
	geoGrid,
	batteryStore,
	threatRadiusM,
	now,
	trackStore,
	tracks,
	strategy,
	doctrine
)
	local battery = findClosestThreatenedBattery(track, geoGrid, batteryStore, threatRadiusM)
	if
		not battery
		or not shutdownBattery(
			battery,
			track,
			now,
			batteryStore,
			trackStore,
			tracks,
			threatRadiusM,
			strategy,
			doctrine,
			geoGrid
		)
	then
		return 0
	end
	_logger:info(
		string.format(
			"HARM shutdown: battery %s for track %s (strategy=%s)",
			battery.BatteryId,
			track.TrackId,
			strategy
		)
	)
	return 1
end

--- Top-level entry point called by IadsNetwork each tick after HARM detection.
--- For each confirmed HARM track, this function does two things: activates any
--- nearby point defense batteries (via PointDefenseService), then evaluates each
--- battery within the threat radius for shutdown or self-defense (via
--- applyLocalizedShutdown). The doctrine's HARMResponse strategy controls how
--- aggressively batteries protect themselves versus staying on the air.
--- Before processing, resets every battery's HarmDefenseState to nil so stale
--- defense decisions from the previous tick do not carry over.
--- @param ctx table Pipeline context with trackStore, batteryStore, doctrine, now, geoGrid
--- @return number shutdowns Count of batteries shut down this tick
function Medusa.Services.HarmResponseService.executeResponse(ctx)
	local trackStore = ctx.trackStore
	local batteryStore = ctx.batteryStore
	local doctrine = ctx.doctrine
	local now = ctx.now
	local geoGrid = ctx.geoGrid
	local strategy = doctrine.HARMResponse or HRS.AUTO_DEFENSE
	if strategy == HRS.IGNORE then
		return 0
	end

	local tracks = trackStore:getAll(_trackBuffer)
	local LS = Medusa.Constants.TrackLifecycleState
	local threatRadiusM = doctrine.HARMShutdownM or C.HARM_DEFAULT_THREAT_RADIUS_M
	local shutdowns = 0

	-- Check if any active HARMs exist before clearing/processing
	local hasHarms = false
	for i = 1, #tracks do
		if tracks[i].LifecycleState == LS.ACTIVE and tracks[i].AssessedAircraftType == AAT.HARM then
			hasHarms = true
			break
		end
	end
	-- Clear previous cycle's defense state. nil means "not yet evaluated this tick";
	-- do NOT replace with a default enum. Metrics check for specific states and nil means unevaluated.
	local allBatts = batteryStore:getAll(_batteryResetBuffer)
	for i = 1, #allBatts do
		local b = allBatts[i]
		b.HarmDefenseState = nil
		b.HarmDefenseDefenders = 0
		b.HarmDefenseThreats = 0
		b.HarmDefenseRatio = 0
	end

	if not hasHarms then
		return 0
	end

	local PDS = Medusa.Services.PointDefenseService
	for i = 1, #tracks do
		local track = tracks[i]
		if track.LifecycleState == LS.ACTIVE and track.AssessedAircraftType == AAT.HARM then
			PDS.activateForHarm(track, geoGrid, batteryStore, now, doctrine)
			shutdowns = shutdowns
				+ applyLocalizedShutdown(
					track,
					geoGrid,
					batteryStore,
					threatRadiusM,
					now,
					trackStore,
					tracks,
					strategy,
					doctrine
				)
		end
	end

	if shutdowns > 0 then
		_logger:info(string.format("HARM response: %d batteries shut down", shutdowns))
	end
	return shutdowns
end
