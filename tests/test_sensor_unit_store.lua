local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("services.Services")
require("services.stores.SensorUnitStore")

-- == Helpers ==

local ulidCounter = 0

local function makeSensor(overrides)
	local base = {
		SensorUnitId = overrides and overrides.SensorUnitId or string.format("sensor-%d", ulidCounter),
		UnitId = overrides and overrides.UnitId or ulidCounter,
		SensorType = overrides and overrides.SensorType or "EWR",
	}
	if overrides then
		for k, v in pairs(overrides) do
			base[k] = v
		end
	end
	return base
end

-- == Tests ==

TestSensorUnitStore = {}

function TestSensorUnitStore:setUp()
	ulidCounter = 0
	self.store = Medusa.Services.SensorUnitStore:new()
end

function TestSensorUnitStore:test_add_and_get()
	ulidCounter = 1
	local sensor = makeSensor({ SensorUnitId = "s-1", UnitId = 100 })
	self.store:add(sensor)

	lu.assertEquals(self.store:count(), 1)
	lu.assertIs(self.store:get("s-1"), sensor)
end

function TestSensorUnitStore:test_get_by_unit_id()
	local sensor = makeSensor({ SensorUnitId = "s-1", UnitId = 100 })
	self.store:add(sensor)

	lu.assertIs(self.store:getByUnitId(100), sensor)
end

function TestSensorUnitStore:test_get_by_unit_id_returns_nil_for_unknown()
	lu.assertIsNil(self.store:getByUnitId(999))
end

function TestSensorUnitStore:test_get_by_type()
	local ewr1 = makeSensor({ SensorUnitId = "s-1", UnitId = 100, SensorType = "EWR" })
	local ewr2 = makeSensor({ SensorUnitId = "s-2", UnitId = 200, SensorType = "EWR" })
	local gci = makeSensor({ SensorUnitId = "s-3", UnitId = 300, SensorType = "GCI" })
	self.store:add(ewr1)
	self.store:add(ewr2)
	self.store:add(gci)

	local ewrs = self.store:getByType("EWR")
	lu.assertEquals(#ewrs, 2)

	local gcis = self.store:getByType("GCI")
	lu.assertEquals(#gcis, 1)
end

function TestSensorUnitStore:test_get_by_type_returns_empty_for_unknown()
	local result = self.store:getByType("AWACS")
	lu.assertEquals(#result, 0)
end

function TestSensorUnitStore:test_duplicate_add_errors()
	self.store:add(makeSensor({ SensorUnitId = "s-1", UnitId = 100 }))

	lu.assertErrorMsgContains("duplicate SensorUnitId: s-1", function()
		self.store:add(makeSensor({ SensorUnitId = "s-1", UnitId = 200 }))
	end)
end

function TestSensorUnitStore:test_remove_returns_entity_and_cleans_all_indexes()
	local sensor = makeSensor({ SensorUnitId = "s-1", UnitId = 100, SensorType = "EWR" })
	self.store:add(sensor)

	local removed = self.store:remove("s-1")
	lu.assertIs(removed, sensor)
	lu.assertEquals(self.store:count(), 0)
	lu.assertIsNil(self.store:get("s-1"))
	lu.assertIsNil(self.store:getByUnitId(100))
	lu.assertEquals(#self.store:getByType("EWR"), 0)
end

function TestSensorUnitStore:test_remove_nonexistent_returns_nil()
	lu.assertIsNil(self.store:remove("no-such-id"))
end

function TestSensorUnitStore:test_getAll_with_buffer_reuse()
	self.store:add(makeSensor({ SensorUnitId = "s-1", UnitId = 100 }))
	self.store:add(makeSensor({ SensorUnitId = "s-2", UnitId = 200 }))

	local buffer = { "stale-1", "stale-2", "stale-3" }
	local result = self.store:getAll(buffer)

	lu.assertIs(result, buffer)
	lu.assertEquals(#result, 2)
end

function TestSensorUnitStore:test_count_tracks_adds_and_removes()
	self.store:add(makeSensor({ SensorUnitId = "s-1", UnitId = 100 }))
	self.store:add(makeSensor({ SensorUnitId = "s-2", UnitId = 200 }))
	lu.assertEquals(self.store:count(), 2)

	self.store:remove("s-1")
	lu.assertEquals(self.store:count(), 1)

	self.store:remove("s-2")
	lu.assertEquals(self.store:count(), 0)
end

