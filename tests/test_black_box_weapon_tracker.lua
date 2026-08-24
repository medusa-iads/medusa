local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("services.Services")
require("observability.MetricsService")
require("services.stores.BlackBoxWeaponStore")
require("services.BlackBoxService")

TestBlackBoxWeaponTracker = {}

local function weapon(name)
	return { Name = name }
end

local function descriptor(category, explosiveMass, shapedExplosiveMass)
	return {
		category = category,
		warhead = {
			explosiveMass = explosiveMass,
			shapedExplosiveMass = shapedExplosiveMass,
		},
	}
end

function TestBlackBoxWeaponTracker:setUp()
	self.originals = {
		GetWeaponDesc = GetWeaponDesc,
		IsWeaponExist = IsWeaponExist,
		GetWeaponPoint = GetWeaponPoint,
		GetWeaponVelocity = GetWeaponVelocity,
		GetTerrainIntersection = GetTerrainIntersection,
		NormalizeVector3D = NormalizeVector3D,
		GetUnitPosition = GetUnitPosition,
		GetUnitPosition3 = GetUnitPosition3,
		GetUnitCategoryEx = GetUnitCategoryEx,
		GetUnitVelocity = GetUnitVelocity,
		GetTime = GetTime,
	}
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	self.originalEnvInfo = env.info
	self.originalLogLevel = Medusa.Logger:getLevel()
	self.logMessages = {}
	env.info = function(message)
		self.logMessages[#self.logMessages + 1] = message
	end
	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.DEBUG)
	Medusa.Observability.MetricsService._registry = {}
	Medusa.Observability.MetricsService.gauge("medusa_crew_suppression_weapons_tracked", "")
	Medusa.Observability.MetricsService.counter("medusa_crew_suppression_weapon_outcomes_total", "", { "outcome" })
	Medusa.Observability.MetricsService.gauge("medusa_crew_suppression_cannon_queue_depth", "")
	Medusa.Observability.MetricsService.counter("medusa_crew_suppression_cannon_outcomes_total", "", { "outcome" })
	Medusa.Services.BlackBoxService.clear()
	self.store = Medusa.Services.BlackBoxWeaponStore:new(128)
	self.impacts = {}
	GetTime = function()
		return 100
	end
	GetWeaponDesc = function()
		return descriptor(Weapon.Category.BOMB, 8, nil)
	end
	IsWeaponExist = function()
		return true
	end
	GetWeaponPoint = function()
		return { x = 1, y = 2, z = 3 }
	end
	GetWeaponVelocity = function()
		return { x = 10, y = -2, z = 0 }
	end
	GetUnitPosition = function(target)
		return target.Position
	end
	GetUnitCategoryEx = function(unit)
		return unit.Category
	end
	GetUnitPosition3 = function(unit)
		return unit.Position3
	end
	GetUnitVelocity = function(unit)
		return unit.Velocity
	end
	NormalizeVector3D = function(value)
		local length = math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
		return { x = value.x / length, y = value.y / length, z = value.z / length }
	end
	GetTerrainIntersection = function()
		return nil
	end
end

local function position3(point, forward)
	return {
		p = point,
		x = forward or { x = 1, y = 0, z = 0 },
		y = { x = 0, y = 1, z = 0 },
		z = { x = 0, y = 0, z = 1 },
	}
end

function TestBlackBoxWeaponTracker:tearDown()
	Medusa.Services.BlackBoxService.clear()
	env.info = self.originalEnvInfo
	Medusa.Logger:setLevel(self.originalLogLevel)
	for name, value in pairs(self.originals) do
		_G[name] = value
	end
end

function TestBlackBoxWeaponTracker:test_metadata_cache_replaces_reused_identifiers()
	local function object(typeName, unitName, coalitionId)
		return {
			getTypeName = function()
				return typeName
			end,
			getName = function()
				return unitName
			end,
			getCoalition = function()
				return coalitionId
			end,
		}
	end

	Medusa.Services.BlackBoxService.cacheFromObject(7, object("old-type", "old-unit", 1))
	Medusa.Services.BlackBoxService.cacheFromObject(7, object("new-type", "new-unit", 2))

	lu.assertEquals(Medusa.Services.BlackBoxService.get(7), {
		TypeName = "new-type",
		UnitName = "new-unit",
		CoalitionId = 2,
	})
end

function TestBlackBoxWeaponTracker:test_metadata_cache_evicts_oldest_distinct_identifier_at_capacity()
	local capacity = Medusa.Constants.BlackBox.METADATA_CACHE_CAPACITY
	local object = {
		getTypeName = function()
			return "type"
		end,
		getName = function()
			return "unit"
		end,
		getCoalition = function()
			return 1
		end,
	}
	for id = 1, capacity + 1 do
		Medusa.Services.BlackBoxService.cacheFromObject(id, object)
	end

	lu.assertNil(Medusa.Services.BlackBoxService.get(1))
	lu.assertNotNil(Medusa.Services.BlackBoxService.get(2))
	lu.assertNotNil(Medusa.Services.BlackBoxService.get(capacity + 1))
end

function TestBlackBoxWeaponTracker:update(now, budget)
	return Medusa.Services.BlackBoxService.update(self.store, now, function(impact)
		self.impacts[#self.impacts + 1] = impact
	end, budget)
end

function TestBlackBoxWeaponTracker:updateCannons(now, budget)
	return Medusa.Services.BlackBoxService.updateCannons(self.store, now, function(terminalEvent)
		self.impacts[#self.impacts + 1] = terminalEvent
	end, budget)
end

function TestBlackBoxWeaponTracker:test_update_details_require_trace_and_debug_reports_thirty_second_summary()
	local tracked = weapon("tracked")
	lu.assertTrue(Medusa.Services.BlackBoxService.onShot(self.store, { weapon = tracked }, 1))

	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.DEBUG)
	lu.assertEquals(Medusa.Services.BlackBoxService.updateDue(self.store, 2, function() end), 1)
	lu.assertEquals(Medusa.Services.BlackBoxService.updateDue(self.store, 32, function() end), 1)
	local summaryMessage = nil
	for i = 1, #self.logMessages do
		lu.assertNil(string.find(self.logMessages[i], "weapon tracker update", 1, true))
		if string.find(self.logMessages[i], "shared recurring work (30s)", 1, true) then
			summaryMessage = self.logMessages[i]
		end
	end
	lu.assertNotNil(summaryMessage)
	lu.assertNotNil(string.match(summaryMessage, "weapon_tracker%s+2%s+1%s+1"))
	lu.assertNotNil(string.match(summaryMessage, "cannon_estimator%s+0%s+0%s+0"))

	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.TRACE)
	lu.assertEquals(self:update(33, 1), 1)
	local foundDetail = false
	for i = 1, #self.logMessages do
		if string.find(self.logMessages[i], "weapon tracker update: sampled=1 tracked=1", 1, true) then
			foundDetail = true
		end
	end
	lu.assertTrue(foundDetail)
end

function TestBlackBoxWeaponTracker:test_rejects_newest_weapon_when_tracker_is_full()
	local store = Medusa.Services.BlackBoxWeaponStore:new(2)
	local first = weapon("first")
	local second = weapon("second")
	local newest = weapon("newest")

	lu.assertTrue(Medusa.Services.BlackBoxService.onShot(store, { weapon = first }, 1))
	lu.assertTrue(Medusa.Services.BlackBoxService.onShot(store, { weapon = second }, 2))
	lu.assertFalse(Medusa.Services.BlackBoxService.onShot(store, { weapon = newest }, 3))
	lu.assertEquals(store:size(), 2)
	lu.assertNotNil(store:get(first))
	lu.assertNotNil(store:get(second))
	lu.assertNil(store:get(newest))
end

function TestBlackBoxWeaponTracker:test_update_samples_only_the_budget_and_rotates_fairly()
	local sampled = {}
	GetWeaponDesc = function(w)
		sampled[#sampled + 1] = w.Name
		return descriptor(Weapon.Category.MISSILE, 1, nil)
	end
	for i = 1, 7 do
		Medusa.Services.BlackBoxService.onShot(self.store, { weapon = weapon(tostring(i)) }, 1)
	end

	local firstCount = self:update(2, 5)
	local secondCount = self:update(3, 5)

	lu.assertEquals(firstCount, 5)
	lu.assertEquals(secondCount, 5)
	lu.assertEquals(sampled, { "1", "2", "3", "4", "5", "6", "7" })
end

function TestBlackBoxWeaponTracker:test_only_bombs_and_missiles_with_positive_explosive_mass_publish_hits()
	local shell = weapon("shell")
	local rocket = weapon("rocket")
	local bomb = weapon("bomb")
	local missile = weapon("missile")
	local totalOnly = weapon("total-only")
	local descriptions = {
		[shell] = descriptor(Weapon.Category.SHELL, 4, nil),
		[rocket] = descriptor(Weapon.Category.ROCKET, 4, nil),
		[bomb] = descriptor(Weapon.Category.BOMB, 8, 12),
		[missile] = descriptor(Weapon.Category.MISSILE, 0, 3),
		[totalOnly] = { category = Weapon.Category.BOMB, warhead = { mass = 100 } },
	}
	GetWeaponDesc = function(w)
		return descriptions[w]
	end
	local target = { Position = { x = 20, y = 5, z = 40 } }
	for _, w in ipairs({ shell, rocket, bomb, missile, totalOnly }) do
		Medusa.Services.BlackBoxService.onShot(self.store, { weapon = w }, 1)
		Medusa.Services.BlackBoxService.onHit(self.store, { weapon = w, target = target }, 2)
	end

	self:update(3, 5)

	lu.assertEquals(#self.impacts, 2)
	lu.assertEquals(self.impacts[1].EffectiveExplosiveMassKg, 8)
	lu.assertEquals(self.impacts[2].EffectiveExplosiveMassKg, 3)
	lu.assertEquals(self.impacts[1].Position, target.Position)
	lu.assertEquals(self.impacts[1].Kind, Medusa.Constants.CrewSuppressionTerminalKind.EXPLOSIVE)
	lu.assertEquals(self.impacts[1].TerminalEventId, 1)
	lu.assertEquals(self.impacts[1].Source, Medusa.Constants.CrewSuppressionTerminalSource.HIT)
	lu.assertNil(self.impacts[1].Weapon)
	lu.assertEquals(self.store:size(), 0)
end

function TestBlackBoxWeaponTracker:test_hit_caches_classification_before_the_weapon_handle_becomes_invalid()
	local tracked = weapon("fast-impact")
	local descriptorAvailable = true
	GetWeaponDesc = function()
		if descriptorAvailable then
			return descriptor(Weapon.Category.BOMB, 8, nil)
		end
		return nil
	end
	local target = { Position = { x = 20, y = 5, z = 40 } }
	Medusa.Services.BlackBoxService.onShot(self.store, { weapon = tracked }, 1)

	lu.assertTrue(Medusa.Services.BlackBoxService.onHit(self.store, { weapon = tracked, target = target }, 2))
	descriptorAvailable = false
	self:update(3, 5)

	lu.assertEquals(#self.impacts, 1)
	lu.assertEquals(self.impacts[1].Position, target.Position)
	lu.assertEquals(self.impacts[1].EffectiveExplosiveMassKg, 8)
end

function TestBlackBoxWeaponTracker:test_disappearance_uses_last_sample_velocity_and_elapsed_time_for_terrain_intersection()
	local tracked = weapon("bomb")
	local exists = true
	local intersectionArgs
	IsWeaponExist = function()
		return exists
	end
	GetWeaponPoint = function()
		return { x = 10, y = 100, z = 20 }
	end
	GetWeaponVelocity = function()
		return { x = 30, y = -40, z = 0 }
	end
	GetTerrainIntersection = function(origin, direction, maxDistance)
		intersectionArgs = { origin, direction, maxDistance }
		return { x = 40, y = 0, z = 20 }
	end
	Medusa.Services.BlackBoxService.onShot(self.store, { weapon = tracked }, 1)
	self:update(10, 5)
	exists = false

	self:update(12, 5)

	lu.assertEquals(#self.impacts, 1)
	lu.assertEquals(self.impacts[1].Source, Medusa.Constants.CrewSuppressionTerminalSource.TERRAIN)
	lu.assertEquals(intersectionArgs[1], { x = 10, y = 100, z = 20 })
	lu.assertAlmostEquals(intersectionArgs[2].x, 0.6, 0.0001)
	lu.assertAlmostEquals(intersectionArgs[2].y, -0.8, 0.0001)
	lu.assertAlmostEquals(intersectionArgs[3], 100, 0.0001)
	lu.assertEquals(self.store:size(), 0)
end

function TestBlackBoxWeaponTracker:test_disappearance_without_intersection_is_rejected()
	local tracked = weapon("bomb")
	local exists = true
	IsWeaponExist = function()
		return exists
	end
	Medusa.Services.BlackBoxService.onShot(self.store, { weapon = tracked }, 1)
	self:update(10, 5)
	exists = false

	self:update(11, 5)

	lu.assertEquals(#self.impacts, 0)
	lu.assertEquals(self.store:size(), 0)
end

function TestBlackBoxWeaponTracker:test_track_lifetime_removes_a_still_live_weapon()
	Medusa.Services.BlackBoxService.onShot(self.store, { weapon = weapon("old") }, 1)

	self:update(1 + Medusa.Constants.CrewSuppression.WEAPON_MAX_AGE_SEC + 1, 5)

	lu.assertEquals(self.store:size(), 0)
	lu.assertEquals(#self.impacts, 0)
end

function TestBlackBoxWeaponTracker:test_unavailable_boundary_data_produces_no_invalid_impact()
	lu.assertFalse(Medusa.Services.BlackBoxService.onShot(self.store, {}, 1))
	lu.assertFalse(Medusa.Services.BlackBoxService.onHit(self.store, { weapon = weapon("x") }, 1))
	GetWeaponDesc = function()
		return nil
	end
	Medusa.Services.BlackBoxService.onShot(self.store, { weapon = weapon("no-descriptor") }, 1)
	self:update(2, 5)
	lu.assertEquals(self.store:size(), 0)

	local unavailable = weapon("unavailable-sample")
	GetWeaponDesc = function()
		return descriptor(Weapon.Category.BOMB, 1, nil)
	end
	GetWeaponPoint = function()
		return nil
	end
	GetWeaponVelocity = function()
		return nil
	end
	Medusa.Services.BlackBoxService.onShot(self.store, { weapon = unavailable }, 1)
	self:update(2, 5)
	lu.assertEquals(self.store:size(), 1)
	IsWeaponExist = function()
		return nil
	end
	self:update(3, 5)

	lu.assertEquals(self.store:size(), 0)
	lu.assertEquals(#self.impacts, 0)
end

function TestBlackBoxWeaponTracker:test_sample_failure_discards_the_indexed_record_and_allows_readmission()
	local tracked = weapon("throwing-sample")
	Medusa.Services.BlackBoxService.onShot(self.store, { weapon = tracked }, 1)
	IsWeaponExist = function()
		error("injected weapon boundary failure")
	end

	lu.assertEquals(self:update(2, 1), 1)

	lu.assertEquals(self.store:size(), 0)
	lu.assertIsNil(self.store:get(tracked))
	lu.assertTrue(self.store:admit(tracked, 3))
	lu.assertEquals(self.store:size(), 1)
end

function TestBlackBoxWeaponTracker:test_start_stop_and_restart_own_exactly_one_subscription_pair()
	local bus = { subscriptions = {}, removed = {} }
	function bus:sub(eventId, sink)
		self.subscriptions[#self.subscriptions + 1] = { eventId, sink }
		return #self.subscriptions
	end
	function bus:unsub(id)
		self.removed[#self.removed + 1] = id
		return true
	end

	lu.assertTrue(Medusa.Services.BlackBoxService.start(self.store, bus))
	lu.assertTrue(Medusa.Services.BlackBoxService.start(self.store, bus))
	lu.assertEquals(#bus.subscriptions, 3)
	lu.assertEquals(bus.subscriptions[3][1], world.event.S_EVENT_SHOOTING_START)
	lu.assertNotEquals(bus.subscriptions[3][1], world.event.S_EVENT_SHOOTING_END)
	lu.assertStrContains(
		table.concat(self.logMessages, "\n"),
		"weapon observation subscriptions active: SHOT=1 HIT=2 SHOOTING_START=3"
	)
	lu.assertTrue(Medusa.Services.BlackBoxService.stop(self.store))
	lu.assertEquals(bus.removed, { 1, 2, 3 })
	lu.assertEquals(self.store:size(), 0)

	lu.assertTrue(Medusa.Services.BlackBoxService.start(self.store, bus))
	lu.assertEquals(#bus.subscriptions, 6)
	lu.assertTrue(Medusa.Services.BlackBoxService.stop(self.store))
	lu.assertEquals(bus.removed, { 1, 2, 3, 4, 5, 6 })
end

function TestBlackBoxWeaponTracker:test_start_contains_and_rolls_back_each_partial_subscription_failure()
	for failAt = 1, 3 do
		local store = Medusa.Services.BlackBoxWeaponStore:new(8)
		local bus = { _nextSubId = 1, active = {}, removed = {} }
		function bus:sub()
			local id = self._nextSubId
			self._nextSubId = id + 1
			self.active[id] = true
			if id == failAt then
				error("injected subscription failure")
			end
			return id
		end
		function bus:unsub(id)
			self.active[id] = nil
			self.removed[#self.removed + 1] = id
			return true
		end

		local contained, started = pcall(Medusa.Services.BlackBoxService.start, store, bus)

		lu.assertTrue(contained)
		lu.assertFalse(started)
		lu.assertFalse(store:isStarted())
		lu.assertIsNil(next(bus.active))
		lu.assertEquals(#bus.removed, failAt)
	end
end

function TestBlackBoxWeaponTracker:test_cannon_ballistic_arc_uses_forward_aircraft_velocity_and_gravity()
	local aircraft = {
		Category = Unit.Category.AIRPLANE,
		Position3 = position3({ x = 0, y = 1000, z = 0 }, { x = 1, y = 0, z = 0 }),
		Velocity = { x = 100, y = 0, z = 0 },
	}
	local terrainArgs = {}
	GetTerrainIntersection = function(origin, direction, maxDistance)
		terrainArgs[#terrainArgs + 1] = { origin, direction, maxDistance }
		if #terrainArgs == 2 then
			return { x = 2000, y = 0, z = 0 }
		end
		return nil
	end

	lu.assertTrue(Medusa.Services.BlackBoxService.onShootingStart(self.store, { initiator = aircraft }, 10))
	lu.assertEquals(self:updateCannons(12, 5), 1)

	lu.assertEquals(#self.impacts, 1)
	lu.assertEquals(self.impacts[1].TerminalEventId, 1)
	lu.assertEquals(self.impacts[1].Kind, Medusa.Constants.CrewSuppressionTerminalKind.CANNON)
	lu.assertEquals(self.impacts[1].Source, Medusa.Constants.CrewSuppressionTerminalSource.FORWARD_VECTOR)
	lu.assertEquals(self.impacts[1].Position, { x = 2000, y = 0, z = 0 })
	lu.assertEquals(#terrainArgs, 2)
	lu.assertEquals(terrainArgs[1][1], aircraft.Position3.p)
	lu.assertAlmostEquals(terrainArgs[1][2].y, -0.006131, 0.000001)
	lu.assertAlmostEquals(terrainArgs[1][3], 1250.0235, 0.001)
	lu.assertAlmostEquals(terrainArgs[2][1].x, 1250, 0.001)
	lu.assertAlmostEquals(terrainArgs[2][1].y, 992.3359375, 0.001)
	lu.assertNil(self.impacts[1].Initiator)
	lu.assertNil(self.impacts[1].Target)
	lu.assertNil(self.impacts[1].ShooterSkill)
	lu.assertNil(self.impacts[1].EffectiveExplosiveMassKg)
end

function TestBlackBoxWeaponTracker:test_explosive_and_cannon_events_share_one_id_sequence()
	local tracked = weapon("bomb")
	local target = { Position = { x = 20, y = 0, z = 40 } }
	local aircraft = {
		Category = Unit.Category.AIRPLANE,
		Position3 = position3({ x = 0, y = 100, z = 0 }, { x = 0, y = -1, z = 0 }),
		Velocity = { x = 0, y = 0, z = 0 },
	}
	GetTerrainIntersection = function()
		return { x = 0, y = 0, z = 0 }
	end
	Medusa.Services.BlackBoxService.onShot(self.store, { weapon = tracked }, 1)
	Medusa.Services.BlackBoxService.onHit(self.store, { weapon = tracked, target = target }, 2)
	self:update(3, 5)
	Medusa.Services.BlackBoxService.onShootingStart(self.store, { initiator = aircraft }, 4)
	self:updateCannons(5, 5)

	lu.assertEquals(self.impacts[1].TerminalEventId, 1)
	lu.assertEquals(self.impacts[2].TerminalEventId, 2)
	lu.assertEquals(self.impacts[1].Kind, Medusa.Constants.CrewSuppressionTerminalKind.EXPLOSIVE)
	lu.assertEquals(self.impacts[2].Kind, Medusa.Constants.CrewSuppressionTerminalKind.CANNON)
end

function TestBlackBoxWeaponTracker:test_ground_initiator_produces_no_cannon_terminal_event()
	local intersectionCalls = 0
	local groundUnit = {
		Category = Unit.Category.GROUND_UNIT,
		Position3 = position3({ x = 0, y = 0, z = 0 }),
	}
	GetTerrainIntersection = function()
		intersectionCalls = intersectionCalls + 1
		return { x = 100, y = 0, z = 0 }
	end
	Medusa.Services.BlackBoxService.onShootingStart(self.store, { initiator = groundUnit }, 10)

	self:updateCannons(11, 5)

	lu.assertEquals(intersectionCalls, 0)
	lu.assertEquals(#self.impacts, 0)
end

function TestBlackBoxWeaponTracker:test_cannon_rejections_log_the_failed_boundary_stage()
	local intersectionCalls = 0
	local groundUnit = {
		Category = Unit.Category.GROUND_UNIT,
		Position3 = position3({ x = 0, y = 0, z = 0 }),
	}
	local missingPosition = {
		Category = Unit.Category.AIRPLANE,
	}
	local missingVelocity = {
		Category = Unit.Category.AIRPLANE,
		Position3 = position3({ x = 10, y = 100, z = 20 }, { x = 0, y = -1, z = 0 }),
	}
	local aircraft = {
		Category = Unit.Category.AIRPLANE,
		Position3 = position3({ x = 10, y = 100, z = 20 }, { x = 0, y = -1, z = 0 }),
		Velocity = { x = 0, y = 0, z = 0 },
	}
	GetTerrainIntersection = function()
		intersectionCalls = intersectionCalls + 1
		return nil
	end
	Medusa.Services.BlackBoxService.onShootingStart(self.store, { initiator = groundUnit }, 10)
	Medusa.Services.BlackBoxService.onShootingStart(self.store, { initiator = missingPosition }, 10)
	Medusa.Services.BlackBoxService.onShootingStart(self.store, { initiator = missingVelocity }, 10)
	Medusa.Services.BlackBoxService.onShootingStart(self.store, { initiator = aircraft }, 10)

	self:updateCannons(11, 5)

	local output = table.concat(self.logMessages, "\n")
	lu.assertStrContains(output, "cannon estimate rejected: initiator category is not aircraft")
	lu.assertStrContains(output, "cannon estimate rejected: initiator Position3 unavailable")
	lu.assertStrContains(output, "cannon estimate rejected: initiator velocity unavailable")
	lu.assertStrContains(output, "cannon ballistic projection rejected: source=FORWARD_VECTOR")
	lu.assertStrContains(output, "origin=(10.0,100.0,20.0)")
	lu.assertStrContains(output, "velocity=(0.000,-900.000,0.000)")
	lu.assertStrContains(output, "maxDistance=5000m")
	lu.assertStrContains(output, "segments=4")
	lu.assertEquals(intersectionCalls, 4)
	lu.assertEquals(#self.impacts, 0)
end

function TestBlackBoxWeaponTracker:test_cannon_queue_rejects_newest_and_update_obeys_budget_and_age()
	local store = Medusa.Services.BlackBoxWeaponStore:new(128, 2)
	local aircraft = {
		Category = Unit.Category.HELICOPTER,
		Position3 = position3({ x = 0, y = 100, z = 0 }, { x = 0, y = -1, z = 0 }),
		Velocity = { x = 0, y = 0, z = 0 },
	}
	lu.assertTrue(Medusa.Services.BlackBoxService.onShootingStart(store, { initiator = aircraft }, 1))
	lu.assertTrue(Medusa.Services.BlackBoxService.onShootingStart(store, { initiator = aircraft }, 2))
	lu.assertFalse(Medusa.Services.BlackBoxService.onShootingStart(store, { initiator = aircraft }, 3))
	lu.assertEquals(store:cannonSize(), 2)

	lu.assertEquals(Medusa.Services.BlackBoxService.updateCannons(store, 3, function() end, 1), 1)
	lu.assertEquals(store:cannonSize(), 1)
	lu.assertEquals(Medusa.Services.BlackBoxService.updateCannons(store, 8, function() end, 1), 1)
	lu.assertEquals(store:cannonSize(), 0)
end

function TestBlackBoxWeaponTracker:test_shared_update_processes_separate_five_weapon_and_cannon_budgets()
	local aircraft = {
		Category = Unit.Category.AIRPLANE,
		Position3 = position3({ x = 0, y = 100, z = 0 }, { x = 0, y = -1, z = 0 }),
		Velocity = { x = 0, y = 0, z = 0 },
	}
	for i = 1, Medusa.Constants.CrewSuppression.CANNON_CANDIDATE_CAPACITY do
		lu.assertTrue(Medusa.Services.BlackBoxService.onShootingStart(self.store, { initiator = aircraft }, i))
	end
	lu.assertFalse(Medusa.Services.BlackBoxService.onShootingStart(self.store, { initiator = aircraft }, 129))
	local weaponSamples = 0
	GetWeaponDesc = function()
		weaponSamples = weaponSamples + 1
		return descriptor(Weapon.Category.BOMB, 1, nil)
	end
	for i = 1, 7 do
		Medusa.Services.BlackBoxService.onShot(self.store, { weapon = weapon(tostring(i)) }, 1)
	end

	lu.assertEquals(Medusa.Services.BlackBoxService.updateDue(self.store, 128, function() end), 10)
	lu.assertEquals(weaponSamples, 5)
	lu.assertEquals(self.store:cannonSize(), 123)
end

function TestBlackBoxWeaponTracker:test_shared_due_gate_allows_only_one_update_per_interval()
	local first = weapon("first")
	local second = weapon("second")
	Medusa.Services.BlackBoxService.onShot(self.store, { weapon = first }, 1)
	Medusa.Services.BlackBoxService.onShot(self.store, { weapon = second }, 1)

	local firstCount = Medusa.Services.BlackBoxService.updateDue(self.store, 2, function() end)
	local duplicateCount = Medusa.Services.BlackBoxService.updateDue(self.store, 2, function() end)
	local nextCount = Medusa.Services.BlackBoxService.updateDue(self.store, 2.1, function() end)

	lu.assertEquals(firstCount, 2)
	lu.assertEquals(duplicateCount, 0)
	lu.assertEquals(nextCount, 2)
end
