local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("services.Services")
require("services.stores.C2NodeStore")

-- == Helpers ==

local ulidCounter = 0

local function makeC2Node(overrides)
	local base = {
		C2NodeId = overrides and overrides.C2NodeId or string.format("c2-%d", ulidCounter),
		NodeName = overrides and overrides.NodeName,
	}
	if overrides then
		for k, v in pairs(overrides) do
			base[k] = v
		end
	end
	return base
end

-- == Tests ==

TestC2NodeStore = {}

function TestC2NodeStore:setUp()
	ulidCounter = 0
	self.store = Medusa.Services.C2NodeStore:new()
end

function TestC2NodeStore:test_add_and_get()
	local node = makeC2Node({ C2NodeId = "c2-1", NodeName = "HQ-Alpha" })
	self.store:add(node)

	lu.assertEquals(self.store:count(), 1)
	lu.assertIs(self.store:get("c2-1"), node)
end

function TestC2NodeStore:test_get_by_node_name()
	local node = makeC2Node({ C2NodeId = "c2-1", NodeName = "HQ-Alpha" })
	self.store:add(node)

	lu.assertIs(self.store:getByNodeName("HQ-Alpha"), node)
end

function TestC2NodeStore:test_get_by_node_name_returns_nil_for_unknown()
	lu.assertIsNil(self.store:getByNodeName("no-such-name"))
end

function TestC2NodeStore:test_add_with_nil_node_name()
	local node = makeC2Node({ C2NodeId = "c2-1" })
	self.store:add(node)

	lu.assertEquals(self.store:count(), 1)
	lu.assertIs(self.store:get("c2-1"), node)
end

function TestC2NodeStore:test_duplicate_add_errors()
	self.store:add(makeC2Node({ C2NodeId = "c2-1", NodeName = "HQ-Alpha" }))

	lu.assertErrorMsgContains("duplicate C2NodeId: c2-1", function()
		self.store:add(makeC2Node({ C2NodeId = "c2-1", NodeName = "HQ-Bravo" }))
	end)
end

function TestC2NodeStore:test_remove_returns_entity_and_cleans_all_indexes()
	local node = makeC2Node({ C2NodeId = "c2-1", NodeName = "HQ-Alpha" })
	self.store:add(node)

	local removed = self.store:remove("c2-1")
	lu.assertIs(removed, node)
	lu.assertEquals(self.store:count(), 0)
	lu.assertIsNil(self.store:get("c2-1"))
	lu.assertIsNil(self.store:getByNodeName("HQ-Alpha"))
end

function TestC2NodeStore:test_remove_with_nil_node_name()
	local node = makeC2Node({ C2NodeId = "c2-1" })
	self.store:add(node)

	local removed = self.store:remove("c2-1")
	lu.assertIs(removed, node)
	lu.assertEquals(self.store:count(), 0)
end

function TestC2NodeStore:test_remove_nonexistent_returns_nil()
	lu.assertIsNil(self.store:remove("no-such-id"))
end

function TestC2NodeStore:test_getAll_with_buffer_reuse()
	self.store:add(makeC2Node({ C2NodeId = "c2-1", NodeName = "HQ-Alpha" }))
	self.store:add(makeC2Node({ C2NodeId = "c2-2", NodeName = "HQ-Bravo" }))

	local buffer = { "stale-1", "stale-2", "stale-3" }
	local result = self.store:getAll(buffer)

	lu.assertIs(result, buffer)
	lu.assertEquals(#result, 2)
end

function TestC2NodeStore:test_count_tracks_adds_and_removes()
	self.store:add(makeC2Node({ C2NodeId = "c2-1", NodeName = "HQ-Alpha" }))
	self.store:add(makeC2Node({ C2NodeId = "c2-2", NodeName = "HQ-Bravo" }))
	lu.assertEquals(self.store:count(), 2)

	self.store:remove("c2-1")
	lu.assertEquals(self.store:count(), 1)

	self.store:remove("c2-2")
	lu.assertEquals(self.store:count(), 0)
end
