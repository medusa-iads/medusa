local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("services.HierarchyService")

TestHierarchyService = {}

local function dto(groupId, name, roles, isHQ, path)
	return {
		groupId = groupId,
		groupName = name,
		coalitionId = (coalition and coalition.side and coalition.side.RED) or 1,
		category = "ground",
		parsed = {
			roles = roles,
			isHQ = isHQ,
			echelonPath = path,
		},
	}
end

function TestHierarchyService:test_upsert_and_get()
	local svc = Medusa.Services.HierarchyService:new()
	local d = dto(1, "iads.alpha.gci.1bn", { "GCI" }, false, { "1bn", "1bde" })
	lu.assertTrue(svc:upsertGroup(d))
	local node = svc:getNode({ "1bn", "1bde" })
	lu.assertNotNil(node)
	lu.assertNotNil(node.groupsSet)
	lu.assertTrue(node.groupsSet and node.groupsSet.contains and node.groupsSet:contains(1))
end

function TestHierarchyService:test_remove()
	local svc = Medusa.Services.HierarchyService:new()
	local d = dto(2, "iads.cp.hq.1div", { "HQ" }, true, { "1div" })
	lu.assertTrue(svc:upsertGroup(d))
	lu.assertTrue(svc:removeGroup(2))
	local node = svc:getNode({ "1div" })
	lu.assertNotNil(node)
	lu.assertTrue((not node.groupsSet) or (node.groupsSet.contains and (not node.groupsSet:contains(2))))
end
