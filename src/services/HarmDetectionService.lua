require("_header")
require("services.Services")
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
    - Uses a sequential probability ratio test (SPRT) to classify tracks as HARM, suspect, or clear.
    - Computes closest-point-of-approach to nearby battery radars for threat assessment.

    How others use it
    - IadsNetwork calls evaluate each tick to update HARM likelihood scores on active tracks.
    - HarmResponseService reads those scores to decide shutdown or defense actions.

    References
    - https://en.wikipedia.org/wiki/Sequential_probability_ratio_test
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

--- Feature vector indices for SPRT kinematic classifier.
--- Each maps to a slot in the _feat array extracted per scan.
local F_SPEED = 1 -- ground speed (m/s)
local F_DIVE = 2 -- dive angle (rad, positive = diving)
local F_HDGRATE = 3 -- heading rate of change (rad/s)
local F_ACCEL = 4 -- longitudinal acceleration (m/s²)
local F_CPA = 5 -- closest point of approach to nearest emitter (m)
local F_CPARATE = 6 -- rate of CPA change (m/s, negative = closing)
local F_RNGRATE = 7 -- range rate to emitter (m/s, negative = closing)
local F_ALTRATE = 8 -- vertical velocity (m/s)
local NUM_FEAT = 8

-- Pre-compute SPRT arrays from model (once at load).
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
--- The SPRT classifier uses CPA to distinguish ARMs from transiting aircraft.
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

--- Find the position of the nearest WARM or HOT battery to a track.
--- SPRT features (CPA, range rate, CPA rate) are measured relative to the closest
--- active emitter because an ARM homes on the strongest signal, which correlates
--- with proximity. Cold batteries are excluded because they are not radiating and
--- cannot be targeted by an ARM.
--- @param track table Track entity with .Position
--- @param geoGrid table GeoGrid spatial index for battery lookups
--- @param batteryStore table BatteryStore for filtering by activation state
--- @return table|nil emitterPos Position {x,y,z} of the closest active emitter, or nil if none in range
local function findClosestEmitter(track, geoGrid, batteryStore)
	local AS = Medusa.Constants.ActivationState
	local batteries = Medusa.Services.SpatialQuery.batteriesInRadius(
		geoGrid,
		batteryStore,
		track.Position,
		Medusa.Constants.HARM_MAX_RANGE_M
	)
	local best, bestDist = nil, math.huge
	for i = 1, #batteries do
		local b = batteries[i]
		if
			(b.ActivationState == AS.STATE_WARM or b.ActivationState == AS.STATE_HOT)
			and not Medusa.Entities.Battery.isIndependentAaa(b)
			and b.Position
		then
			local dist = Distance2D(track.Position, b.Position)
			if dist < bestDist then
				best = b.Position
				bestDist = dist
			end
		end
	end
	return best
end

--- Extract the 8-element kinematic feature vector from two consecutive position
--- history entries. These features capture the flight signature of an ARM:
--- high speed, steep dive, minimal heading change (ARMs fly straight once locked),
--- slight deceleration (coasting after motor burnout), small and shrinking CPA to
--- the nearest emitter, negative range rate (closing), and negative altitude rate
--- (descending). Non-ARM aircraft differ on most features because they maneuver,
--- climb, and do not converge on a specific ground point.
--- Writes into the module-level _feat buffer to avoid per-call allocation.
--- @param curr table Current position history entry {position, velocity, timestamp}
--- @param prev table Previous position history entry
--- @param dt number Time delta between curr and prev (seconds)
--- @param emitterPos table {x,y,z} position of the nearest active emitter
--- @param sprtState table Per-track SPRT state (carries prevCpa/prevTime for rate computation)
--- @param ballisticDt number|nil Ballistic sim time step (default 1.0s)
--- @param ballisticMaxT number|nil Ballistic sim max steps (default 120)
--- @return number[] feat 8-element feature vector (reused buffer, do not hold across calls)
local function extractFeatures(curr, prev, dt, emitterPos, sprtState, ballisticDt, ballisticMaxT)
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
		-- Wrap heading difference to [-pi, pi]; Lua lacks a true modulo for negatives
		dHdg = dHdg - 2 * math.pi * math.floor((dHdg + math.pi) / (2 * math.pi))
		_feat[F_HDGRATE] = math.abs(dHdg) / dt
	else
		_feat[F_HDGRATE] = 0
	end

	local prevSpeed = math.sqrt(pvxSq + pvySq + pvzSq)
	_feat[F_ACCEL] = (speed - prevSpeed) / dt

	local linearCpa = computeCPA3D(cp.x, cp.y, cp.z, cv.x, cv.y, cv.z, emitterPos.x, emitterPos.y, emitterPos.z)
	local ballisticCpa = computeBallisticCPA(
		cp.x,
		cp.y,
		cp.z,
		cv.x,
		cv.y,
		cv.z,
		emitterPos.x,
		emitterPos.y,
		emitterPos.z,
		ballisticDt,
		ballisticMaxT
	)
	_feat[F_CPA] = math.min(linearCpa, ballisticCpa)

	if sprtState.prevCpa and sprtState.prevTime then
		local cpaDt = curr.timestamp - sprtState.prevTime
		local cpaDist = _feat[F_CPA]
		_feat[F_CPARATE] = (cpaDt > 0.001) and ((cpaDist - sprtState.prevCpa) / cpaDt) or 0
	else
		_feat[F_CPARATE] = 0
	end

	local rx = cp.x - emitterPos.x
	local ry = cp.y - emitterPos.y
	local rz = cp.z - emitterPos.z
	local rng = math.sqrt(rx * rx + ry * ry + rz * rz)
	_feat[F_RNGRATE] = (rng > 1.0) and ((rx * cv.x + ry * cv.y + rz * cv.z) / rng) or 0

	_feat[F_ALTRATE] = cv.y

	return _feat
end

local _FEAT_NAMES = { "SPD", "DIV", "HDG", "ACC", "CPA", "CPR", "RNG", "ALT" }

--- Compute the per-scan log-likelihood ratio (LLR) across all 8 features.
--- For each feature, this computes how much more likely the observed value is
--- under the "ARM" distribution vs the "non-ARM" distribution, using the Gaussian
--- parameters from HARM_SPRT_MODEL. We work in log space because SPRT accumulates
--- evidence by summing across scans. Multiplying raw probabilities would quickly
--- underflow to zero, but adding logs is stable.
--- Per-feature contributions are clamped to ±HARM_SPRT_MAX_FEAT_LLR so one bad
--- reading (e.g. a position glitch spiking CPA) cannot dominate the total.
--- Positive LLR = looks like an ARM. Negative = looks like something else.
--- See: https://en.wikipedia.org/wiki/Likelihood-ratio_test
--- @param feat number[] 8-element feature vector from extractFeatures
--- @return number scanLlr Total clamped log-likelihood ratio for this scan
local function computeScanLLR(feat)
	local llr = 0
	local featCap = Medusa.Constants.HARM_SPRT_MAX_FEAT_LLR
	for i = 1, NUM_FEAT do
		local x = feat[i]
		local dArm = x - _muArm[i]
		local dNon = x - _muNon[i]
		-- SPRT log-likelihood ratio: positive = more ARM-like, negative = more non-ARM
		local contribution = _lsigRatio[i] - dArm * dArm * _inv2vArm[i] + dNon * dNon * _inv2vNon[i]
		llr = llr + math.max(-featCap, math.min(featCap, contribution))
	end
	return llr
end

local function formatFeatureLLRs(feat)
	local parts = {}
	local featCap = Medusa.Constants.HARM_SPRT_MAX_FEAT_LLR
	for i = 1, NUM_FEAT do
		local x = feat[i]
		local dArm = x - _muArm[i]
		local dNon = x - _muNon[i]
		local raw = _lsigRatio[i] - dArm * dArm * _inv2vArm[i] + dNon * dNon * _inv2vNon[i]
		local clamped = math.max(-featCap, math.min(featCap, raw))
		parts[i] = string.format("%s=%.1f(%.2f)", _FEAT_NAMES[i], x, clamped)
	end
	return table.concat(parts, " ")
end

local function updateLabel(state)
	if state.label == HAS.CONFIRMED then
		if state.llr <= C.HARM_SPRT_THRESH_CLEAR then
			state.label = HAS.CLEARED
		end
		return state.label
	end
	if state.label == HAS.CLEARED then
		if state.llr >= C.HARM_SPRT_THRESH_CONFIRM then
			state.label = HAS.CONFIRMED
		end
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

local function createAssessment(track, emitterPos)
	local confirmed = track.AssessedAircraftType == AAT.HARM
	local state = {
		llr = confirmed and C.HARM_SPRT_THRESH_CONFIRM or 0,
		scanCount = 0,
		label = confirmed and HAS.CONFIRMED or HAS.EVALUATING,
		prevCpa = nil,
		prevTime = nil,
		emitterPosition = { x = emitterPos.x, y = emitterPos.y, z = emitterPos.z },
	}
	if confirmed then
		state.previousAircraftType = AAT.UNKNOWN
		state.previousIsSeadThreat = false
	end
	track.HarmAssessment = state
	_logger:info(string.format("track %s entered ARM evaluation", Medusa.Entities.Track.displayId(track)))
	return state
end

local function updateEmitterPosition(state, emitterPos)
	local saved = state.emitterPosition
	if not saved then
		saved = {}
		state.emitterPosition = saved
	end
	saved.x = emitterPos.x
	saved.y = emitterPos.y
	saved.z = emitterPos.z
end

local function accumulateEvidence(state, scanLlr)
	state.llr = state.llr + math.max(-C.HARM_SPRT_MAX_SCAN_LLR, math.min(C.HARM_SPRT_MAX_SCAN_LLR, scanLlr))
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

--- Run one SPRT evaluation cycle for a single track.
--- This is the per-track workhorse called each tick. It manages the full
--- lifecycle: creating SPRT state on first sight, gating on minimum scans and
--- speed, extracting features, accumulating the LLR, and updating the label.
--- Decision evidence persists after confirmation or clearance. A decision changes
--- only after cumulative evidence crosses the opposite threshold.
--- @param track table Track entity with PositionHistory, TrackId, FirstDetectionTime
--- @param geoGrid table GeoGrid spatial index
--- @param batteryStore table BatteryStore for emitter lookup
--- @param ballisticDt number|nil Ballistic sim step size
--- @param ballisticMaxT number|nil Ballistic sim max steps
--- @param effectiveMinScans number|nil Minimum scans before an SPRT decision (defaults to HARM_SPRT_MIN_SCANS)
--- @return string label Current SPRT label for this track
--- @return table|nil state The SPRT state table, or nil if track has insufficient data
local function evaluateTrack(track, geoGrid, batteryStore, ballisticDt, ballisticMaxT, effectiveMinScans)
	local n = track.PositionHistory:size()
	if n < 2 then
		local state = track.HarmAssessment
		return state and state.label or HAS.EVALUATING, state
	end

	local curr = track.PositionHistory:get(n)
	local prev = track.PositionHistory:get(n - 1)
	local dt = curr.timestamp - prev.timestamp
	if dt < C.HARM_SPRT_MIN_DT_SEC then
		local state = track.HarmAssessment
		return state and state.label or HAS.EVALUATING, state
	end

	local state = track.HarmAssessment
	if state and state.prevTime and curr.timestamp <= state.prevTime then
		return state.label, state
	end
	local cv = curr.velocity
	local speedSq = cv.x * cv.x + cv.y * cv.y + cv.z * cv.z
	if speedSq < C.HARM_SPRT_SPEED_GATE * C.HARM_SPRT_SPEED_GATE then
		if not state then
			return HAS.CLEARED, nil
		end
		state.prevTime = curr.timestamp
		state.scanCount = state.scanCount + 1
		local previousLabel = state.label
		if state.label == HAS.EVALUATING or state.label == HAS.SUSPECT or state.label == HAS.PROBABLE then
			state.llr = math.min(state.llr - C.HARM_SPRT_MAX_SCAN_LLR, C.HARM_SPRT_THRESH_CLEAR)
		else
			accumulateEvidence(state, -C.HARM_SPRT_MAX_SCAN_LLR)
		end
		updateLabel(state)
		logStateChange(track, previousLabel, state)
		return state.label, state
	end

	local emitterPos = findClosestEmitter(track, geoGrid, batteryStore)
	if emitterPos then
		if not state then
			state = createAssessment(track, emitterPos)
		else
			updateEmitterPosition(state, emitterPos)
		end
	elseif state then
		emitterPos = state.emitterPosition
	end
	if not state or not emitterPos then
		return state and state.label or HAS.EVALUATING, state
	end

	state.scanCount = state.scanCount + 1
	local previousLabel = state.label

	local feat = extractFeatures(curr, prev, dt, emitterPos, state, ballisticDt, ballisticMaxT)

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

	local minScans = effectiveMinScans or C.HARM_SPRT_MIN_SCANS
	local scanLlr = computeScanLLR(feat)
	accumulateEvidence(state, scanLlr)
	if state.scanCount < minScans then
		return state.label, state
	end

	updateLabel(state)
	logStateChange(track, previousLabel, state, feat)

	return state.label, state
end

--- Returns the ballistic simulation parameters needed by assessSingleTrack.
--- @param ctx table Pipeline context with doctrine
--- @return number ballisticDt Ballistic sim time step
--- @return number ballisticMaxT Ballistic sim max steps
function Medusa.Services.HarmDetectionService.getAssessContext(ctx)
	local doctrine = ctx.doctrine
	local ballisticDt = doctrine and doctrine.BallisticSimStepSec or 1.0
	local ballisticMaxT = doctrine and doctrine.BallisticSimMaxSec or 120
	return ballisticDt, ballisticMaxT
end

--- Assesses a single track for HARM classification via SPRT.
--- @param track table Track entity
--- @param tracks table Array of all tracks (for launcher backtracking)
--- @param geoGrid table GeoGrid spatial index
--- @param batteryStore table BatteryStore for emitter proximity lookups
--- @param ballisticDt number Ballistic sim time step
--- @param ballisticMaxT number Ballistic sim max steps
--- @return boolean reclassified True if this track was newly classified as HARM
function Medusa.Services.HarmDetectionService.assessSingleTrack(
	track,
	tracks,
	geoGrid,
	batteryStore,
	ballisticDt,
	ballisticMaxT
)
	local LS = Medusa.Constants.TrackLifecycleState
	local vel = track.Velocity
	local speedSq = vel and (vel.x * vel.x + vel.y * vel.y + vel.z * vel.z) or 0
	local trackAge = track.FirstDetectionTime and (GetTime() - track.FirstDetectionTime) or 0
	if
		track.LifecycleState ~= LS.ACTIVE
		or not vel
		or (not track.HarmAssessment and speedSq < C.HARM_SPRT_SPEED_GATE * C.HARM_SPRT_SPEED_GATE)
		or (not track.HarmAssessment and trackAge < C.HARM_SPRT_MIN_TRACK_AGE_SEC)
	then
		return false
	end

	local previousLabel = track.HarmAssessment and track.HarmAssessment.label
	local label, state = evaluateTrack(track, geoGrid, batteryStore, ballisticDt, ballisticMaxT)

	if state then
		track.HarmLikelihoodScore = math.max(0, math.min(1, state.llr / math.max(0.001, C.HARM_SPRT_THRESH_CONFIRM)))
	end

	if label == HAS.CONFIRMED and previousLabel ~= HAS.CONFIRMED then
		if not state.previousAircraftType then
			state.previousAircraftType = track.AssessedAircraftType
			state.previousIsSeadThreat = track.IsSeadThreat == true
		end
		Medusa.Services.MetricsService.inc("medusa_harm_confirmed_total")
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
		if previousLabel == HAS.CONFIRMED then
			local restoredType = state.previousAircraftType or AAT.UNKNOWN
			local restoredSeadThreat = state.previousIsSeadThreat == true
			track.AssessedAircraftType = restoredType
			track.IsSeadThreat = restoredSeadThreat
			state.previousAircraftType = nil
			state.previousIsSeadThreat = nil
			_logger:info(
				string.format(
					"track %s HARM classification cleared (LLR=%.2f)",
					Medusa.Entities.Track.displayId(track),
					state.llr
				)
			)
		end
	end
	return false
end

--- Top-level entry point called by IadsNetwork each tick.
--- Iterates all active tracks in the network. For each eligible track, runs
--- evaluateTrack to accumulate SPRT evidence and update the label.
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

	local ballisticDt, ballisticMaxT = Medusa.Services.HarmDetectionService.getAssessContext(ctx)

	for i = 1, #tracks do
		if
			Medusa.Services.HarmDetectionService.assessSingleTrack(
				tracks[i],
				tracks,
				geoGrid,
				batteryStore,
				ballisticDt,
				ballisticMaxT
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
