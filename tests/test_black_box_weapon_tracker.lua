local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("services.Services")
require("services.MetricsService")
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
		GetTime = GetTime,
	}
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	Medusa.Services.MetricsService._registry = {}
	Medusa.Services.MetricsService.gauge("medusa_crew_suppression_weapons_tracked", "")
	Medusa.Services.MetricsService.counter("medusa_crew_suppression_weapon_outcomes_total", "", { "outcome" })
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
	NormalizeVector3D = function(value)
		local length = math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
		return { x = value.x / length, y = value.y / length, z = value.z / length }
	end
	GetTerrainIntersection = function()
		return nil
	end
end

function TestBlackBoxWeaponTracker:tearDown()
	for name, value in pairs(self.originals) do
		_G[name] = value
	end
end

function TestBlackBoxWeaponTracker:update(now, budget)
	return Medusa.Services.BlackBoxService.update(self.store, now, function(impact)
		self.impacts[#self.impacts + 1] = impact
	end, budget)
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
	lu.assertEquals(self.impacts[1].Source, Medusa.Constants.CrewSuppressionImpactSource.HIT)
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
	lu.assertEquals(self.impacts[1].Source, Medusa.Constants.CrewSuppressionImpactSource.TERRAIN)
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
	lu.assertEquals(#bus.subscriptions, 2)
	lu.assertTrue(Medusa.Services.BlackBoxService.stop(self.store))
	lu.assertEquals(bus.removed, { 1, 2 })
	lu.assertEquals(self.store:size(), 0)

	lu.assertTrue(Medusa.Services.BlackBoxService.start(self.store, bus))
	lu.assertEquals(#bus.subscriptions, 4)
	lu.assertTrue(Medusa.Services.BlackBoxService.stop(self.store))
	lu.assertEquals(bus.removed, { 1, 2, 3, 4 })
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
