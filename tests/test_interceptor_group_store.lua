local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("services.Services")
require("services.stores.InterceptorGroupStore")

-- == Helpers ==

local function makeInterceptorGroup(groupId, groupName)
	return {
		InterceptorGroupId = groupId,
		GroupName = groupName,
	}
end

-- == Tests ==

TestInterceptorGroupStore = {}

function TestInterceptorGroupStore:setUp()
	self.store = Medusa.Services.InterceptorGroupStore:new()
end

function TestInterceptorGroupStore:test_add_and_get()
	local group = makeInterceptorGroup("ig-1", "Viper-1")
	self.store:add(group)

	lu.assertEquals(self.store:count(), 1)
	lu.assertIs(self.store:get("ig-1"), group)
end

function TestInterceptorGroupStore:test_get_by_group_name()
	local group = makeInterceptorGroup("ig-1", "Viper-1")
	self.store:add(group)

	lu.assertIs(self.store:getByGroupName("Viper-1"), group)
end

function TestInterceptorGroupStore:test_get_by_group_name_returns_nil_for_unknown()
	lu.assertIsNil(self.store:getByGroupName("no-such-group"))
end

function TestInterceptorGroupStore:test_duplicate_add_errors()
	self.store:add(makeInterceptorGroup("ig-1", "Viper-1"))

	lu.assertErrorMsgContains("duplicate InterceptorGroupId: ig-1", function()
		self.store:add(makeInterceptorGroup("ig-1", "Eagle-1"))
	end)
end

function TestInterceptorGroupStore:test_remove_returns_entity_and_cleans_all_indexes()
	local group = makeInterceptorGroup("ig-1", "Viper-1")
	self.store:add(group)

	local removed = self.store:remove("ig-1")
	lu.assertIs(removed, group)
	lu.assertEquals(self.store:count(), 0)
	lu.assertIsNil(self.store:get("ig-1"))
	lu.assertIsNil(self.store:getByGroupName("Viper-1"))
end

function TestInterceptorGroupStore:test_remove_nonexistent_returns_nil()
	lu.assertIsNil(self.store:remove("no-such-id"))
end

function TestInterceptorGroupStore:test_getAll_with_buffer_reuse()
	self.store:add(makeInterceptorGroup("ig-1", "Viper-1"))
	self.store:add(makeInterceptorGroup("ig-2", "Eagle-1"))

	local buffer = { "stale-1", "stale-2", "stale-3" }
	local result = self.store:getAll(buffer)

	lu.assertIs(result, buffer)
	lu.assertEquals(#result, 2)
end

function TestInterceptorGroupStore:test_count_tracks_adds_and_removes()
	self.store:add(makeInterceptorGroup("ig-1", "Viper-1"))
	self.store:add(makeInterceptorGroup("ig-2", "Eagle-1"))
	lu.assertEquals(self.store:count(), 2)

	self.store:remove("ig-1")
	lu.assertEquals(self.store:count(), 1)

	self.store:remove("ig-2")
	lu.assertEquals(self.store:count(), 0)
end
