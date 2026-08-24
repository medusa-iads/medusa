require("_header")
require("services.Services")
require("services.CoverageGeometry")
require("entities.Partition")
require("entities.Battery")
require("entities.C2Node")
require("entities.SensorUnit")
require("core.Constants")

Medusa.Services.PartitionService = {}

local C = Medusa.Constants
local Battery = Medusa.Entities.Battery
local C2Node = Medusa.Entities.C2Node
local SensorUnit = Medusa.Entities.SensorUnit
local CoverageGeometry = Medusa.Services.CoverageGeometry

--- Protects partition geometry from a non-finite coordinate or radius value.
local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--- Defines the valid position and positive-radius domain for a provider or battery envelope.
local function validCircle(position, radius)
	return position and isFinite(position.x) and isFinite(position.z) and isFinite(radius) and radius > 0
end

--- Returns the connected-component root for value and shortens its lookup path in parent.
local function find(parent, value)
	local cursor = value
	while parent[cursor] ~= cursor do
		cursor = parent[cursor]
	end
	local root = cursor
	cursor = value
	while parent[cursor] ~= cursor do
		local nextValue = parent[cursor]
		parent[cursor] = root
		cursor = nextValue
	end
	return root
end

--- Joins the connected components that contain the left and right cluster keys in parent.
local function join(parent, left, right)
	local leftRoot = find(parent, left)
	local rightRoot = find(parent, right)
	if leftRoot ~= rightRoot then
		parent[rightRoot] = leftRoot
	end
end

--- Returns whether any command center in ids has an available mission-selected provider.
local function anyCommandCenterAvailable(ids, nodesByGroupId)
	for i = 1, #ids do
		local node = nodesByGroupId[ids[i]]
		if node and C2Node.hasAvailableProvider(node) then
			return true
		end
	end
	return false
end

--- Returns whether the virtual or placed root command center permits top-level links.
local function rootConnectionAvailable(topology, nodesByGroupId)
	local ids = topology.RootCommandCenterGroupIds or {}
	return #ids == 0 or anyCommandCenterAvailable(ids, nodesByGroupId)
end

--- Returns whether the child and, when required, root command centers keep an edge available.
local function edgeAvailable(edge, nodesByGroupId, rootAvailable)
	return anyCommandCenterAvailable(edge.CommandCenterGroupIds or {}, nodesByGroupId)
		and (edge.ParentKey ~= "" or rootAvailable)
end

--- Returns connected topology components and the component indexed by each cluster.
local function buildComponents(topology, nodes)
	local parent = {}
	local nodesByGroupId = {}
	for i = 1, #nodes do
		nodesByGroupId[nodes[i].GroupId] = nodes[i]
	end
	for i = 1, #topology.ClusterKeys do
		local key = topology.ClusterKeys[i]
		parent[key] = key
	end
	local rootAvailable = rootConnectionAvailable(topology, nodesByGroupId)
	for i = 1, #topology.Edges do
		local edge = topology.Edges[i]
		if edgeAvailable(edge, nodesByGroupId, rootAvailable) then
			join(parent, edge.ChildKey, edge.ParentKey)
		end
	end
	local membersByRoot = {}
	for i = 1, #topology.ClusterKeys do
		local key = topology.ClusterKeys[i]
		local root = find(parent, key)
		membersByRoot[root] = membersByRoot[root] or {}
		membersByRoot[root][#membersByRoot[root] + 1] = key
	end
	local components = {}
	local componentByCluster = {}
	for _, members in pairs(membersByRoot) do
		table.sort(members)
		local component = { ClusterKeys = members }
		components[#components + 1] = component
		for i = 1, #members do
			componentByCluster[members[i]] = component
		end
	end
	-- Orders components by their first cluster key so partition staging is deterministic.
	table.sort(components, function(left, right)
		return left.ClusterKeys[1] < right.ClusterKeys[1]
	end)
	return components, componentByCluster
end

--- Returns whether sensor is an operational EWR, GCI, or AWACS partition provider.
local function sensorIsProvider(sensor)
	return sensor.Available
		and (
			sensor.SensorType == C.SensorType.EWR
			or sensor.SensorType == C.SensorType.GCI
			or sensor.SensorType == C.SensorType.AWACS
		)
end

--- Returns whether battery is the operational SAM-as-EWR provider selected by doctrine.
local function batteryIsProvider(battery)
	local status = battery.OperationalStatus
	return battery.IsActingAsEWR == true
		and (status == C.BatteryOperationalStatus.ACTIVE or status == C.BatteryOperationalStatus.SEARCH_ONLY)
		and battery.HasSearchRadar
end

--- Copies position so later live-asset movement cannot change the captured refresh input.
local function copyPosition(position)
	if not position then
		return nil
	end
	return { x = position.x, y = position.y, z = position.z }
end

--- Returns the scalar sensor and frozen-cluster inputs captured for one partition refresh.
local function snapshotSensors(sensorStore, hierarchy)
	local sensors = sensorStore:getAll()
	local snapshot = {}
	for i = 1, #sensors do
		local sensor = sensors[i]
		snapshot[i] = {
			SensorUnitId = sensor.SensorUnitId,
			ClusterKey = hierarchy:clusterKeyForGroup(sensor.GroupId),
			Available = SensorUnit.isAvailable(sensor),
			SensorType = sensor.SensorType,
			Position = copyPosition(sensor.Position),
			DetectionRangeMax = sensor.DetectionRangeMax,
		}
	end
	return snapshot
end

--- Returns the scalar battery, frozen-cluster, and doctrine inputs captured for one partition refresh.
local function snapshotBatteries(batteryRepository, hierarchy, doctrine)
	local batteries = batteryRepository:getAll()
	local snapshot = {}
	for i = 1, #batteries do
		local battery = batteries[i]
		snapshot[i] = {
			BatteryId = battery.BatteryId,
			ClusterKey = hierarchy:clusterKeyForGroup(battery.GroupId),
			OperationalStatus = battery.OperationalStatus,
			IsActingAsEWR = battery.IsActingAsEWR,
			Position = copyPosition(battery.Position),
			DetectionRangeMax = battery.DetectionRangeMax,
			EngagementRangeMax = battery.EngagementRangeMax,
			WeaponRangeMax = battery.WeaponRangeMax,
			HasSearchRadar = Battery.hasSearchRadar(battery),
			EngagementRangeLimitPct = doctrine.MaxEngageRangePct and doctrine.MaxEngageRangePct[battery.Role],
		}
	end
	return snapshot
end

--- Adds one valid provider identity, cluster, position, and radius to pending refresh inputs.
local function addProvider(pending, clusterKey, position, radius)
	if not validCircle(position, radius) then
		return
	end
	pending.Providers[#pending.Providers + 1] = {
		ClusterKey = clusterKey,
		x = position.x,
		z = position.z,
		radius = radius,
	}
end

--- Records provider sustainment on the staged component that owns clusterKey.
local function markSustained(pending, clusterKey)
	local component = pending.ComponentByCluster[clusterKey]
	if component then
		component.Sustained = true
	end
end

--- Determines whether the ordered left and right component memberships can retain one partition key.
local function sameClusters(left, right)
	if not left or not right or #left ~= #right then
		return false
	end
	for i = 1, #left do
		if left[i] ~= right[i] then
			return false
		end
	end
	return true
end

--- Creates staged partition entities and indexes after all provider inputs are processed.
local function finalizePartitions(pending)
	local previousByCluster = pending.PreviousPartitionByCluster
	for i = 1, #pending.Components do
		local component = pending.Components[i]
		local sustained = component.Sustained == true
		local old = previousByCluster[component.ClusterKeys[1]]
		local key = old
				and old.Sustained == sustained
				and sameClusters(old.ClusterKeys, component.ClusterKeys)
				and old.Key
			or NewULID()
		local partition = Medusa.Entities.Partition.new({
			Key = key,
			ClusterKeys = component.ClusterKeys,
			Sustained = sustained,
		})
		for j = 1, #component.ClusterKeys do
			pending.PartitionByCluster[component.ClusterKeys[j]] = partition
		end
	end
	for i = 1, #pending.Sensors do
		local sensor = pending.Sensors[i]
		sensor.PartitionKey = pending.PartitionByCluster[sensor.ClusterKey].Key
	end
	for i = 1, #pending.Batteries do
		local battery = pending.Batteries[i]
		battery.PartitionKey = pending.PartitionByCluster[battery.ClusterKey].Key
	end
	pending.Phase = "COVERAGE"
end

--- Processes at most budget captured sensor and battery inputs without exposing staged results.
local function processInput(pending, budget)
	local processed = 0
	while processed < budget and pending.InputCursor <= #pending.Sensors do
		local sensor = pending.Sensors[pending.InputCursor]
		if sensorIsProvider(sensor) then
			markSustained(pending, sensor.ClusterKey)
			addProvider(pending, sensor.ClusterKey, sensor.Position, sensor.DetectionRangeMax)
		end
		pending.InputCursor = pending.InputCursor + 1
		processed = processed + 1
	end
	while processed < budget and pending.BatteryInputCursor <= #pending.Batteries do
		local battery = pending.Batteries[pending.BatteryInputCursor]
		if batteryIsProvider(battery) then
			markSustained(pending, battery.ClusterKey)
			addProvider(pending, battery.ClusterKey, battery.Position, battery.DetectionRangeMax)
		end
		pending.BatteryInputCursor = pending.BatteryInputCursor + 1
		processed = processed + 1
	end
	if pending.InputCursor > #pending.Sensors and pending.BatteryInputCursor > #pending.Batteries then
		finalizePartitions(pending)
	end
end

--- Returns the doctrine-limited coverage envelope for battery or nil when its geometry is invalid.
local function batteryEnvelope(battery)
	if not battery.Position then
		return nil
	end
	local radius = battery.EngagementRangeMax or battery.WeaponRangeMax or 0
	if battery.HasSearchRadar and (battery.DetectionRangeMax or 0) > 0 then
		radius = math.min(radius, battery.DetectionRangeMax)
	end
	local limit = battery.EngagementRangeLimitPct
	if type(limit) == "number" then
		radius = math.min(radius, (battery.EngagementRangeMax or radius) * limit / 100)
	end
	if not validCircle(battery.Position, radius) then
		return nil
	end
	return { x = battery.Position.x, z = battery.Position.z, radius = radius }
end

--- Returns at most the fixed provider ceiling plus one intersecting provider for overflow detection.
local function candidateProviders(pending, envelope, partition)
	local providers = {}
	for i = 1, #pending.Providers do
		local provider = pending.Providers[i]
		if provider and pending.PartitionByCluster[provider.ClusterKey] == partition then
			local dx = provider.x - envelope.x
			local dz = provider.z - envelope.z
			local intersectionRadius = provider.radius + envelope.radius
			if dx * dx + dz * dz <= intersectionRadius * intersectionRadius then
				providers[#providers + 1] = provider
				if #providers > C.C2.PROVIDER_CAPACITY then
					break
				end
			end
		end
	end
	return providers
end

--- Returns battery coordination and provider-overflow results from the pending partition snapshot.
local function evaluateBattery(pending, battery)
	local partition = pending.PartitionByCluster[battery.ClusterKey]
	if not partition or not partition.Sustained then
		return C.CoordinationState.DEGRADED, false
	end
	local envelope = batteryEnvelope(battery)
	if not envelope then
		return C.CoordinationState.DEGRADED, false
	end
	local providers = candidateProviders(pending, envelope, partition)
	local coverage, overflow = CoverageGeometry.evaluate(envelope, providers)
	return coverage == C.CoverageClass.SUFFICIENT and C.CoordinationState.COORDINATED or C.CoordinationState.DEGRADED,
		overflow
end

--- Rejects refresh input counts above the supported sensor, command-center, battery, or total ceilings.
local function validateCapacity(ctx)
	local sensorCount = ctx.sensorStore:count()
	local commandCenterCount = ctx.c2NodeStore:count()
	local batteryCount = ctx.batteryRepository:count()
	if sensorCount > C.C2.MAX_SENSORS then
		error(string.format("partition sensor capacity exceeded: %d > %d", sensorCount, C.C2.MAX_SENSORS))
	end
	if commandCenterCount > C.C2.MAX_COMMAND_CENTERS then
		error(
			string.format(
				"partition command-center capacity exceeded: %d > %d",
				commandCenterCount,
				C.C2.MAX_COMMAND_CENTERS
			)
		)
	end
	if batteryCount > C.C2.MAX_BATTERIES then
		error(string.format("partition battery capacity exceeded: %d > %d", batteryCount, C.C2.MAX_BATTERIES))
	end
	local assetCount = sensorCount + commandCenterCount + batteryCount
	if assetCount > C.C2.MAX_ASSETS then
		error(string.format("partition asset capacity exceeded: %d > %d", assetCount, C.C2.MAX_ASSETS))
	end
end

--- Returns the conservative initial snapshot with one unsustained local partition per frozen cluster.
function Medusa.Services.PartitionService.bootstrap(ctx)
	validateCapacity(ctx)
	local topology = ctx.hierarchy:getC2Topology()
	local partitionByCluster = {}
	for i = 1, #topology.ClusterKeys do
		local clusterKey = topology.ClusterKeys[i]
		local partition = Medusa.Entities.Partition.new({
			Key = NewULID(),
			ClusterKeys = { clusterKey },
			Sustained = false,
		})
		partitionByCluster[clusterKey] = partition
	end
	local sensors = snapshotSensors(ctx.sensorStore, ctx.hierarchy)
	local batteries = snapshotBatteries(ctx.batteryRepository, ctx.hierarchy, ctx.doctrine)
	for i = 1, #sensors do
		local sensor = sensors[i]
		sensor.PartitionKey = partitionByCluster[sensor.ClusterKey].Key
	end
	for i = 1, #batteries do
		local battery = batteries[i]
		battery.PartitionKey = partitionByCluster[battery.ClusterKey].Key
		battery.CoordinationState = C.CoordinationState.DEGRADED
	end
	return {
		PartitionByCluster = partitionByCluster,
		Sensors = sensors,
		Batteries = batteries,
		ProviderOverflowCount = 0,
	}
end

--- Captures bounded refresh inputs and returns private staged partition work based on previous.
function Medusa.Services.PartitionService.begin(ctx, previous)
	validateCapacity(ctx)
	local topology = ctx.hierarchy:getC2Topology()
	local nodes = ctx.c2NodeStore:getAll()
	local components, componentByCluster = buildComponents(topology, nodes)
	return {
		PreviousPartitionByCluster = previous and previous.PartitionByCluster or {},
		Components = components,
		ComponentByCluster = componentByCluster,
		Batteries = snapshotBatteries(ctx.batteryRepository, ctx.hierarchy, ctx.doctrine),
		Sensors = snapshotSensors(ctx.sensorStore, ctx.hierarchy),
		InputCursor = 1,
		BatteryInputCursor = 1,
		CoverageCursor = 1,
		Phase = "INPUTS",
		Providers = {},
		PartitionByCluster = {},
		ProviderOverflowCount = 0,
	}
end

--- Processes one bounded input or coverage slice and reports whether pending is complete.
function Medusa.Services.PartitionService.step(pending)
	if pending.Phase == "INPUTS" then
		processInput(pending, C.C2.INPUT_PROCESSING_BUDGET)
		return false
	end
	local processed = 0
	while processed < C.C2.COVERAGE_EVALUATION_BUDGET and pending.CoverageCursor <= #pending.Batteries do
		local battery = pending.Batteries[pending.CoverageCursor]
		local coordination, overflow = evaluateBattery(pending, battery)
		battery.CoordinationState = coordination
		if overflow then
			pending.ProviderOverflowCount = pending.ProviderOverflowCount + 1
		end
		pending.CoverageCursor = pending.CoverageCursor + 1
		processed = processed + 1
	end
	return pending.CoverageCursor > #pending.Batteries
end
