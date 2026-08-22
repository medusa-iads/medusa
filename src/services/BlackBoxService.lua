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
    - Publishes narrow explosive-impact records for crew-suppression evaluation.

    How others use it
    - IadsNetwork caches metadata on world events so MetricsSnapshotService can label metrics with unit names.
    - The entrypoint starts one mission-shared weapon tracker and distributes its impact records to each IADS.
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
	local outcomeLabels = {}
	for _, outcome in pairs(C.CrewSuppressionWeaponOutcome) do
		outcomeLabels[outcome] = { outcome = outcome }
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

	local function publishImpact(store, record, position, observedAt, source, sink)
		local impact = {
			ImpactId = store:nextImpactId(),
			Position = copyPosition(position),
			EffectiveExplosiveMassKg = record.EffectiveExplosiveMassKg,
			ObservedAt = observedAt,
			Source = source,
		}
		local ok, err = pcall(sink, impact)
		if not ok then
			logger:error(string.format("explosive impact publication failed: %s", tostring(err)))
			return false
		end
		local outcome = source == C.CrewSuppressionImpactSource.HIT and C.CrewSuppressionWeaponOutcome.IMPACT_HIT
			or C.CrewSuppressionWeaponOutcome.IMPACT_TERRAIN
		recordOutcome(outcome)
		logger:debug(
			string.format(
				"explosive impact published: id=%s source=%s mass=%.3fkg",
				tostring(impact.ImpactId),
				source,
				impact.EffectiveExplosiveMassKg
			)
		)
		return true
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
		local shotId = bus:sub(world.event.S_EVENT_SHOT, shotSink)
		local hitId = bus:sub(world.event.S_EVENT_HIT, hitSink)
		if not shotId or not hitId then
			if shotId and type(bus.unsub) == "function" then
				bus:unsub(shotId)
			end
			if hitId and type(bus.unsub) == "function" then
				bus:unsub(hitId)
			end
			return false
		end
		store:setSubscriptions(bus, shotId, hitId, shotSink, hitSink)
		logger:debug("weapon tracker subscriptions active")
		return true
	end

	function Service.stop(store)
		local bus, shotId, hitId = store:clearSubscriptions()
		if bus and type(bus.unsub) == "function" then
			if shotId then
				bus:unsub(shotId)
			end
			if hitId then
				bus:unsub(hitId)
			end
		end
		store:clear()
		logger:debug("weapon tracker subscriptions removed and state cleared")
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
			publishImpact(
				store,
				record,
				record.HitPosition,
				record.HitObservedAt or now,
				C.CrewSuppressionImpactSource.HIT,
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
				publishImpact(store, record, position, now, C.CrewSuppressionImpactSource.TERRAIN, sink)
			else
				recordOutcome(C.CrewSuppressionWeaponOutcome.NO_TERRAIN_INTERSECTION)
				logger:debug("weapon disappearance rejected: terminal point unavailable")
			end
			return false
		end
		recordOutcome(C.CrewSuppressionWeaponOutcome.UNTRACKABLE)
		return false
	end

	function Service.update(store, now, impactSink, budget)
		local maximum = budget or C.CrewSuppression.WEAPON_SAMPLES_PER_UPDATE
		if type(impactSink) ~= "function" or not validNumber(now) or type(maximum) ~= "number" or maximum < 1 then
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
			if sample(store, record, now, impactSink) then
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

	function Service.updateDue(store, now, impactSink)
		if not store:beginUpdate(now, C.CrewSuppression.WEAPON_UPDATE_INTERVAL_SEC) then
			return 0
		end
		return Service.update(store, now, impactSink, C.CrewSuppression.WEAPON_SAMPLES_PER_UPDATE)
	end
end
