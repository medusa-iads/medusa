local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("services.Services")
require("services.stores.BatteryStore")

-- == Helpers ==

local function makeBattery(batteryId, groupId)
	return {
		BatteryId = batteryId,
		GroupId = groupId,
	}
end

-- == Tests ==

TestBatteryStore = {}

function TestBatteryStore:setUp()
	self.store = Medusa.Services.BatteryStore:new()
end

function TestBatteryStore:test_add_and_get()
	local battery = makeBattery("bat-1", 100)
	self.store:add(battery)

	lu.assertEquals(self.store:count(), 1)
	lu.assertIs(self.store:get("bat-1"), battery)
end

function TestBatteryStore:test_add_duplicate_errors()
	self.store:add(makeBattery("bat-1", 100))

	lu.assertErrorMsgContains("duplicate BatteryId: bat-1", function()
		self.store:add(makeBattery("bat-1", 200))
	end)
end

function TestBatteryStore:test_get_returns_nil_for_unknown()
	lu.assertIsNil(self.store:get("no-such-id"))
end

function TestBatteryStore:test_getByGroupId()
	local battery = makeBattery("bat-1", 100)
	self.store:add(battery)

	lu.assertIs(self.store:getByGroupId(100), battery)
end

function TestBatteryStore:test_getByGroupId_returns_nil_for_unknown()
	lu.assertIsNil(self.store:getByGroupId(999))
end

function TestBatteryStore:test_remove_returns_battery()
	local battery = makeBattery("bat-1", 100)
	self.store:add(battery)

	local removed = self.store:remove("bat-1")
	lu.assertIs(removed, battery)
	lu.assertEquals(self.store:count(), 0)
end

function TestBatteryStore:test_remove_clears_both_indexes()
	local battery = makeBattery("bat-1", 100)
	self.store:add(battery)
	self.store:remove("bat-1")

	lu.assertIsNil(self.store:get("bat-1"))
	lu.assertIsNil(self.store:getByGroupId(100))
end

function TestBatteryStore:test_remove_unknown_returns_nil()
	lu.assertIsNil(self.store:remove("no-such-id"))
end

function TestBatteryStore:test_getAll_returns_all_batteries()
	self.store:add(makeBattery("bat-1", 100))
	self.store:add(makeBattery("bat-2", 200))
	self.store:add(makeBattery("bat-3", 300))

	local all = self.store:getAll()
	lu.assertEquals(#all, 3)
end

function TestBatteryStore:test_getAll_reuses_output_table()
	self.store:add(makeBattery("bat-1", 100))
	self.store:add(makeBattery("bat-2", 200))

	local buffer = { "stale-entry-1", "stale-entry-2", "stale-entry-3" }
	local result = self.store:getAll(buffer)

	lu.assertIs(result, buffer)
	lu.assertEquals(#result, 2)
end

function TestBatteryStore:test_getAll_empty_store()
	local all = self.store:getAll()
	lu.assertEquals(#all, 0)
end

function TestBatteryStore:test_count_tracks_add_and_remove()
	self.store:add(makeBattery("bat-1", 100))
	self.store:add(makeBattery("bat-2", 200))
	lu.assertEquals(self.store:count(), 2)

	self.store:remove("bat-1")
	lu.assertEquals(self.store:count(), 1)

	self.store:remove("bat-2")
	lu.assertEquals(self.store:count(), 0)
end
