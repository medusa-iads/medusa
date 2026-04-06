local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("services.Services")
require("services.stores.AirbaseStore")

-- == Helpers ==

local function makeAirbase(airbaseId, airbaseName)
	return {
		AirbaseId = airbaseId,
		AirbaseName = airbaseName,
	}
end

-- == Tests ==

TestAirbaseStore = {}

function TestAirbaseStore:setUp()
	self.store = Medusa.Services.AirbaseStore:new()
end

function TestAirbaseStore:test_add_and_get()
	local airbase = makeAirbase("ab-1", "Incirlik")
	self.store:add(airbase)

	lu.assertEquals(self.store:count(), 1)
	lu.assertIs(self.store:get("ab-1"), airbase)
end

function TestAirbaseStore:test_get_by_name()
	local airbase = makeAirbase("ab-1", "Incirlik")
	self.store:add(airbase)

	lu.assertIs(self.store:getByName("Incirlik"), airbase)
end

function TestAirbaseStore:test_get_by_name_returns_nil_for_unknown()
	lu.assertIsNil(self.store:getByName("no-such-airbase"))
end

function TestAirbaseStore:test_duplicate_add_errors()
	self.store:add(makeAirbase("ab-1", "Incirlik"))

	lu.assertErrorMsgContains("duplicate AirbaseId: ab-1", function()
		self.store:add(makeAirbase("ab-1", "Batumi"))
	end)
end

function TestAirbaseStore:test_remove_returns_entity_and_cleans_all_indexes()
	local airbase = makeAirbase("ab-1", "Incirlik")
	self.store:add(airbase)

	local removed = self.store:remove("ab-1")
	lu.assertIs(removed, airbase)
	lu.assertEquals(self.store:count(), 0)
	lu.assertIsNil(self.store:get("ab-1"))
	lu.assertIsNil(self.store:getByName("Incirlik"))
end

function TestAirbaseStore:test_remove_nonexistent_returns_nil()
	lu.assertIsNil(self.store:remove("no-such-id"))
end

function TestAirbaseStore:test_getAll_with_buffer_reuse()
	self.store:add(makeAirbase("ab-1", "Incirlik"))
	self.store:add(makeAirbase("ab-2", "Batumi"))

	local buffer = { "stale-1", "stale-2", "stale-3" }
	local result = self.store:getAll(buffer)

	lu.assertIs(result, buffer)
	lu.assertEquals(#result, 2)
end

function TestAirbaseStore:test_count_tracks_adds_and_removes()
	self.store:add(makeAirbase("ab-1", "Incirlik"))
	self.store:add(makeAirbase("ab-2", "Batumi"))
	lu.assertEquals(self.store:count(), 2)

	self.store:remove("ab-1")
	lu.assertEquals(self.store:count(), 1)

	self.store:remove("ab-2")
	lu.assertEquals(self.store:count(), 0)
end
