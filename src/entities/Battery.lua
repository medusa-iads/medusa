require("_header")
require("entities.Entities")
require("core.Constants")

--[[
            ██████╗  █████╗ ████████╗████████╗███████╗██████╗ ██╗   ██╗
            ██╔══██╗██╔══██╗╚══██╔══╝╚══██╔══╝██╔════╝██╔══██╗╚██╗ ██╔╝
            ██████╔╝███████║   ██║      ██║   █████╗  ██████╔╝ ╚████╔╝
            ██╔══██╗██╔══██║   ██║      ██║   ██╔══╝  ██╔══██╗  ╚██╔╝
            ██████╔╝██║  ██║   ██║      ██║   ███████╗██║  ██║   ██║
            ╚═════╝ ╚═╝  ╚═╝   ╚═╝      ╚═╝   ╚══════╝╚═╝  ╚═╝   ╚═╝

    What this entity does
    - Holds all data for a SAM battery: position, activation state, ammo counts, and engagement envelope.
    - Provides methods to recompute operational status, engagement range, and Pk parameters from live unit data.
    - Tracks state transition timing so hold-down intervals are enforced.

    How others use it
    - EntityFactory creates Battery instances from discovered DCS groups.
    - TargetAssigner, EmconService, and BatteryActivationService read and mutate battery state each tick.
--]]

Medusa.Entities.Battery = {}

local DEGRADED_DETECTION_RANGE_PERCENT = 60
local REACTION_DELAY_MULTIPLIER_ON_DEGRADE = 1.5

local BUR = Medusa.Constants.BatteryUnitRole
local TRACKER_ROLES = { [BUR.TRACK_RADAR] = true, [BUR.TELAR] = true, [BUR.TLAR] = true }
local LAUNCHER_ROLES = Medusa.Constants.LAUNCHER_ROLES
local SEARCH_ROLES = { [BUR.SEARCH_RADAR] = true, [BUR.TLAR] = true }
local RDP = Medusa.Constants.BatteryRadarDependencyPolicy

function Medusa.Entities.Battery.new(data)
	if not data then
		error("data table is required")
	end
	if data.NetworkId == nil then
		error("missing required field: NetworkId")
	end
	if data.GroupId == nil then
		error("missing required field: GroupId")
	end
	if data.GroupName == nil then
		error("missing required field: GroupName")
	end

	local o = {
		BatteryId = data.BatteryId or NewULID(),
		NetworkId = data.NetworkId,
		GroupId = data.GroupId,
		GroupName = data.GroupName,
		Role = data.Role or Medusa.Constants.BatteryRole.GENERIC_SAM,
		ActivationState = data.ActivationState or Medusa.Constants.ActivationState.INITIALIZING,
		OperationalStatus = data.OperationalStatus or Medusa.Constants.BatteryOperationalStatus.ACTIVE,
		SystemType = data.SystemType or "UNKNOWN",
		CurrentTargetTrackId = data.CurrentTargetTrackId,
		DetectionRangeMax = data.DetectionRangeMax,
		WeaponRangeMax = data.WeaponRangeMax,
		EngagementRangeMax = data.EngagementRangeMax,
		EngagementRangeMin = data.EngagementRangeMin,
		EngagementAltitudeMax = data.EngagementAltitudeMax,
		EngagementAltitudeMin = data.EngagementAltitudeMin,
		TotalAmmoStatus = data.TotalAmmoStatus or 0,
		Position = data.Position,
		LastStateChangeTime = nil,
		StateChangeHoldDownSec = data.StateChangeHoldDownSec or 5,
		RadarDependencyPolicy = data.RadarDependencyPolicy or Medusa.Constants.BatteryRadarDependencyPolicy.REQUIRED,
		ReactionDelaySec = data.ReactionDelaySec or 5,
		EffectiveDetectionRangeMax = nil,
		EffectiveReactionDelaySec = nil,
		AmmoDepletedBehavior = data.AmmoDepletedBehavior,
		IsPointDefense = data.IsPointDefense or false,
		PointDefenseTargetId = data.PointDefenseTargetId,
		PointDefenseProviderId = data.PointDefenseProviderId,
		HarmCapableUnitCount = data.HarmCapableUnitCount or 0,
		HarmDefenseState = nil,
		HarmDefenseDefenders = 0,
		HarmDefenseThreats = 0,
		HarmDefenseRatio = 0,
		IsActingAsEWR = data.IsActingAsEWR or false,
		PkRangeOptimal = data.PkRangeOptimal,
		PkRangeSigma = data.PkRangeSigma,
		LastAssignmentChangeTime = data.LastAssignmentChangeTime,
		LastShotTime = data.LastShotTime,
		ShotsFired = 0,
		RearmCheckTime = nil,
	}

	return o
end

function Medusa.Entities.Battery.newUnit(data)
	if not data then
		error("data table is required")
	end
	if data.UnitId == nil then
		error("missing required field: UnitId")
	end

	return {
		UnitId = data.UnitId,
		UnitName = data.UnitName,
		UnitTypeName = data.UnitTypeName,
		DisplayName = data.DisplayName,
		Roles = data.Roles or { Medusa.Constants.BatteryUnitRole.OTHER },
		AmmoCount = data.AmmoCount or 0,
		AmmoTypes = data.AmmoTypes,
		OperationalStatus = data.OperationalStatus or Medusa.Constants.UnitOperationalStatus.ACTIVE,
		RadarStatus = data.RadarStatus or Medusa.Constants.RadarStatus.NA,
	}
end

function Medusa.Entities.Battery.computeEngagementRange(battery)
	local detRange = battery.DetectionRangeMax
	local weapRange = battery.WeaponRangeMax
	if detRange and weapRange then
		battery.EngagementRangeMax = math.min(detRange, weapRange)
	elseif weapRange then
		battery.EngagementRangeMax = weapRange
	elseif detRange then
		battery.EngagementRangeMax = detRange
	end
end

function Medusa.Entities.Battery.canTransition(battery, newState, now)
	if battery.ActivationState == newState then
		return false
	end
	if not battery.LastStateChangeTime then
		return true
	end
	if battery.StateChangeHoldDownSec and (now - battery.LastStateChangeTime) < battery.StateChangeHoldDownSec then
		return false
	end
	return true
end

--- Returns true if a HOT battery can be deactivated (no missiles in flight).
function Medusa.Entities.Battery.canDeactivate(battery, now)
	if battery.MissileInFlightUntil and now < battery.MissileInFlightUntil then
		return false
	end
	return true
end

function Medusa.Entities.Battery.transitionTo(battery, newState, now)
	battery.ActivationState = newState
	battery.LastStateChangeTime = now
	return true
end

--- Sets the battery's target and registers it in the track's AssignedBatteryIds.
function Medusa.Entities.Battery.assignTrack(battery, track, now)
	battery.CurrentTargetTrackId = track.TrackId
	battery.LastAssignmentChangeTime = now
	if track.AssignedBatteryIds then
		track.AssignedBatteryIds:add(battery.BatteryId)
	end
end

--- Clears the battery's target and removes it from the track's AssignedBatteryIds.
function Medusa.Entities.Battery.releaseTrack(battery, trackStore)
	local trackId = battery.CurrentTargetTrackId
	if not trackId then
		return
	end
	battery.CurrentTargetTrackId = nil
	if trackStore then
		local track = trackStore:get(trackId)
		if track then
			track.AssignedBatteryIds:remove(battery.BatteryId)
		end
	end
end

--- Sets up last-chance salvo state after a handoff.
function Medusa.Entities.Battery.beginLastChance(battery, trackId, holdDownSec)
	battery.LastChanceTrackId = trackId
	battery.LastChanceExpiresAt = (GetTime()) + holdDownSec
	battery.LastChanceShotsRemaining = Medusa.Constants.LAST_CHANCE_SALVO_COUNT
	battery.LastChanceExtended = false
end

function Medusa.Entities.Battery.clearLastChance(battery)
	battery.LastChanceTrackId = nil
	battery.LastChanceExpiresAt = nil
	battery.LastChanceShotsRemaining = nil
	battery.LastChanceExtended = nil
end

function Medusa.Entities.Battery.hasLauncherRole(unit, launcherRoles)
	if not unit.Roles then
		return false
	end
	for j = 1, #unit.Roles do
		if launcherRoles[unit.Roles[j]] then
			return true
		end
	end
	return false
end

function Medusa.Entities.Battery.updateAmmoEnvelope(at, env)
	if at.RangeMax and (not env.maxWeaponRange or at.RangeMax > env.maxWeaponRange) then
		env.maxWeaponRange = at.RangeMax
	end
	if at.RangeMin and (not env.minWeaponRange or at.RangeMin < env.minWeaponRange) then
		env.minWeaponRange = at.RangeMin
	end
	if at.AltMax and (not env.maxAlt or at.AltMax > env.maxAlt) then
		env.maxAlt = at.AltMax
	end
	if at.AltMin and (not env.minAlt or at.AltMin < env.minAlt) then
		env.minAlt = at.AltMin
	end
	if at.Nmax and (not env.bestNmax or at.Nmax > env.bestNmax) then
		env.bestNmax = at.Nmax
	end
end

function Medusa.Entities.Battery.accumulateLauncherAmmo(unit, env)
	local total = 0
	for j = 1, #unit.AmmoTypes do
		local at = unit.AmmoTypes[j]
		if at.Count > 0 then
			Medusa.Entities.Battery.updateAmmoEnvelope(at, env)
		end
		total = total + at.Count
	end
	return total
end

function Medusa.Entities.Battery.recomputeEnvelope(battery)
	if not battery.Units then
		return
	end
	local env = {}
	local totalAmmo = 0

	for i = 1, #battery.Units do
		local unit = battery.Units[i]
		if
			Medusa.Entities.Battery.hasLauncherRole(unit, LAUNCHER_ROLES)
			and unit.AmmoCount
			and unit.AmmoCount > 0
			and unit.AmmoTypes
		then
			totalAmmo = totalAmmo + Medusa.Entities.Battery.accumulateLauncherAmmo(unit, env)
		end
	end

	battery.WeaponRangeMax = env.maxWeaponRange
	battery.EngagementRangeMin = env.minWeaponRange
	battery.EngagementAltitudeMax = env.maxAlt
	battery.EngagementAltitudeMin = env.minAlt
	battery.TotalAmmoStatus = totalAmmo
	battery.MissileNmax = env.bestNmax
	Medusa.Entities.Battery.computeEngagementRange(battery)

	local rMin = battery.EngagementRangeMin or 0
	local rMax = battery.WeaponRangeMax or 0
	if rMax > rMin and rMax > 0 then
		local C = Medusa.Constants
		local span = rMax - rMin
		local refK = C.PK_OPTIMAL_REFERENCE_M
		-- Log-scaled optimal range: compresses long-range systems so optimal sits closer to min range
		battery.PkRangeOptimal = rMin + C.PK_OPTIMAL_FRACTION * refK * math.log(1 + span / refK)
		if rMax <= C.PK_FLOOR_ANCHOR_RANGE_M then
			-- SR/MR SAMs: anchor sigma so Pk = PkFloor at max range (full envelope usable)
			local floorDelta = math.sqrt(-2 * math.log(C.PK_FLOOR / C.PK_MAX_DEFAULT))
			battery.PkRangeSigma = math.max((rMax - battery.PkRangeOptimal) / floorDelta, 100)
		else
			battery.PkRangeSigma = math.max(math.min(span / C.PK_RANGE_DECAY_RATE, C.PK_SIGMA_CAP_M), 100)
		end
	else
		battery.PkRangeOptimal = nil
		battery.PkRangeSigma = nil
	end
end

--- Recomputes envelope, operational status, and effective ranges in the correct order.
function Medusa.Entities.Battery.recomputeState(battery)
	Medusa.Entities.Battery.recomputeEnvelope(battery)
	Medusa.Entities.Battery.recomputeOperationalStatus(battery)
	Medusa.Entities.Battery.computeEffectiveRanges(battery)
	return battery.OperationalStatus
end

function Medusa.Entities.Battery.hasRoleAlive(battery, roleSet)
	if not battery.Units then
		return false
	end
	for i = 1, #battery.Units do
		local roles = battery.Units[i].Roles
		if roles then
			for j = 1, #roles do
				if roleSet[roles[j]] then
					return true
				end
			end
		end
	end
	return false
end

local CP_ROLES = { [Medusa.Constants.BatteryUnitRole.COMMAND_POST] = true }

--- Classifies what degradation the battery is experiencing. Returns nil if fully operational.
function Medusa.Entities.Battery.classifyDegradation(battery)
	local BOS = Medusa.Constants.BatteryOperationalStatus
	if battery.OperationalStatus ~= BOS.ENGAGEMENT_IMPAIRED then
		return nil
	end
	if not battery.HasTelar then
		return nil
	end
	local cpAlive = battery.HasCommandPost and Medusa.Entities.Battery.hasRoleAlive(battery, CP_ROLES)
	if cpAlive then
		return "SEARCH_LOST_CP_ALIVE"
	end
	return "SEARCH_LOST_CP_DEAD"
end

--- Executes the appropriate degraded behavior based on degradation type and doctrine.
--- Returns "autonomous", "weapons_free", or nil (no action).
function Medusa.Entities.Battery.applyDegradedBehavior(battery, degradation, context)
	if not degradation then
		return nil
	end
	local BAS = Medusa.Services.BatteryActivationService
	if degradation == "SEARCH_LOST_CP_DEAD" then
		BAS.goAutonomous(battery, context.batteryStore, context.geoGrid, context.unitIdIndex, context.trackStore)
		return "autonomous"
	end
	if degradation == "SEARCH_LOST_CP_ALIVE" then
		BAS.erectGroup(battery.GroupName)
		Medusa.Entities.Battery.releaseTrack(battery, context.trackStore)
		return "weapons_free"
	end
	return nil
end

function Medusa.Entities.Battery.recomputeOperationalStatus(battery)
	local BOS = Medusa.Constants.BatteryOperationalStatus

	if not battery.Units or #battery.Units == 0 then
		battery.OperationalStatus = BOS.DESTROYED
		return BOS.DESTROYED
	end

	local hasTracker = false
	local hasLauncher = false
	local hasSearch = false
	for i = 1, #battery.Units do
		local roles = battery.Units[i].Roles
		if roles then
			for j = 1, #roles do
				local r = roles[j]
				if TRACKER_ROLES[r] then
					hasTracker = true
				end
				if LAUNCHER_ROLES[r] then
					hasLauncher = true
				end
				if SEARCH_ROLES[r] then
					hasSearch = true
				end
			end
		end
	end

	local status
	if not hasTracker and not hasLauncher then
		status = BOS.INOPERATIVE
	elseif not hasTracker or not hasLauncher then
		status = BOS.SEARCH_ONLY
	elseif battery.TotalAmmoStatus <= 0 then
		status = battery.AmmoDepletedBehavior or BOS.REARMING
	elseif not hasSearch then
		status = BOS.ENGAGEMENT_IMPAIRED
	else
		status = BOS.ACTIVE
	end

	battery.OperationalStatus = status
	return status
end

function Medusa.Entities.Battery.computeEffectiveRanges(battery)
	local searchDown = not Medusa.Entities.Battery.hasRoleAlive(battery, SEARCH_ROLES)

	if searchDown and battery.RadarDependencyPolicy == RDP.OPTIONAL_DEGRADED then
		battery.EffectiveDetectionRangeMax =
			math.floor((battery.DetectionRangeMax or 0) * DEGRADED_DETECTION_RANGE_PERCENT / 100)
		battery.EffectiveReactionDelaySec = math.ceil(battery.ReactionDelaySec * REACTION_DELAY_MULTIPLIER_ON_DEGRADE)
	elseif searchDown and battery.RadarDependencyPolicy == RDP.REQUIRED then
		battery.EffectiveDetectionRangeMax = 0
		battery.EffectiveReactionDelaySec = battery.ReactionDelaySec
	else
		battery.EffectiveDetectionRangeMax = battery.DetectionRangeMax
		battery.EffectiveReactionDelaySec = battery.ReactionDelaySec
	end

	-- Engagement range = min(detection, weapon). Must use Effective (degraded) range, not raw.
	local effDet = battery.EffectiveDetectionRangeMax
	local weapRange = battery.WeaponRangeMax
	if effDet and weapRange then
		battery.EngagementRangeMax = math.min(effDet, weapRange)
	elseif weapRange then
		battery.EngagementRangeMax = weapRange
	elseif effDet then
		battery.EngagementRangeMax = effDet
	end
end
