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
	GetUnitDesc = function(unit)
		local name = unit and unit.getName and unit:getName() or ""
		if string.find(name, ".gci.", 1, true) or string.find(name, ".ewr.", 1, true) then
			return { attributes = { ["SAM SR"] = true } }
		end
		return { attributes = { ["SAM LL"] = true } }
	end
end

function TestIadsNetwork:tearDown()
	GetUnitDesc = origGetUnitDesc
end

function TestIadsNetwork:test_initialize_registers_barrage_limit_before_start()
	local barrageState = Medusa.Services.AaaService.newBarrageState()
	local iads = Medusa.Core.IadsNetwork:new({
		id = "limit-net",
		coalitionId = COAL_RED,
		prefix = "iads",
		doctrine = { AAA = { MaxBarrageGroups = 7 } },
		aaaBarrageState = barrageState,
	})

	iads:initialize()

	lu.assertEquals(barrageState.limitsByNetwork["limit-net"], 7)
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

function TestIadsNetwork:test_battery_datalink_excludes_independent_aaa()
	local iads = makeIads()
	iads:initialize()
	iads._doctrine = { BatteryTargetDatalink = true }
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 202,
		GroupName = "iads.alpha.aaa.site1",
		Role = Medusa.Constants.BatteryRole.AAA,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
	})
	iads:getAssetIndex():batteries():add(battery)

	lu.assertEquals(iads:_buildPollList(), {})
end

function TestIadsNetwork:test_poll_list_classifies_track_origin_sources()
	local iads = makeIads()
	iads:initialize()
	iads._doctrine = { BatteryTargetDatalink = true }
	local sensors = iads:getAssetIndex():sensors()
	local batteries = iads:getAssetIndex():batteries()
	local sensorType = Medusa.Constants.SensorType

	sensors:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 1,
		UnitName = "awacs",
		GroupId = 1,
		GroupName = "awacs-group",
		SensorType = sensorType.AWACS,
		IsAirborne = true,
		GroupCategory = Group.Category.AIRPLANE,
	}))
	sensors:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 2,
		UnitName = "ewr",
		GroupId = 2,
		GroupName = "ewr-group",
		SensorType = sensorType.EWR,
		GroupCategory = Group.Category.GROUND,
	}))
	sensors:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 3,
		UnitName = "ship",
		GroupId = 3,
		GroupName = "ship-group",
		SensorType = sensorType.EWR,
		GroupCategory = Group.Category.SHIP,
	}))
	sensors:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 4,
		UnitName = "fighter",
		GroupId = 4,
		GroupName = "fighter-group",
		SensorType = sensorType.GCI,
		IsAirborne = true,
		GroupCategory = Group.Category.AIRPLANE,
	}))
	batteries:add(Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 5,
		GroupName = "sam-group",
		GroupCategory = Group.Category.GROUND,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
	}))
	batteries:add(Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 6,
		GroupName = "sam-ship-group",
		GroupCategory = Group.Category.SHIP,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
	}))

	local byName = {}
	for _, source in ipairs(iads:_buildPollList()) do
		byName[source.groupName] = source.sourceType
	end

	local trackSource = Medusa.Constants.TrackSource
	lu.assertEquals(byName["awacs-group"], trackSource.AWACS)
	lu.assertEquals(byName["ewr-group"], trackSource.EARLY_WARNING_RADAR)
	lu.assertEquals(byName["ship-group"], trackSource.SHIPBORNE_RADAR)
	lu.assertEquals(byName["fighter-group"], trackSource.AIRBORNE_DATALINK)
	lu.assertEquals(byName["sam-group"], trackSource.SAM_BATTERY)
	lu.assertEquals(byName["sam-ship-group"], trackSource.SHIPBORNE_RADAR)
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

local function localDefenseUnit(unitId, role)
	return Medusa.Entities.Battery.newUnit({
		UnitId = unitId,
		UnitName = "local-defense-" .. tostring(unitId),
		Roles = { role },
		AmmoCount = 10,
		AmmoTypes = {
			{
				Count = 10,
				RangeMax = 5000,
			},
		},
	})
end

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

function TestIadsNetwork:test_destroyed_aaa_member_suppresses_surviving_battery()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	local batteryStore = iads:getAssetIndex():batteries()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 750,
		GroupName = "iads.alpha.aaa.site1",
		Role = Medusa.Constants.BatteryRole.AAA,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		GroupDiameterM = 0,
	})
	battery.Units = {
		localDefenseUnit(65, Medusa.Constants.BatteryUnitRole.AAA),
		localDefenseUnit(66, Medusa.Constants.BatteryUnitRole.AAA),
	}
	batteryStore:add(battery)

	iads._deathQueue:enqueue({ _unitId = 65 })
	iads:_processDeathEvents(2)

	lu.assertEquals(#battery.Units, 1)
	lu.assertEquals(battery.OperationalStatus, Medusa.Constants.BatteryOperationalStatus.ACTIVE)
	lu.assertEquals(battery.CrewSuppressionState, Medusa.Constants.CrewSuppressionState.SUPPRESSED)
	lu.assertEquals(battery.CrewSuppressionCause, Medusa.Constants.CrewSuppressionCause.DAMAGE)
	lu.assertNotNil(battery.CrewSuppressionTimerId)
	lu.assertEquals(battery.ActivationState, Medusa.Constants.ActivationState.STATE_COLD)
end

function TestIadsNetwork:test_destroyed_manpad_member_suppresses_surviving_group()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 760,
		GroupName = "iads.alpha.manpad.team1",
		Role = Medusa.Constants.BatteryRole.MANPAD,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		GroupDiameterM = 0,
		Manpad = {
			SleepWakeState = Medusa.Constants.Manpad.SleepWakeState.HOT,
			WakeReason = Medusa.Constants.Manpad.WakeReason.IADS,
			AlertCycleCount = 0,
			AudioCueRangeM = Medusa.Constants.Manpad.AUDIO_RANGE_MAX_M,
			UnitHeadings = {},
			UnitHeadingCount = 0,
		},
	})
	battery.Units = {
		localDefenseUnit(67, Medusa.Constants.BatteryUnitRole.MANPAD),
		localDefenseUnit(68, Medusa.Constants.BatteryUnitRole.MANPAD),
	}
	iads:getAssetIndex():manpads():add(battery)

	iads._deathQueue:enqueue({ _unitId = 67 })
	iads:_processDeathEvents(2)

	lu.assertEquals(#battery.Units, 1)
	lu.assertEquals(battery.OperationalStatus, Medusa.Constants.BatteryOperationalStatus.ACTIVE)
	lu.assertEquals(battery.CrewSuppressionState, Medusa.Constants.CrewSuppressionState.SUPPRESSED)
	lu.assertEquals(battery.CrewSuppressionCause, Medusa.Constants.CrewSuppressionCause.DAMAGE)
	lu.assertNotNil(battery.CrewSuppressionTimerId)
	lu.assertEquals(battery.Manpad.SleepWakeState, Medusa.Constants.Manpad.SleepWakeState.ALERT)
	lu.assertEquals(battery.ActivationState, Medusa.Constants.ActivationState.STATE_COLD)
end

function TestIadsNetwork:test_death_removes_battery_when_all_dead()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	local batteryStore = iads:getAssetIndex():batteries()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 800,
		GroupName = "iads.alpha.aaa.last",
		Role = Medusa.Constants.BatteryRole.AAA,
		GroupDiameterM = 0,
	})
	battery.Units = {
		localDefenseUnit(70, Medusa.Constants.BatteryUnitRole.AAA),
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
	lu.assertEquals(battery.CrewSuppressionState, Medusa.Constants.CrewSuppressionState.CLEAR)
	lu.assertNil(battery.CrewSuppressionTimerId)
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

TestIadsSuppressionEvents = {}

function TestIadsSuppressionEvents:setUp()
	self.originalBus = HarnessWorldEventBus
	self.originalGetTime = GetTime
	self.originalInfo = env.info
	self.originalLogLevel = Medusa.Logger:getLevel()
	self.messages = {}
	env.info = function(message)
		self.messages[#self.messages + 1] = message
	end
	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.DEBUG)
	self.now = 1000
	GetTime = function()
		return self.now
	end
	HarnessWorldEventBus = CreateHarnessWorldEventBus()
end

function TestIadsSuppressionEvents:tearDown()
	HarnessWorldEventBus:dispose()
	HarnessWorldEventBus = self.originalBus
	GetTime = self.originalGetTime
	env.info = self.originalInfo
	Medusa.Logger:setLevel(self.originalLogLevel)
end

local function hitEvent(unitId, coalitionId)
	return {
		initiator = {},
		target = {
			getCoalition = function()
				return coalitionId or COAL_RED
			end,
			getID = function()
				return unitId
			end,
		},
	}
end

function TestIadsSuppressionEvents:test_hit_boundary_rejects_missing_or_invalid_fields()
	local iads = makeIads()
	iads:initialize()

	HarnessWorldEventBus:publish({ id = world.event.S_EVENT_HIT })
	HarnessWorldEventBus:publish({ id = world.event.S_EVENT_HIT, initiator = {} })
	HarnessWorldEventBus:publish(hitEvent(10, coalition.side.BLUE))
	HarnessWorldEventBus:publish({
		id = world.event.S_EVENT_HIT,
		initiator = {},
		target = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})

	lu.assertTrue(iads._hitQueue:isEmpty())
end

function TestIadsSuppressionEvents:test_hit_boundary_translates_to_bounded_unit_record()
	local iads = makeIads()
	iads:initialize()
	local capacity = Medusa.Constants.CrewSuppression.HIT_EVENT_QUEUE_CAPACITY

	for unitId = 1, capacity + 1 do
		local event = hitEvent(unitId)
		event.id = world.event.S_EVENT_HIT
		HarnessWorldEventBus:publish(event)
	end

	lu.assertEquals(iads._hitQueue:size(), capacity)
	lu.assertEquals(iads._hitQueue:pop().TargetUnitId, 2)
end

function TestIadsSuppressionEvents:test_debug_trace_reports_hit_and_death_processing_paths()
	local iads = makeIads()
	iads:initialize()
	self.messages = {}

	local event = hitEvent(10)
	event.id = world.event.S_EVENT_HIT
	HarnessWorldEventBus:publish(event)
	iads:_processHitEvents(1)
	iads._deathQueue:enqueue({ _unitId = 10 })
	iads:_processDeathEvents(1)

	local output = table.concat(self.messages, "\n")
	lu.assertStrContains(output, "crew suppression HIT queued: targetUnitId=10")
	lu.assertStrContains(output, "processing crew suppression HIT: targetUnitId=10")
	lu.assertStrContains(output, "damage evaluation rejected: unitId=10 is not managed")
	lu.assertStrContains(output, "crew suppression HIT processed: targetUnitId=10 applied=false")
	lu.assertStrContains(output, "processing death event: unitId=10")
	lu.assertStrContains(output, "death event ignored: unitId=10 is not managed")
end

function TestIadsSuppressionEvents:test_hit_processing_obeys_budget_and_expiry()
	local iads = makeIads()
	iads:initialize()

	for unitId = 1, 3 do
		local event = hitEvent(unitId)
		event.id = world.event.S_EVENT_HIT
		HarnessWorldEventBus:publish(event)
	end
	lu.assertEquals(iads:_processHitEvents(2), 2)
	lu.assertEquals(iads._hitQueue:size(), 1)

	self.now = self.now + Medusa.Constants.CrewSuppression.HIT_EVENT_MAX_AGE_SEC + 1
	lu.assertEquals(iads:_processHitEvents(2), 1)
	lu.assertTrue(iads._hitQueue:isEmpty())
end

function TestIadsSuppressionEvents:test_stop_and_restart_replace_hit_subscription()
	local iads = makeIads()
	iads:initialize()
	lu.assertEquals(#HarnessWorldEventBus._subscribers[world.event.S_EVENT_HIT], 1)
	for unitId = 1, 2 do
		local event = hitEvent(unitId)
		event.id = world.event.S_EVENT_HIT
		HarnessWorldEventBus:publish(event)
	end
	lu.assertEquals(iads:_processHitEvents(1), 1)
	lu.assertStrContains(
		Medusa.Services.MetricsService.serialize(),
		'medusa_crew_suppression_event_queue_depth{network="T"} 1'
	)

	iads:stop()
	lu.assertIsNil(HarnessWorldEventBus._subscribers[world.event.S_EVENT_HIT])
	lu.assertTrue(iads._hitQueue:isEmpty())

	iads:start()
	iads:start()
	lu.assertEquals(#HarnessWorldEventBus._subscribers[world.event.S_EVENT_HIT], 1)
	iads:stop()
end

function TestIadsSuppressionEvents:test_disabled_doctrine_does_not_subscribe_to_hit_events()
	local iads = Medusa.Core.IadsNetwork:new({
		id = "T",
		coalitionId = COAL_RED,
		prefix = "iads",
		doctrine = { CrewSuppression = { Enabled = false } },
	})

	iads:initialize()

	lu.assertIsNil(HarnessWorldEventBus._subscribers[world.event.S_EVENT_HIT])
end
