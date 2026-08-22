require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")
require("services.MetricsService")
require("services.stores.BlackBoxWeaponStore")

--[[
            ██████╗ ██╗      █████╗  ██████╗██╗  ██╗    ██████╗  ██████╗ ██╗  ██╗
            ██╔══██╗██║     ██╔══██╗██╔════╝██║ ██╔╝    ██╔══██╗██╔═══██╗╚██╗██╔╝
            ██████╔╝██║     ███████║██║     █████╔╝     ██████╔╝██║   ██║ ╚███╔╝
            ██╔══██╗██║     ██╔══██║██║     ██╔═██╗     ██╔══██╗██║   ██║ ██╔██╗
            ██████╔╝███████╗██║  ██║╚██████╗██║  ██╗    ██████╔╝╚██████╔╝██╔╝ ██╗
            ╚═════╝ ╚══════╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝    ╚═════╝  ╚═════╝ ╚═╝  ╚═╝

    What this service does
    - Caches DCS object metadata (type name, unit name, coalition) from live objects for later use.
    - Owns validated weapon observation while keeping exact DCS weapon data outside IADS domain logic.
    - Publishes narrow explosive and cannon terminal-event records for crew-suppression evaluation.

    How others use it
    - IadsNetwork caches metadata on world events so MetricsSnapshotService can label metrics with unit names.
    - The entrypoint starts one mission-shared observer and distributes terminal events to each IADS.
--]]

Medusa.Services.BlackBoxService = {}
Medusa.Services.BlackBoxService._cache = {}
function Medusa.Services.BlackBoxService.cacheFromObject(networkId, obj)
	if not networkId or Medusa.Services.BlackBoxService._cache[networkId] then
		return
	end
	local entry = {}
	local ok, val = pcall(obj.getTypeName, obj)
	if ok then
		entry.TypeName = val
	end
	ok, val = pcall(obj.getName, obj)
	if ok then
		entry.UnitName = val
	end
	ok, val = pcall(obj.getCoalition, obj)
	if ok then
		entry.CoalitionId = val
	end
	Medusa.Services.BlackBoxService._cache[networkId] = entry
end

function Medusa.Services.BlackBoxService.get(networkId)
	return Medusa.Services.BlackBoxService._cache[networkId]
end

function Medusa.Services.BlackBoxService.clear()
	Medusa.Services.BlackBoxService._cache = {}
end

do
	local Service = Medusa.Services.BlackBoxService
	local C = Medusa.Constants
	local MetricsService = Medusa.Services.MetricsService
	local logger = Medusa.Logger:ns("BlackBoxService")
	local sqrt = math.sqrt
	local min = math.min
	local CANNON_SOURCE = C.CrewSuppressionTerminalSource.FORWARD_VECTOR
	local outcomeLabels = {}
	for _, outcome in pairs(C.CrewSuppressionWeaponOutcome) do
		outcomeLabels[outcome] = { outcome = outcome }
	end
	local cannonOutcomeLabels = {}
	for _, outcome in pairs(C.CrewSuppressionCannonOutcome) do
		cannonOutcomeLabels[outcome] = { outcome = outcome }
	end

	local function validNumber(value)
		return type(value) == "number" and value == value and value > -math.huge and value < math.huge
	end

	local function validPositive(value)
		return validNumber(value) and value > 0
	end

	local function validPosition(value)
		return type(value) == "table" and validNumber(value.x) and validNumber(value.y) and validNumber(value.z)
	end

	local function copyPosition(value)
		return { x = value.x, y = value.y, z = value.z }
	end

	local function recordOutcome(outcome)
		MetricsService.inc("medusa_crew_suppression_weapon_outcomes_total", nil, outcomeLabels[outcome])
	end

	local function recordCannonOutcome(outcome)
		MetricsService.inc("medusa_crew_suppression_cannon_outcomes_total", nil, cannonOutcomeLabels[outcome])
	end

	local function effectiveExplosiveMass(descriptor)
		local warhead = type(descriptor) == "table" and descriptor.warhead or nil
		if type(warhead) ~= "table" then
			return nil
		end
		if validPositive(warhead.explosiveMass) then
			return warhead.explosiveMass
		end
		if validPositive(warhead.shapedExplosiveMass) then
			return warhead.shapedExplosiveMass
		end
		return nil
	end

	local function classify(record)
		local descriptor = GetWeaponDesc(record.Weapon)
		local category = descriptor and descriptor.category
		if category ~= Weapon.Category.BOMB and category ~= Weapon.Category.MISSILE then
			return false
		end
		local mass = effectiveExplosiveMass(descriptor)
		if not mass then
			return false
		end
		record.EffectiveExplosiveMassKg = mass
		record.Classified = true
		return true
	end

	local function publishExplosiveTerminal(store, record, position, observedAt, source, sink)
		local terminalEvent = {
			TerminalEventId = store:nextTerminalEventId(),
			Kind = C.CrewSuppressionTerminalKind.EXPLOSIVE,
			Position = copyPosition(position),
			EffectiveExplosiveMassKg = record.EffectiveExplosiveMassKg,
			ObservedAt = observedAt,
			Source = source,
		}
		local ok, err = pcall(sink, terminalEvent)
		if not ok then
			logger:error(string.format("explosive terminal-event publication failed: %s", tostring(err)))
			return
		end
		local outcome = source == C.CrewSuppressionTerminalSource.HIT and C.CrewSuppressionWeaponOutcome.IMPACT_HIT
			or C.CrewSuppressionWeaponOutcome.IMPACT_TERRAIN
		recordOutcome(outcome)
		logger:debug(
			string.format(
				"explosive terminal event published: id=%s source=%s mass=%.3fkg",
				tostring(terminalEvent.TerminalEventId),
				source,
				terminalEvent.EffectiveExplosiveMassKg
			)
		)
	end

	local function publishCannonTerminal(store, position, observedAt, sink)
		local terminalEvent = {
			TerminalEventId = store:nextTerminalEventId(),
			Kind = C.CrewSuppressionTerminalKind.CANNON,
			Position = copyPosition(position),
			ObservedAt = observedAt,
			Source = CANNON_SOURCE,
		}
		local ok, err = pcall(sink, terminalEvent)
		if not ok then
			logger:error(string.format("cannon terminal-event publication failed: %s", tostring(err)))
			return
		end
		recordCannonOutcome(C.CrewSuppressionCannonOutcome.ESTIMATED_FORWARD)
		logger:debug(
			string.format(
				"cannon terminal event published: id=%s source=%s",
				tostring(terminalEvent.TerminalEventId),
				terminalEvent.Source
			)
		)
	end

	function Service.onShot(store, event, observedAt)
		if type(event) ~= "table" or event.weapon == nil or not validNumber(observedAt) then
			recordOutcome(C.CrewSuppressionWeaponOutcome.UNTRACKABLE)
			logger:debug("weapon tracking rejected: invalid SHOT event")
			return false
		end
		if store:get(event.weapon) then
			logger:debug(string.format("weapon already tracked: tracked=%d", store:size()))
			return false
		end
		if store:isFull() then
			recordOutcome(C.CrewSuppressionWeaponOutcome.TRACKER_FULL)
			logger:debug(string.format("weapon not tracked: tracker full at %d", store:size()))
			return false
		end
		if not store:admit(event.weapon, observedAt) then
			recordOutcome(C.CrewSuppressionWeaponOutcome.UNTRACKABLE)
			logger:debug("weapon not tracked: admission failed")
			return false
		end
		recordOutcome(C.CrewSuppressionWeaponOutcome.TRACKED)
		logger:debug(string.format("weapon admitted: tracked=%d", store:size()))
		return true
	end

	function Service.onHit(store, event, observedAt)
		if type(event) ~= "table" or event.weapon == nil or event.target == nil or not validNumber(observedAt) then
			return false
		end
		local record = store:get(event.weapon)
		if not record or record.ClassificationRejected or record.HitPosition then
			return false
		end
		if not record.Classified and not classify(record) then
			record.ClassificationRejected = true
			return false
		end
		local position = GetUnitPosition(event.target)
		if not validPosition(position) then
			logger:debug("tracked weapon HIT ignored: target position unavailable")
			return false
		end
		return store:markHit(event.weapon, position, observedAt)
	end

	function Service.onShootingStart(store, event, observedAt)
		if type(event) ~= "table" or event.initiator == nil or not validNumber(observedAt) then
			recordCannonOutcome(C.CrewSuppressionCannonOutcome.UNTRACKABLE)
			logger:debug("cannon estimate rejected: invalid SHOOTING_START event")
			return false
		end
		if not store:admitCannon(event.initiator, observedAt) then
			recordCannonOutcome(C.CrewSuppressionCannonOutcome.QUEUE_FULL)
			logger:debug(string.format("cannon estimate rejected: queue full at %d", store:cannonSize()))
			return false
		end
		recordCannonOutcome(C.CrewSuppressionCannonOutcome.QUEUED)
		logger:debug(string.format("cannon estimate queued: depth=%d", store:cannonSize()))
		return true
	end

	local function unsubscribe(bus, subscriptionId)
		if bus and subscriptionId and type(bus.unsub) == "function" then
			bus:unsub(subscriptionId)
		end
	end

	function Service.start(store, bus)
		if store:isStarted() then
			return true
		end
		if type(bus) ~= "table" or type(bus.sub) ~= "function" then
			return false
		end
		local shotSink = {}
		function shotSink:enqueue(event)
			return Service.onShot(store, event, GetTime())
		end
		local hitSink = {}
		function hitSink:enqueue(event)
			return Service.onHit(store, event, GetTime())
		end
		local shootingStartSink = {}
		function shootingStartSink:enqueue(event)
			return Service.onShootingStart(store, event, GetTime())
		end
		local shotId = bus:sub(world.event.S_EVENT_SHOT, shotSink)
		local hitId = bus:sub(world.event.S_EVENT_HIT, hitSink)
		local shootingStartId = bus:sub(world.event.S_EVENT_SHOOTING_START, shootingStartSink)
		if not shotId or not hitId or not shootingStartId then
			unsubscribe(bus, shotId)
			unsubscribe(bus, hitId)
			unsubscribe(bus, shootingStartId)
			return false
		end
		store:setSubscriptions(bus, shotId, hitId, shootingStartId)
		logger:debug(
			string.format(
				"weapon observation subscriptions active: SHOT=%s HIT=%s SHOOTING_START=%s",
				tostring(shotId),
				tostring(hitId),
				tostring(shootingStartId)
			)
		)
		return true
	end

	function Service.stop(store)
		local bus, shotId, hitId, shootingStartId = store:clearSubscriptions()
		unsubscribe(bus, shotId)
		unsubscribe(bus, hitId)
		unsubscribe(bus, shootingStartId)
		store:clear()
		logger:debug("weapon observation subscriptions removed and state cleared")
		return true
	end

	local function terminalPosition(record, now)
		if not validPosition(record.LastPosition) or not validPosition(record.LastVelocity) then
			return nil
		end
		local elapsed = now - record.LastSampleAt
		if not validPositive(elapsed) then
			return nil
		end
		local velocity = record.LastVelocity
		local speed = sqrt(velocity.x * velocity.x + velocity.y * velocity.y + velocity.z * velocity.z)
		if not validPositive(speed) then
			return nil
		end
		local direction = NormalizeVector3D(velocity)
		if not validPosition(direction) then
			return nil
		end
		local maxDistance = speed * elapsed
		if not validPositive(maxDistance) then
			return nil
		end
		local position = GetTerrainIntersection(record.LastPosition, direction, maxDistance)
		if not validPosition(position) then
			return nil
		end
		return position
	end

	local function sample(store, record, now, sink)
		if now - record.ObservedAt > C.CrewSuppression.WEAPON_MAX_AGE_SEC then
			recordOutcome(C.CrewSuppressionWeaponOutcome.EXPIRED)
			return false
		end
		if record.ClassificationRejected then
			recordOutcome(C.CrewSuppressionWeaponOutcome.UNTRACKABLE)
			return false
		end
		if not record.Classified then
			local accepted = classify(record)
			if not accepted then
				recordOutcome(C.CrewSuppressionWeaponOutcome.UNTRACKABLE)
				return false
			end
		end
		if record.HitPosition then
			publishExplosiveTerminal(
				store,
				record,
				record.HitPosition,
				record.HitObservedAt or now,
				C.CrewSuppressionTerminalSource.HIT,
				sink
			)
			return false
		end
		local exists = IsWeaponExist(record.Weapon)
		if exists == true then
			local point = GetWeaponPoint(record.Weapon)
			local velocity = GetWeaponVelocity(record.Weapon)
			if validPosition(point) and validPosition(velocity) then
				record.LastPosition = copyPosition(point)
				record.LastVelocity = copyPosition(velocity)
				record.LastSampleAt = now
			end
			return true
		end
		if exists == false then
			local position = terminalPosition(record, now)
			if position then
				publishExplosiveTerminal(store, record, position, now, C.CrewSuppressionTerminalSource.TERRAIN, sink)
			else
				recordOutcome(C.CrewSuppressionWeaponOutcome.NO_TERRAIN_INTERSECTION)
				logger:debug("weapon disappearance rejected: terminal point unavailable")
			end
			return false
		end
		recordOutcome(C.CrewSuppressionWeaponOutcome.UNTRACKABLE)
		return false
	end

	function Service.update(store, now, terminalSink, budget)
		local maximum = budget or C.CrewSuppression.WEAPON_SAMPLES_PER_UPDATE
		if type(terminalSink) ~= "function" or not validNumber(now) or type(maximum) ~= "number" or maximum < 1 then
			return 0
		end
		maximum = math.floor(maximum)
		local processed = 0
		local available = min(store:size(), maximum)
		for _ = 1, available do
			local record = store:pop()
			if not record then
				break
			end
			processed = processed + 1
			if sample(store, record, now, terminalSink) then
				store:requeue(record)
			else
				store:discard(record)
			end
		end
		MetricsService.set("medusa_crew_suppression_weapons_tracked", store:size())
		if processed > 0 then
			logger:debug(string.format("weapon tracker update: sampled=%d tracked=%d", processed, store:size()))
		end
		return processed
	end

	local function vectorMagnitude(value)
		return sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
	end

	local function cannonInitialState(record)
		local category = GetUnitCategoryEx(record.Initiator)
		if category == nil then
			return nil, nil, "initiator category unavailable"
		end
		if category ~= Unit.Category.AIRPLANE and category ~= Unit.Category.HELICOPTER then
			return nil, nil, string.format("initiator category is not aircraft: category=%s", tostring(category))
		end
		local initiatorPosition = GetUnitPosition3(record.Initiator)
		if not initiatorPosition or not validPosition(initiatorPosition.p) then
			return nil, nil, "initiator Position3 unavailable"
		end
		if not validPosition(initiatorPosition.x) then
			return nil, nil, "initiator forward vector unavailable"
		end
		local direction = NormalizeVector3D(initiatorPosition.x)
		if not validPosition(direction) then
			return nil, nil, "normalized forward vector unavailable"
		end
		local aircraftVelocity = GetUnitVelocity(record.Initiator)
		if not validPosition(aircraftVelocity) then
			return nil, nil, "initiator velocity unavailable"
		end
		local muzzleVelocity = C.CrewSuppression.CANNON_EFFECTIVE_MUZZLE_VELOCITY_MPS
		return initiatorPosition.p,
			{
				x = direction.x * muzzleVelocity + aircraftVelocity.x,
				y = direction.y * muzzleVelocity + aircraftVelocity.y,
				z = direction.z * muzzleVelocity + aircraftVelocity.z,
			}
	end

	local function ballisticPoint(origin, velocity, timeSec)
		return {
			x = origin.x + velocity.x * timeSec,
			y = origin.y + velocity.y * timeSec - 0.5 * C.CrewSuppression.CANNON_GRAVITY_MPS2 * timeSec * timeSec,
			z = origin.z + velocity.z * timeSec,
		}
	end

	local function ballisticTerrainIntersection(origin, velocity)
		local speed = vectorMagnitude(velocity)
		if not validPositive(speed) then
			return nil, 0
		end
		local maxDistance = C.CrewSuppression.CANNON_MAX_PROJECTION_M
		local segments = C.CrewSuppression.CANNON_TRAJECTORY_SEGMENTS
		local stepSec = maxDistance / speed / segments
		local segmentOrigin = origin
		local remainingDistance = maxDistance
		for i = 1, segments do
			local segmentEnd = ballisticPoint(origin, velocity, stepSec * i)
			local delta = {
				x = segmentEnd.x - segmentOrigin.x,
				y = segmentEnd.y - segmentOrigin.y,
				z = segmentEnd.z - segmentOrigin.z,
			}
			local segmentDistance = vectorMagnitude(delta)
			local direction = NormalizeVector3D(delta)
			if not validPositive(segmentDistance) or not validPosition(direction) then
				return nil, i - 1
			end
			local distance = min(segmentDistance, remainingDistance)
			local position = GetTerrainIntersection(segmentOrigin, direction, distance)
			if validPosition(position) then
				return position, i
			end
			remainingDistance = remainingDistance - distance
			if remainingDistance <= 0 then
				return nil, i
			end
			segmentOrigin = segmentEnd
		end
		return nil, segments
	end

	local function estimateCannon(store, record, now, sink)
		if now - record.ObservedAt > C.CrewSuppression.CANNON_CANDIDATE_MAX_AGE_SEC then
			recordCannonOutcome(C.CrewSuppressionCannonOutcome.EXPIRED)
			logger:debug(
				string.format(
					"cannon estimate rejected: candidate expired age=%.3fs maxAge=%.3fs",
					now - record.ObservedAt,
					C.CrewSuppression.CANNON_CANDIDATE_MAX_AGE_SEC
				)
			)
			return
		end
		local origin, velocity, rejectionReason = cannonInitialState(record)
		if not origin then
			recordCannonOutcome(C.CrewSuppressionCannonOutcome.UNTRACKABLE)
			logger:debug("cannon estimate rejected: " .. rejectionReason)
			return
		end
		local position, segments = ballisticTerrainIntersection(origin, velocity)
		if not validPosition(position) then
			recordCannonOutcome(C.CrewSuppressionCannonOutcome.NO_TERRAIN_INTERSECTION)
			logger:debug(
				string.format(
					"cannon ballistic projection rejected: source=%s origin=(%.1f,%.1f,%.1f) velocity=(%.3f,%.3f,%.3f) maxDistance=%.0fm segments=%d",
					CANNON_SOURCE,
					origin.x,
					origin.y,
					origin.z,
					velocity.x,
					velocity.y,
					velocity.z,
					C.CrewSuppression.CANNON_MAX_PROJECTION_M,
					segments
				)
			)
			return
		end
		logger:debug(
			string.format(
				"cannon ballistic projection accepted: source=%s position=(%.1f,%.1f,%.1f) segments=%d",
				CANNON_SOURCE,
				position.x,
				position.y,
				position.z,
				segments
			)
		)
		publishCannonTerminal(store, position, record.ObservedAt, sink)
	end

	function Service.updateCannons(store, now, terminalSink, budget)
		local maximum = budget or C.CrewSuppression.CANNON_ESTIMATES_PER_UPDATE
		if type(terminalSink) ~= "function" or not validNumber(now) or type(maximum) ~= "number" or maximum < 1 then
			return 0
		end
		maximum = math.floor(maximum)
		local processed = 0
		local available = min(store:cannonSize(), maximum)
		for _ = 1, available do
			local record = store:popCannon()
			if not record then
				break
			end
			processed = processed + 1
			estimateCannon(store, record, now, terminalSink)
		end
		MetricsService.set("medusa_crew_suppression_cannon_queue_depth", store:cannonSize())
		if processed > 0 then
			logger:debug(
				string.format("cannon estimator update: processed=%d queued=%d", processed, store:cannonSize())
			)
		end
		return processed
	end

	function Service.updateDue(store, now, terminalSink)
		if not store:beginUpdate(now, C.CrewSuppression.WEAPON_UPDATE_INTERVAL_SEC) then
			return 0
		end
		local weaponCount = Service.update(store, now, terminalSink, C.CrewSuppression.WEAPON_SAMPLES_PER_UPDATE)
		local cannonCount =
			Service.updateCannons(store, now, terminalSink, C.CrewSuppression.CANNON_ESTIMATES_PER_UPDATE)
		return weaponCount + cannonCount
	end
end
