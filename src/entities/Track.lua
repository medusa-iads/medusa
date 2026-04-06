require("_header")
require("entities.Entities")
require("core.Constants")
require("core.Logger")

--[[
            ████████╗██████╗  █████╗  ██████╗██╗  ██╗
            ╚══██╔══╝██╔══██╗██╔══██╗██╔════╝██║ ██╔╝
               ██║   ██████╔╝███████║██║     █████╔╝
               ██║   ██╔══██╗██╔══██║██║     ██╔═██╗
               ██║   ██║  ██║██║  ██║╚██████╗██║  ██╗
               ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝

    What this entity does
    - Holds a radar contact's position, velocity, identification level, and a ring buffer of position history.
    - Computes smoothed velocity over a time window and derives maneuver state from heading changes.

    How others use it
    - TrackManager creates and updates Track instances from sensor polling reports.
    - TrackClassifier promotes identification; HarmDetectionService reads kinematic history for HARM scoring.
--]]

Medusa.Entities.Track = {}
Medusa.Entities.Track._logger = Medusa.Logger:ns("Track")

Medusa.Entities.Track._REQUIRED_FIELDS = { "Position", "Velocity", "NetworkId" }

-- 3 minutes of history at max update rate (1s interval = 180 entries)
Medusa.Entities.Track.MAX_POSITION_HISTORY = 180

function Medusa.Entities.Track.new(data)
	if not data then
		error("data table is required")
	end

	for _, field in ipairs(Medusa.Entities.Track._REQUIRED_FIELDS) do
		if data[field] == nil then
			error(string.format("missing required field: %s", field))
		end
	end

	local now = GetTime()

	local o = {
		TrackId = data.TrackId or NewULID(),
		NetworkId = data.NetworkId,
		Position = data.Position,
		Velocity = data.Velocity,
		TrackIdentification = data.TrackIdentification or "UNKNOWN",
		AssessedAircraftType = data.AssessedAircraftType or "UNKNOWN",
		UpdateCount = data.UpdateCount or 0,
		LifecycleState = data.LifecycleState or Medusa.Constants.TrackLifecycleState.ACTIVE,
		FirstDetectionTime = data.FirstDetectionTime or now,
		LastDetectionTime = data.LastDetectionTime or now,
		AssignedBatteryIds = data.AssignedBatteryIds or Set(),
		DetectingSensorIds = data.DetectingSensorIds or Set(),
		PositionHistory = RingBuffer(Medusa.Entities.Track.MAX_POSITION_HISTORY),

		SmoothedVelocity = data.SmoothedVelocity,
		ManeuverState = data.ManeuverState,
		HarmLikelihoodScore = data.HarmLikelihoodScore,
		IdentityConfidence = data.IdentityConfidence,
		LastIdentificationTime = data.LastIdentificationTime,
		IffAmbiguityState = data.IffAmbiguityState,
		AltitudeAGL = data.AltitudeAGL,
		AltitudeMSL = data.AltitudeMSL,
		CoalitionId = data.CoalitionId,
		ConfidenceLevel = data.ConfidenceLevel,
		RaidId = data.RaidId,
		IsSeadThreat = data.IsSeadThreat,
		AssignmentTime = data.AssignmentTime,

		-- ROE identification ladder fields (ADR-0018)
		InsideBorder = false,
		InsideADIZ = false,
		BorderCrossingTime = nil,
		IffConfirmTime = nil,
		IntelIdentifyTime = nil,
		VIDIdentifyTime = nil,
		RWRIlluminationStart = nil,
		HostileActionConfirmed = false,
		HostileIntentStart = nil,
		BorderHostileDwellSec = nil,
	}

	Medusa.Entities.Track._logger:debug(
		string.format("created track %s for network %s", o.TrackId, tostring(o.NetworkId))
	)
	return o
end

function Medusa.Entities.Track.update(track, position, velocity, timestamp)
	track.Position = position
	track.Velocity = velocity
	track.LastDetectionTime = timestamp
	track.UpdateCount = track.UpdateCount + 1

	track.PositionHistory:push({
		timestamp = timestamp,
		position = { x = position.x, y = position.y, z = position.z },
		velocity = { x = velocity.x, y = velocity.y, z = velocity.z },
	})

	if track.LifecycleState == Medusa.Constants.TrackLifecycleState.STALE then
		track.LifecycleState = Medusa.Constants.TrackLifecycleState.ACTIVE
	end
end

function Medusa.Entities.Track.computeSmoothedVelocity(track, windowSec)
	local ring = track.PositionHistory
	local sz = ring:size()
	if sz < 2 then
		local v = track.Velocity
		if not v then
			track.SmoothedVelocity = nil
			return
		end
		track.SmoothedVelocity = { x = v.x, y = v.y, z = v.z }
		return
	end

	-- Walk ring buffer in-place from tail (newest) to head (oldest)
	local items = ring._items
	local cap = ring._capacity
	local tail = ring._tail
	local newest = items[tail]
	local cutoff = newest.timestamp - windowSec
	local sumVx, sumVy, sumVz, count = 0, 0, 0, 0
	local pos = tail
	for _ = 1, sz do
		local entry = items[pos]
		if entry.timestamp < cutoff then
			break
		end
		local v = entry.velocity
		sumVx = sumVx + v.x
		sumVy = sumVy + v.y
		sumVz = sumVz + v.z
		count = count + 1
		pos = pos - 1
		if pos < 1 then
			pos = cap
		end
	end

	if count == 0 then
		track.SmoothedVelocity = {
			x = track.Velocity.x,
			y = track.Velocity.y,
			z = track.Velocity.z,
		}
		return
	end

	if track.SmoothedVelocity then
		track.SmoothedVelocity.x = sumVx / count
		track.SmoothedVelocity.y = sumVy / count
		track.SmoothedVelocity.z = sumVz / count
	else
		track.SmoothedVelocity = {
			x = sumVx / count,
			y = sumVy / count,
			z = sumVz / count,
		}
	end
end

local C = Medusa.Constants
local TURN_THRESHOLD = C.TRACK_TURN_THRESHOLD_RAD
local ORBIT_THRESHOLD = C.TRACK_ORBIT_THRESHOLD_RAD

function Medusa.Entities.Track.deriveManeuverState(track)
	local ManeuverState = Medusa.Constants.ManeuverState

	if not track.SmoothedVelocity then
		track.ManeuverState = ManeuverState.UNKNOWN
		return
	end

	local vel = track.Velocity
	if not vel then
		track.ManeuverState = ManeuverState.UNKNOWN
		return
	end
	local speed = VecLength(vel)
	if speed < 1.0 then
		track.ManeuverState = ManeuverState.UNKNOWN
		return
	end

	local sv = track.SmoothedVelocity
	local smoothedSpeed = VecLength(sv)
	if smoothedSpeed < 1.0 then
		track.ManeuverState = ManeuverState.UNKNOWN
		return
	end

	local heading = math.atan2(vel.z, vel.x)
	local smoothedHeading = math.atan2(sv.z, sv.x)
	local headingDelta = heading - smoothedHeading

	-- Normalize to [-pi, pi]
	if headingDelta > math.pi then
		headingDelta = headingDelta - 2 * math.pi
	elseif headingDelta < -math.pi then
		headingDelta = headingDelta + 2 * math.pi
	end

	if math.abs(headingDelta) > ORBIT_THRESHOLD then
		track.ManeuverState = ManeuverState.ORBITING
		return
	end
	if headingDelta > TURN_THRESHOLD then
		track.ManeuverState = ManeuverState.TURNING_RIGHT
		return
	end
	if headingDelta < -TURN_THRESHOLD then
		track.ManeuverState = ManeuverState.TURNING_LEFT
		return
	end

	local speedRatio = math.abs(speed - smoothedSpeed) / smoothedSpeed
	if speedRatio > C.MANEUVER_SPEED_RATIO_THRESHOLD then
		track.ManeuverState = ManeuverState.MANEUVERING
		return
	end

	track.ManeuverState = ManeuverState.STRAIGHT
end
