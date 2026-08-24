require("_header")
require("services.Services")
require("observability.MetricsService")
require("services.SpatialQuery")
require("core.Constants")
require("core.Logger")
require("entities.Battery")
require("entities.Track")

--[[
            ██╗  ██╗ █████╗ ██████╗ ███╗   ███╗    ██████╗ ███████╗████████╗███████╗ ██████╗████████╗██╗ ██████╗ ███╗   ██╗
            ██║  ██║██╔══██╗██╔══██╗████╗ ████║    ██╔══██╗██╔════╝╚══██╔══╝██╔════╝██╔════╝╚══██╔══╝██║██╔═══██╗████╗  ██║
            ███████║███████║██████╔╝██╔████╔██║    ██║  ██║█████╗     ██║   █████╗  ██║        ██║   ██║██║   ██║██╔██╗ ██║
            ██╔══██║██╔══██║██╔══██╗██║╚██╔╝██║    ██║  ██║██╔══╝     ██║   ██╔══╝  ██║        ██║   ██║██║   ██║██║╚██╗██║
            ██║  ██║██║  ██║██║  ██║██║ ╚═╝ ██║    ██████╔╝███████╗   ██║   ███████╗╚██████╗   ██║   ██║╚██████╔╝██║ ╚████║
            ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝    ╚═════╝ ╚══════╝   ╚═╝   ╚══════╝ ╚═════╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝

    What this service does
    - Scores each track against an 8-feature kinematic model to detect anti-radiation missiles.
    - Classifies tracks from a bounded accumulated likelihood score.
    - Computes closest-point-of-approach to nearby battery radars for threat assessment.

    How others use it
    - IadsNetwork calls evaluate each tick to update HARM likelihood scores on active tracks.
    - HarmResponseService reads those scores to decide shutdown or defense actions.

--]]

Medusa.Services.HarmDetectionService = {}

local _logger = Medusa.Logger:ns("HarmDetectionService")
--- @type table Alias for Medusa.Constants
local C = Medusa.Constants
--- @type table Enum mapping for assessed aircraft types (e.g. AAT.HARM)
local AAT = Medusa.Constants.AssessedAircraftType
local HAS = Medusa.Constants.HarmAssessmentState
--- @type table Reusable buffer for track iteration
Medusa.Services.HarmDetectionService._trackBuffer = {}
local _trackBuffer = Medusa.Services.HarmDetectionService._trackBuffer
--- @type number[] Pre-allocated 8-element feature vector reused each extraction call
Medusa.Services.HarmDetectionService._feat = { 0, 0, 0, 0, 0, 0, 0, 0 }
local _feat = Medusa.Services.HarmDetectionService._feat

--- Feature vector indices for the kinematic likelihood classifier.
--- Each maps to a slot in the _feat array extracted per scan.
local F_SPEED = 1 -- 3D speed (m/s)
local F_DIVE = 2 -- dive angle (rad, positive = diving)
local F_HDGRATE = 3 -- horizontal heading rate of change (rad/s)
local F_ACCEL = 4 -- three-dimensional speed change (m/s²)
local F_CPA = 5 -- closest point of approach to candidate radar battery (m)
local F_CPARATE = 6 -- rate of CPA change (m/s, negative = closing)
local F_RNGRATE = 7 -- range rate to candidate radar battery (m/s, negative = closing)
local F_ALTRATE = 8 -- vertical velocity (m/s)
local NUM_FEAT = 8

-- Pre-compute likelihood arrays from the model once at load.
-- Each array is indexed [1..NUM_FEAT] and derived from HARM_SPRT_MODEL Gaussians.
--- @type number[] 1/(2·σ²) for ARM distribution, used in log-likelihood exponent
Medusa.Services.HarmDetectionService._inv2vArm = {}
local _inv2vArm = Medusa.Services.HarmDetectionService._inv2vArm
--- @type number[] 1/(2·σ²) for non-ARM distribution
Medusa.Services.HarmDetectionService._inv2vNon = {}
local _inv2vNon = Medusa.Services.HarmDetectionService._inv2vNon
--- @type number[] log(σ_non / σ_arm), normalisation term in LLR
Medusa.Services.HarmDetectionService._lsigRatio = {}
local _lsigRatio = Medusa.Services.HarmDetectionService._lsigRatio
--- @type number[] Mean of ARM distribution per feature
Medusa.Services.HarmDetectionService._muArm = {}
local _muArm = Medusa.Services.HarmDetectionService._muArm
--- @type number[] Mean of non-ARM distribution per feature
Medusa.Services.HarmDetectionService._muNon = {}
local _muNon = Medusa.Services.HarmDetectionService._muNon

local MODEL = Medusa.Constants.HARM_SPRT_MODEL
for i = 1, NUM_FEAT do
	local m = MODEL[i]
	local sa, sn = m[2], m[4]
	_inv2vArm[i] = 1.0 / (2.0 * sa * sa)
	_inv2vNon[i] = 1.0 / (2.0 * sn * sn)
	_lsigRatio[i] = math.log(sn / sa)
	_muArm[i] = m[1]
	_muNon[i] = m[3]
end

--- Compute the 3D closest point of approach (CPA) between a moving object and a
--- stationary emitter. Returns the minimum distance the object will reach along
--- its current linear velocity vector, plus the time until that point.
--- The classifier uses CPA to distinguish ARMs from transiting aircraft.
--- ARMs converge on the emitter (CPA near zero), while passing aircraft have
--- a large CPA that stays roughly constant.
--- @param px number Track position X (DCS world coords)
--- @param py number Track position Y (altitude)
--- @param pz number Track position Z
--- @param vx number Track velocity X (m/s)
--- @param vy number Track velocity Y (m/s)
--- @param vz number Track velocity Z (m/s)
--- @param ex number Emitter position X
--- @param ey number Emitter position Y
--- @param ez number Emitter position Z
--- @return number cpaDistance Closest approach distance in meters
--- @return number tCpa Time in seconds until closest approach (0 if already past)
function Medusa.Services.HarmDetectionService.computeCPA3D(px, py, pz, vx, vy, vz, ex, ey, ez)
	local rx, ry, rz = px - ex, py - ey, pz - ez
	local vdotv = vx * vx + vy * vy + vz * vz
	if vdotv < 1e-6 then
		return math.sqrt(rx * rx + ry * ry + rz * rz), 0
	end
	local tCpa = math.max(0, -(rx * vx + ry * vy + rz * vz) / vdotv)
	local cx, cy, cz = rx + vx * tCpa, ry + vy * tCpa, rz + vz * tCpa
	return math.sqrt(cx * cx + cy * cy + cz * cz), tCpa
end

--- Returns the closest point of approach distance between a track and a position.
function Medusa.Services.HarmDetectionService.computeTrackCPA(track, targetPos)
	local vel = track.SmoothedVelocity or track.Velocity
	if not vel then
		return math.huge
	end
	return Medusa.Services.HarmDetectionService.computeCPA3D(
		track.Position.x,
		track.Position.y,
		track.Position.z,
		vel.x,
		vel.y,
		vel.z,
		targetPos.x,
		targetPos.y,
		targetPos.z
	)
end

--- @type fun(px:number,py:number,pz:number,vx:number,vy:number,vz:number,ex:number,ey:number,ez:number):number,number Local alias for CPA computation
local computeCPA3D = Medusa.Services.HarmDetectionService.computeCPA3D

local G = Medusa.Constants.GRAVITY_MPS2

--- Compute CPA using a ballistic (gravity-only) trajectory simulation.
--- Linear CPA assumes constant velocity, but ARMs in their terminal dive arc
--- downward under gravity after motor burnout. This function forward-integrates
--- position with gravity each step and returns the smallest distance encountered.
--- The feature extractor takes the smaller of linear and ballistic CPA, so a
--- diving missile's true closest approach is not underestimated.
--- @param px number Track position X
--- @param py number Track position Y (altitude)
--- @param pz number Track position Z
--- @param vx number Track velocity X (m/s)
--- @param vy number Track velocity Y (m/s)
--- @param vz number Track velocity Z (m/s)
--- @param ex number Emitter position X
--- @param ey number Emitter position Y
--- @param ez number Emitter position Z
--- @param dt number Simulation time step in seconds
--- @param maxT number Maximum simulation time in seconds
--- @return number bestDist Closest approach distance in meters along the ballistic arc
local function computeBallisticCPA(px, py, pz, vx, vy, vz, ex, ey, ez, dt, maxT)
	local bestDist = math.huge
	local x, y, z = px, py, pz
	local bvx, bvy, bvz = vx, vy, vz
	for _ = 1, math.ceil(maxT / dt) do
		bvy = bvy - G * dt
		x = x + bvx * dt
		y = y + bvy * dt
		z = z + bvz * dt
		if y < 0 then
			break
		end
		local dx, dy, dz = x - ex, y - ey, z - ez
		local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
		if dist < bestDist then
			bestDist = dist
		elseif dist > bestDist * 1.5 then
			break
		end
	end
	return bestDist
end

--- Reports whether a managed battery currently owns a live radar target.
local function isCurrentRadarTarget(battery)
	return battery and battery.Position ~= nil and Medusa.Entities.Battery.hasSearchRadar(battery)
end

--- Returns projected horizontal closest approach to one stationary battery.
local function horizontalCpa(track, batteryPosition)
	local velocity = track.SmoothedVelocity or track.Velocity
	if not velocity then
		return math.huge
	end
	local rx = track.Position.x - batteryPosition.x
	local rz = track.Position.z - batteryPosition.z
	local speedSq = velocity.x * velocity.x + velocity.z * velocity.z
	if speedSq < 1e-6 then
		return math.sqrt(rx * rx + rz * rz)
	end
	local time = math.max(0, -(rx * velocity.x + rz * velocity.z) / speedSq)
	local closestX = rx + velocity.x * time
	local closestZ = rz + velocity.z * time
	return math.sqrt(closestX * closestX + closestZ * closestZ)
end

--- Finds the current radar battery nearest the track's projected horizontal path.
--- @param track table Track entity with .Position
--- @param geoGrid table GeoGrid spatial index for battery lookups
--- @param batteryStore table BatteryStore for resolving spatial results
--- @param threatRadiusM number Maximum projected horizontal miss distance
--- @return table|nil battery Closest relevant radar battery, or nil
local function findCandidateBattery(track, geoGrid, batteryStore, threatRadiusM)
	local batteries = Medusa.Services.SpatialQuery.batteriesInRadius(
		geoGrid,
		batteryStore,
		track.Position,
		Medusa.Constants.HARM_MAX_RANGE_M
	)
	local best, bestDist = nil, math.huge
	for i = 1, #batteries do
		local b = batteries[i]
		if isCurrentRadarTarget(b) then
			local dist = horizontalCpa(track, b.Position)
			if dist < threatRadiusM and dist < bestDist then
				best = b
				bestDist = dist
			end
		end
	end
	return best
end

--- Extracts the 8-element kinematic feature vector from two consecutive position
--- history entries. These features capture the flight signature of an ARM:
--- high speed, steep dive, minimal horizontal heading change, raw speed change,
--- small and shrinking closest approach to the candidate radar battery, negative
--- range rate, and negative altitude rate. Aircraft usually maneuver, climb, or
--- pass the battery instead of maintaining this combined flight signature.
--- Writes into the module-level _feat buffer to avoid per-observation allocation.
--- @param curr table Current position history entry {position, velocity, timestamp}
--- @param prev table Previous position history entry
--- @param dt number Time delta between curr and prev (seconds)
--- @param targetPos table {x,y,z} position of the retained candidate battery
--- @param assessmentState table Per-track state with prior CPA evidence
--- @param ballisticDt number|nil Ballistic sim time step (default 1.0s)
--- @param ballisticMaxT number|nil Ballistic sim max steps (default 120)
--- @return number[] feat 8-element feature vector (reused buffer, do not hold across calls)
local function extractFeatures(curr, prev, dt, targetPos, assessmentState, ballisticDt, ballisticMaxT)
	ballisticDt = ballisticDt or 1.0
	ballisticMaxT = ballisticMaxT or 120
	local cv = curr.velocity
	local pv = prev.velocity
	local cp = curr.position

	local cvxSq, cvySq, cvzSq = cv.x * cv.x, cv.y * cv.y, cv.z * cv.z
	local speed = math.sqrt(cvxSq + cvySq + cvzSq)
	_feat[F_SPEED] = speed

	local hSpeed = math.sqrt(cvxSq + cvzSq)
	_feat[F_DIVE] = (speed > 1.0) and math.atan2(-cv.y, hSpeed) or 0

	local pvxSq, pvySq, pvzSq = pv.x * pv.x, pv.y * pv.y, pv.z * pv.z
	local hSpeedPrev = math.sqrt(pvxSq + pvzSq)
	if hSpeed > 1.0 and hSpeedPrev > 1.0 then
		local hdgCurr = math.atan2(cv.z, cv.x)
		local hdgPrev = math.atan2(pv.z, pv.x)
		local dHdg = hdgCurr - hdgPrev
		dHdg = dHdg - 2 * math.pi * math.floor((dHdg + math.pi) / (2 * math.pi))
		_feat[F_HDGRATE] = math.abs(dHdg) / dt
	else
		_feat[F_HDGRATE] = 0
	end

	local prevSpeed = math.sqrt(pvxSq + pvySq + pvzSq)
	_feat[F_ACCEL] = (speed - prevSpeed) / dt

	local linearCpa = computeCPA3D(cp.x, cp.y, cp.z, cv.x, cv.y, cv.z, targetPos.x, targetPos.y, targetPos.z)
	local ballisticCpa = computeBallisticCPA(
		cp.x,
		cp.y,
		cp.z,
		cv.x,
		cv.y,
		cv.z,
		targetPos.x,
		targetPos.y,
		targetPos.z,
		ballisticDt,
		ballisticMaxT
	)
	_feat[F_CPA] = math.min(linearCpa, ballisticCpa)

	if assessmentState.prevCpa and assessmentState.prevTime then
		local cpaDt = curr.timestamp - assessmentState.prevTime
		local cpaDist = _feat[F_CPA]
		_feat[F_CPARATE] = (cpaDt > 0.001) and ((cpaDist - assessmentState.prevCpa) / cpaDt) or 0
	else
		_feat[F_CPARATE] = 0
	end

	local rx = cp.x - targetPos.x
	local ry = cp.y - targetPos.y
	local rz = cp.z - targetPos.z
	local rng = math.sqrt(rx * rx + ry * ry + rz * rz)
	_feat[F_RNGRATE] = (rng > 1.0) and ((rx * cv.x + ry * cv.y + rz * cv.z) / rng) or 0

	_feat[F_ALTRATE] = cv.y

	return _feat
end

local _FEAT_NAMES = { "SPD", "DIV", "HDG", "ACC", "CPA", "CPR", "RNG", "ALT" }

--- Returns one feature's capped ARM versus non-ARM Gaussian log-likelihood contribution.
local function featureLLR(index, value)
	local featCap = Medusa.Constants.HARM_SPRT_MAX_FEAT_LLR
	local dArm = value - _muArm[index]
	local dNon = value - _muNon[index]
	local raw = _lsigRatio[index] - dArm * dArm * _inv2vArm[index] + dNon * dNon * _inv2vNon[index]
	return math.max(-featCap, math.min(featCap, raw))
end

--- Returns the summed log-likelihood contribution of one extracted feature vector.
local function computeScanLLR(feat)
	local llr = 0
	for i = 1, NUM_FEAT do
		llr = llr + featureLLR(i, feat[i])
	end
	return llr
end

--- Returns the operator-facing feature values and likelihood contributions for one observation.
local function formatFeatureLLRs(feat)
	local parts = {}
	for i = 1, NUM_FEAT do
		local x = feat[i]
		parts[i] = string.format("%s=%.1f(%.2f)", _FEAT_NAMES[i], x, featureLLR(i, x))
	end
	return table.concat(parts, " ")
end

--- Selects one candidate radar battery and restarts evidence tied to it.
local function setCandidateBattery(state, battery)
	state.candidateBatteryId = battery.BatteryId
	state.candidatePosition = { x = battery.Position.x, y = battery.Position.y, z = battery.Position.z }
	state.prevCpa = nil
	state.llr = 0
	state.scanCount = 0
	state.label = HAS.EVALUATING
end

--- Starts one track assessment without inheriting an unsupported HARM confirmation.
local function createAssessment(track, candidate)
	local wasClassifiedHarm = track.AssessedAircraftType == AAT.HARM
	local state = {}
	setCandidateBattery(state, candidate)
	if wasClassifiedHarm then
		track.AssessedAircraftType = AAT.UNKNOWN
		track.IsSeadThreat = false
	end
	track.HarmAssessment = state
	_logger:info(string.format("track %s entered ARM evaluation", Medusa.Entities.Track.displayId(track)))
	return state
end

--- Adds one capped observation score to the bounded track evidence total.
--- @param state table Assessment state that owns the accumulated score
--- @param scanLlr number Current observation's raw log-likelihood score
local function accumulateEvidence(state, scanLlr)
	local contribution = math.max(-C.HARM_SPRT_MAX_SCAN_LLR, math.min(C.HARM_SPRT_MAX_SCAN_LLR, scanLlr))
	local limit = C.HARM_SPRT_ACCUMULATED_LLR_LIMIT
	state.llr = math.max(-limit, math.min(limit, state.llr + contribution))
end

--- Classifies accumulated evidence after the five-observation floor.
--- @param state table Assessment state with a bounded score and observation count
--- @return string label Current assessment label
local function updateLabel(state)
	if state.label == HAS.CONFIRMED then
		return state.label
	end
	if state.scanCount < C.HARM_SPRT_MIN_SCANS then
		state.label = HAS.EVALUATING
		return state.label
	end
	if state.llr >= C.HARM_SPRT_THRESH_CONFIRM then
		state.label = HAS.CONFIRMED
	elseif state.llr <= C.HARM_SPRT_THRESH_CLEAR then
		state.label = HAS.CLEARED
	elseif state.llr >= C.HARM_SPRT_THRESH_PROBABLE then
		state.label = HAS.PROBABLE
	elseif state.llr >= C.HARM_SPRT_THRESH_SUSPECT then
		state.label = HAS.SUSPECT
	else
		state.label = HAS.EVALUATING
	end
	return state.label
end

local function logStateChange(track, previousLabel, state, feat)
	if state.label == previousLabel then
		return
	end
	local detail = feat and (" [" .. formatFeatureLLRs(feat) .. "]") or ""
	_logger:info(
		string.format(
			"track %s ARM %s -> %s (LLR=%.2f, scans=%d)%s",
			Medusa.Entities.Track.displayId(track),
			previousLabel,
			state.label,
			state.llr,
			state.scanCount,
			detail
		)
	)
end

--- Runs one likelihood evaluation cycle for a single track.
--- This is the per-track workhorse called each tick. It manages the full
--- lifecycle: creating state, extracting evidence, accumulating a bounded score,
--- and requiring at least five observations before confirmation.
--- @param track table Track entity with PositionHistory, TrackId, FirstDetectionTime
--- @param geoGrid table GeoGrid spatial index
--- @param batteryStore table BatteryStore for radar-battery lookup
--- @param ballisticDt number|nil Ballistic sim step size
--- @param ballisticMaxT number|nil Ballistic sim max steps
--- @param threatRadiusM number|nil Projected-path relevance radius
--- @return string label Current HARM assessment label for this track
--- @return table|nil state The assessment state, or nil if track has insufficient data
local function evaluateTrack(track, geoGrid, batteryStore, ballisticDt, ballisticMaxT, threatRadiusM)
	threatRadiusM = threatRadiusM or C.HARM_DEFAULT_THREAT_RADIUS_M
	local state = track.HarmAssessment
	if state and state.label == HAS.CONFIRMED then
		return state.label, state
	end
	local n = track.PositionHistory:size()
	if n < 2 then
		return state and state.label or HAS.EVALUATING, state
	end

	local curr = track.PositionHistory:get(n)
	local prev = track.PositionHistory:get(n - 1)
	local dt = curr.timestamp - prev.timestamp
	if dt < C.HARM_SPRT_MIN_DT_SEC then
		return state and state.label or HAS.EVALUATING, state
	end

	if state and state.prevTime and curr.timestamp <= state.prevTime then
		return state.label, state
	end

	local candidate = state and state.candidateBatteryId and batteryStore:get(state.candidateBatteryId) or nil
	if state and state.candidateBatteryId and not isCurrentRadarTarget(candidate) then
		local replacement = findCandidateBattery(track, geoGrid, batteryStore, threatRadiusM)
		if replacement then
			setCandidateBattery(state, replacement)
			candidate = replacement
		end
	elseif not state then
		candidate = findCandidateBattery(track, geoGrid, batteryStore, threatRadiusM)
		if candidate then
			state = createAssessment(track, candidate)
		end
	end
	local targetPos = state and state.candidatePosition or nil
	if not state or not targetPos then
		return state and state.label or HAS.EVALUATING, state
	end
	if isCurrentRadarTarget(candidate) then
		targetPos.x = candidate.Position.x
		targetPos.y = candidate.Position.y
		targetPos.z = candidate.Position.z
	end

	state.scanCount = state.scanCount + 1
	local previousLabel = state.label

	local feat = extractFeatures(curr, prev, dt, targetPos, state, ballisticDt, ballisticMaxT)

	state.prevCpa = feat[F_CPA]
	state.prevTime = curr.timestamp
	if not state.lastFeat then
		state.lastFeat = { false, false, false, false, false, false, false, false }
	end
	local lf = state.lastFeat
	lf[1] = feat[1]
	lf[2] = feat[2]
	lf[3] = feat[3]
	lf[4] = feat[4]
	lf[5] = feat[5]
	lf[6] = feat[6]
	lf[7] = feat[7]
	lf[8] = feat[8]

	local scanLlr = computeScanLLR(feat)
	accumulateEvidence(state, scanLlr)
	if state.scanCount < C.HARM_SPRT_MIN_SCANS then
		return state.label, state
	end

	updateLabel(state)
	logStateChange(track, previousLabel, state, feat)

	return state.label, state
end

--- Returns HARM assessment parameters derived from doctrine.
--- @param ctx table Pipeline context with doctrine
--- @return number ballisticDt Ballistic sim time step
--- @return number ballisticMaxT Ballistic sim max steps
--- @return number threatRadiusM Projected-path relevance radius
function Medusa.Services.HarmDetectionService.getAssessContext(ctx)
	local doctrine = ctx.doctrine
	local ballisticDt = doctrine and doctrine.BallisticSimStepSec or 1.0
	local ballisticMaxT = doctrine and doctrine.BallisticSimMaxSec or 120
	local threatRadiusM = doctrine and doctrine.HARMShutdownM or C.HARM_DEFAULT_THREAT_RADIUS_M
	return ballisticDt, ballisticMaxT, threatRadiusM
end

--- Assesses a single track for HARM classification.
--- @param track table Track entity
--- @param tracks table Array of all tracks (for launcher backtracking)
--- @param geoGrid table GeoGrid spatial index
--- @param batteryStore table BatteryStore for radar-battery proximity lookups
--- @param ballisticDt number Ballistic sim time step
--- @param ballisticMaxT number Ballistic sim max steps
--- @param threatRadiusM number|nil Projected-path relevance radius
--- @return boolean reclassified True if this track was newly classified as HARM
function Medusa.Services.HarmDetectionService.assessSingleTrack(
	track,
	tracks,
	geoGrid,
	batteryStore,
	ballisticDt,
	ballisticMaxT,
	threatRadiusM
)
	local LS = Medusa.Constants.TrackLifecycleState
	local vel = track.Velocity
	if track.LifecycleState ~= LS.ACTIVE or not vel or track.IsHarmLauncher then
		return false
	end

	local label, state = evaluateTrack(track, geoGrid, batteryStore, ballisticDt, ballisticMaxT, threatRadiusM)

	if state then
		track.HarmLikelihoodScore = math.max(0, math.min(1, state.llr / C.HARM_SPRT_THRESH_CONFIRM))
	end

	if label == HAS.CONFIRMED and track.AssessedAircraftType ~= AAT.HARM then
		Medusa.Observability.MetricsService.inc("medusa_harm_confirmed_total")
		track.AssessedAircraftType = AAT.HARM
		track.IsSeadThreat = true
		_logger:info(
			string.format(
				"track %s classified as HARM (ARM CONFIRMED, LLR=%.2f)",
				Medusa.Entities.Track.displayId(track),
				state.llr
			)
		)
		Medusa.Services.HarmDetectionService._backtrackLauncher(track, tracks)
		return true
	elseif label == HAS.CLEARED then
		track.HarmLikelihoodScore = 0
	end
	return false
end

--- Top-level entry point called by IadsNetwork each tick.
--- Iterates all active tracks in the network. For each eligible track, runs
--- evaluateTrack to accumulate likelihood evidence and update the label.
--- When a track reaches CONFIRMED, this function promotes it: sets
--- AssessedAircraftType to HARM, flags IsSeadThreat, and increments the
--- Prometheus counter. HarmResponseService reads these flags on its next
--- tick to decide whether batteries should shut down or defend.
--- @param ctx table Pipeline context with trackStore, batteryStore, geoGrid, doctrine
--- @return number reclassified Count of tracks newly classified as HARM this tick
function Medusa.Services.HarmDetectionService.assessHarmThreats(ctx)
	local trackStore = ctx.trackStore
	local batteryStore = ctx.batteryStore
	local geoGrid = ctx.geoGrid
	local tracks = trackStore:getAll(_trackBuffer)
	local reclassified = 0

	local ballisticDt, ballisticMaxT, threatRadiusM = Medusa.Services.HarmDetectionService.getAssessContext(ctx)

	for i = 1, #tracks do
		if
			Medusa.Services.HarmDetectionService.assessSingleTrack(
				tracks[i],
				tracks,
				geoGrid,
				batteryStore,
				ballisticDt,
				ballisticMaxT,
				threatRadiusM
			)
		then
			reclassified = reclassified + 1
		end
	end

	if reclassified > 0 then
		_logger:info(string.format("assessed %d new HARM threats", reclassified))
	end
	return reclassified
end

--- Find the aircraft that launched a confirmed HARM by comparing ring buffer
--- positions at the same timestamp. At launch, the HARM and its launcher are
--- co-located. We check the HARM's oldest ring buffer entry against every
--- other track's position at that same time. The search radius is bounded by
--- the total distance the HARM has traveled since first detection.
function Medusa.Services.HarmDetectionService._backtrackLauncher(harmTrack, allTracks)
	local harmRing = harmTrack.PositionHistory
	local harmSize = harmRing:size()
	if harmSize < 2 then
		return
	end

	local oldest = harmRing:get(1)
	local newest = harmRing:get(harmSize)
	if not oldest or not oldest.position or not newest or not newest.position then
		return
	end

	local originX = oldest.position.x
	local originZ = oldest.position.z
	local originTime = oldest.timestamp

	local dx = newest.position.x - originX
	local dz = newest.position.z - originZ
	local searchRadiusSq = dx * dx + dz * dz

	local bestTrack = nil
	local bestDistSq = searchRadiusSq

	for i = 1, #allTracks do
		local candidate = allTracks[i]
		if
			candidate.TrackId ~= harmTrack.TrackId
			and candidate.AssessedAircraftType ~= AAT.HARM
			and candidate.PositionHistory
		then
			local cHistory = candidate.PositionHistory:toArray()
			for ci = 1, #cHistory do
				local entry = cHistory[ci]
				if entry and entry.position and math.abs(entry.timestamp - originTime) < 3 then
					local cdx = entry.position.x - originX
					local cdz = entry.position.z - originZ
					local distSq = cdx * cdx + cdz * cdz
					if distSq < bestDistSq then
						bestDistSq = distSq
						bestTrack = candidate
					end
					break
				end
			end
		end
	end

	if bestTrack then
		bestTrack.HostileActionConfirmed = true
		bestTrack.IsSeadThreat = true
		bestTrack.IsHarmLauncher = true
		bestTrack.HarmAssessment = nil
		bestTrack.HarmLikelihoodScore = 0
		if bestTrack.AssessedAircraftType == AAT.HARM then
			bestTrack.AssessedAircraftType = AAT.UNKNOWN
		end
		_logger:info(
			string.format(
				"track %s flagged hostile action (launched HARM %s, dist=%.0fm)",
				Medusa.Entities.Track.displayId(bestTrack),
				Medusa.Entities.Track.displayId(harmTrack),
				math.sqrt(bestDistSq)
			)
		)
	end
end

Medusa.Services.HarmDetectionService._evaluateTrack = evaluateTrack
Medusa.Services.HarmDetectionService._computeScanLLR = computeScanLLR
Medusa.Services.HarmDetectionService._extractFeatures = extractFeatures
