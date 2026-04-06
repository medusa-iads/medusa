local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Config")
require("core.IadsNetwork")
require("entities.SensorUnit")
require("entities.Battery")

-- == Helpers ==

local function makeIads()
	return Medusa.Core.IadsNetwork:new({
		id = "T",
		coalitionId = (coalition and coalition.side and coalition.side.RED) or 1,
		prefix = "iads",
	})
end

local function injectProvider(iads, groups)
	iads._discovery._provider = {
		list = function()
			return groups
		end,
	}
end

local COAL_RED = (coalition and coalition.side and coalition.side.RED) or 1
local origGetUnitDesc

-- == Tests ==

TestIadsNetwork = {}

function TestIadsNetwork:setUp()
	origGetUnitDesc = GetUnitDesc
	-- Return launcher attributes so batteries are not skipped by the hasLauncher guard.
	GetUnitDesc = function()
		return { attributes = { ["SAM LL"] = true } }
	end
end

function TestIadsNetwork:tearDown()
	GetUnitDesc = origGetUnitDesc
end

function TestIadsNetwork:test_initialize_and_tick_wires_discovery_to_hierarchy()
	local iads = makeIads()
	lu.assertTrue(iads:initialize())
	lu.assertTrue(iads:start())

	injectProvider(iads, {
		{
			groupId = 42,
			groupName = "iads.1bn.gci.alpha",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()
	local node = iads:getHierarchy():getNode({ "1bn" })
	lu.assertNotNil(node)
	lu.assertTrue(node.groupsSet and node.groupsSet:contains(42))
end

function TestIadsNetwork:test_discovery_creates_battery_for_non_role_group()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{
			groupId = 100,
			groupName = "iads.alpha.sa6",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()

	local store = iads:getAssetIndex():batteries()
	lu.assertEquals(store:count(), 1)
	local battery = store:getByGroupId(100)
	lu.assertNotNil(battery)
	lu.assertEquals(battery.GroupName, "iads.alpha.sa6")
	lu.assertEquals(battery.NetworkId, "T")
end

function TestIadsNetwork:test_discovery_routes_gci_to_sensors()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{
			groupId = 200,
			groupName = "iads.alpha.gci.site1",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()

	lu.assertEquals(iads:getAssetIndex():batteries():count(), 0)
	local sensorNames = iads:getAssetIndex():sensors():getUniqueGroupNames()
	lu.assertEquals(#sensorNames, 1)
	lu.assertEquals(sensorNames[1], "iads.alpha.gci.site1")
end

function TestIadsNetwork:test_discovery_routes_ewr_to_sensors()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{
			groupId = 201,
			groupName = "iads.alpha.ewr.bigbird",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()

	lu.assertEquals(iads:getAssetIndex():batteries():count(), 0)
	local sensorNames = iads:getAssetIndex():sensors():getUniqueGroupNames()
	lu.assertEquals(#sensorNames, 1)
	lu.assertEquals(sensorNames[1], "iads.alpha.ewr.bigbird")
end

function TestIadsNetwork:test_discovery_routes_hq_to_c2nodes()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{
			groupId = 300,
			groupName = "iads.alpha.hq.cmd",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()

	lu.assertEquals(iads:getAssetIndex():batteries():count(), 0)
	lu.assertEquals(iads:getAssetIndex():sensors():count(), 0)
	lu.assertEquals(iads:getAssetIndex():c2Nodes():count(), 1)
end

function TestIadsNetwork:test_first_tick_initializes_batteries_cold()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{
			groupId = 400,
			groupName = "iads.alpha.sa10",
			coalitionId = COAL_RED,
			category = "ground",
		},
		{
			groupId = 401,
			groupName = "iads.alpha.sa11",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()

	local store = iads:getAssetIndex():batteries()
	lu.assertEquals(store:count(), 2)
	local all = store:getAll()
	-- Batteries stay INITIALIZING after tick 1 (doctrine states deferred 60s for fast erect)
	for i = 1, #all do
		lu.assertEquals(all[i].ActivationState, Medusa.Constants.ActivationState.INITIALIZING)
	end
end

function TestIadsNetwork:test_mixed_groups_route_correctly()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{ groupId = 500, groupName = "iads.alpha.sa6", coalitionId = COAL_RED, category = "ground" },
		{ groupId = 501, groupName = "iads.alpha.gci.site1", coalitionId = COAL_RED, category = "ground" },
		{ groupId = 502, groupName = "iads.alpha.hq.cmd", coalitionId = COAL_RED, category = "ground" },
		{ groupId = 503, groupName = "iads.alpha.sa11", coalitionId = COAL_RED, category = "ground" },
		{ groupId = 504, groupName = "iads.alpha.ewr.bigbird", coalitionId = COAL_RED, category = "ground" },
	})

	iads._tickCounter = 0
	iads:tick()

	-- 2 batteries (sa6, sa11), 2 sensor groups (gci, ewr), 1 HQ -> c2node
	lu.assertEquals(iads:getAssetIndex():batteries():count(), 2)
	lu.assertEquals(#iads:getAssetIndex():sensors():getUniqueGroupNames(), 2)
	lu.assertEquals(iads:getAssetIndex():c2Nodes():count(), 1)
end

-- == Death Event Tests ==

function TestIadsNetwork:test_death_removes_sensor()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	local sensorStore = iads:getAssetIndex():sensors()
	sensorStore:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 50,
		UnitName = "ewr-1",
		GroupId = 600,
		GroupName = "iads.alpha.ewr.site1",
		SensorType = "EWR",
	}))
	lu.assertEquals(sensorStore:count(), 1)

	iads._deathQueue:enqueue({
		_unitId = 50,
		initiator = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
	iads:_processDeathEvents(2)

	lu.assertEquals(sensorStore:count(), 0)
end

function TestIadsNetwork:test_death_removes_battery_unit()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	local batteryStore = iads:getAssetIndex():batteries()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 700,
		GroupName = "iads.alpha.sa10",
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({ UnitId = 60 }),
		Medusa.Entities.Battery.newUnit({ UnitId = 61 }),
	}
	batteryStore:add(battery)
	lu.assertEquals(batteryStore:count(), 1)
	lu.assertEquals(#battery.Units, 2)

	iads._deathQueue:enqueue({
		_unitId = 60,
		initiator = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
	iads:_processDeathEvents(2)

	lu.assertEquals(batteryStore:count(), 1)
	lu.assertEquals(#battery.Units, 1)
	lu.assertEquals(battery.Units[1].UnitId, 61)
end

function TestIadsNetwork:test_death_removes_battery_when_all_dead()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	local batteryStore = iads:getAssetIndex():batteries()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 800,
		GroupName = "iads.alpha.sa6",
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({ UnitId = 70 }),
	}
	batteryStore:add(battery)

	iads._deathQueue:enqueue({
		_unitId = 70,
		initiator = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
	iads:_processDeathEvents(2)

	lu.assertEquals(batteryStore:count(), 0)
end

function TestIadsNetwork:test_death_ignores_unknown_unit()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	local sensorStore = iads:getAssetIndex():sensors()
	local batteryStore = iads:getAssetIndex():batteries()

	iads._deathQueue:enqueue({
		_unitId = 999,
		initiator = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
	iads:_processDeathEvents(2)

	lu.assertEquals(sensorStore:count(), 0)
	lu.assertEquals(batteryStore:count(), 0)
end
