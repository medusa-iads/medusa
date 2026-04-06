local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Battery")
require("entities.Track")
require("services.Services")
require("services.stores.BatteryStore")
require("services.stores.SensorUnitStore")
require("services.stores.C2NodeStore")
require("services.EntityFactory")
require("services.TargetAssigner")
require("services.PkModel")

-- == Helpers ==

local ulidCounter = 0
local origGetGroupUnits, origGetUnitDesc, origGetUnitID, origGetUnitType, origGetUnitPosition, origGetUnitAmmo

local function makeBattery(overrides)
	local data = {
		NetworkId = "net-1",
		GroupId = 100,
		GroupName = "SAM-1",
		ActivationState = Medusa.Constants.ActivationState.STATE_COLD,
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
		Position = { x = 0, y = 0, z = 0 },
		EngagementRangeMax = 12000,
		PkRangeOptimal = 6000,
		PkRangeSigma = 4000,
		TotalAmmoStatus = 8,
		EngagementAltitudeMin = 0,
		EngagementAltitudeMax = 12000,
		MissileNmax = 16,
		WeaponRangeMax = 12000,
		DetectionRangeMax = 15000,
	}
	if overrides then
		for k, v in pairs(overrides) do
			data[k] = v
		end
	end
	local b = Medusa.Entities.Battery.new(data)
	b.Units = {}
	return b
end

-- == nearestClusterDist tests (TargetAssigner internal) ==

TestNearestClusterDist = {}

function TestNearestClusterDist:test_no_clusters_uses_battery_position()
	local battery = makeBattery({ Position = { x = 1000, y = 0, z = 0 } })
	local pos = { x = 4000, y = 0, z = 4000 }
	local expected = math.sqrt(3000 * 3000 + 4000 * 4000) -- 5000
	local dist = Medusa.Services.TargetAssigner._nearestClusterDist(battery, pos)
	lu.assertAlmostEquals(dist, expected, 1)
end

function TestNearestClusterDist:test_with_clusters_returns_nearest()
	local battery = makeBattery({
		Position = { x = 5000, y = 0, z = 5000 },
	})
	battery.Clusters = {
		{ x = 0, y = 0, z = 0 },
		{ x = 10000, y = 0, z = 10000 },
	}
	-- Point near cluster 1
	local pos = { x = 3000, y = 0, z = 4000 }
	local dist = Medusa.Services.TargetAssigner._nearestClusterDist(battery, pos)
	-- Distance to cluster 1: sqrt(3000^2 + 4000^2) = 5000
	lu.assertAlmostEquals(dist, 5000, 1)
end

function TestNearestClusterDist:test_with_clusters_picks_second_cluster()
	local battery = makeBattery({
		Position = { x = 5000, y = 0, z = 5000 },
	})
	battery.Clusters = {
		{ x = 0, y = 0, z = 0 },
		{ x = 10000, y = 0, z = 10000 },
	}
	-- Point near cluster 2
	local pos = { x = 10000, y = 0, z = 13000 }
	local dist = Medusa.Services.TargetAssigner._nearestClusterDist(battery, pos)
	-- Distance to cluster 2: sqrt(0 + 3000^2) = 3000
	lu.assertAlmostEquals(dist, 3000, 1)
end

-- == Clustering algorithm tests (EntityFactory) ==

TestClusterLaunchers = {}

function TestClusterLaunchers:setUp()
	ulidCounter = 0
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
	origGetGroupUnits = GetGroupUnits
	origGetUnitDesc = GetUnitDesc
	origGetUnitID = GetUnitID
	origGetUnitType = GetUnitType
	origGetUnitPosition = GetUnitPosition
	origGetUnitAmmo = GetUnitAmmo
end

function TestClusterLaunchers:tearDown()
	GetGroupUnits = origGetGroupUnits
	GetUnitDesc = origGetUnitDesc
	GetUnitID = origGetUnitID
	GetUnitType = origGetUnitType
	GetUnitPosition = origGetUnitPosition
	GetUnitAmmo = origGetUnitAmmo
end

local function setupMockForPositions(positions)
	local units = {}
	for i = 1, #positions do
		units[i] = { _idx = i, _id = 100 + i }
	end
	GetGroupUnits = function()
		return units
	end
	GetUnitID = function(unit)
		return unit._id
	end
	GetUnitType = function()
		return "SA-8"
	end
	GetUnitPosition = function(unit)
		return positions[unit._idx]
	end
	GetUnitAmmo = function()
		return {
			{
				desc = {
					typeName = "9M33M3",
					displayName = "9M33M3",
					missileCategory = 2,
					rangeMaxAltMax = 12000,
					rangeMaxAltMin = 10000,
					rangeMin = 200,
					altMax = 6000,
					altMin = 25,
					Nmax = 16,
				},
				count = 4,
			},
		}
	end
	GetUnitDesc = function()
		return {
			attributes = {
				["AA_missile"] = true,
				["SAM LL"] = true,
				["SAM SR"] = true,
				["SAM TR"] = true,
			},
		}
	end
end

local function makeStores()
	return {
		batteries = Medusa.Services.BatteryStore:new(),
		sensors = Medusa.Services.SensorUnitStore:new(),
		c2Nodes = Medusa.Services.C2NodeStore:new(),
	}
end

function TestClusterLaunchers:test_single_launcher_no_clusters()
	setupMockForPositions({
		{ x = 0, y = 0, z = 0 },
	})
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(
		{ groupId = 1, groupName = "SA8-1", parsed = { roles = { "battery" } } },
		stores,
		"net-1",
		{}
	)
	local battery = stores.batteries:getByGroupId(1)
	lu.assertNotNil(battery)
	lu.assertNil(battery.Clusters)
	lu.assertNil(battery.ClusterSpreadRadius)
end

function TestClusterLaunchers:test_tight_group_no_clusters()
	-- Two launchers 500m apart (< 1 NM threshold)
	setupMockForPositions({
		{ x = 0, y = 0, z = 0 },
		{ x = 500, y = 0, z = 0 },
	})
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(
		{ groupId = 2, groupName = "SA8-2", parsed = { roles = { "battery" } } },
		stores,
		"net-1",
		{}
	)
	local battery = stores.batteries:getByGroupId(2)
	lu.assertNotNil(battery)
	lu.assertNil(battery.Clusters)
end

function TestClusterLaunchers:test_two_distant_launchers_creates_two_clusters()
	local dist = 10 * 1852
	setupMockForPositions({
		{ x = 0, y = 0, z = 0 },
		{ x = dist, y = 0, z = 0 },
	})
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(
		{ groupId = 3, groupName = "SA8-3", parsed = { roles = { "battery" } } },
		stores,
		"net-1",
		{}
	)
	local battery = stores.batteries:getByGroupId(3)
	lu.assertNotNil(battery)
	lu.assertNotNil(battery.Clusters)
	lu.assertEquals(#battery.Clusters, 2)
	-- Centroid should be at midpoint
	lu.assertAlmostEquals(battery.Position.x, dist / 2, 1)
	lu.assertAlmostEquals(battery.Position.z, 0, 1)
	-- Spread radius = dist/2
	lu.assertAlmostEquals(battery.ClusterSpreadRadius, dist / 2, 1)
end

function TestClusterLaunchers:test_three_launchers_two_close_one_far()
	local farDist = 10 * 1852
	setupMockForPositions({
		{ x = 0, y = 0, z = 0 },
		{ x = 200, y = 0, z = 0 },
		{ x = farDist, y = 0, z = 0 },
	})
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(
		{ groupId = 4, groupName = "SA8-4", parsed = { roles = { "battery" } } },
		stores,
		"net-1",
		{}
	)
	local battery = stores.batteries:getByGroupId(4)
	lu.assertNotNil(battery)
	lu.assertNotNil(battery.Clusters)
	lu.assertEquals(#battery.Clusters, 2)
	-- Cluster 1 centroid at (100, 0) -- mean of 0 and 200
	lu.assertAlmostEquals(battery.Clusters[1].x, 100, 1)
	-- Cluster 2 centroid at farDist
	lu.assertAlmostEquals(battery.Clusters[2].x, farDist, 1)
end

function TestClusterLaunchers:test_four_launchers_in_line_four_clusters()
	local step = 5 * 1852
	setupMockForPositions({
		{ x = 0, y = 0, z = 0 },
		{ x = step, y = 0, z = 0 },
		{ x = step * 2, y = 0, z = 0 },
		{ x = step * 3, y = 0, z = 0 },
	})
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(
		{ groupId = 5, groupName = "SA8-5", parsed = { roles = { "battery" } } },
		stores,
		"net-1",
		{}
	)
	local battery = stores.batteries:getByGroupId(5)
	lu.assertNotNil(battery)
	lu.assertNotNil(battery.Clusters)
	lu.assertEquals(#battery.Clusters, 4)
	local expectedCentroidX = (0 + step + step * 2 + step * 3) / 4
	lu.assertAlmostEquals(battery.Position.x, expectedCentroidX, 1)
end
