local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("entities.Battery")
require("entities.C2Node")
require("entities.SensorUnit")
require("services.EntityFactory")
require("services.GroupNameParser")
require("services.HierarchyService")
require("services.PartitionService")
require("services.stores.BatteryStore")
require("services.stores.C2NodeStore")
require("services.stores.SensorUnitStore")

local C = Medusa.Constants
local PartitionService = Medusa.Services.PartitionService

local function makeBattery(id, groupId, x)
	local battery = Medusa.Entities.Battery.new({
		BatteryId = id,
		NetworkId = "net",
		GroupId = groupId,
		GroupName = id,
		Role = C.BatteryRole.LR_SAM,
		Position = { x = x or 0, y = 0, z = 0 },
		ActivationState = C.ActivationState.STATE_WARM,
		OperationalStatus = C.BatteryOperationalStatus.ACTIVE,
		DetectionRangeMax = 100,
		EngagementRangeMax = 100,
		TotalAmmoStatus = 4,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = groupId * 10,
			UnitName = id .. "-radar",
			Roles = { C.BatteryUnitRole.SEARCH_RADAR },
		}),
	}
	return battery
end

local function makeSensor(id, groupId, x, radius, sensorType)
	return Medusa.Entities.SensorUnit.new({
		SensorUnitId = id,
		NetworkId = "net",
		UnitId = groupId * 10,
		UnitName = id,
		GroupId = groupId,
		GroupName = id,
		SensorType = sensorType or C.SensorType.EWR,
		Position = { x = x or 0, y = 0, z = 0 },
		DetectionRangeMax = radius or 1000,
	})
end

local function addGroup(hierarchy, groupId, groupName, path, isHQ)
	hierarchy:upsertGroup({
		groupId = groupId,
		groupName = groupName,
		parsed = { echelonPath = path or {}, roles = {}, isHQ = isHQ == true },
	})
end

local function makeContext()
	local repository = Medusa.Services.BatteryStore:new()
	return {
		hierarchy = Medusa.Services.HierarchyService:new(),
		batteryRepository = repository,
		sensorStore = Medusa.Services.SensorUnitStore:new(),
		c2NodeStore = Medusa.Services.C2NodeStore:new(),
		doctrine = {
			DegradedMode = C.NetworkDegradationPolicy.REVERT_TO_AUTONOMOUS,
			MaxEngageRangePct = nil,
		},
	}
end

local function addBattery(ctx, battery, path)
	addGroup(ctx.hierarchy, battery.GroupId, battery.GroupName, path, false)
	ctx.batteryRepository:add(battery)
end

local function addSensor(ctx, sensor, path)
	addGroup(ctx.hierarchy, sensor.GroupId, sensor.GroupName, path, false)
	ctx.sensorStore:add(sensor)
end

local function refresh(ctx, previous)
	ctx.hierarchy:freezeC2Topology()
	local pending = PartitionService.begin(ctx, previous or { PartitionByCluster = {} })
	local steps = 0
	while true do
		steps = steps + 1
		if PartitionService.step(pending) then
			return pending, steps
		end
		if steps > 200 then
			error("partition refresh did not complete")
		end
	end
end

local function capturedBattery(snapshot, battery)
	for i = 1, #snapshot.Batteries do
		if snapshot.Batteries[i].BatteryId == battery.BatteryId then
			return snapshot.Batteries[i]
		end
	end
	return nil
end

local function capturedSensor(snapshot, sensor)
	for i = 1, #snapshot.Sensors do
		if snapshot.Sensors[i].SensorUnitId == sensor.SensorUnitId then
			return snapshot.Sensors[i]
		end
	end
	return nil
end

local function partitionForBattery(snapshot, battery)
	local captured = capturedBattery(snapshot, battery)
	return captured and snapshot.PartitionByCluster[captured.ClusterKey] or nil
end

TestPartitionService = {}

function TestPartitionService:test_unsustained_component_remains_a_partition_and_battery_is_degraded()
	local ctx = makeContext()
	local battery = makeBattery("sam", 1)
	addBattery(ctx, battery, { "west" })

	local snapshot = refresh(ctx)
	local partition = partitionForBattery(snapshot, battery)

	lu.assertNotNil(partition)
	lu.assertFalse(partition.Sustained)
	lu.assertNotNil(capturedBattery(snapshot, battery).PartitionKey)
	lu.assertEquals(capturedBattery(snapshot, battery).CoordinationState, C.CoordinationState.DEGRADED)
end

function TestPartitionService:test_no_command_centers_form_one_virtual_root_component()
	local ctx = makeContext()
	local sensor = makeSensor("ewr", 1)
	local battery = makeBattery("sam", 2)
	addSensor(ctx, sensor, { "west" })
	addBattery(ctx, battery, { "east" })

	local snapshot = refresh(ctx)

	lu.assertEquals(capturedSensor(snapshot, sensor).PartitionKey, capturedBattery(snapshot, battery).PartitionKey)
	lu.assertTrue(partitionForBattery(snapshot, battery).Sustained)
	lu.assertEquals(capturedBattery(snapshot, battery).CoordinationState, C.CoordinationState.COORDINATED)
end

function TestPartitionService:test_root_command_centers_gate_connections_between_sibling_branches()
	local ctx = makeContext()
	local batteries = {
		root = makeBattery("root-sam", 1),
		east = makeBattery("east-sam", 2),
		west = makeBattery("west-sam", 3),
	}
	addBattery(ctx, batteries.root, {})
	addBattery(ctx, batteries.east, { "east" })
	addBattery(ctx, batteries.west, { "west" })

	local commandCenters = {
		{ GroupId = 10, NodeName = "root-hq-a", Path = {}, UnitId = 100 },
		{ GroupId = 11, NodeName = "root-hq-b", Path = {}, UnitId = 110 },
		{ GroupId = 12, NodeName = "east-hq", Path = { "east" }, UnitId = 120 },
		{ GroupId = 13, NodeName = "west-hq", Path = { "west" }, UnitId = 130 },
	}
	local nodes = {}
	for i = 1, #commandCenters do
		local command = commandCenters[i]
		addGroup(ctx.hierarchy, command.GroupId, command.NodeName, command.Path, true)
		local node = Medusa.Entities.C2Node.new({
			GroupId = command.GroupId,
			NodeName = command.NodeName,
			Providers = { { UnitId = command.UnitId, UnitName = command.NodeName .. "-1", Available = true } },
		})
		ctx.c2NodeStore:add(node)
		nodes[command.NodeName] = node
	end

	local connected = refresh(ctx)
	lu.assertEquals(ctx.hierarchy:getC2Topology().RootCommandCenterGroupIds, { 10, 11 })
	lu.assertIs(partitionForBattery(connected, batteries.root), partitionForBattery(connected, batteries.east))
	lu.assertIs(partitionForBattery(connected, batteries.root), partitionForBattery(connected, batteries.west))

	nodes["root-hq-a"].Providers[1].Available = false
	local redundantRoot = refresh(ctx, connected)
	lu.assertIs(partitionForBattery(redundantRoot, batteries.root), partitionForBattery(redundantRoot, batteries.east))
	lu.assertIs(partitionForBattery(redundantRoot, batteries.root), partitionForBattery(redundantRoot, batteries.west))

	nodes["root-hq-b"].Providers[1].Available = false
	local split = refresh(ctx, redundantRoot)
	lu.assertNotIs(partitionForBattery(split, batteries.root), partitionForBattery(split, batteries.east))
	lu.assertNotIs(partitionForBattery(split, batteries.root), partitionForBattery(split, batteries.west))
	lu.assertNotIs(partitionForBattery(split, batteries.east), partitionForBattery(split, batteries.west))

	nodes["root-hq-a"].Providers[1].Available = true
	local restored = refresh(ctx, split)
	lu.assertIs(partitionForBattery(restored, batteries.root), partitionForBattery(restored, batteries.east))
	lu.assertIs(partitionForBattery(restored, batteries.root), partitionForBattery(restored, batteries.west))
end

function TestPartitionService:test_command_center_loss_splits_components_and_changes_partition_keys()
	local ctx = makeContext()
	local sensor = makeSensor("root-ewr", 1)
	local battery = makeBattery("child-sam", 3)
	addSensor(ctx, sensor, {})
	addGroup(ctx.hierarchy, 2, "child-hq", { "child" }, true)
	addBattery(ctx, battery, { "child" })
	local hq = Medusa.Entities.C2Node.new({
		GroupId = 2,
		NodeName = "child-hq",
		Providers = { { UnitId = 20, UnitName = "child-hq-1", Available = true } },
	})
	ctx.c2NodeStore:add(hq)

	local connected = refresh(ctx)
	local connectedKey = capturedBattery(connected, battery).PartitionKey
	lu.assertEquals(connectedKey, capturedSensor(connected, sensor).PartitionKey)

	hq.Providers[1].Available = false
	local split = refresh(ctx, connected)

	lu.assertNotEquals(capturedBattery(split, battery).PartitionKey, connectedKey)
	lu.assertNotEquals(capturedBattery(split, battery).PartitionKey, capturedSensor(split, sensor).PartitionKey)
	lu.assertFalse(partitionForBattery(split, battery).Sustained)
	lu.assertEquals(capturedBattery(split, battery).CoordinationState, C.CoordinationState.DEGRADED)
end

--- Verifies nearest-ancestor inheritance through one missing HQ and independent sibling-branch splits.
function TestPartitionService:test_four_level_hierarchy_skips_a_missing_hq_across_sibling_branches()
	local ctx = makeContext()
	local batteries = {
		root = makeBattery("pt.sam-root", 201),
		level1 = makeBattery("pt.1front.sam-front", 202),
		level2 = makeBattery("pt.1front.1army.sam-army", 203),
		level3 = makeBattery("pt.1front.1army.1corps.sam-corps", 204),
		level4 = makeBattery("pt.1front.1army.1corps.1div.sam-division", 205),
		siblingDeep = makeBattery("pt.1front.1army.2corps.sam-corps", 206),
		siblingTop = makeBattery("pt.2front.sam-front", 207),
	}
	local sensors = {
		root = makeSensor("pt.ewr.root", 101),
		level1 = makeSensor("pt.1front.ewr.local", 102),
		level2 = makeSensor("pt.1front.1army.ewr.local", 103),
		level3 = makeSensor("pt.1front.1army.1corps.ewr.local", 104),
		level4 = makeSensor("pt.1front.1army.1corps.1div.ewr.local", 105),
		siblingDeep = makeSensor("pt.1front.1army.2corps.ewr.local", 106),
		siblingTop = makeSensor("pt.2front.ewr.local", 107),
	}
	for name, battery in pairs(batteries) do
		local batteryPath = Medusa.Services.GroupNameParser:parse(battery.GroupName, "pt").echelonPath
		local sensorPath = Medusa.Services.GroupNameParser:parse(sensors[name].GroupName, "pt").echelonPath
		addBattery(ctx, battery, batteryPath)
		addSensor(ctx, sensors[name], sensorPath)
	end

	local hqs = {
		level1 = {
			GroupId = 301,
			NodeName = "pt.1front.hq.command",
			Provider = { UnitId = 3010, UnitName = "pt.1front.hq.command-1", Available = true },
		},
		level2 = {
			GroupId = 302,
			NodeName = "pt.1front.1army.hq.command",
			Provider = { UnitId = 3020, UnitName = "pt.1front.1army.hq.command-1", Available = true },
		},
		level4 = {
			GroupId = 304,
			NodeName = "pt.1front.1army.1corps.1div.hq.command",
			Provider = {
				UnitId = 3040,
				UnitName = "pt.1front.1army.1corps.1div.hq.command-1",
				Available = true,
			},
		},
		siblingDeep = {
			GroupId = 305,
			NodeName = "pt.1front.1army.2corps.hq.command",
			Provider = { UnitId = 3050, UnitName = "pt.1front.1army.2corps.hq.command-1", Available = true },
		},
		siblingTop = {
			GroupId = 306,
			NodeName = "pt.2front.hq.command",
			Provider = { UnitId = 3060, UnitName = "pt.2front.hq.command-1", Available = true },
		},
	}
	for _, hq in pairs(hqs) do
		local parsed = Medusa.Services.GroupNameParser:parse(hq.NodeName, "pt")
		ctx.hierarchy:upsertGroup({ groupId = hq.GroupId, groupName = hq.NodeName, parsed = parsed })
		ctx.c2NodeStore:add(Medusa.Entities.C2Node.new({
			GroupId = hq.GroupId,
			NodeName = hq.NodeName,
			Providers = { hq.Provider },
		}))
	end

	local topology = ctx.hierarchy:freezeC2Topology()
	lu.assertEquals(topology.ClusterKeys, {
		"",
		"1front",
		"1front.1army",
		"1front.1army.1corps.1div",
		"1front.1army.2corps",
		"2front",
	})
	lu.assertEquals(topology.Edges[3].ParentKey, "1front.1army")
	lu.assertEquals(topology.Edges[3].ChildKey, "1front.1army.1corps.1div")
	lu.assertEquals(topology.Edges[4].ParentKey, "1front.1army")
	lu.assertEquals(topology.Edges[4].ChildKey, "1front.1army.2corps")
	lu.assertEquals(topology.Edges[5].ParentKey, "")
	lu.assertEquals(topology.Edges[5].ChildKey, "2front")
	lu.assertEquals(ctx.hierarchy:clusterKeyForGroup(batteries.level3.GroupId), "1front.1army")
	lu.assertEquals(ctx.hierarchy:clusterKeyForGroup(batteries.level4.GroupId), "1front.1army.1corps.1div")

	local connected = refresh(ctx)
	lu.assertIs(partitionForBattery(connected, batteries.root), partitionForBattery(connected, batteries.level4))
	lu.assertIs(partitionForBattery(connected, batteries.root), partitionForBattery(connected, batteries.siblingTop))

	hqs.level2.Provider.Available = false
	local middleSplit = refresh(ctx, connected)
	lu.assertIs(partitionForBattery(middleSplit, batteries.root), partitionForBattery(middleSplit, batteries.level1))
	lu.assertIs(partitionForBattery(middleSplit, batteries.root), partitionForBattery(middleSplit, batteries.siblingTop))
	lu.assertIs(partitionForBattery(middleSplit, batteries.level2), partitionForBattery(middleSplit, batteries.level3))
	lu.assertIs(partitionForBattery(middleSplit, batteries.level2), partitionForBattery(middleSplit, batteries.level4))
	lu.assertIs(partitionForBattery(middleSplit, batteries.level2), partitionForBattery(middleSplit, batteries.siblingDeep))
	lu.assertNotIs(partitionForBattery(middleSplit, batteries.level1), partitionForBattery(middleSplit, batteries.level2))

	hqs.level4.Provider.Available = false
	local deepSplit = refresh(ctx, middleSplit)
	lu.assertIs(partitionForBattery(deepSplit, batteries.level2), partitionForBattery(deepSplit, batteries.level3))
	lu.assertIs(partitionForBattery(deepSplit, batteries.level2), partitionForBattery(deepSplit, batteries.siblingDeep))
	lu.assertNotIs(partitionForBattery(deepSplit, batteries.level3), partitionForBattery(deepSplit, batteries.level4))

	hqs.siblingTop.Provider.Available = false
	local siblingSplit = refresh(ctx, deepSplit)
	lu.assertIs(partitionForBattery(siblingSplit, batteries.root), partitionForBattery(siblingSplit, batteries.level1))
	lu.assertNotIs(partitionForBattery(siblingSplit, batteries.root), partitionForBattery(siblingSplit, batteries.siblingTop))
	for _, battery in pairs(batteries) do
		lu.assertEquals(capturedBattery(siblingSplit, battery).CoordinationState, C.CoordinationState.COORDINATED)
	end
end

function TestPartitionService:test_hq_ewr_provider_keeps_its_frozen_edge_available()
	local ctx = makeContext()
	local rootSensor = makeSensor("root-ewr", 1)
	local battery = makeBattery("child-sam", 3)
	local hqDto = {
		groupId = 2,
		groupName = "child-hq-ewr",
		parsed = { echelonPath = { "child" }, roles = { "EWR" }, isHQ = true },
	}
	addSensor(ctx, rootSensor, {})
	ctx.hierarchy:upsertGroup(hqDto)
	addBattery(ctx, battery, { "child" })
	local originalGetGroupUnits = GetGroupUnits
	GetGroupUnits = function()
		return {
			{
				getID = function()
					return 20
				end,
				getName = function()
					return "child-hq-radar"
				end,
				getPosition = function()
					return { p = { x = 0, y = 0, z = 0 } }
				end,
				getDesc = function()
					return { attributes = { ["SAM SR"] = true } }
				end,
			},
		}
	end
	local ok, kind = pcall(Medusa.Services.EntityFactory.createFromDTO, hqDto, {
		sensors = ctx.sensorStore,
		batteries = ctx.batteryRepository:batteries(),
		c2Nodes = ctx.c2NodeStore,
	}, "net")
	GetGroupUnits = originalGetGroupUnits
	if not ok then
		error(kind)
	end

	local snapshot = refresh(ctx)

	lu.assertEquals(kind, "hq")
	lu.assertEquals(ctx.c2NodeStore:count(), 1)
	lu.assertEquals(ctx.sensorStore:count(), 2)
	lu.assertEquals(capturedSensor(snapshot, rootSensor).PartitionKey, capturedBattery(snapshot, battery).PartitionKey)
end

function TestPartitionService:test_sustainment_loss_and_restoration_use_fresh_incarnations()
	local ctx = makeContext()
	local sensor = makeSensor("ewr", 1)
	local battery = makeBattery("sam", 2)
	addSensor(ctx, sensor, {})
	addBattery(ctx, battery, {})

	local initial = refresh(ctx)
	local initialKey = capturedBattery(initial, battery).PartitionKey
	sensor.OperationalStatus = C.UnitOperationalStatus.DESTROYED
	local lost = refresh(ctx, initial)
	local lostKey = capturedBattery(lost, battery).PartitionKey
	lu.assertNotEquals(lostKey, initialKey)
	lu.assertFalse(partitionForBattery(lost, battery).Sustained)

	sensor.OperationalStatus = C.UnitOperationalStatus.ACTIVE
	local restored = refresh(ctx, lost)
	lu.assertNotEquals(capturedBattery(restored, battery).PartitionKey, lostKey)
	lu.assertNotEquals(capturedBattery(restored, battery).PartitionKey, initialKey)
end

function TestPartitionService:test_awacs_and_selected_sam_as_ewr_sustain_partitions()
	local awacsCtx = makeContext()
	local awacs = makeSensor("awacs", 1, 0, 1000, C.SensorType.AWACS)
	local awacsBattery = makeBattery("awacs-sam", 2)
	addSensor(awacsCtx, awacs, {})
	addBattery(awacsCtx, awacsBattery, {})
	local awacsSnapshot = refresh(awacsCtx)
	lu.assertTrue(partitionForBattery(awacsSnapshot, awacsBattery).Sustained)

	local samCtx = makeContext()
	samCtx.doctrine.SAMAsEWR = C.SAMAsEWRPolicy.ALWAYS
	local provider = makeBattery("provider", 3)
	local member = makeBattery("member", 4)
	addBattery(samCtx, provider, {})
	addBattery(samCtx, member, {})
	local samSnapshot = refresh(samCtx)
	lu.assertTrue(partitionForBattery(samSnapshot, member).Sustained)
end

function TestPartitionService:test_when_no_ewr_selects_sam_fallback_only_in_component_without_ewr()
	local ctx = makeContext()
	ctx.doctrine.SAMAsEWR = C.SAMAsEWRPolicy.WHEN_NO_EWR
	local rootEwr = makeSensor("root-ewr", 1)
	local fallback = makeBattery("child-sam", 3)
	addSensor(ctx, rootEwr, {})
	addGroup(ctx.hierarchy, 2, "child-hq", { "child" }, true)
	addBattery(ctx, fallback, { "child" })
	local provider = { UnitId = 20, UnitName = "child-hq-1", Available = true }
	ctx.c2NodeStore:add(Medusa.Entities.C2Node.new({
		GroupId = 2,
		NodeName = "child-hq",
		Providers = { provider },
	}))

	local connected = refresh(ctx)
	lu.assertIs(partitionForBattery(connected, fallback), connected.PartitionByCluster[""])
	lu.assertFalse(capturedBattery(connected, fallback).IsActingAsEWR)

	provider.Available = false
	local split = refresh(ctx, connected)
	lu.assertNotIs(partitionForBattery(split, fallback), split.PartitionByCluster[""])
	lu.assertTrue(capturedBattery(split, fallback).IsActingAsEWR)
	lu.assertTrue(partitionForBattery(split, fallback).Sustained)

	provider.Available = true
	local rejoined = refresh(ctx, split)
	lu.assertIs(partitionForBattery(rejoined, fallback), rejoined.PartitionByCluster[""])
	lu.assertFalse(capturedBattery(rejoined, fallback).IsActingAsEWR)
end

function TestPartitionService:test_provider_overflow_degrades_only_the_affected_battery()
	local ctx = makeContext()
	ctx.doctrine.SAMAsEWR = C.SAMAsEWRPolicy.ALWAYS
	for i = 1, C.C2.PROVIDER_CAPACITY do
		addSensor(ctx, makeSensor("ewr-" .. i, i), {})
	end
	local samProvider = makeBattery("sam-provider", 1001)
	local covered = makeBattery("covered", 1002)
	local isolated = makeBattery("isolated", 1003, 10000)
	covered.Role = C.BatteryRole.SR_SAM
	isolated.Role = C.BatteryRole.SR_SAM
	addBattery(ctx, samProvider, {})
	addBattery(ctx, covered, {})
	addBattery(ctx, isolated, {})

	local snapshot = refresh(ctx)

	lu.assertEquals(capturedBattery(snapshot, samProvider).CoordinationState, C.CoordinationState.DEGRADED)
	lu.assertEquals(capturedBattery(snapshot, covered).CoordinationState, C.CoordinationState.DEGRADED)
	lu.assertEquals(capturedBattery(snapshot, isolated).CoordinationState, C.CoordinationState.DEGRADED)
	lu.assertEquals(snapshot.ProviderOverflowCount, 2)
end

function TestPartitionService:test_partial_refresh_does_not_mutate_committed_assets()
	local ctx = makeContext()
	local sensor = makeSensor("ewr", 1)
	local first = makeBattery("sam-1", 2)
	local second = makeBattery("sam-2", 3)
	first.PartitionKey = "committed"
	second.PartitionKey = "committed"
	addSensor(ctx, sensor, {})
	addBattery(ctx, first, {})
	addBattery(ctx, second, {})
	ctx.hierarchy:freezeC2Topology()
	local pending = PartitionService.begin(ctx, { PartitionByCluster = {} })

	PartitionService.step(pending)
	PartitionService.step(pending)

	lu.assertEquals(first.PartitionKey, "committed")
	lu.assertEquals(second.PartitionKey, "committed")
end

function TestPartitionService:test_active_refresh_uses_its_captured_inputs()
	local ctx = makeContext()
	local sensor = makeSensor("ewr", 1)
	local battery = makeBattery("sam", 2)
	ctx.doctrine.MaxEngageRangePct = { [C.BatteryRole.LR_SAM] = 100 }
	addGroup(ctx.hierarchy, 99, "hq", { "child" }, true)
	addSensor(ctx, sensor, { "child" })
	addBattery(ctx, battery, { "child" })
	ctx.hierarchy:freezeC2Topology()
	local pending = PartitionService.begin(ctx, { PartitionByCluster = {} })

	sensor.OperationalStatus = C.UnitOperationalStatus.DESTROYED
	sensor.Position.x = 10000
	addGroup(ctx.hierarchy, sensor.GroupId, sensor.GroupName, {}, false)
	ctx.doctrine.MaxEngageRangePct[C.BatteryRole.LR_SAM] = 0
	while not PartitionService.step(pending) do
	end

	lu.assertTrue(partitionForBattery(pending, battery).Sustained)
	lu.assertEquals(capturedBattery(pending, battery).CoordinationState, C.CoordinationState.COORDINATED)

	local nextSnapshot = refresh(ctx, pending)
	lu.assertFalse(partitionForBattery(nextSnapshot, battery).Sustained)
	lu.assertEquals(capturedBattery(nextSnapshot, battery).CoordinationState, C.CoordinationState.DEGRADED)
end

function TestPartitionService:test_supported_population_completes_within_fifteen_seconds_at_ten_hertz()
	local ctx = makeContext()
	for i = 1, 64 do
		local groupId = 10000 + i
		local name = "hq-" .. tostring(i)
		addGroup(ctx.hierarchy, groupId, name, { name }, true)
		ctx.c2NodeStore:add(Medusa.Entities.C2Node.new({
			GroupId = groupId,
			NodeName = name,
			Providers = { { UnitId = groupId, UnitName = name, Available = true } },
		}))
	end
	for i = 1, 128 do
		addSensor(ctx, makeSensor("ewr-" .. tostring(i), i), {})
	end
	for i = 1, 512 do
		addBattery(ctx, makeBattery("sam-" .. tostring(i), 1000 + i), {})
	end

	local snapshot, steps = refresh(ctx)

	lu.assertTrue(steps + 1 <= 150)
	lu.assertEquals(#snapshot.PartitionByCluster[""].ClusterKeys, 65)
	lu.assertEquals(snapshot.PartitionByCluster["hq-64"], snapshot.PartitionByCluster[""])
	lu.assertEquals(capturedBattery(snapshot, { BatteryId = "sam-512" }).CoordinationState, C.CoordinationState.COORDINATED)
end

function TestPartitionService:test_population_overflow_rejects_the_refresh()
	local ctx = makeContext()
	ctx.sensorStore = {
		count = function()
			return C.C2.MAX_SENSORS + 1
		end,
	}
	ctx.hierarchy:freezeC2Topology()

	lu.assertErrorMsgContains("partition sensor capacity exceeded", function()
		PartitionService.begin(ctx, { PartitionByCluster = {} })
	end)
end

function TestPartitionService:test_frozen_topology_ignores_dynamic_command_center_boundaries()
	local ctx = makeContext()
	addGroup(ctx.hierarchy, 1, "initial", { "west" }, false)
	local frozen = ctx.hierarchy:freezeC2Topology()
	addGroup(ctx.hierarchy, 2, "dynamic-hq", { "east" }, true)

	lu.assertEquals(ctx.hierarchy:getC2Topology(), frozen)
	lu.assertEquals(#frozen.ClusterKeys, 1)
	lu.assertEquals(ctx.hierarchy:clusterKeyForGroup(2), "")
end
