require("_header")
require("services.Services")
require("services.PkModel")
require("services.SpatialQuery")
require("core.Constants")
require("core.Logger")
require("services.BatteryActivationService")
require("services.HarmDetectionService")

--[[
            ██████╗  ██████╗ ██╗███╗   ██╗████████╗    ██████╗ ███████╗███████╗███████╗███╗   ██╗███████╗███████╗
            ██╔══██╗██╔═══██╗██║████╗  ██║╚══██╔══╝    ██╔══██╗██╔════╝██╔════╝██╔════╝████╗  ██║██╔════╝██╔════╝
            ██████╔╝██║   ██║██║██╔██╗ ██║   ██║       ██║  ██║█████╗  █████╗  █████╗  ██╔██╗ ██║███████╗█████╗
            ██╔═══╝ ██║   ██║██║██║╚██╗██║   ██║       ██║  ██║██╔══╝  ██╔══╝  ██╔══╝  ██║╚██╗██║╚════██║██╔══╝
            ██║     ╚██████╔╝██║██║ ╚████║   ██║       ██████╔╝███████╗██║     ███████╗██║ ╚████║███████║███████╗
            ╚═╝      ╚═════╝ ╚═╝╚═╝  ╚═══╝   ╚═╝       ╚═════╝ ╚══════╝╚═╝     ╚══════╝╚═╝  ╚═══╝╚══════╝╚══════╝

    What this service does
    - Finds SHORAD and HARM-capable batteries near a threatened battery using spatial queries.
    - Activates nearby point-defense batteries to engage inbound HARMs that threaten high-value SAMs.

    How others use it
    - HarmResponseService calls activate when a battery's doctrine says to use point defense.
    - IadsNetwork includes point-defense evaluation as part of the HARM response tick.
--]]

Medusa.Services.PointDefenseService = {}

local _logger = Medusa.Logger:ns("PointDefenseService")
local AAT = Medusa.Constants.AssessedAircraftType
Medusa.Services.PointDefenseService._batteryBuffer = {}
local _pdBatteryBuffer = Medusa.Services.PointDefenseService._batteryBuffer
Medusa.Services.PointDefenseService._harmActivationBuffer = {}
local _harmActivationBuffer = Medusa.Services.PointDefenseService._harmActivationBuffer
local AS = Medusa.Constants.ActivationState
local BOS = Medusa.Constants.BatteryOperationalStatus
local BR = Medusa.Constants.BatteryRole
local LS = Medusa.Constants.TrackLifecycleState
local BatteryActivationService = Medusa.Services.BatteryActivationService
local C = Medusa.Constants

local function clearTable(t)
	for k in pairs(t) do
		t[k] = nil
	end
end

local HVA_ROLES = { [BR.LR_SAM] = true, [BR.MR_SAM] = true }
local PD_ROLES = { [BR.SR_SAM] = true, [BR.AAA] = true }

function Medusa.Services.PointDefenseService.setAssignment(pdBatteryId, targetBatteryId, batteryStore)
	if pdBatteryId == targetBatteryId then
		return false
	end
	local pdBattery = batteryStore:get(pdBatteryId)
	local targetBattery = batteryStore:get(targetBatteryId)
	if not pdBattery or not targetBattery then
		return false
	end
	pdBattery.IsPointDefense = true
	pdBattery.PointDefenseTargetId = targetBatteryId
	targetBattery.PointDefenseProviderId = pdBatteryId
	_logger:info(string.format("assigned PD %s -> target %s", pdBatteryId, targetBatteryId))
	return true
end

function Medusa.Services.PointDefenseService.clearAssignment(pdBatteryId, batteryStore)
	local pdBattery = batteryStore:get(pdBatteryId)
	if not pdBattery then
		return true
	end
	if pdBattery.PointDefenseTargetId then
		local targetBattery = batteryStore:get(pdBattery.PointDefenseTargetId)
		if targetBattery then
			targetBattery.PointDefenseProviderId = nil
		end
	end
	pdBattery.IsPointDefense = false
	pdBattery.PointDefenseTargetId = nil
	return true
end

function Medusa.Services.PointDefenseService.isProviderViable(provider)
	if not provider then
		return false
	end
	if provider.OperationalStatus ~= BOS.ACTIVE and provider.OperationalStatus ~= BOS.ENGAGEMENT_IMPAIRED then
		return false
	end
	if provider.TotalAmmoStatus <= 0 then
		return false
	end
	return true
end

function Medusa.Services.PointDefenseService.releaseOrphanedDefenders(ctx)
	local batteryStore = ctx.batteryStore
	local batteries = batteryStore:getAll(_pdBatteryBuffer)
	local released = 0
	for i = 1, #batteries do
		local pd = batteries[i]
		if pd.IsPointDefense and pd.PointDefenseTargetId then
			local liege = batteryStore:get(pd.PointDefenseTargetId)
			if not liege or not Medusa.Services.PointDefenseService.isProviderViable(liege) then
				_logger:info(
					string.format(
						"PD %s released: liege %s no longer viable",
						pd.GroupName or pd.BatteryId,
						pd.PointDefenseTargetId
					)
				)
				Medusa.Services.PointDefenseService.clearAssignment(pd.BatteryId, batteryStore)
				released = released + 1
			end
		end
	end
	return released
end

function Medusa.Services.PointDefenseService.autoAssignShorad(ctx)
	local batteryStore = ctx.batteryStore
	local geoGrid = ctx.geoGrid
	local batteries = batteryStore:getAll(_pdBatteryBuffer)
	local assignCount = 0
	for i = 1, #batteries do
		local pd = batteries[i]
		if PD_ROLES[pd.Role] and pd.OperationalStatus == BOS.ACTIVE and pd.Position and not pd.IsPointDefense then
			local nearby = Medusa.Services.SpatialQuery.batteriesInRadius(
				geoGrid,
				batteryStore,
				pd.Position,
				C.POINT_DEFENSE_SEARCH_RADIUS_M
			)
			local bestDist = math.huge
			local bestId = nil
			for j = 1, #nearby do
				local hva = nearby[j]
				if
					HVA_ROLES[hva.Role]
					and hva.OperationalStatus == BOS.ACTIVE
					and hva.Position
					and not hva.PointDefenseProviderId
				then
					local dist = Distance2D(pd.Position, hva.Position)
					if dist < bestDist then
						bestDist = dist
						bestId = hva.BatteryId
					end
				end
			end
			if bestId then
				Medusa.Services.PointDefenseService.setAssignment(pd.BatteryId, bestId, batteryStore)
				assignCount = assignCount + 1
			end
		end
	end
	return assignCount
end

local computeTrackCPA = Medusa.Services.HarmDetectionService.computeTrackCPA

local function tryActivatePd(provider, harmTrack, protectedLabel, now)
	if not Medusa.Services.PointDefenseService.isProviderViable(provider) then
		return false
	end
	if provider.ActivationState == AS.STATE_HOT then
		return false
	end
	if provider.CurrentTargetTrackId then
		return false
	end
	if not provider.Position or not provider.EngagementRangeMax then
		return false
	end
	local cpaDist = computeTrackCPA(harmTrack, provider.Position)
	if cpaDist > provider.EngagementRangeMax then
		return false
	end
	Medusa.Entities.Battery.assignTrack(provider, harmTrack, now)
	BatteryActivationService.forceGoHot(provider, now)
	_logger:info(
		string.format(
			"PD %s activated for HARM track %s (protecting %s)",
			provider.GroupName or provider.BatteryId,
			harmTrack.TrackId,
			protectedLabel
		)
	)
	return true
end

function Medusa.Services.PointDefenseService.activateForHarm(harmTrack, geoGrid, batteryStore, now, doctrine)
	if not harmTrack.Position then
		return 0
	end
	local vel = harmTrack.SmoothedVelocity or harmTrack.Velocity
	if not vel then
		return 0
	end

	local defendPk = (doctrine and doctrine.DefendPk) or 0.30
	local activated = 0
	clearTable(_harmActivationBuffer)

	-- Pass 1: activate assigned PD for batteries directly threatened by the HARM (no Pk gate)
	local batteries = batteryStore:getAll(_pdBatteryBuffer)
	for i = 1, #batteries do
		local battery = batteries[i]
		if battery.PointDefenseProviderId and battery.Position then
			local cpaDist = computeTrackCPA(harmTrack, battery.Position)
			if cpaDist < C.HARM_DEFAULT_THREAT_RADIUS_M then
				local provider = batteryStore:get(battery.PointDefenseProviderId)
				if provider and not _harmActivationBuffer[provider.BatteryId] then
					if tryActivatePd(provider, harmTrack, battery.GroupName or battery.BatteryId, now) then
						_harmActivationBuffer[provider.BatteryId] = true
						activated = activated + 1
					end
				end
			end
		end
	end

	-- Pass 2: any battery along the flight path that can intercept with Pk >= DefendPk
	local searchRadius = C.POINT_DEFENSE_SEARCH_RADIUS_M
	local nearby =
		Medusa.Services.SpatialQuery.batteriesInRadius(geoGrid, batteryStore, harmTrack.Position, searchRadius)
	for i = 1, #nearby do
		local battery = nearby[i]
		if
			battery.EngagementRangeMax
			and battery.EngagementRangeMax > 0
			and battery.Position
			and not _harmActivationBuffer[battery.BatteryId]
			and not battery.CurrentTargetTrackId
			and not battery.HarmShutdownUntil
			and battery.ActivationState ~= AS.STATE_HOT
			and Medusa.Services.PointDefenseService.isProviderViable(battery)
			and (battery.IsPointDefense or battery.HarmCapableUnitCount > 0)
		then
			local cpaDist = computeTrackCPA(harmTrack, battery.Position)
			if cpaDist < battery.EngagementRangeMax then
				local pk = Medusa.Services.PkModel.computePk(battery, harmTrack, cpaDist)
				if pk < defendPk then
					_logger:debug(
						string.format(
							"battery %s skipped HARM intercept (Pk=%.2f < %.2f, CPA=%.0fm)",
							battery.GroupName or battery.BatteryId,
							pk,
							defendPk,
							cpaDist
						)
					)
				else
					Medusa.Entities.Battery.assignTrack(battery, harmTrack, now)
					if BatteryActivationService.forceGoHot(battery, now) then
						_harmActivationBuffer[battery.BatteryId] = true
						activated = activated + 1
						_logger:info(
							string.format(
								"battery %s HOT for HARM intercept (Pk=%.2f, CPA=%.0fm)",
								battery.GroupName or battery.BatteryId,
								pk,
								cpaDist
							)
						)
					else
						battery.CurrentTargetTrackId = nil
						harmTrack.AssignedBatteryIds:remove(battery.BatteryId)
					end
				end
			end
		end
	end

	return activated
end

function Medusa.Services.PointDefenseService.engageThreats(ctx)
	local trackStore = ctx.trackStore
	local batteryStore = ctx.batteryStore
	local geoGrid = ctx.geoGrid
	local now = ctx.now
	local batteries = batteryStore:getAll(_pdBatteryBuffer)
	local engageCount = 0
	for i = 1, #batteries do
		local protected = batteries[i]
		if protected.PointDefenseProviderId then
			local provider = batteryStore:get(protected.PointDefenseProviderId)
			if
				Medusa.Services.PointDefenseService.isProviderViable(provider)
				and not provider.CurrentTargetTrackId
				and provider.EngagementRangeMax
			then
				local results = geoGrid:queryRadius(provider.Position, provider.EngagementRangeMax, { "Track" })
				local trackIds = results.TrackIds
				if trackIds then
					local bestDist = math.huge
					local bestTrack = nil
					for trackId in pairs(trackIds) do
						local track = trackStore:get(trackId)
						if
							track
							and track.LifecycleState == LS.ACTIVE
							and (track.AssessedAircraftType == AAT.HARM or track.IsSeadThreat)
						then
							local dist = Distance2D(track.Position, provider.Position)
							if dist <= provider.EngagementRangeMax and dist < bestDist then
								bestDist = dist
								bestTrack = track
							end
						end
					end
					if bestTrack then
						Medusa.Entities.Battery.assignTrack(provider, bestTrack, now)
						BatteryActivationService.forceGoHot(provider, now)
						_logger:info(
							string.format(
								"PD %s engaging %s to defend %s",
								provider.BatteryId,
								bestTrack.TrackId,
								protected.BatteryId
							)
						)
						engageCount = engageCount + 1
					end
				end
			end
		end
	end
	return engageCount
end
