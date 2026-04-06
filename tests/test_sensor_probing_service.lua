local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.SensorUnit")
require("entities.Battery")
require("services.Services")
require("services.stores.SensorUnitStore")
require("services.stores.BatteryStore")
require("services.SensorProbingService")

-- == Helpers ==

local ulidCounter = 0

local function nextUlid()
	ulidCounter = ulidCounter + 1
	return string.format("ULID-%d", ulidCounter)
end

-- == Tests ==

TestSensorProbingService = {}

function TestSensorProbingService:setUp()
	ulidCounter = 0
	NewULID = function()
		return nextUlid()
	end
	self.service = Medusa.Services.SensorProbingService:new(1)
end

-- _parseSensors tests

function TestSensorProbingService:test_parseSensors_nil_returns_nil()
	lu.assertIsNil(self.service:_parseSensors(nil))
end

function TestSensorProbingService:test_parseSensors_empty_returns_nil()
	lu.assertIsNil(self.service:_parseSensors({}))
end

function TestSensorProbingService:test_parseSensors_radar_headon()
	local sensors = {
		[1] = {
			[1] = {
				detectionDistanceAir = {
					upperHemisphere = { headOn = 200000 },
				},
			},
		},
	}
	local result = self.service:_parseSensors(sensors)
	lu.assertNotIsNil(result)
	lu.assertEquals(result.detectionRangeMax, 200000)
end

function TestSensorProbingService:test_parseSensors_radar_maximal_fallback()
	local sensors = {
		[1] = {
			[1] = {
				detectionDistanceMaximal = 150000,
			},
		},
	}
	local result = self.service:_parseSensors(sensors)
	lu.assertNotIsNil(result)
	lu.assertEquals(result.detectionRangeMax, 150000)
end

function TestSensorProbingService:test_parseSensors_multiple_radars_takes_max()
	local sensors = {
		[1] = {
			[1] = {
				detectionDistanceAir = {
					upperHemisphere = { headOn = 80000 },
				},
			},
			[2] = {
				detectionDistanceAir = {
					upperHemisphere = { headOn = 200000 },
				},
			},
		},
	}
	local result = self.service:_parseSensors(sensors)
	lu.assertNotIsNil(result)
	lu.assertEquals(result.detectionRangeMax, 200000)
end

function TestSensorProbingService:test_parseSensors_ignores_non_detection()
	local sensors = {
		[1] = {
			[1] = {
				typeName = "some sensor",
			},
		},
	}
	lu.assertIsNil(self.service:_parseSensors(sensors))
end

function TestSensorProbingService:test_parseSensors_headon_preferred_over_maximal()
	local sensors = {
		[1] = {
			[1] = {
				detectionDistanceAir = {
					upperHemisphere = { headOn = 200000 },
				},
				detectionDistanceMaximal = 300000,
			},
		},
	}
	-- headOn is preferred; since 200k < 300k, headOn wins as the extraction path
	local result = self.service:_parseSensors(sensors)
	lu.assertEquals(result.detectionRangeMax, 200000)
end

-- applySensorRanges tests

function TestSensorProbingService:test_applySensorRanges_backfills()
	self.service._cache["SA-10 TR"] = { detectionRangeMax = 75000 }

	local store = Medusa.Services.SensorUnitStore:new()
	store:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "net1",
		UnitId = 1,
		UnitName = "u1",
		GroupId = 10,
		GroupName = "g1",
		UnitTypeName = "SA-10 TR",
	}))

	local updated = self.service:applySensorRanges(store)
	lu.assertEquals(updated, 1)

	local sensor = store:getByUnitId(1)
	lu.assertEquals(sensor.DetectionRangeMax, 75000)
end

function TestSensorProbingService:test_applySensorRanges_skips_unknown()
	local store = Medusa.Services.SensorUnitStore:new()
	store:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "net1",
		UnitId = 1,
		UnitName = "u1",
		GroupId = 10,
		GroupName = "g1",
		UnitTypeName = "UnknownType",
	}))

	local updated = self.service:applySensorRanges(store)
	lu.assertEquals(updated, 0)

	local sensor = store:getByUnitId(1)
	lu.assertIsNil(sensor.DetectionRangeMax)
end

-- applyBatteryRanges tests

function TestSensorProbingService:test_applyBatteryRanges_sets_max()
	self.service._cache["SA-10 LN"] = { detectionRangeMax = 75000 }

	local store = Medusa.Services.BatteryStore:new()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "net1",
		GroupId = 10,
		GroupName = "g1",
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({ UnitId = 1, UnitTypeName = "SA-10 LN" }),
	}
	store:add(battery)

	local updated = self.service:applyBatteryRanges(store)
	lu.assertEquals(updated, 1)
	lu.assertEquals(battery.EngagementRangeMax, 75000)
end

function TestSensorProbingService:test_applyBatteryRanges_takes_max_across_units()
	self.service._cache["SA-10 TR"] = { detectionRangeMax = 75000 }
	self.service._cache["SA-10 LN"] = { detectionRangeMax = 40000 }

	local store = Medusa.Services.BatteryStore:new()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "net1",
		GroupId = 10,
		GroupName = "g1",
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({ UnitId = 1, UnitTypeName = "SA-10 TR" }),
		Medusa.Entities.Battery.newUnit({ UnitId = 2, UnitTypeName = "SA-10 LN" }),
	}
	store:add(battery)

	local updated = self.service:applyBatteryRanges(store)
	lu.assertEquals(updated, 1)
	lu.assertEquals(battery.EngagementRangeMax, 75000)
end

-- getCapabilities tests
