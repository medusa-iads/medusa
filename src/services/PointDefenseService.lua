require("_header")
require("services.Services")
require("services.SpatialQuery")
require("core.Constants")
require("core.Logger")
require("services.BatteryActivationService")
require("services.HarmDetectionService")
require("entities.Battery")
require("entities.Track")

--[[
            ██████╗  ██████╗ ██╗███╗   ██╗████████╗    ██████╗ ███████╗███████╗███████╗███╗   ██╗███████╗███████╗
            ██╔══██╗██╔═══██╗██║████╗  ██║╚══██╔══╝    ██╔══██╗██╔════╝██╔════╝██╔════╝████╗  ██║██╔════╝██╔════╝
            ██████╔╝██║   ██║██║██╔██╗ ██║   ██║       ██║  ██║█████╗  █████╗  █████╗  ██╔██╗ ██║███████╗█████╗
            ██╔═══╝ ██║   ██║██║██║╚██╗██║   ██║       ██║  ██║██╔══╝  ██╔══╝  ██╔══╝  ██║╚██╗██║╚════██║██╔══╝
            ██║     ╚██████╔╝██║██║ ╚████║   ██║       ██████╔╝███████╗██║     ███████╗██║ ╚████║███████║███████╗
            ╚═╝      ╚═════╝ ╚═╝╚═╝  ╚═══╝   ╚═╝       ╚═════╝ ╚══════╝╚═╝     ╚══════╝╚═╝  ╚═══╝╚══════╝╚══════╝

    What this service does
    - Derives which nearby short-range batteries can defend high-value SAMs in the same partition.
    - Assigns each viable defender to its closest eligible confirmed HARM and requests HOT readiness.

    How others use it
    - IadsNetwork refreshes the derived point-defense role before each HARM response pass.
    - HarmResponseService uses the eligibility and activation operations for available and committed capacity.
--]]

Medusa.Services.PointDefenseService = {}

local _logger = Medusa.Logger:ns("PointDefenseService")
local AS = Medusa.Constants.ActivationState
local BOS = Medusa.Constants.BatteryOperationalStatus
local BR = Medusa.Constants.BatteryRole
local C = Medusa.Constants
local Battery = Medusa.Entities.Battery
local BatteryActivationService = Medusa.Services.BatteryActivationService
local computeTrackCPA = Medusa.Services.HarmDetectionService.computeTrackCPA
local HVA_ROLES = { [BR.LR_SAM] = true, [BR.MR_SAM] = true }
local PD_ROLES = { [BR.SR_SAM] = true, [BR.AAA] = true }
local _batteryBuffer = {}

--- Reports exact nonnil partition equality for point-defense work.
local function sharesPartition(left, right)
	return left.PartitionKey ~= nil and left.PartitionKey == right.PartitionKey
end

--- Reports whether a battery can contribute current HARM-defense capacity.
function Medusa.Services.PointDefenseService.isProviderViable(provider)
	if not provider or Medusa.Entities.Battery.isIndependentAaa(provider) then
		return false
	end
	if Battery.isCrewSuppressed(provider) then
		return false
	end
	if provider.OperationalStatus ~= BOS.ACTIVE and provider.OperationalStatus ~= BOS.ENGAGEMENT_IMPAIRED then
		return false
	end
	return Battery.hasKnownAmmo(provider)
end

--- Reports whether provider is a viable nearby point defender for protected.
function Medusa.Services.PointDefenseService.canProtect(provider, protected)
	return provider ~= protected
		and PD_ROLES[provider.Role] == true
		and HVA_ROLES[protected.Role] == true
		and Medusa.Services.PointDefenseService.isProviderViable(provider)
		and Medusa.Services.PointDefenseService.isProviderViable(protected)
		and provider.Position ~= nil
		and protected.Position ~= nil
		and sharesPartition(provider, protected)
		and Distance2D(provider.Position, protected.Position) <= C.POINT_DEFENSE_SEARCH_RADIUS_M
end

--- Refreshes the derived point-defense role from current proximity and partition state.
function Medusa.Services.PointDefenseService.reconcileProviders(ctx)
	local batteryStore = ctx.batteryStore
	local batteries = batteryStore:getAll(_batteryBuffer)
	local count = 0
	for i = 1, #batteries do
		local provider = batteries[i]
		local isPointDefense = false
		if PD_ROLES[provider.Role] and provider.Position and Medusa.Services.PointDefenseService.isProviderViable(provider) then
			local nearby = Medusa.Services.SpatialQuery.batteriesInRadius(ctx.geoGrid, batteryStore, provider.Position, C.POINT_DEFENSE_SEARCH_RADIUS_M)
			for j = 1, #nearby do
				if Medusa.Services.PointDefenseService.canProtect(provider, nearby[j]) then
					isPointDefense = true
					break
				end
			end
		end
		provider.IsPointDefense = isPointDefense
		if isPointDefense then
			count = count + 1
		end
	end
	return count
end

--- Reports whether provider can retain or accept one confirmed HARM within its maximum envelope.
function Medusa.Services.PointDefenseService.canEngageHarm(provider, harmTrack, doctrine)
	if
		not Medusa.Services.PointDefenseService.isProviderViable(provider)
		or not provider.Position
		or not provider.EngagementRangeMax
		or provider.EngagementRangeMax <= 0
		or not harmTrack
		or harmTrack.AssessedAircraftType ~= C.AssessedAircraftType.HARM
		or not Battery.canAcceptTrack(provider, harmTrack, doctrine)
	then
		return false
	end
	local cpaDist = computeTrackCPA(harmTrack, provider.Position)
	return cpaDist <= provider.EngagementRangeMax
end

--- Reports whether provider can accept at least one HARM in threats.
function Medusa.Services.PointDefenseService.canEngageAnyHarm(provider, threats, doctrine)
	for i = 1, #threats do
		if Medusa.Services.PointDefenseService.canEngageHarm(provider, threats[i], doctrine) then
			return true
		end
	end
	return false
end

--- Confirms HOT readiness for an assigned HARM or releases the failed commitment.
local function confirmHotOrRelease(provider, harmTrack, now, trackStore)
	if provider.ActivationState == AS.STATE_HOT or BatteryActivationService.forceGoHot(provider, now) then
		return true
	end
	Battery.releaseTrack(provider, trackStore, harmTrack)
	return false
end

--- Assigns provider to its closest eligible HARM and returns whether HOT readiness is confirmed.
function Medusa.Services.PointDefenseService.activateClosestHarm(provider, threats, now, doctrine, trackStore)
	if provider.CurrentTargetTrackId then
		for i = 1, #threats do
			if threats[i].TrackId == provider.CurrentTargetTrackId and Medusa.Services.PointDefenseService.canEngageHarm(provider, threats[i], doctrine) then
				return confirmHotOrRelease(provider, threats[i], now, trackStore)
			end
		end
	end

	local bestTrack = nil
	local bestDistance = math.huge
	for i = 1, #threats do
		local track = threats[i]
		if Medusa.Services.PointDefenseService.canEngageHarm(provider, track, doctrine) then
			local distance = Distance2D(provider.Position, track.Position)
			if distance < bestDistance or (distance == bestDistance and bestTrack and tostring(track.TrackId) < tostring(bestTrack.TrackId)) then
				bestTrack = track
				bestDistance = distance
			end
		end
	end
	if not bestTrack or not Battery.assignTrack(provider, bestTrack, now, trackStore) then
		return false
	end
	if confirmHotOrRelease(provider, bestTrack, now, trackStore) then
		_logger:info(string.format("battery %s committed to closest HARM %s", provider.GroupName or provider.BatteryId, Medusa.Entities.Track.displayId(bestTrack)))
		return true
	end
	return false
end
