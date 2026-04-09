require("_header")
require("services.Services")
require("services.SpatialQuery")
require("core.Constants")
require("core.Logger")

--[[
            ████████╗██████╗  █████╗  ██████╗██╗  ██╗     ██████╗██╗      █████╗ ███████╗███████╗██╗███████╗██╗███████╗██████╗
            ╚══██╔══╝██╔══██╗██╔══██╗██╔════╝██║ ██╔╝    ██╔════╝██║     ██╔══██╗██╔════╝██╔════╝██║██╔════╝██║██╔════╝██╔══██╗
               ██║   ██████╔╝███████║██║     █████╔╝     ██║     ██║     ███████║███████╗███████╗██║█████╗  ██║█████╗  ██████╔╝
               ██║   ██╔══██╗██╔══██║██║     ██╔═██╗     ██║     ██║     ██╔══██║╚════██║╚════██║██║██╔══╝  ██║██╔══╝  ██╔══██╗
               ██║   ██║  ██║██║  ██║╚██████╗██║  ██╗    ╚██████╗███████╗██║  ██║███████║███████║██║██║     ██║███████╗██║  ██║
               ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝     ╚═════╝╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝╚═╝╚═╝     ╚═╝╚══════╝╚═╝  ╚═╝

    What this service does
    - Promotes track identification through the ROE ladder: UNKNOWN → BOGEY → BANDIT → HOSTILE.
    - Uses criteria-based promotion with DCS surrogates for real ROE decision-making (ADR-0018).
    - Posture (HOT/WARM/COLD_WAR) and border zones gate how fast and whether tracks can advance.
    - Classifies aircraft type (fixed-wing, rotary, missile, fighter, heavy) from speed and maneuver data.

    How others use it
    - IadsNetwork calls updateIdentifications each assignment tick to advance the identification ladder.
    - TargetAssigner reads track identification to decide which tracks are eligible for engagement.
--]]

Medusa.Services.TrackClassifier = {}

local _logger = Medusa.Logger:ns("TrackClassifier")
Medusa.Services.TrackClassifier._trackBuffer = {}
local _trackBuffer = Medusa.Services.TrackClassifier._trackBuffer

local C = Medusa.Constants
local AAT = Medusa.Constants.AssessedAircraftType
local ManeuverState = Medusa.Constants.ManeuverState
local TI = Medusa.Constants.TrackIdentification
local P = Medusa.Constants.Posture

local TYPE_RANK = {
	[AAT.UNKNOWN] = 0,
	[AAT.FIXED_WING] = 1,
	[AAT.ROTARY_WING] = 1,
	[AAT.MISSILE] = 1,
	[AAT.FIGHTER] = 2,
	[AAT.SEAD_AIRCRAFT] = 2,
	[AAT.HARM] = 3,
}

local RWR_SUSTAINED_SEC = 30
local INTENT_BEARING_DEG = 30
local INTENT_MIN_SPEED_MPS = 150

--- @type table<string, number[]> Per-posture IFF confirmation timer (seconds). Time from first detection to
--- BOGEY promotion. DCS getDetectedTargets already filters friendlies, so this timer simulates the delay
--- for operators to confirm a new contact as non-friendly.
local IFF_CONFIRM_TIMER = {
	[P.HOT_WAR] = { 3, 8 },
	[P.WARM_WAR] = { 10, 30 },
	[P.COLD_WAR] = { 30, 60 },
}
--- @type table<string, number[]> Per-posture randomized timer range for intel identification (seconds)
local INTEL_TIMER = {
	[P.HOT_WAR] = { 15, 45 },
	[P.WARM_WAR] = { 45, 120 },
	[P.COLD_WAR] = { 120, 300 },
}
--- @type table<string, number[]> Per-posture randomized timer range for VID identification (seconds)
local VID_TIMER = {
	[P.HOT_WAR] = { 30, 60 },
	[P.WARM_WAR] = { 60, 180 },
	[P.COLD_WAR] = { 120, 300 },
}
--- @type table<string, number[]> Per-posture randomized dwell before HOSTILE on NFZ trespass (seconds)
local BORDER_HOSTILE_DWELL = {
	[P.HOT_WAR] = { 0, 0 },
	[P.WARM_WAR] = { 15, 45 },
	[P.COLD_WAR] = { 30, 120 },
}

--- @type table<string, {x: number, z: number}> Module-local cache for zone containment position delta check, keyed by TrackId
Medusa.Services.TrackClassifier._zoneCheckCache = {}
local _zoneCheckCache = Medusa.Services.TrackClassifier._zoneCheckCache

local function randomInRange(range)
	if not range then
		return 0
	end
	local lo, hi = range[1], range[2]
	if lo >= hi then
		return lo
	end
	return lo + math.random() * (hi - lo)
end

local function isRWRIlluminated(track)
	return track.DetectingSensorIds and not track.DetectingSensorIds:isEmpty()
end

local function checkHostileIntent(track, geoGrid, batteryStore, now, sustainedSec, bearingDeg, minSpeedMps, maxRange)
	local vel = track.SmoothedVelocity or track.Velocity
	if not vel or not track.Position then
		return false
	end
	local speed = VecLength2D(vel)
	if speed < minSpeedMps then
		track.HostileIntentStart = nil
		return false
	end

	local batteries =
		Medusa.Services.SpatialQuery.batteriesInRadius(geoGrid, batteryStore, track.Position, maxRange or 200000)
	if #batteries == 0 then
		track.HostileIntentStart = nil
		return false
	end

	local trackHdg = math.atan2(vel.z, vel.x)
	local toleranceRad = bearingDeg * math.pi / 180

	for bi = 1, #batteries do
		local b = batteries[bi]
		if b.Position then
			local dx = b.Position.x - track.Position.x
			local dz = b.Position.z - track.Position.z
			local bearingToAsset = math.atan2(dz, dx)
			local angleDiff = math.abs(trackHdg - bearingToAsset)
			if angleDiff > math.pi then
				angleDiff = 2 * math.pi - angleDiff
			end
			if angleDiff < toleranceRad then
				local dist = math.sqrt(dx * dx + dz * dz)
				if dist > 1 then
					local rangeRate = (dx * vel.x + dz * vel.z) / dist
					if rangeRate > 0 then
						if not track.HostileIntentStart then
							track.HostileIntentStart = now
							return false
						end
						return (now - track.HostileIntentStart) >= sustainedSec
					end
				end
			end
		end
	end

	track.HostileIntentStart = nil
	return false
end

local ZONE_RECHECK_DIST_SQ = 2000 * 2000
local GUILT_RANGE_SQ = 11000 * 11000
local GUILT_HEADING_TOL_RAD = 15 * math.pi / 180
local GUILT_SPEED_TOL = 0.20

local function updateZoneContainment(track, borderPolygons, adizPolygon)
	local pos = track.Position
	if not pos then
		return
	end

	-- Skip expensive polygon test if track hasn't moved significantly
	-- Cache is module-local to keep Track entity clean
	local now = GetTime()
	local cached = _zoneCheckCache[track.TrackId]
	if cached then
		local dx = pos.x - cached.x
		local dz = pos.z - cached.z
		if (dx * dx + dz * dz) < ZONE_RECHECK_DIST_SQ and (now - cached.t) < 60 then
			return
		end
		cached.x = pos.x
		cached.z = pos.z
		cached.t = now
	else
		_zoneCheckCache[track.TrackId] = { x = pos.x, z = pos.z, t = now }
	end

	local wasBorder = track.InsideBorder

	track.InsideBorder = Medusa.Services.SpatialQuery.pointInBorderZones(borderPolygons, pos)

	if adizPolygon then
		track.InsideADIZ = PointInPolygon2D(pos, adizPolygon) or track.InsideBorder
	else
		track.InsideADIZ = track.InsideBorder
	end

	if track.InsideBorder and not wasBorder then
		track.BorderCrossingTime = GetTime()
	end
end

--- Checks if a track has confirmed hostile action and promotes it to HOSTILE instantly.
local function checkHostileAction(track, trackStore, posture, now)
	if not track.HostileActionConfirmed then
		return false
	end
	local prev = track.TrackIdentification
	trackStore:updateIdentification(track.TrackId, TI.HOSTILE)
	Medusa.Services.MetricsService.inc("medusa_track_promotions_total")
	track.LastIdentificationTime = now
	_logger:info(string.format("track %s %s->HOSTILE (hostile action, %s)", track.TrackId, prev, posture))
	return true
end

local function evaluateUnknown(track, trackStore, posture, hasBorders, now)
	if checkHostileAction(track, trackStore, posture, now) then
		return
	end

	-- Assign IFF confirmation timer on first evaluation
	if not track.IffConfirmTime then
		track.IffConfirmTime = track.FirstDetectionTime
			+ randomInRange(IFF_CONFIRM_TIMER[posture] or IFF_CONFIRM_TIMER[P.HOT_WAR])
	end

	-- ADIZ entry forces immediate BOGEY in WARM/COLD
	local forceByADIZ = hasBorders and track.InsideADIZ and posture ~= P.HOT_WAR

	if forceByADIZ or now >= track.IffConfirmTime then
		trackStore:updateIdentification(track.TrackId, TI.BOGEY)
		Medusa.Services.MetricsService.inc("medusa_track_promotions_total")
		track.LastIdentificationTime = now
		if forceByADIZ then
			_logger:info(string.format("track %s UNKNOWN->BOGEY (ADIZ entry, %s)", track.TrackId, posture))
		else
			_logger:debug(string.format("track %s UNKNOWN->BOGEY (%s, IFF confirmed)", track.TrackId, posture))
		end
	end
end

local function evaluateBogey(track, trackStore, posture, hasBorders, now)
	if checkHostileAction(track, trackStore, posture, now) then
		return
	end

	-- COLD_WAR contacts outside ADIZ are frozen at BOGEY
	if posture == P.COLD_WAR and hasBorders and not track.InsideADIZ then
		return
	end

	local criteria = 0

	if now >= track.IntelIdentifyTime then
		criteria = criteria + 1
	end

	if posture == P.HOT_WAR then
		if isRWRIlluminated(track) then
			criteria = criteria + 1
		end
	elseif posture == P.WARM_WAR then
		if isRWRIlluminated(track) then
			if not track.RWRIlluminationStart then
				track.RWRIlluminationStart = now
			end
			if (now - track.RWRIlluminationStart) >= RWR_SUSTAINED_SEC then
				criteria = criteria + 1
			end
		else
			track.RWRIlluminationStart = nil
		end
	end

	if now >= track.VIDIdentifyTime then
		criteria = criteria + 1
	end

	if criteria >= 2 then
		trackStore:updateIdentification(track.TrackId, TI.BANDIT)
		Medusa.Services.MetricsService.inc("medusa_track_promotions_total")
		track.LastIdentificationTime = now
		_logger:info(string.format("track %s BOGEY->BANDIT (%s, criteria=%d)", track.TrackId, posture, criteria))
	end
end

local function evaluateBandit(track, trackStore, posture, hasBorders, now, geoGrid, batteryStore, maxRange)
	if checkHostileAction(track, trackStore, posture, now) then
		return
	end

	-- HOT_WAR without borders: BANDIT promotes to HOSTILE on dwell timer alone.
	-- At war with no defined service area, identified adversaries are cleared to engage.
	if posture == P.HOT_WAR and not hasBorders then
		local dwell = now - (track.LastIdentificationTime or now)
		if dwell >= C.BANDIT_DWELL_SEC then
			trackStore:updateIdentification(track.TrackId, TI.HOSTILE)
			Medusa.Services.MetricsService.inc("medusa_track_promotions_total")
			track.LastIdentificationTime = now
			_logger:info(string.format("track %s BANDIT->HOSTILE (HOT_WAR dwell %.0fs)", track.TrackId, dwell))
		end
		return
	end

	-- NFZ Trespass
	if hasBorders and track.InsideBorder then
		if not track.BorderHostileDwellSec then
			track.BorderHostileDwellSec = randomInRange(BORDER_HOSTILE_DWELL[posture])
		end
		if track.BorderCrossingTime and (now - track.BorderCrossingTime) >= track.BorderHostileDwellSec then
			trackStore:updateIdentification(track.TrackId, TI.HOSTILE)
			Medusa.Services.MetricsService.inc("medusa_track_promotions_total")
			track.LastIdentificationTime = now
			_logger:info(
				string.format(
					"track %s BANDIT->HOSTILE (NFZ trespass, dwell=%.0fs, %s)",
					track.TrackId,
					track.BorderHostileDwellSec,
					posture
				)
			)
			return
		end
	end

	-- HOT_WAR with borders: dwell timer also applies (don't require NFZ trespass at war)
	if posture == P.HOT_WAR and hasBorders then
		local dwell = now - (track.LastIdentificationTime or now)
		if dwell >= C.BANDIT_DWELL_SEC then
			trackStore:updateIdentification(track.TrackId, TI.HOSTILE)
			Medusa.Services.MetricsService.inc("medusa_track_promotions_total")
			track.LastIdentificationTime = now
			_logger:info(string.format("track %s BANDIT->HOSTILE (HOT_WAR dwell %.0fs)", track.TrackId, dwell))
			return
		end
	end

	-- Hostile intent: converging on defended asset
	local intentSustainedSec = posture == P.COLD_WAR and 120 or 60
	if
		checkHostileIntent(
			track,
			geoGrid,
			batteryStore,
			now,
			intentSustainedSec,
			INTENT_BEARING_DEG,
			INTENT_MIN_SPEED_MPS,
			maxRange
		)
	then
		trackStore:updateIdentification(track.TrackId, TI.HOSTILE)
		Medusa.Services.MetricsService.inc("medusa_track_promotions_total")
		track.LastIdentificationTime = now
		_logger:info(string.format("track %s BANDIT->HOSTILE (hostile intent, %s)", track.TrackId, posture))
	end
end

-- HOSTILE is terminal. Once declared hostile, the decision stands for the
-- lifetime of the track. No demotion.

--- @type table[] Reuse buffer for tracks promoted this tick (for guilt-by-association pass)
Medusa.Services.TrackClassifier._promotedBuffer = {}
local _promotedBuffer = Medusa.Services.TrackClassifier._promotedBuffer

--- Returns true if candidate is close, heading the same direction, at similar speed as the promoted track.
local function isGuiltAligned(promoted, pSpeed, pHdg, candidate)
	local dx = candidate.Position.x - promoted.Position.x
	local dz = candidate.Position.z - promoted.Position.z
	if (dx * dx + dz * dz) > GUILT_RANGE_SQ then
		return false
	end
	local cVel = candidate.SmoothedVelocity or candidate.Velocity
	if not cVel then
		return false
	end
	local cSpeed = VecLength2D(cVel)
	if pSpeed <= 1 or cSpeed <= 1 then
		return false
	end
	local cHdg = math.atan2(cVel.z, cVel.x)
	local hdgDiff = math.abs(pHdg - cHdg)
	if hdgDiff > math.pi then
		hdgDiff = 2 * math.pi - hdgDiff
	end
	return hdgDiff < GUILT_HEADING_TOL_RAD and math.abs(pSpeed - cSpeed) / pSpeed < GUILT_SPEED_TOL
end

local function applyGuiltByAssociation(tracks, trackStore, now)
	if #_promotedBuffer == 0 then
		return
	end
	for pi = 1, #_promotedBuffer do
		local promoted = _promotedBuffer[pi]
		local pVel = promoted.track.SmoothedVelocity or promoted.track.Velocity
		if pVel and promoted.track.Position then
			local pSpeed = VecLength2D(pVel)
			local pHdg = math.atan2(pVel.z, pVel.x)
			for ti = 1, #tracks do
				local candidate = tracks[ti]
				local cId = candidate.TrackIdentification
				if
					candidate.TrackId ~= promoted.track.TrackId
					and cId ~= TI.ARM
					and cId ~= TI.FRIENDLY
					and cId ~= TI.WHITEAIR
					and cId ~= promoted.newId
					and candidate.Position
				then
					if isGuiltAligned(promoted.track, pSpeed, pHdg, candidate) then
						trackStore:updateIdentification(candidate.TrackId, promoted.newId)
						Medusa.Services.MetricsService.inc("medusa_track_promotions_total")
						candidate.LastIdentificationTime = now
						_logger:info(
							string.format(
								"track %s %s->%s (guilt by association with %s)",
								candidate.TrackId,
								cId,
								promoted.newId,
								promoted.track.TrackId
							)
						)
					end
				end
			end
		end
	end
end

--- Classifies a single track through the ROE ladder. Returns promotion info if
--- guilt-by-association is enabled and the track was promoted, nil otherwise.
--- @param track table Track entity
--- @param ctx table Pipeline context: trackStore, batteryStore, geoGrid, now, maxRange, doctrine, borderPolygons, adizPolygon
--- @return table|nil promotion {track=track, newId=newId} if promoted, nil otherwise
function Medusa.Services.TrackClassifier.classifyTrack(track, ctx)
	local trackStore = ctx.trackStore
	local now = ctx.now
	local doctrine = ctx.doctrine
	local posture = doctrine and doctrine.Posture or P.HOT_WAR
	local hasBorders = ctx.borderPolygons and #ctx.borderPolygons > 0
	local guiltEnabled = not doctrine or doctrine.GuiltByAssociation ~= false

	local prevId = track.TrackIdentification

	if prevId == TI.ARM or prevId == TI.FRIENDLY or prevId == TI.WHITEAIR then
		return nil
	end

	if hasBorders then
		updateZoneContainment(track, ctx.borderPolygons, ctx.adizPolygon)
	end

	if not track.IntelIdentifyTime then
		track.IntelIdentifyTime = now + randomInRange(INTEL_TIMER[posture])
	end
	if not track.VIDIdentifyTime then
		track.VIDIdentifyTime = now + randomInRange(VID_TIMER[posture])
	end

	if prevId == TI.UNKNOWN then
		evaluateUnknown(track, trackStore, posture, hasBorders, now)
	elseif prevId == TI.BOGEY then
		evaluateBogey(track, trackStore, posture, hasBorders, now)
	elseif prevId == TI.BANDIT then
		evaluateBandit(track, trackStore, posture, hasBorders, now, ctx.geoGrid, ctx.batteryStore, ctx.maxRange)
	end

	local newId = track.TrackIdentification
	if guiltEnabled and newId ~= prevId and (newId == TI.BANDIT or newId == TI.HOSTILE) then
		return { track = track, newId = newId }
	end
	return nil
end

function Medusa.Services.TrackClassifier.updateIdentifications(ctx)
	local trackStore = ctx.trackStore
	local now = ctx.now
	local doctrine = ctx.doctrine
	local guiltEnabled = not doctrine or doctrine.GuiltByAssociation ~= false

	local tracks = trackStore:getAll(_trackBuffer)

	for k = #_promotedBuffer, 1, -1 do
		_promotedBuffer[k] = nil
	end

	for i = 1, #tracks do
		local result = Medusa.Services.TrackClassifier.classifyTrack(tracks[i], ctx)
		if result then
			_promotedBuffer[#_promotedBuffer + 1] = result
		end
	end

	if guiltEnabled then
		applyGuiltByAssociation(tracks, trackStore, now)
	end

	-- Prune stale zone check cache entries for removed tracks
	local hasBorders = ctx.borderPolygons and #ctx.borderPolygons > 0
	if hasBorders then
		for id in pairs(_zoneCheckCache) do
			if not trackStore:get(id) then
				_zoneCheckCache[id] = nil
			end
		end
	end
end

-- Aircraft type classification

local function deriveAircraftType(track)
	local vel = track.SmoothedVelocity or track.Velocity
	if not vel then
		return nil
	end
	local speed = VecLength2D(vel)
	if speed < C.ROTARY_WING_SPEED_THRESHOLD then
		return AAT.ROTARY_WING
	end
	if speed >= C.MISSILE_SPEED_THRESHOLD then
		return AAT.MISSILE
	end
	return AAT.FIXED_WING
end

local function isFighterManeuver(track)
	local ms = track.ManeuverState
	if ms ~= ManeuverState.MANEUVERING and ms ~= ManeuverState.TURNING_LEFT and ms ~= ManeuverState.TURNING_RIGHT then
		return false
	end
	local vel = track.SmoothedVelocity or track.Velocity
	if not vel then
		return false
	end
	return VecLength2D(vel) > C.FIGHTER_MANEUVER_SPEED_THRESHOLD
end

local function subdivideFixedWing(track, aircraftType)
	if aircraftType ~= AAT.FIXED_WING then
		return aircraftType
	end
	if isFighterManeuver(track) then
		return AAT.FIGHTER
	end
	local trackAge = track.LastDetectionTime - track.FirstDetectionTime
	if trackAge > Medusa.Constants.HEAVY_DWELL_SEC and track.ManeuverState == ManeuverState.STRAIGHT then
		return AAT.HEAVY
	end
	return AAT.FIXED_WING
end

--- Classifies a single track's aircraft type from kinematic data. Promotes only
--- upward in the type hierarchy (e.g. FIXED_WING -> FIGHTER, never the reverse).
--- @param track table Track entity
function Medusa.Services.TrackClassifier.assessSingleAircraftType(track)
	local LS = Medusa.Constants.TrackLifecycleState
	if track.LifecycleState ~= LS.ACTIVE or track.AssessedAircraftType == AAT.HARM then
		return
	end
	local baseType = deriveAircraftType(track)
	if not baseType then
		return
	end
	local finalType = subdivideFixedWing(track, baseType)
	local currentRank = TYPE_RANK[track.AssessedAircraftType] or 0
	local newRank = TYPE_RANK[finalType] or 0
	if newRank > currentRank then
		_logger:info(string.format("track %s type %s -> %s", track.TrackId, track.AssessedAircraftType, finalType))
		track.AssessedAircraftType = finalType
	end
end

function Medusa.Services.TrackClassifier.assessAircraftTypes(trackStore)
	local tracks = trackStore:getAll(_trackBuffer)
	for i = 1, #tracks do
		Medusa.Services.TrackClassifier.assessSingleAircraftType(tracks[i])
	end
end

--- Applies guilt-by-association using the current promoted buffer, then clears it.
--- Called by the chunked pipeline when a classification cycle completes.
--- @param tracks table Array of track entities
--- @param trackStore table TrackStore
--- @param now number Current simulation time
function Medusa.Services.TrackClassifier.flushGuiltByAssociation(tracks, trackStore, now)
	applyGuiltByAssociation(tracks, trackStore, now)
	for k = #_promotedBuffer, 1, -1 do
		_promotedBuffer[k] = nil
	end
end

--- Clears the promoted buffer without applying guilt-by-association.
function Medusa.Services.TrackClassifier.clearPromotedBuffer()
	for k = #_promotedBuffer, 1, -1 do
		_promotedBuffer[k] = nil
	end
end
