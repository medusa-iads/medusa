require("_header")
require("services.Services")
require("core.Constants")

--[[
            ██████╗ ██╗  ██╗    ███╗   ███╗ ██████╗ ██████╗ ███████╗██╗
            ██╔══██╗██║ ██╔╝    ████╗ ████║██╔═══██╗██╔══██╗██╔════╝██║
            ██████╔╝█████╔╝     ██╔████╔██║██║   ██║██║  ██║█████╗  ██║
            ██╔═══╝ ██╔═██╗     ██║╚██╔╝██║██║   ██║██║  ██║██╔══╝  ██║
            ██║     ██║  ██╗    ██║ ╚═╝ ██║╚██████╔╝██████╔╝███████╗███████╗
            ╚═╝     ╚═╝  ╚═╝    ╚═╝     ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝╚══════╝

    What this service does
    - Estimates single-shot kill probability for a battery-track pair.
    - Combines range (split Gaussian), aspect angle, and altitude taper factors into a composite Pk value.

    How others use it
    - TargetAssigner calls computePk to rank candidate batteries for each track.
    - PointDefenseService uses Pk estimates to decide whether a SHORAD battery should engage a HARM.

    References
    - Gaussian damage function: https://apps.dtic.mil/sti/citations/ADA039660
    - Radar horizon formula: https://en.wikipedia.org/wiki/Radar_horizon
    - Aspect angle / proportional navigation: https://en.wikipedia.org/wiki/Proportional_navigation
    - Greedy WTA optimality guarantee: https://link.springer.com/article/10.1007/BF01588971
--]]

Medusa.Services.PkModel = {}

--- Split Gaussian range factor: peaks at optimal range.
--- The Gaussian shape comes from the Carleton damage function, which is the
--- standard DoD model for weapon effectiveness vs distance.
--- Real SAM envelopes are asymmetric: Pk drops steeply near Rmin (fuze arming,
--- minimum guidance time) but tapers gradually near Rmax (energy depletion).
--- The inner side uses a wider sigma so Pk is still ~0.75 at min range,
--- while the outer side decays normally toward max range.
--- See: https://apps.dtic.mil/sti/citations/ADA039660
--- @param dist number Slant range to target in meters
--- @param rOptimal number Optimal engagement range in meters (peak Pk)
--- @param sigma number Gaussian decay width in meters (outer side)
--- @param rMin number|nil Minimum engagement range in meters
--- @return number pkRange Range factor from 0.0 to 1.0
function Medusa.Services.PkModel.computePkRange(dist, rOptimal, sigma, rMin)
	if not rOptimal or not sigma or sigma == 0 then
		return 0
	end
	local effSigma = sigma
	if dist < rOptimal and rMin and rOptimal > rMin then
		effSigma = math.max(1, (rOptimal - rMin) / Medusa.Constants.PK_INNER_SIGMA_FACTOR)
	end
	local delta = (dist - rOptimal) / effSigma
	return math.exp(-0.5 * delta * delta)
end

--- Aspect angle factor: models how engagement geometry affects Pk.
--- Missiles using proportional navigation must generate lateral acceleration
--- proportional to the line-of-sight (LOS) rotation rate. A beam/crossing
--- target (flying perpendicular to the missile) maximizes LOS rate and is the
--- hardest geometry. Head-on and tail-chase both produce low LOS rates.
--- The result is a U-shaped curve: head-on=1.0, tail=1.0, beam=floor (0.30).
--- See: https://en.wikipedia.org/wiki/Proportional_navigation
--- @param track table Track entity with .Position and .SmoothedVelocity or .Velocity
--- @param batteryPos table Battery position {x, y, z}
--- @return number pkAspect Aspect factor from PK_ASPECT_BEAM_FLOOR to 1.0
function Medusa.Services.PkModel.computePkAspect(track, batteryPos)
	local vel = track.SmoothedVelocity or track.Velocity
	if not vel then
		return 1.0
	end
	local speed = VecLength2D(vel)
	if speed < 0.1 then
		return 1.0
	end
	local dir = { x = track.Position.x - batteryPos.x, z = track.Position.z - batteryPos.z }
	local velXZ = { x = vel.x, z = vel.z }
	local normDir = NormalizeVector2D(dir)
	local normVel = NormalizeVector2D(velXZ)
	-- cosAngle: +1 = head-on, 0 = beam/crossing, -1 = tail-chase
	local cosAngle = -DotProduct2D(normDir, normVel)
	-- U-shape: head-on and tail both good, beam worst (highest LOS rate)
	local absCos = math.abs(cosAngle)
	local floor = Medusa.Constants.PK_ASPECT_BEAM_FLOOR
	return floor + (1 - floor) * absCos
end

--- Altitude factor: 1.0 within the engagement envelope, linear taper near
--- the edges, 0 outside. The taper (PK_ALTITUDE_TAPER_M) avoids a hard
--- cliff at the altitude boundary. Targets just outside the envelope still
--- get a small Pk, which lets the WTA prefer batteries whose envelopes
--- actually cover the target altitude.
--- @param track table Track entity with .Position.y (altitude in meters)
--- @param battery table Battery entity with .EngagementAltitudeMin and .EngagementAltitudeMax
--- @return number pkAlt Altitude factor from 0.0 to 1.0
function Medusa.Services.PkModel.computePkAltitude(track, battery)
	local alt = track.Position.y
	local altMin = battery.EngagementAltitudeMin or 0
	local altMax = battery.EngagementAltitudeMax or 99999
	local taper = Medusa.Constants.PK_ALTITUDE_TAPER_M
	if alt >= altMin and alt <= altMax then
		return 1.0
	end
	if alt < altMin then
		if alt >= altMin - taper then
			return (alt - (altMin - taper)) / taper
		end
		return 0
	end
	if alt <= altMax + taper then
		return ((altMax + taper) - alt) / taper
	end
	return 0
end

--- Computes altitude-adjusted effective engagement range using radar horizon.
--- The radar horizon limits how far a ground-based radar can see a target at
--- a given altitude. The formula is d = 4.12 * (sqrt(h_ant) + sqrt(h_tgt))
--- in km, where 4.12 accounts for atmospheric refraction (4/3 Earth radius
--- model). Short-range systems are rarely constrained. Long-range systems
--- (SA-10, SA-5) lose much of their range against low-altitude targets.
--- See: https://en.wikipedia.org/wiki/Radar_horizon
--- @param battery table Battery entity with .EngagementRangeMax
--- @param targetAltY number Target altitude in meters (DCS Y axis)
--- @return number effRange Effective engagement range in meters (capped by radar horizon)
function Medusa.Services.PkModel.effectiveEngagementRange(battery, targetAltY)
	local rangeMax = battery.EngagementRangeMax
	if not rangeMax or rangeMax <= 0 then
		return 0
	end
	local h_tgt = math.max(0, targetAltY)
	-- 9213 = 4120*sqrt(5): 5m antenna height; 4120 = 4.12 km horizon factor * 1000
	local radarHorizonM = 9213 + 4120 * math.sqrt(h_tgt)
	return math.min(rangeMax, radarHorizonM)
end

--- Composite kill probability combining range, aspect angle, and altitude factors.
--- The chain (PK_MAX * pkRange * pkAspect * pkAlt) is standard
--- practice in campaign-level wargaming models (RAND, NPS). Each factor
--- independently degrades the base Pk. This is Medusa's estimate for deciding
--- which battery to activate, not a prediction of DCS AI hit probability (which could be wildly different in reality)
--- @param battery table Battery entity
--- @param track table Track entity
--- @param dist number 2D distance between battery and track in meters
--- @return number pk Composite kill probability from 0.0 to PK_MAX_DEFAULT
function Medusa.Services.PkModel.computePk(battery, track, dist)
	if not track.Position or not battery.Position then
		return 0
	end
	if battery.EngagementRangeMin and dist < battery.EngagementRangeMin then
		return 0
	end
	local targetAlt = track.Position.y or 0
	local effRange = Medusa.Services.PkModel.effectiveEngagementRange(battery, targetAlt)
	if effRange <= 0 or not battery.EngagementRangeMax or battery.EngagementRangeMax <= 0 then
		return 0
	end
	local scaleFactor = effRange / battery.EngagementRangeMax
	local effOptimal = (battery.PkRangeOptimal or 0) * scaleFactor
	local effSigma = (battery.PkRangeSigma or 0) * scaleFactor
	local pkRange = Medusa.Services.PkModel.computePkRange(dist, effOptimal, effSigma, battery.EngagementRangeMin)
	if pkRange < 0.01 then
		return 0
	end
	local pkAspect = Medusa.Services.PkModel.computePkAspect(track, battery.Position)
	local pkAlt = Medusa.Services.PkModel.computePkAltitude(track, battery)
	if pkAlt < 0.01 then
		return 0
	end
	local pk = Medusa.Constants.PK_MAX_DEFAULT * pkRange * pkAspect * pkAlt
	if pk ~= pk then
		return 0
	end
	return pk
end
