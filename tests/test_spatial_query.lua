local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("entities.Entities")
require("entities.Battery")
require("services.Services")
require("services.stores.BatteryStore")
require("services.SpatialQuery")

local ulidCounter = 0
local groupCounter = 0

local function setupMocks()
	ulidCounter = 0
	groupCounter = 0
	GetTime = function()
		return 1000
	end
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
end

local function makeBattery(overrides)
	groupCounter = groupCounter + 1
	local data = {
		NetworkId = 1,
		GroupId = overrides and overrides.GroupId or groupCounter,
		GroupName = overrides and overrides.GroupName or string.format("SAM-%d", groupCounter),
		OperationalStatus = "ACTIVE",
		Position = { x = 0, y = 0, z = 0 },
		EngagementRangeMax = 50000,
	}
	if overrides then
		for k, v in pairs(overrides) do
			data[k] = v
		end
	end
	return Medusa.Entities.Battery.new(data)
end

TestBatteriesInRadius = {}

function TestBatteriesInRadius:setUp()
	setupMocks()
	self.grid = GeoGrid(10000, { "Battery", "Track" })
	self.store = Medusa.Services.BatteryStore:new()
end

function TestBatteriesInRadius:test_returns_batteries_within_radius()
	local b1 = makeBattery({ Position = { x = 0, y = 0, z = 0 } })
	local b2 = makeBattery({ Position = { x = 5000, y = 0, z = 5000 } })
	self.store:add(b1)
	self.store:add(b2)
	self.grid:add("Battery", b1.BatteryId, b1.Position)
	self.grid:add("Battery", b2.BatteryId, b2.Position)

	local result = Medusa.Services.SpatialQuery.batteriesInRadius(self.grid, self.store, { x = 0, y = 0, z = 0 }, 10000)

	lu.assertEquals(#result, 2)
end

function TestBatteriesInRadius:test_excludes_batteries_outside_radius()
	local b1 = makeBattery({ Position = { x = 100000, y = 0, z = 100000 } })
	self.store:add(b1)
	self.grid:add("Battery", b1.BatteryId, b1.Position)

	local result = Medusa.Services.SpatialQuery.batteriesInRadius(self.grid, self.store, { x = 0, y = 0, z = 0 }, 10000)

	lu.assertEquals(#result, 0)
end

function TestBatteriesInRadius:test_returns_empty_when_grid_empty()
	local result = Medusa.Services.SpatialQuery.batteriesInRadius(self.grid, self.store, { x = 0, y = 0, z = 0 }, 50000)

	lu.assertEquals(#result, 0)
end

function TestBatteriesInRadius:test_mixed_near_and_far()
	local b1 = makeBattery({ Position = { x = 1000, y = 0, z = 1000 } })
	local b2 = makeBattery({ Position = { x = 2000, y = 0, z = 2000 } })
	local b3 = makeBattery({ Position = { x = 500000, y = 0, z = 500000 } })
	self.store:add(b1)
	self.store:add(b2)
	self.store:add(b3)
	self.grid:add("Battery", b1.BatteryId, b1.Position)
	self.grid:add("Battery", b2.BatteryId, b2.Position)
	self.grid:add("Battery", b3.BatteryId, b3.Position)

	local result = Medusa.Services.SpatialQuery.batteriesInRadius(self.grid, self.store, { x = 0, y = 0, z = 0 }, 10000)

	lu.assertEquals(#result, 2)
end

function TestBatteriesInRadius:test_battery_removed_from_store_not_returned()
	local b1 = makeBattery({ Position = { x = 0, y = 0, z = 0 } })
	self.store:add(b1)
	self.grid:add("Battery", b1.BatteryId, b1.Position)
	self.store:remove(b1.BatteryId)

	local result = Medusa.Services.SpatialQuery.batteriesInRadius(self.grid, self.store, { x = 0, y = 0, z = 0 }, 10000)

	lu.assertEquals(#result, 0)
end
