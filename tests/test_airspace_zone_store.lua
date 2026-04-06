local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("services.Services")
require("services.stores.AirspaceZoneStore")

-- == Helpers ==

local function makeZone(zoneName, kind)
	return {
		ZoneName = zoneName,
		Kind = kind or "MEZ",
	}
end

-- == Tests ==

TestAirspaceZoneStore = {}

function TestAirspaceZoneStore:setUp()
	self.store = Medusa.Services.AirspaceZoneStore:new()
end

function TestAirspaceZoneStore:test_add_and_get()
	local zone = makeZone("Zone-Alpha", "MEZ")
	self.store:add(zone)

	lu.assertEquals(self.store:count(), 1)
	lu.assertIs(self.store:get("Zone-Alpha"), zone)
end

function TestAirspaceZoneStore:test_get_by_kind()
	local mez1 = makeZone("Zone-Alpha", "MEZ")
	local mez2 = makeZone("Zone-Bravo", "MEZ")
	local fez = makeZone("Zone-Charlie", "FEZ")
	self.store:add(mez1)
	self.store:add(mez2)
	self.store:add(fez)

	local mezZones = self.store:getByKind("MEZ")
	lu.assertEquals(#mezZones, 2)

	local fezZones = self.store:getByKind("FEZ")
	lu.assertEquals(#fezZones, 1)
end

function TestAirspaceZoneStore:test_get_by_kind_returns_empty_for_unknown()
	local result = self.store:getByKind("JEZ")
	lu.assertEquals(#result, 0)
end

function TestAirspaceZoneStore:test_duplicate_add_errors()
	self.store:add(makeZone("Zone-Alpha", "MEZ"))

	lu.assertErrorMsgContains("duplicate ZoneName: Zone-Alpha", function()
		self.store:add(makeZone("Zone-Alpha", "FEZ"))
	end)
end

function TestAirspaceZoneStore:test_remove_returns_entity_and_cleans_all_indexes()
	local zone = makeZone("Zone-Alpha", "MEZ")
	self.store:add(zone)

	local removed = self.store:remove("Zone-Alpha")
	lu.assertIs(removed, zone)
	lu.assertEquals(self.store:count(), 0)
	lu.assertIsNil(self.store:get("Zone-Alpha"))
	lu.assertEquals(#self.store:getByKind("MEZ"), 0)
end

function TestAirspaceZoneStore:test_remove_nonexistent_returns_nil()
	lu.assertIsNil(self.store:remove("no-such-zone"))
end

function TestAirspaceZoneStore:test_getAll_with_buffer_reuse()
	self.store:add(makeZone("Zone-Alpha", "MEZ"))
	self.store:add(makeZone("Zone-Bravo", "FEZ"))

	local buffer = { "stale-1", "stale-2", "stale-3" }
	local result = self.store:getAll(buffer)

	lu.assertIs(result, buffer)
	lu.assertEquals(#result, 2)
end

function TestAirspaceZoneStore:test_count_tracks_adds_and_removes()
	self.store:add(makeZone("Zone-Alpha", "MEZ"))
	self.store:add(makeZone("Zone-Bravo", "FEZ"))
	lu.assertEquals(self.store:count(), 2)

	self.store:remove("Zone-Alpha")
	lu.assertEquals(self.store:count(), 1)

	self.store:remove("Zone-Bravo")
	lu.assertEquals(self.store:count(), 0)
end

