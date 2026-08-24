local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("services.Services")
require("services.stores.C2NodeStore")

-- == Helpers ==

local function makeC2Node(overrides)
	local base = {
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
	self.unitIndex = Medusa.Services.UnitIndex:new()
	self.store = Medusa.Services.C2NodeStore:new(self.unitIndex)
end

function TestC2NodeStore:test_add_and_get_by_node_name()
	local node = makeC2Node({ NodeName = "HQ-Alpha" })
	self.store:add(node)

	lu.assertEquals(self.store:count(), 1)
	lu.assertIs(self.store:getByNodeName("HQ-Alpha"), node)
end

function TestC2NodeStore:test_capacity_rejects_additional_command_center_without_growth()
	for i = 1, Medusa.Constants.C2.MAX_COMMAND_CENTERS do
		self.store:add(makeC2Node({ NodeName = "HQ-" .. i }))
	end

	lu.assertError(function()
		self.store:add(makeC2Node({ NodeName = "HQ-overflow" }))
	end)
	lu.assertEquals(self.store:count(), Medusa.Constants.C2.MAX_COMMAND_CENTERS)
	lu.assertNil(self.store:getByNodeName("HQ-overflow"))
end

function TestC2NodeStore:test_get_by_node_name_returns_nil_for_unknown()
	lu.assertIsNil(self.store:getByNodeName("no-such-name"))
end

function TestC2NodeStore:test_add_without_node_name_errors()
	lu.assertErrorMsgContains("missing NodeName", function()
		self.store:add(makeC2Node())
	end)
	lu.assertEquals(self.store:count(), 0)
end

function TestC2NodeStore:test_duplicate_add_errors()
	self.store:add(makeC2Node({ NodeName = "HQ-Alpha" }))

	lu.assertErrorMsgContains("duplicate NodeName: HQ-Alpha", function()
		self.store:add(makeC2Node({ NodeName = "HQ-Alpha" }))
	end)
end

function TestC2NodeStore:test_duplicate_provider_rejects_node_without_publishing_any_index()
	local existing = { UnitId = 41, UnitName = "HQ-alpha-provider", Available = true }
	self.store:add(makeC2Node({ NodeName = "HQ-Alpha", Providers = { existing } }))

	local unique = { UnitId = 42, UnitName = "HQ-bravo-primary", Available = true }
	local conflict = { UnitId = 41, UnitName = "HQ-bravo-secondary", Available = true }
	lu.assertErrorMsgContains("duplicate command provider UnitId: 41", function()
		self.store:add(makeC2Node({
			NodeName = "HQ-Bravo",
			Providers = { unique, conflict },
		}))
	end)

	lu.assertEquals(self.store:count(), 1)
	lu.assertNil(self.store:getByNodeName("HQ-Bravo"))
	lu.assertNil(self.unitIndex:getRegisteredOwner(42, Medusa.Constants.UnitOwnerKind.COMMAND_PROVIDER))
	lu.assertIs(self.unitIndex:getRegisteredOwner(41, Medusa.Constants.UnitOwnerKind.COMMAND_PROVIDER), existing)
end

function TestC2NodeStore:test_duplicate_provider_within_node_rejects_node()
	local first = { UnitId = 41, UnitName = "HQ-primary", Available = true }
	local second = { UnitId = 41, UnitName = "HQ-secondary", Available = true }

	lu.assertErrorMsgContains("duplicate command provider UnitId: 41", function()
		self.store:add(makeC2Node({
			NodeName = "HQ-Alpha",
			Providers = { first, second },
		}))
	end)

	lu.assertEquals(self.store:count(), 0)
	lu.assertNil(self.store:getByNodeName("HQ-Alpha"))
	lu.assertNil(self.unitIndex:getRegisteredOwner(41, Medusa.Constants.UnitOwnerKind.COMMAND_PROVIDER))
end

function TestC2NodeStore:test_getAll_with_buffer_reuse()
	self.store:add(makeC2Node({ NodeName = "HQ-Alpha" }))
	self.store:add(makeC2Node({ NodeName = "HQ-Bravo" }))

	local buffer = { "stale-1", "stale-2", "stale-3" }
	local result = self.store:getAll(buffer)

	lu.assertIs(result, buffer)
	lu.assertEquals(#result, 2)
end

function TestC2NodeStore:test_count_tracks_adds()
	self.store:add(makeC2Node({ NodeName = "HQ-Alpha" }))
	self.store:add(makeC2Node({ NodeName = "HQ-Bravo" }))
	lu.assertEquals(self.store:count(), 2)
end

function TestC2NodeStore:test_restores_the_selected_provider_with_a_new_unit_id()
	local provider = { UnitId = 41, UnitName = "HQ-provider", Available = true }
	self.store:add(makeC2Node({
		NodeName = "HQ-Alpha",
		Providers = { provider },
	}))
	self.store:setProviderUnavailable(provider)
	self.store:markProviderAvailable(provider, 51)

	lu.assertTrue(provider.Available)
	lu.assertNil(self.unitIndex:getRegisteredOwner(41, Medusa.Constants.UnitOwnerKind.COMMAND_PROVIDER))
	lu.assertIs(self.unitIndex:getRegisteredOwner(51, Medusa.Constants.UnitOwnerKind.COMMAND_PROVIDER), provider)
end

function TestC2NodeStore:test_reused_unit_id_retires_the_previous_provider_owner()
	local first = { UnitId = 41, UnitName = "HQ-alpha-provider", Available = true }
	local second = { UnitId = 42, UnitName = "HQ-bravo-provider", Available = false }
	self.store:add(makeC2Node({ NodeName = "HQ-Alpha", Providers = { first } }))
	self.store:add(makeC2Node({ NodeName = "HQ-Bravo", Providers = { second } }))

	self.store:markProviderAvailable(second, 41)

	lu.assertFalse(first.Available)
	lu.assertTrue(second.Available)
	lu.assertEquals(second.UnitId, 41)
	lu.assertIs(self.unitIndex:getRegisteredOwner(41, Medusa.Constants.UnitOwnerKind.COMMAND_PROVIDER), second)
end
