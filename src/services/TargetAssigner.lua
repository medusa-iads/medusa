require("_header")
require("services.Services")
require("services.PkModel")
require("services.SpatialQuery")
require("core.Constants")
require("core.Logger")

--[[
            ████████╗ █████╗ ██████╗  ██████╗ ███████╗████████╗     █████╗ ███████╗███████╗██╗ ██████╗ ███╗   ██╗███████╗██████╗
            ╚══██╔══╝██╔══██╗██╔══██╗██╔════╝ ██╔════╝╚══██╔══╝    ██╔══██╗██╔════╝██╔════╝██║██╔════╝ ████╗  ██║██╔════╝██╔══██╗
               ██║   ███████║██████╔╝██║  ███╗█████╗     ██║       ███████║███████╗███████╗██║██║  ███╗██╔██╗ ██║█████╗  ██████╔╝
               ██║   ██╔══██║██╔══██╗██║   ██║██╔══╝     ██║       ██╔══██║╚════██║╚════██║██║██║   ██║██║╚██╗██║██╔══╝  ██╔══██╗
               ██║   ██║  ██║██║  ██║╚██████╔╝███████╗   ██║       ██║  ██║███████║███████║██║╚██████╔╝██║ ╚████║███████╗██║  ██║
               ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝   ╚═╝       ╚═╝  ╚═╝╚══════╝╚══════╝╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝

    What this service does
    - Picks which batteries to activate for each hostile track using Pk-based greedy assignment.
    - Manages handoffs when a better battery becomes available and last-chance salvo for departing tracks.
    - Deactivates batteries whose assigned tracks expire or leave range.

    How others use it
    - IadsNetwork calls evaluateAssignments each tick to drive the main engagement loop.
--]]

Medusa.Services.TargetAssigner = {}

local _logger = Medusa.Logger:ns("TargetAssigner")
Medusa.Services.TargetAssigner._trackBuffer = {}
local _trackBuffer = Medusa.Services.TargetAssigner._trackBuffer
Medusa.Services.TargetAssigner._batteryBuffer = {}
local _batteryBuffer = Medusa.Services.TargetAssigner._batteryBuffer
Medusa.Services.TargetAssigner._pairBuffer = {}
local _pairBuffer = Medusa.Services.TargetAssigner._pairBuffer
Medusa.Services.TargetAssigner._survive = {}
local _survive = Medusa.Services.TargetAssigner._survive
Medusa.Services.TargetAssigner._assigned = {}
local _assigned = Medusa.Services.TargetAssigner._assigned
Medusa.Services.TargetAssigner._trackRoleTiers = {}
local _trackRoleTiers = Medusa.Services.TargetAssigner._trackRoleTiers
Medusa.Services.TargetAssigner._saturationPairsByBattery = {}
local _saturationPairsByBattery = Medusa.Services.TargetAssigner._saturationPairsByBattery
local _pkFloor = Medusa.Constants.PK_FLOOR
local _lookaheadSec = Medusa.Constants.LOOKAHEAD_DEFAULT_SEC
local _threatSpeedScaling = 30
local _tactics = nil
local _maxEngageRangePct = nil
local _stickyRangePct = 15
local computePk = Medusa.Services.PkModel.computePk

local ROE = Medusa.Constants.ROEState
local TI = Medusa.Constants.TrackIdentification
local ECP = Medusa.Constants.EmissionControlPolicy

local function clearTable(t)
	for k in pairs(t) do
		t[k] = nil
	end
end

--- Scores a track's threat priority (0-100) based on aircraft type and speed.
local function computeThreatValue(track)
	local C = Medusa.Constants
	local typeScore = C.AircraftTypeThreatScore[track.AssessedAircraftType] or 30
	local vel = track.SmoothedVelocity or track.Velocity
	if not vel then
		return typeScore
	end
	local speed = VecLength2D(vel)
	-- Speed as fraction of Mach 1, scaled to doctrine-configured point value.
	-- Faster targets score higher threat; capped at Mach 1 to avoid outsized weighting.
	local speedTerm = math.min(speed / Medusa.Constants.SPEED_OF_SOUND_MPS, 1.0) * _threatSpeedScaling
	return math.min(typeScore + speedTerm, 100)
end

--- Returns true if a battery can receive a new target assignment.
local function isBatteryEligible(battery)
	local AS = Medusa.Constants.ActivationState
	local BOS = Medusa.Constants.BatteryOperationalStatus
	return (battery.ActivationState == AS.STATE_COLD or battery.ActivationState == AS.STATE_WARM)
		and battery.OperationalStatus == BOS.ACTIVE
		and battery.Position
		and battery.EngagementRangeMax
		and battery.EngagementRangeMax > 0
		and not battery.CurrentTargetTrackId
		and not battery.HarmShutdownUntil
		and battery.TotalAmmoStatus > 0
		and not battery.IsPointDefense
end

--- Checks whether a track's identification meets the ROE minimum threshold.
local function meetsMinIdentification(trackId, minId)
	if minId == TI.BANDIT then
		return trackId == TI.BANDIT or trackId == TI.HOSTILE
	elseif minId == TI.HOSTILE then
		return trackId == TI.HOSTILE
	end
	return false
end

--- Returns the 2D distance from pos to the nearest launcher cluster centroid,
--- or to battery.Position if the battery has no clusters (the common case).
local function nearestClusterDist(battery, pos)
	local clusters = battery.Clusters
	if not clusters then
		local dx = pos.x - battery.Position.x
		local dz = pos.z - battery.Position.z
		return math.sqrt(dx * dx + dz * dz)
	end
	local best = math.huge
	for i = 1, #clusters do
		local c = clusters[i]
		local dx = pos.x - c.x
		local dz = pos.z - c.z
		local d2 = dx * dx + dz * dz
		if d2 < best then
			best = d2
		end
	end
	return math.sqrt(best)
end
Medusa.Services.TargetAssigner._nearestClusterDist = nearestClusterDist

--- Returns true if Pk dropped below the sticky hysteresis band (should release).
--- Returns false if Pk is still above floor or within the sticky band (suppress release).
local function pkBelowStickyFloor(pk, pkFloor, stickyFactor)
	return pk < pkFloor and pk < pkFloor * stickyFactor
end

--- Projects a track's position forward by the given number of seconds.
local function projectTrackPosition(track, seconds)
	local vel = track.SmoothedVelocity or track.Velocity
	if not vel or not track.Position then
		return track.Position
	end
	return {
		x = track.Position.x + vel.x * seconds,
		y = track.Position.y + vel.y * seconds,
		z = track.Position.z + vel.z * seconds,
	}
end

--- Evaluates a single battery-track pair and adds it to the candidate buffer if viable.
local function tryAddPair(battery, track, threatValue, n)
	if not isBatteryEligible(battery) then
		return n
	end
	local projPos = projectTrackPosition(track, _lookaheadSec)
	if not projPos then
		return n
	end
	local projDist = nearestClusterDist(battery, projPos)
	local maxRange = battery.EngagementRangeMax
	if _maxEngageRangePct then
		local pct = _maxEngageRangePct[battery.Role]
		if pct then
			maxRange = maxRange * pct / 100
		end
	end
	local alreadyEngaged = battery.CurrentTargetTrackId == track.TrackId
	local effectiveRange = alreadyEngaged and maxRange * (1 + _stickyRangePct / 100) or maxRange
	if projDist > effectiveRange then
		return n
	end
	local pk = computePk(battery, track, projDist)
	if pk < _pkFloor then
		return n
	end
	-- Slots are reused across ticks; callers must not hold references past the current assignment cycle
	n = n + 1
	local slot = _pairBuffer[n]
	if not slot then
		slot = {}
		_pairBuffer[n] = slot
	end
	slot.battery = battery
	slot.track = track
	slot.pk = pk
	slot.effectivePk = pk
	slot.threatValue = threatValue
	return n
end

local function _satPkDescending(a, b)
	return _pairBuffer[a].pk > _pairBuffer[b].pk
end

--- Builds sparse battery-track candidate pairs via GeoGrid spatial queries.
local CET = Medusa.Constants.CoordinatedEngagementTactics

local BR = Medusa.Constants.BatteryRole

local function trackAcceptsBattery(track, batteryRole)
	if not track.AssignedBatteryIds or track.AssignedBatteryIds:isEmpty() then
		return true
	end
	-- VLR_SAMs always SHOOT_LOOK_SHOOT among themselves, independent of doctrine tactic
	if batteryRole == BR.VLR_SAM then
		local tiers = _trackRoleTiers[track.TrackId]
		return not tiers or not tiers[BR.VLR_SAM]
	end
	if _tactics == CET.SHOOT_IN_DEPTH then
		local tiers = _trackRoleTiers[track.TrackId]
		return not tiers or not tiers[batteryRole]
	end
	if _tactics == CET.SHOOT_SHOOT then
		return track.AssignedBatteryIds:size() < 2
	end
	if _tactics == CET.SHOOT_SHOOT_FLOOD then
		if batteryRole == BR.SR_SAM or batteryRole == BR.AAA then
			return true
		end
		-- LR/MR capped at 2, counted separately from SR/AAA
		local lrMrCount = 0
		local tiers = _trackRoleTiers[track.TrackId]
		if tiers then
			if tiers[BR.LR_SAM] then
				lrMrCount = lrMrCount + 1
			end
			if tiers[BR.MR_SAM] then
				lrMrCount = lrMrCount + 1
			end
		end
		return lrMrCount < 2
	end
	return false
end

local function buildCandidatePairs(tracks, geoGrid, batteryStore, maxEngagementRange, minId)
	for i = #_pairBuffer, 1, -1 do
		_pairBuffer[i] = nil
	end
	local LS = Medusa.Constants.TrackLifecycleState
	local n = 0

	local AAT = Medusa.Constants.AssessedAircraftType
	for i = 1, #tracks do
		local track = tracks[i]
		if track.AssessedAircraftType == AAT.HARM then
			-- HARMs are handled by HarmResponseService + PointDefenseService, not WTA
		elseif track.LifecycleState == LS.ACTIVE and meetsMinIdentification(track.TrackIdentification, minId) then
			local hasRoom = _tactics ~= CET.SHOOT_LOOK_SHOOT or track.AssignedBatteryIds:isEmpty()
			if hasRoom then
				local threatValue = computeThreatValue(track)
				local batteries = Medusa.Services.SpatialQuery.batteriesInRadius(
					geoGrid,
					batteryStore,
					track.Position,
					maxEngagementRange
				)
				for j = 1, #batteries do
					if trackAcceptsBattery(track, batteries[j].Role) then
						n = tryAddPair(batteries[j], track, threatValue, n)
					end
				end
			end
		end
	end

	return n
end

--- Penalizes lower-ranked tracks per battery so saturated batteries shed low-priority pairs.
local function applySaturationPenalty(pairCount)
	local alpha = Medusa.Constants.SATURATION_PENALTY_ALPHA
	if alpha <= 0 then
		return
	end

	clearTable(_saturationPairsByBattery)

	for i = 1, pairCount do
		local batId = _pairBuffer[i].battery.BatteryId
		local list = _saturationPairsByBattery[batId]
		if not list then
			list = {}
			_saturationPairsByBattery[batId] = list
		end
		list[#list + 1] = i
	end

	for _, list in pairs(_saturationPairsByBattery) do
		if #list > 1 then
			table.sort(list, _satPkDescending)
			for rank = 2, #list do
				local idx = list[rank]
				local p = _pairBuffer[idx]
				-- Harmonic decay: 2nd-best gets Pk*0.77, 3rd gets Pk*0.63, discouraging battery overload
				p.effectivePk = p.pk * (1 / (1 + alpha * (rank - 1)))
			end
		end
	end
end

--- Public wrapper for threat value computation (exposed for testing).
function Medusa.Services.TargetAssigner.computeThreatValue(track)
	return computeThreatValue(track)
end

--- Finds the highest-Pk track within a battery's engagement envelope.
local function findBestTrackForBattery(battery, trackStore, geoGrid, maxEngagementRange)
	local LS = Medusa.Constants.TrackLifecycleState
	local results = geoGrid:queryRadius(battery.Position, maxEngagementRange, { "Track" })
	local trackIds = results.TrackIds
	if not trackIds then
		return nil
	end
	local bestPk = _pkFloor
	local bestTrackId = nil
	for id in pairs(trackIds) do
		local track = trackStore:get(id)
		if
			track
			and track.LifecycleState == LS.ACTIVE
			and track.AssessedAircraftType ~= Medusa.Constants.AssessedAircraftType.HARM
			and meetsMinIdentification(track.TrackIdentification, TI.BANDIT)
		then
			local projPos = projectTrackPosition(track, _lookaheadSec)
			if projPos then
				local projDist = nearestClusterDist(battery, projPos)
				if projDist and projDist <= battery.EngagementRangeMax then
					local pk = computePk(battery, track, projDist)
					if pk > bestPk then
						bestPk = pk
						bestTrackId = id
					end
				end
			end
		end
	end
	return bestTrackId
end

--- Lets ALWAYS_ON + ROE FREE batteries self-assign targets without waiting for WTA coordination.
function Medusa.Services.TargetAssigner.emconSelfAssign(
	trackStore,
	batteryStore,
	doctrine,
	now,
	geoGrid,
	maxEngagementRange
)
	_pkFloor = (doctrine and doctrine.EffectivePkFloor) or (doctrine and doctrine.PkFloor) or Medusa.Constants.PK_FLOOR
	_lookaheadSec = (doctrine and doctrine.LookaheadSec) or Medusa.Constants.LOOKAHEAD_DEFAULT_SEC
	_threatSpeedScaling = (doctrine and doctrine.ThreatSpeedScaling) or 30
	local roe = doctrine and doctrine.ROE or ROE.FREE
	local emcon = doctrine and doctrine.EMCON
	local batteries = batteryStore:getAll(_batteryBuffer)
	local AS = Medusa.Constants.ActivationState
	local BOS = Medusa.Constants.BatteryOperationalStatus
	local assignments = {}

	for i = 1, #batteries do
		local battery = batteries[i]
		local isEmconAutonomous = roe == ROE.FREE
			and emcon
			and battery.ActivationState == AS.STATE_WARM
			and isBatteryEligible(battery)
			and emcon[battery.Role] == ECP.ALWAYS_ON
		if isEmconAutonomous then
			local trackId = findBestTrackForBattery(battery, trackStore, geoGrid, maxEngagementRange)
			if trackId then
				local trackObj = trackStore:get(trackId)
				if trackObj then
					Medusa.Entities.Battery.assignTrack(battery, trackObj, now)
				end
				assignments[#assignments + 1] = { batteryId = battery.BatteryId, trackId = trackId }
				_logger:info(
					string.format("EMCON self-assign: battery %s engaging track %s", battery.GroupName, trackId)
				)
			end
		end
	end

	return assignments
end

local function _buildRoleTierMap(batteryStore)
	clearTable(_trackRoleTiers)
	if _tactics == CET.SHOOT_IN_DEPTH then
		local allBatts = batteryStore:getAll(_batteryBuffer)
		for i = 1, #allBatts do
			local b = allBatts[i]
			if b.CurrentTargetTrackId then
				local tiers = _trackRoleTiers[b.CurrentTargetTrackId]
				if not tiers then
					tiers = {}
					_trackRoleTiers[b.CurrentTargetTrackId] = tiers
				end
				tiers[b.Role] = true
			end
		end
	end
end

local function _initGreedyState()
	clearTable(_survive)
	clearTable(_assigned)
end

--- SEAD priority: force-assign best-Pk battery to HARM/SEAD threats before greedy loop.
local function _assignSeadPriority(tracks, geoGrid, batteryStore, maxEngagementRange, minId, now, assignments)
	local AAT = Medusa.Constants.AssessedAircraftType
	local LS = Medusa.Constants.TrackLifecycleState
	for i = 1, #tracks do
		local track = tracks[i]
		if
			track.LifecycleState == LS.ACTIVE
			and (track.AssessedAircraftType == AAT.HARM or track.IsSeadThreat)
			and meetsMinIdentification(track.TrackIdentification, minId)
			and (not track.AssignedBatteryIds or track.AssignedBatteryIds:isEmpty())
		then
			local nearby = Medusa.Services.SpatialQuery.batteriesInRadius(
				geoGrid,
				batteryStore,
				track.Position,
				maxEngagementRange
			)
			local bestPk, bestBat = 0, nil
			for j = 1, #nearby do
				if
					isBatteryEligible(nearby[j])
					and not _assigned[nearby[j].BatteryId]
					and (track.AssessedAircraftType ~= AAT.HARM or nearby[j].HarmCapableUnitCount > 0)
				then
					local projPos = projectTrackPosition(track, _lookaheadSec)
					if projPos then
						local d = nearestClusterDist(nearby[j], projPos)
						local pk = computePk(nearby[j], track, d)
						if pk > bestPk then
							bestPk = pk
							bestBat = nearby[j]
						end
					end
				end
			end
			if bestBat and bestPk >= _pkFloor then
				-- Set target before timestamp: handoff dwell checks read LastAssignmentChangeTime
				Medusa.Entities.Battery.assignTrack(bestBat, track, now)
				track.AssignmentTime = now
				_assigned[bestBat.BatteryId] = true
				-- Cumulative survival: P(survives) = product of (1 - Pk) across all assigned batteries
				local surv = _survive[track.TrackId] or 1.0
				_survive[track.TrackId] = surv * (1 - bestPk)
				assignments[#assignments + 1] = { batteryId = bestBat.BatteryId, trackId = track.TrackId }
				_logger:info(
					string.format(
						"SEAD priority: battery %s to track %s (pk=%.2f)",
						bestBat.GroupName,
						track.TrackId,
						bestPk
					)
				)
			end
		end
	end
end

local function _greedyAssign(pairCount, now, assignments)
	local budget = Medusa.Constants.MAX_ASSIGNMENT_BUDGET
	for _ = 1, budget do
		local bestGain = 0
		local bestIdx = nil
		for i = 1, pairCount do
			local p = _pairBuffer[i]
			if not _assigned[p.battery.BatteryId] and trackAcceptsBattery(p.track, p.battery.Role) then
				local surv = _survive[p.track.TrackId] or 1.0
				local gain = p.threatValue * surv * p.effectivePk
				if gain > bestGain then
					bestGain = gain
					bestIdx = i
				end
			end
		end
		if not bestIdx then
			break
		end
		local best = _pairBuffer[bestIdx]
		_assigned[best.battery.BatteryId] = true
		Medusa.Entities.Battery.assignTrack(best.battery, best.track, now)
		best.track.AssignmentTime = now
		local surv = _survive[best.track.TrackId] or 1.0
		-- FLOOD: SR/AAA don't reduce survival (they all engage regardless of diminishing returns)
		if _tactics ~= CET.SHOOT_SHOOT_FLOOD or (best.battery.Role ~= BR.SR_SAM and best.battery.Role ~= BR.AAA) then
			_survive[best.track.TrackId] = surv * (1 - best.pk)
		end
		-- Record role tier for SHOOT_IN_DEPTH, SHOOT_SHOOT_FLOOD LR/MR cap, and VLR_SAM (always)
		if _tactics == CET.SHOOT_IN_DEPTH or _tactics == CET.SHOOT_SHOOT_FLOOD or best.battery.Role == BR.VLR_SAM then
			local tiers = _trackRoleTiers[best.track.TrackId]
			if not tiers then
				tiers = {}
				_trackRoleTiers[best.track.TrackId] = tiers
			end
			tiers[best.battery.Role] = true
		end
		assignments[#assignments + 1] = { batteryId = best.battery.BatteryId, trackId = best.track.TrackId }
		_logger:info(
			string.format(
				"assigned battery %s to track %s (pk=%.2f, threat=%d)",
				best.battery.GroupName,
				best.track.TrackId,
				best.pk,
				best.threatValue
			)
		)
	end
end

--- Greedy WTA: assigns batteries to tracks maximizing aggregate kill probability.
function Medusa.Services.TargetAssigner.assignTargets(
	trackStore,
	batteryStore,
	maxEngagementRange,
	doctrine,
	now,
	geoGrid
)
	local roe = doctrine and doctrine.ROE or ROE.FREE
	_pkFloor = (doctrine and doctrine.EffectivePkFloor) or (doctrine and doctrine.PkFloor) or Medusa.Constants.PK_FLOOR
	_lookaheadSec = (doctrine and doctrine.LookaheadSec) or Medusa.Constants.LOOKAHEAD_DEFAULT_SEC
	_threatSpeedScaling = (doctrine and doctrine.ThreatSpeedScaling) or 30
	_maxEngageRangePct = doctrine and doctrine.MaxEngageRangePct or nil
	_stickyRangePct = (doctrine and doctrine.StickyRangePct) or 15
	if roe == ROE.HOLD then
		return {}
	end
	_tactics = doctrine and doctrine.EngageTactics or CET.SHOOT_LOOK_SHOOT

	_buildRoleTierMap(batteryStore)

	local minId = roe == ROE.TIGHT and TI.HOSTILE or TI.BANDIT
	local tracks = trackStore:getAll(_trackBuffer)
	local pairCount = buildCandidatePairs(tracks, geoGrid, batteryStore, maxEngagementRange, minId)
	applySaturationPenalty(pairCount)
	Medusa.Services.MetricsService.inc("medusa_assignment_pairs_evaluated", pairCount)
	if pairCount == 0 then
		return {}
	end

	_initGreedyState()
	local assignments = {}
	_assignSeadPriority(tracks, geoGrid, batteryStore, maxEngagementRange, minId, now, assignments)
	_greedyAssign(pairCount, now, assignments)

	_logger:debug(string.format("assignment: %d pairs, %d assigned", pairCount, #assignments))
	return assignments
end

--- Returns true if a HOT battery is eligible for handoff evaluation.
local function isHandoffEligible(battery, now)
	local AS = Medusa.Constants.ActivationState
	if battery.ActivationState ~= AS.STATE_HOT then
		return false
	end
	if not battery.CurrentTargetTrackId or not battery.Position then
		return false
	end
	if
		battery.LastAssignmentChangeTime
		and (now - battery.LastAssignmentChangeTime) < Medusa.Constants.HANDOFF_DWELL_SEC
	then
		return false
	end
	return true
end

--- Returns true if enough time has passed since last shot/assignment to justify reassessment.
local function shouldReassess(battery, now, threshold)
	local lastActivity = battery.LastShotTime or battery.LastAssignmentChangeTime
	if not lastActivity then
		return true
	end
	return (now - lastActivity) >= threshold
end

--- Searches for an alternative battery with higher Pk than the current holder.
local function findBetterBattery(track, projPos, currentPk, currentBatteryId, geoGrid, batteryStore, maxEngagementRange)
	local batteries =
		Medusa.Services.SpatialQuery.batteriesInRadius(geoGrid, batteryStore, track.Position, maxEngagementRange)
	local bestId, bestPk = nil, currentPk
	for i = 1, #batteries do
		local alt = batteries[i]
		if alt.BatteryId ~= currentBatteryId and isBatteryEligible(alt) then
			local projDist = nearestClusterDist(alt, projPos)
			if projDist and projDist <= alt.EngagementRangeMax then
				local altPk = computePk(alt, track, projDist)
				if altPk > bestPk then
					bestId, bestPk = alt.BatteryId, altPk
				end
			end
		end
	end
	return bestId, bestPk
end

--- Evaluates a single battery for handoff eligibility. Returns a handoff record
--- if the battery should release its target, nil otherwise.
--- @param battery table Battery entity
--- @param trackStore table TrackStore
--- @param batteryStore table BatteryStore
--- @param doctrine table|nil Doctrine table
--- @param now number Current simulation time
--- @param geoGrid table GeoGrid spatial index
--- @param maxEngagementRange number Maximum engagement range in meters
--- @return table|nil handoff {batteryId, trackId} if handoff needed
function Medusa.Services.TargetAssigner.evaluateSingleHandoff(
	battery,
	trackStore,
	batteryStore,
	doctrine,
	now,
	geoGrid,
	maxEngagementRange
)
	if not isHandoffEligible(battery, now) then
		return nil
	end
	local LS = Medusa.Constants.TrackLifecycleState
	local track = trackStore:get(battery.CurrentTargetTrackId)
	if not track or track.LifecycleState ~= LS.ACTIVE then
		return nil
	end

	local C = Medusa.Constants
	local stickyPct = (doctrine and doctrine.StickyRangePct) or 15
	local stickyFactor = 1 - stickyPct / 100
	local reassessThreshold = (doctrine and doctrine.EngageTimeoutSec) or C.REASSIGNMENT_EVAL_SEC

	local projPos = projectTrackPosition(track, _lookaheadSec)
	if not projPos then
		return nil
	end
	local projDist = nearestClusterDist(battery, projPos)
	local pk = computePk(battery, track, projDist)

	if pkBelowStickyFloor(pk, _pkFloor, stickyFactor) then
		_logger:info(
			string.format(
				"handoff: battery %s pk=%.2f below floor for track %s",
				battery.GroupName,
				pk,
				battery.CurrentTargetTrackId
			)
		)
		return { batteryId = battery.BatteryId, trackId = battery.CurrentTargetTrackId }
	end

	if pk >= _pkFloor then
		local readyToReassess = shouldReassess(battery, now, reassessThreshold)
		local altId, altPk =
			findBetterBattery(track, projPos, pk, battery.BatteryId, geoGrid, batteryStore, maxEngagementRange)
		local threshold = readyToReassess and pk or (pk * C.HANDOFF_PK_IMPROVEMENT)
		if altId and altPk >= threshold then
			local altBat = batteryStore:get(altId)
			_logger:info(
				string.format(
					"handoff: battery %s pk=%.2f -> %s pk=%.2f for track %s",
					battery.GroupName,
					pk,
					altBat and altBat.GroupName or altId,
					altPk,
					battery.CurrentTargetTrackId
				)
			)
			return { batteryId = battery.BatteryId, trackId = battery.CurrentTargetTrackId }
		end
	end

	return nil
end

--- Releases HOT batteries whose Pk dropped below floor or that timed out without firing.
function Medusa.Services.TargetAssigner.evaluateHandoffs(
	trackStore,
	batteryStore,
	doctrine,
	now,
	geoGrid,
	maxEngagementRange
)
	local batteries = batteryStore:getAll(_batteryBuffer)
	local C = Medusa.Constants
	_pkFloor = (doctrine and doctrine.EffectivePkFloor) or (doctrine and doctrine.PkFloor) or C.PK_FLOOR
	_lookaheadSec = (doctrine and doctrine.LookaheadSec) or C.LOOKAHEAD_DEFAULT_SEC
	local handoffs = {}

	for i = 1, #batteries do
		local result = Medusa.Services.TargetAssigner.evaluateSingleHandoff(
			batteries[i],
			trackStore,
			batteryStore,
			doctrine,
			now,
			geoGrid,
			maxEngagementRange
		)
		if result then
			handoffs[#handoffs + 1] = result
		end
	end

	return handoffs
end

local function batteryDetectsTrack(battery, track)
	if not track or not track.NetworkId then
		return false
	end
	local controller = GetGroupController(battery.GroupName)
	local detections = controller and GetControllerDetectedTargets(controller)
	if not detections then
		return false
	end
	for k = 1, #detections do
		if detections[k].object and detections[k].object.id_ == track.NetworkId then
			return true
		end
	end
	return false
end

--- Evaluates a single battery for deactivation eligibility.
--- @param battery table Battery entity
--- @param trackStore table TrackStore
--- @param doctrine table|nil Doctrine table
--- @param now number Current simulation time
--- @return table|nil deactivation {battery, reason} if deactivation needed
function Medusa.Services.TargetAssigner.checkSingleDeactivation(battery, trackStore, doctrine, now)
	local AS = Medusa.Constants.ActivationState
	local LS = Medusa.Constants.TrackLifecycleState
	local BOS = Medusa.Constants.BatteryOperationalStatus
	local holdDownSec = doctrine and doctrine.HoldDownSec or 15

	if battery.ActivationState ~= AS.STATE_HOT then
		return nil
	end

	if battery.OperationalStatus ~= BOS.ACTIVE and battery.OperationalStatus ~= BOS.ENGAGEMENT_IMPAIRED then
		return { battery = battery, reason = battery.OperationalStatus }
	end

	if not battery.CurrentTargetTrackId then
		local missileInFlight = battery.MissileInFlightUntil and now < battery.MissileInFlightUntil
		if battery.LastChanceTrackId then
			if battery.LastChanceShotsRemaining <= 0 then
				if not missileInFlight then
					Medusa.Entities.Battery.clearLastChance(battery)
					return { battery = battery, reason = "last-chance shots exhausted" }
				end
			elseif now < battery.LastChanceExpiresAt then
				-- Hold-down still active, stay HOT
			elseif not battery.LastChanceExtended then
				local track = trackStore:get(battery.LastChanceTrackId)
				if track and track.LifecycleState == LS.ACTIVE and batteryDetectsTrack(battery, track) then
					battery.LastChanceExpiresAt = now + holdDownSec
					battery.LastChanceExtended = true
				else
					Medusa.Entities.Battery.clearLastChance(battery)
					return { battery = battery, reason = "last-chance target lost" }
				end
			else
				Medusa.Entities.Battery.clearLastChance(battery)
				return { battery = battery, reason = "last-chance expired" }
			end
		else
			local lastActivity = math.max(battery.LastAssignmentChangeTime or 0, battery.LastShotTime or 0)
			local recentRelease = lastActivity > 0 and (now - lastActivity) < holdDownSec
			if not missileInFlight and not recentRelease then
				return { battery = battery, reason = "idle hold-down expired" }
			end
		end
		return nil
	end

	local track = trackStore:get(battery.CurrentTargetTrackId)
	if not track or track.LifecycleState == LS.EXPIRED then
		return { battery = battery, reason = "track expired" }
	end
	if track.LifecycleState == LS.STALE then
		local protected = track.AssignmentTime and (now - track.AssignmentTime) < holdDownSec
		if not protected then
			return { battery = battery, reason = "track stale" }
		end
	end
	return nil
end

--- Finds HOT batteries whose targets are gone, expired, or stale for deactivation.
function Medusa.Services.TargetAssigner.checkDeactivations(trackStore, batteryStore, doctrine, now)
	local batteries = batteryStore:getAll(_batteryBuffer)
	local deactivations = {}

	for i = 1, #batteries do
		local result = Medusa.Services.TargetAssigner.checkSingleDeactivation(batteries[i], trackStore, doctrine, now)
		if result then
			deactivations[#deactivations + 1] = result
		end
	end

	return deactivations
end
