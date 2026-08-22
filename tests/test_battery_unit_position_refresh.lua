local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("services.Services")
require("entities.Battery")
require("services.stores.BatteryStore")
require("services.CrewPerceptionService")

TestBatteryUnitPositionRefresh = {}

function TestBatteryUnitPositionRefresh:setUp()
	self.originalGetUnitPosition = GetUnitPosition
	self.originalGetUnitHeading = GetUnitHeading
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	self.repository = Medusa.Services.BatteryStore:new()
	self.battery = Medusa.Entities.Battery.new({
		BatteryId = "sam-1",
		NetworkId = "test",
		GroupId = 1,
		GroupName = "sam-1",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
	})
	self.battery.Units = {}
	for i = 1, 6 do
		self.battery.Units[i] = Medusa.Entities.Battery.newUnit({
			UnitId = i,
			UnitName = "sam-1-" .. i,
			Position = { x = i, y = 0, z = i },
		})
	end
	self.battery.PositionAnchorUnitId = 1
	self.repository:add(self.battery)
	self.spatialIndex = { units = {}, batteries = {} }
	function self.spatialIndex:syncSuppressibleUnit(unit)
		self.units[#self.units + 1] = unit.UnitId
	end
	function self.spatialIndex:syncBattery(battery)
		self.batteries[#self.batteries + 1] = battery.BatteryId
	end
	self.positionCalls = {}
	local calls = self.positionCalls
	GetUnitPosition = function(unitName)
		calls[#calls + 1] = unitName
		local id = tonumber(string.match(unitName, "(%d+)$"))
		return { x = id * 10, y = id, z = id * 20 }
	end
end

function TestBatteryUnitPositionRefresh:tearDown()
	GetUnitPosition = self.originalGetUnitPosition
	GetUnitHeading = self.originalGetUnitHeading
end

function TestBatteryUnitPositionRefresh:test_aaa_heading_updates_with_the_same_bounded_unit_refresh()
	local repository = Medusa.Services.BatteryStore:new()
	local battery = Medusa.Entities.Battery.new({
		BatteryId = "aaa-1",
		NetworkId = "test",
		GroupId = 2,
		GroupName = "aaa-1",
		Role = Medusa.Constants.BatteryRole.AAA,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 20,
			UnitName = "aaa-1-1",
			Roles = { Medusa.Constants.BatteryUnitRole.AAA },
			Position = { x = 0, y = 0, z = 0 },
		}),
	}
	repository:add(battery)
	GetUnitHeading = function()
		return 90
	end

	local visited, refreshed, aaaRefreshed = Medusa.Services.CrewPerceptionService.refreshUnitPositions({
		batteryRepository = repository,
		spatialIndex = self.spatialIndex,
		now = 100,
		budget = 1,
	})

	lu.assertEquals(visited, 1)
	lu.assertEquals(refreshed, 1)
	lu.assertEquals(aaaRefreshed, 1)
	lu.assertEquals(battery.Aaa.UnitHeadingCount, 1)
	lu.assertAlmostEquals(battery.Aaa.UnitHeadings[1].hx, 0, 0.0001)
	lu.assertAlmostEquals(battery.Aaa.UnitHeadings[1].hz, 1, 0.0001)
end

function TestBatteryUnitPositionRefresh:test_refresh_is_bounded_and_includes_missile_battery_units()
	local visited, refreshed = Medusa.Services.CrewPerceptionService.refreshUnitPositions({
		batteryRepository = self.repository,
		spatialIndex = self.spatialIndex,
		now = 100,
		budget = 4,
	})

	lu.assertEquals(visited, 4)
	lu.assertEquals(refreshed, 4)
	lu.assertEquals(#self.positionCalls, 4)
	lu.assertEquals(self.spatialIndex.units, { 1, 2, 3, 4 })
	lu.assertEquals(self.battery.Units[1].Position, { x = 10, y = 1, z = 20 })
	lu.assertEquals(self.battery.Position, { x = 10, y = 1, z = 20 })
	lu.assertEquals(self.spatialIndex.batteries, { "sam-1" })
	lu.assertEquals(self.battery.Units[5].Position, { x = 5, y = 0, z = 5 })
end

function TestBatteryUnitPositionRefresh:test_recent_units_are_skipped_without_exceeding_visit_budget()
	Medusa.Services.CrewPerceptionService.refreshUnitPositions({
		batteryRepository = self.repository,
		spatialIndex = self.spatialIndex,
		now = 100,
		budget = 4,
	})
	self.positionCalls = {}
	local calls = self.positionCalls
	GetUnitPosition = function(unitName)
		calls[#calls + 1] = unitName
		return { x = 99, y = 1, z = 99 }
	end

	local visited, refreshed = Medusa.Services.CrewPerceptionService.refreshUnitPositions({
		batteryRepository = self.repository,
		spatialIndex = self.spatialIndex,
		now = 110,
		budget = 4,
	})

	lu.assertEquals(visited, 4)
	lu.assertEquals(refreshed, 2)
	lu.assertEquals(self.positionCalls, { "sam-1-5", "sam-1-6" })
end

function TestBatteryUnitPositionRefresh:test_unavailable_unit_is_not_polled_again_before_refresh_interval()
	local repository = Medusa.Services.BatteryStore:new()
	local battery = Medusa.Entities.Battery.new({
		BatteryId = "missing",
		NetworkId = "test",
		GroupId = 3,
		GroupName = "missing",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({ UnitId = 30, UnitName = "missing-1" }),
	}
	repository:add(battery)
	local calls = 0
	GetUnitPosition = function()
		calls = calls + 1
		return nil
	end

	local _, firstRefresh = Medusa.Services.CrewPerceptionService.refreshUnitPositions({
		batteryRepository = repository,
		spatialIndex = self.spatialIndex,
		now = 100,
		budget = 1,
	})
	local _, secondRefresh = Medusa.Services.CrewPerceptionService.refreshUnitPositions({
		batteryRepository = repository,
		spatialIndex = self.spatialIndex,
		now = 110,
		budget = 1,
	})

	lu.assertEquals(firstRefresh, 0)
	lu.assertEquals(secondRefresh, 0)
	lu.assertEquals(calls, 1)
end
