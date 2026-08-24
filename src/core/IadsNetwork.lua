require("_header")
require("core.Core")
require("core.Config")
require("core.Logger")
require("services.DiscoveryService")
require("services.HierarchyService")
require("services.TrackManager")
require("services.TrackDisplayIdAllocator")
require("entities.Battery")
require("entities.Track")
require("services.stores.BatteryStore")
require("services.SensorPollingService")
require("services.TargetAssigner")
require("services.TrackClassifier")
require("services.BatteryActivationService")
require("services.EmconService")
require("services.ManpadService")
require("services.AaaService")
require("services.CrewSuppressionService")
require("services.CrewPerceptionService")
require("services.HarmDetectionService")
require("services.HarmResponseService")
require("services.EntityFactory")
require("services.AssetIndex")
require("services.stores.UnitIndex")
require("services.GeospatialIndexService")
require("services.stores.SensorUnitStore")
require("services.SensorProbingService")
require("services.stores.C2NodeStore")
require("services.stores.AirspaceZoneStore")
require("services.stores.AirbaseStore")
require("services.stores.InterceptorGroupStore")
require("entities.Doctrine")
require("services.PointDefenseService")
require("observability.MetricsService")
require("services.BlackBoxService")
require("observability.MetricsSnapshot")
require("services.PartitionService")

--[[
            ██╗ █████╗ ██████╗ ███████╗    ███╗   ██╗███████╗████████╗██╗    ██╗ ██████╗ ██████╗ ██╗  ██╗
            ██║██╔══██╗██╔══██╗██╔════╝    ████╗  ██║██╔════╝╚══██╔══╝██║    ██║██╔═══██╗██╔══██╗██║ ██╔╝
            ██║███████║██║  ██║███████╗    ██╔██╗ ██║█████╗     ██║   ██║ █╗ ██║██║   ██║██████╔╝█████╔╝
            ██║██╔══██║██║  ██║╚════██║    ██║╚██╗██║██╔══╝     ██║   ██║███╗██║██║   ██║██╔══██╗██╔═██╗
            ██║██║  ██║██████╔╝███████║    ██║ ╚████║███████╗   ██║   ╚███╔███╔╝╚██████╔╝██║  ██║██║  ██╗
            ╚═╝╚═╝  ╚═╝╚═════╝ ╚══════╝    ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝

    What this module does
    - Runs the main tick loop that drives every IADS service on a fixed interval.
    - Coordinates discovery, sensor polling, track management, target assignment, EMCON, and HARM response.
    - Manages world event subscriptions for unit death, weapon fire, and kill tracking.

    How others use it
    - The Entrypoint creates one IadsNetwork per configured network and calls initialize/start.
    - ApiService looks up network instances by ID to change doctrine at runtime.
]]

---@class Medusa.Core.IadsNetwork
---@field _logger table
---@field _discovery Medusa.Services.DiscoveryService
---@field _hierarchy Medusa.Services.HierarchyService
---@field _initialized boolean
---@field _running boolean
---@field _tickCounter number
---@field new fun(self: Medusa.Core.IadsNetwork): Medusa.Core.IadsNetwork
---@field initialize fun(self: Medusa.Core.IadsNetwork): boolean
---@field start fun(self: Medusa.Core.IadsNetwork): boolean
---@field stop fun(self: Medusa.Core.IadsNetwork): boolean
---@field tick fun(self: Medusa.Core.IadsNetwork)
---@field getHierarchy fun(self: Medusa.Core.IadsNetwork): Medusa.Services.HierarchyService

Medusa.Core.IadsNetwork = {}

Medusa.Core.IadsNetwork._assignBatteryBuffer = {}
local _assignBatteryBuffer = Medusa.Core.IadsNetwork._assignBatteryBuffer
local UnitOwnerKind = Medusa.Constants.UnitOwnerKind

-- Shared orchestration helpers

--- Reports whether a DCS group category identifies a ship group.
--- @param groupCategory number|string|nil DCS group category value
--- @return boolean isShip True when the category identifies a ship group
local function isShipGroupCategory(groupCategory)
	local shipCategory = Group and Group.Category and Group.Category.SHIP
	return groupCategory == shipCategory or string.upper(tostring(groupCategory)) == "SHIP"
end

--- Selects the track-source type contributed by one sensor.
--- @param sensor table|nil Sensor entity
--- @return string source Track-source value
local function trackSourceForSensor(sensor)
	if isShipGroupCategory(sensor and sensor.GroupCategory) then
		return Medusa.Constants.TrackSource.SHIPBORNE_RADAR
	end
	if sensor and sensor.SensorType == Medusa.Constants.SensorType.AWACS then
		return Medusa.Constants.TrackSource.AWACS
	end
	if sensor and sensor.IsAirborne then
		return Medusa.Constants.TrackSource.AIRBORNE_DATALINK
	end
	return Medusa.Constants.TrackSource.EARLY_WARNING_RADAR
end

--- Selects the track-source type contributed by one battery radar.
--- @param battery table Battery entity
--- @return string source Track-source value
local function trackSourceForBattery(battery)
	if isShipGroupCategory(battery.GroupCategory) then
		return Medusa.Constants.TrackSource.SHIPBORNE_RADAR
	end
	return Medusa.Constants.TrackSource.SAM_BATTERY
end

--- Processes a bounded queue snapshot and skips items that are no longer valid.
local ChunkStep = {}
ChunkStep.__index = ChunkStep

--- Creates a bounded-work queue owner.
--- @param budget number Maximum items processed by one caller pass
--- @param isValid fun(item: any): boolean|nil Optional item-validity predicate
--- @return table step Chunk processor
function ChunkStep.new(budget, isValid)
	return setmetatable({ _queue = Queue(), budget = budget, _isValid = isValid }, ChunkStep)
end

--- Fills an empty chunk queue from one snapshot.
--- @param items table[] Snapshot items
--- @return boolean filled True when the queue accepted the snapshot
function ChunkStep:fill(items)
	if not self._queue:isEmpty() then
		return false
	end
	for i = 1, #items do
		self._queue:enqueue(items[i])
	end
	return true
end

--- Removes and returns the next valid queued item.
--- @return any|nil item Next valid item, or nil when drained
function ChunkStep:next()
	while not self._queue:isEmpty() do
		local item = self._queue:dequeue()
		if not self._isValid or self._isValid(item) then
			return item
		end
	end
	return nil
end

--- Reports whether the chunk queue has no pending items.
--- @return boolean empty True when no items remain
function ChunkStep:isEmpty()
	return self._queue:isEmpty()
end

--- Returns the number of pending chunk items.
--- @return number count Pending item count
function ChunkStep:remaining()
	return self._queue:size()
end

local _chunkLabels = {
	classify = { phase = "classify" },
	harm_detect = { phase = "harm_detect" },
	handoff = { phase = "handoff" },
	deactivation = { phase = "deactivation" },
}

local _workSummaryOwners = {
	"classify",
	"harm_detect",
	"handoff",
	"deactivation",
	"unit_refresh",
}

local _phaseLabels = {
	[0] = { phase = "classify" },
	{ phase = "harm" },
	{ phase = "assign" },
	{ phase = "maintain" },
	{ phase = "emcon" },
}

local _LS = Medusa.Constants.TrackLifecycleState

--- Reports whether a track remains eligible for recurring work.
--- @param track table|nil Track entity
--- @return boolean alive True when the track is active
local function _isTrackAlive(track)
	return track and track.LifecycleState == _LS.ACTIVE
end

--- Records one bounded phase pass in trace logs, summaries, and metrics.
--- @param iads Medusa.Core.IadsNetwork Network owner
--- @param MS table Metrics service
--- @param phaseName string Recurring-work owner name
--- @param processed number Items processed in this pass
--- @param remaining number Items still queued
local function logChunk(iads, MS, phaseName, processed, remaining)
	iads._logger:trace(string.format("phase %s: processed %d, queued %d", phaseName, processed, remaining))
	iads:_recordRecurringWork(phaseName, processed, remaining, processed + remaining)
	local labels = _chunkLabels[phaseName]
	MS.set("medusa_chunk_processed", processed, labels)
	MS.set("medusa_chunk_queued", remaining, labels)
end

--- Returns a stable signature and operator summary for one committed partition state.
--- @param partitionByCluster table<string, table> Committed partitions keyed by cluster
--- @param batteries table[] Battery entities in the snapshot
--- @return string summary Stable partition summary
local function describePartitionState(partitionByCluster, batteries)
	local components = {}
	local seen = {}
	local sustained = 0
	for _, partition in pairs(partitionByCluster or {}) do
		if type(partition) == "table" and partition.Key and not seen[partition.Key] then
			seen[partition.Key] = true
			if partition.Sustained then
				sustained = sustained + 1
			end
			local clusters = {}
			for i = 1, #(partition.ClusterKeys or {}) do
				local cluster = partition.ClusterKeys[i]
				clusters[i] = cluster == "" and "<root>" or tostring(cluster)
			end
			table.sort(clusters)
			components[#components + 1] = string.format(
				"%s:%s",
				table.concat(clusters, "+"),
				partition.Sustained and "sustained" or "unsustained"
			)
		end
	end
	table.sort(components)
	local coordinated = 0
	local degraded = 0
	for i = 1, #batteries do
		if batteries[i].CoordinationState == Medusa.Constants.CoordinationState.COORDINATED then
			coordinated = coordinated + 1
		else
			degraded = degraded + 1
		end
	end
	local topology = table.concat(components, " | ")
	local summary = string.format(
		"components=%d, sustained=%d, coordinated=%d, degraded=%d; topology=[%s]",
		#components,
		sustained,
		coordinated,
		degraded,
		topology
	)
	return summary
end

-- Lifecycle and runtime state

--- Allocates the orchestration owner for the IADS identity, coalition, doctrine, and shared inputs in opts.
--- @param opts table|nil Network configuration and shared runtime owners
--- @return Medusa.Core.IadsNetwork network New stopped network
function Medusa.Core.IadsNetwork:new(opts)
	local o = {
		_id = opts and opts.id or "IADS",
		_coalitionId = opts and opts.coalitionId,
		_prefix = opts and opts.prefix,
		_doctrineKey = opts and opts.doctrine,
		_logger = nil,
		_discovery = nil,
		_hierarchy = Medusa.Services.HierarchyService:new(),
		_initialized = false,
		_running = false,
		_bootstrapComplete = false,
		_bootstrapRetryAt = 0,
		_trackManager = nil,
		_assetIndex = nil,
		_spatialIndex = nil,
		_doctrine = nil,
		_partitionSnapshot = { PartitionByCluster = {} },
		_partitionRefresh = nil,
		_nextPartitionRefreshAt = 0,
		_partitionCtx = {},
		_sensorPollingService = nil,
		_sensorPollIndex = 1,
		_sensorPollBudget = 3,
		_sensorDetectionOffsets = {},
		_assignmentInterval = 2,
		_manpadInterval = 10,
		_manpadCtx = {},
		_aaaInterval = 10,
		_nextErectRetrySweepAt = 0,
		_unitPosRefreshInterval = Medusa.Constants.LocalAircraftDetection.POSITION_REFRESH_TICK_INTERVAL,
		-- IadsNetwork fills this table before each AaaService operation.
		_aaaCtx = {},
		_aaaBarrageState = opts and opts.aaaBarrageState or Medusa.Services.AaaService.newBarrageState(),
		_assignmentPhase = 0,
		_tickCounter = 0,
		_pollDetectionAccum = {},
		_lastAssetLogTime = 0,
		_assetLogIntervalSec = 300,
		_recurringWorkSummary = {
			classify = { Processed = 0, Queued = 0, HighWater = 0 },
			harm_detect = { Processed = 0, Queued = 0, HighWater = 0 },
			handoff = { Processed = 0, Queued = 0, HighWater = 0 },
			deactivation = { Processed = 0, Queued = 0, HighWater = 0 },
			unit_refresh = { Processed = 0, Queued = 0, HighWater = 0 },
		},
		_nextRecurringWorkSummaryAt = nil,
		_timerId = nil,
		_tickIntervalSec = (opts and opts.tick) or 0.1,
		_probingService = nil,
		_deathQueue = nil,
		_shotQueue = nil,
		_killQueue = nil,
		_worldEventBus = nil,
		_worldSubscriptionIds = {},
		_deathOverflowQueue = RingBuffer(Medusa.Constants.WorldEventQueue.DEATH_OVERFLOW_CAPACITY, false),
		_deathOverflowSet = {},
		_ammoReconcileIds = {},
		_ammoReconcileSet = {},
		_ammoReconcileCursor = 1,
		_hitQueue = nil,
		_hitSubscriptionId = nil,
		_hitEventBus = nil,
		_terminalEventQueue = RingBuffer(Medusa.Constants.CrewSuppression.IMPACT_QUEUE_CAPACITY, false),
		_activeTerminalEvent = nil,
		_terminalUnitBuffer = {},
		_blackBoxWeaponStore = opts and opts.blackBoxWeaponStore,
		_blackBoxTerminalSink = opts and opts.blackBoxTerminalSink,
		_crewSkillIndex = opts and opts.crewSkillIndex,
		_crewSuppressionCtx = {},
		_networkedGeoGrid = nil,
		_maxEngagementRange = 0,
		_erectComplete = false,
		_erectReadyAt = nil,
		_erectRetryAt = nil,
		_classifyStep = nil,
		_harmDetectStep = nil,
		_handoffStep = nil,
		_deactivationStep = nil,
		_borderZoneNames = opts and opts.borderZones or {},
		_borderPolygons = {},
		_borderPolygonsLL = {},
		_adizPolygon = nil,
		_tickFailures = 0,
		_phaseFailures = {},
		_periodicFailures = {},
		_failureLimit = Medusa.Constants.Scheduler.MAX_CONSECUTIVE_FAILURES,
		_harmSortBuffer = {},
		_harmPriorityKeys = {},
		_harmNormalBuffer = {},
		_ctx = {},
	}
	o._metricLabels = { network = o._id }
	o._deathEventMetricLabels = { network = o._id, event = "DEATH" }
	o._shotEventMetricLabels = { network = o._id, event = "SHOT" }
	o._killEventMetricLabels = { network = o._id, event = "KILL" }
	o._birthEventMetricLabels = { network = o._id, event = "BIRTH" }
	o._logger = Medusa.Logger:ns(string.format("%s | Core.IadsNetwork", tostring(o._id)))
	o._discovery = Medusa.Services.DiscoveryService:new(nil, {
		id = o._id,
		coalitionId = o._coalitionId,
		prefix = o._prefix,
	})
	setmetatable(o, { __index = self })
	--- Runs the contained callback for one scheduled network tick.
	o._tickCallback = function()
		o:_onTick()
	end
	if o._coalitionId == nil then
		error("IadsNetwork:new requires coalitionId", 0)
	end
	if not o._prefix or #tostring(o._prefix) == 0 then
		error("IadsNetwork:new requires prefix", 0)
	end
	return o
end

--- Adds one recurring operation to this IADS interval summary.
--- @param owner string Recurring-work owner name
--- @param processed number Items processed in this pass
--- @param queued number Items pending after this pass
--- @param highWater number|nil Largest observed workload for this pass
function Medusa.Core.IadsNetwork:_recordRecurringWork(owner, processed, queued, highWater)
	local stats = self._recurringWorkSummary[owner]
	if not stats then
		return
	end
	stats.Processed = stats.Processed + processed
	stats.Queued = queued
	stats.HighWater = math.max(stats.HighWater, highWater or queued, queued)
end

--- Emits and resets this IADS recurring-work summary every 30 seconds.
--- @param now number Current mission time in seconds
function Medusa.Core.IadsNetwork:_logRecurringWorkSummary(now)
	local intervalSec = Medusa.Constants.Diagnostics.WORK_SUMMARY_INTERVAL_SEC
	if not self._nextRecurringWorkSummaryAt then
		self._nextRecurringWorkSummaryAt = now + intervalSec
		return
	end
	if now < self._nextRecurringWorkSummaryAt then
		return
	end
	while self._nextRecurringWorkSummaryAt <= now do
		self._nextRecurringWorkSummaryAt = self._nextRecurringWorkSummaryAt + intervalSec
	end

	local lines = {
		string.format("recurring work (%ds)", intervalSec),
		string.format("%-18s %9s %7s %10s", "owner", "processed", "queued", "high-water"),
	}
	for i = 1, #_workSummaryOwners do
		local owner = _workSummaryOwners[i]
		local stats = self._recurringWorkSummary[owner]
		lines[#lines + 1] = string.format("%-18s %9d %7d %10d", owner, stats.Processed, stats.Queued, stats.HighWater)
		stats.Processed = 0
		stats.HighWater = stats.Queued
	end
	self._logger:debug(table.concat(lines, "\n"))
end

--- Builds the network runtime graph before scheduling starts, so partial initialization cannot enter a mission tick.
--- @return boolean initialized True when the runtime graph is ready
function Medusa.Core.IadsNetwork:initialize()
	if self._initialized then
		return true
	end
	self._logger:info(
		string.format("config: coalitionId=%s, prefix='%s'", tostring(self._coalitionId), tostring(self._prefix))
	)

	local unitIndex = Medusa.Services.UnitIndex:new()
	local batteryRepository = Medusa.Services.BatteryStore:new(unitIndex)
	local batteryStore = batteryRepository:batteries()
	local manpadStore = batteryRepository:manpads()
	local sensorStore = Medusa.Services.SensorUnitStore:new(unitIndex)
	local c2NodeStore = Medusa.Services.C2NodeStore:new(unitIndex)
	local zoneStore = Medusa.Services.AirspaceZoneStore:new()
	local airbaseStore = Medusa.Services.AirbaseStore:new()
	local interceptorStore = Medusa.Services.InterceptorGroupStore:new()
	self._spatialIndex = Medusa.Services.GeospatialIndexService:new(10000)
	self._networkedGeoGrid = self._spatialIndex:networkedGeoGrid()
	self._trackManager = Medusa.Services.TrackManager:new({
		geoGrid = self._networkedGeoGrid,
		displayIdAllocator = Medusa.Services.TrackDisplayIdAllocator.shared(),
		batteryRepository = batteryRepository,
	})

	self._assetIndex = Medusa.Services.AssetIndex.new({
		unitIndex = unitIndex,
		batteryRepository = batteryRepository,
		sensors = sensorStore,
		batteries = batteryStore,
		manpads = manpadStore,
		c2Nodes = c2NodeStore,
		zones = zoneStore,
		airbases = airbaseStore,
		interceptors = interceptorStore,
		tracks = self._trackManager:getStore(),
		networkedGeoGrid = self._networkedGeoGrid,
		localGeoGrid = self._spatialIndex:localGeoGrid(),
		suppressibleUnitGeoGrid = self._spatialIndex:suppressibleUnitGeoGrid(),
		spatialIndex = self._spatialIndex,
	})

	self._probingService = Medusa.Services.SensorProbingService:new(self._coalitionId)
	self._doctrine = Medusa.Config:getDoctrine(self._doctrineKey)
	self._partitionCtx = {
		hierarchy = self._hierarchy,
		batteryRepository = batteryRepository,
		sensorStore = sensorStore,
		c2NodeStore = c2NodeStore,
		doctrine = self._doctrine,
	}
	local network = self
	--- Recomputes battery range when AAA control mode changes.
	--- @param battery table Battery entity
	--- @param mode string New AAA control mode
	self._aaaCtx.onModeChanged = function(battery, mode)
		if mode == Medusa.Constants.Aaa.Mode.RADAR_DIRECTED then
			network:_updateMaxEngagementRange(battery)
		end
	end
	Medusa.Services.AaaService.setBarrageLimit(self._aaaBarrageState, self._id, self._doctrine.AAA.MaxBarrageGroups)

	local cfg = Medusa.Config:get()
	self._classifyStep = ChunkStep.new(cfg.ChunkBudgetTracks, _isTrackAlive)
	self._harmDetectStep = ChunkStep.new(cfg.ChunkBudgetHarm, _isTrackAlive)
	self._handoffStep = ChunkStep.new(cfg.ChunkBudgetBatteries)
	self._deactivationStep = ChunkStep.new(cfg.ChunkBudgetBatteries)
	self._rollingPkBuffer = {}
	self._rollingPkIndex = 0
	self._rollingPkCount = 0
	self._effectivePkFloor = self._doctrine.PkFloor
	self._lastRollingPkEventTime = 0
	self._sensorPollingService = Medusa.Services.SensorPollingService:new(self._doctrine)
	self:_logDoctrine()

	local harmSystems = {}
	for i = 1, #Medusa.Constants.HARM_CAPABLE_SYSTEMS do
		harmSystems[i] = Medusa.Constants.HARM_CAPABLE_SYSTEMS[i]
	end
	-- selene: allow(undefined_variable)
	local userConfig = (type(MEDUSA_CONFIG) == "table") and MEDUSA_CONFIG or {}
	if userConfig.HarmCapableSystems then
		for i = 1, #userConfig.HarmCapableSystems do
			harmSystems[#harmSystems + 1] = userConfig.HarmCapableSystems[i]
		end
	end
	self._harmCapableSystems = harmSystems

	self:_attachDiscoveryListener()

	if #self._borderZoneNames > 0 then
		local AirspaceService = Medusa.Services.AirspaceService
		self._borderPolygons = AirspaceService.discover(self._borderZoneNames)
		self._logger:info(
			string.format("border zones: %d configured, %d discovered", #self._borderZoneNames, #self._borderPolygons)
		)
		if #self._borderPolygons > 0 then
			self._borderPolygonsLL = AirspaceService.convertToLatLon(self._borderPolygons)
			if self._doctrine.ADIZEnabled then
				self._adizPolygon = AirspaceService.computeADIZ(self._borderPolygons, self._doctrine.ADIZBufferNm)
				if self._adizPolygon then
					self._logger:info(
						string.format(
							"ADIZ: %d vertices, buffer=%.0fnm",
							#self._adizPolygon,
							self._doctrine.ADIZBufferNm
						)
					)
				end
			end
		end
	end

	local netLabel = { "network" }
	Medusa.Observability.MetricsSnapshot.register(netLabel)
	local MetricsService = Medusa.Observability.MetricsService
	MetricsService.inc("medusa_world_events_dropped_total", 0, self._deathEventMetricLabels)
	MetricsService.inc("medusa_world_events_dropped_total", 0, self._shotEventMetricLabels)
	MetricsService.inc("medusa_world_events_dropped_total", 0, self._killEventMetricLabels)
	MetricsService.inc("medusa_world_events_dropped_total", 0, self._birthEventMetricLabels)
	MetricsService.set("medusa_world_event_queue_depth", 0, self._deathEventMetricLabels)
	MetricsService.set("medusa_world_event_queue_depth", 0, self._shotEventMetricLabels)
	MetricsService.set("medusa_world_event_queue_depth", 0, self._killEventMetricLabels)
	MetricsService.set("medusa_world_event_queue_depth", 0, self._birthEventMetricLabels)
	MetricsService.set("medusa_ammo_reconciliation_queue_depth", 0, self._metricLabels)

	local initTime = GetTime()
	self._lastAssetLogTime = initTime - self._assetLogIntervalSec + 30
	self._initialized = true
	self._logger:info("initialized")
	return true
end

--- Starts this network after contained initialization and reports whether one recurring tick was scheduled.
--- @return boolean started True when recurring work is running
function Medusa.Core.IadsNetwork:start()
	if not self._initialized then
		local initialized, result = pcall(self.initialize, self)
		if not initialized or not result then
			self._running = false
			if self._logger then
				pcall(
					self._logger.error,
					self._logger,
					string.format("initialization failed; network remains stopped: %s", tostring(result))
				)
			end
			return false
		end
	end
	if self._running then
		return true
	end
	if not self:_subscribeWorldEvents() then
		return false
	end
	if not self:_subscribeSuppressionEvents() then
		self:_unsubscribeWorldEvents()
		return false
	end
	if not self._discovery:enableDynamicAdds() then
		self:_unsubscribeSuppressionEvents()
		self:_unsubscribeWorldEvents()
		return false
	end
	self._running = true
	Medusa.Services.CrewSuppressionService.resume(self:_updateCrewSuppressionContext(GetTime()))
	self._logger:info("started")
	self:_onTick()
	return self._running
end

--- Cancels MANPAD wakes and relinquishes AAA response work owned by this network.
function Medusa.Core.IadsNetwork:_releaseLocalDefenses()
	if not self._assetIndex then
		return
	end
	Medusa.Services.ManpadService.cancelPendingWakes(self._assetIndex:manpads())
	Medusa.Services.AaaService.cleanup({
		networkId = self._id,
		barrageState = self._aaaBarrageState,
		batteryStore = self._assetIndex:batteries(),
		trackStore = self._trackManager and self._trackManager:getStore() or nil,
		now = GetTime(),
	})
end

--- Clears this network's recurring timer, subscriptions, and deferred local-defense work.
function Medusa.Core.IadsNetwork:_stopRuntime()
	self._running = false
	local timerId = self._timerId
	self._timerId = nil
	if timerId then
		pcall(CancelSchedule, timerId)
	end
	if self._initialized then
		pcall(function()
			Medusa.Services.CrewSuppressionService.stop(self:_updateCrewSuppressionContext(GetTime()))
		end)
	end
	pcall(self._unsubscribeSuppressionEvents, self)
	pcall(self._discovery.disableDynamicAdds, self._discovery)
	pcall(self._unsubscribeWorldEvents, self)
	pcall(self._releaseLocalDefenses, self)
end

--- Releases controlled batteries and stops all runtime ownership after one recurring owner reaches its failure limit.
--- @param owner string Recurring-work owner name
--- @param count number Consecutive failure count
function Medusa.Core.IadsNetwork:_stopAfterPersistentFailure(owner, count)
	self._logger:error(
		string.format(
			"%s failed %d consecutive times; releasing batteries to autonomous DCS AI control and stopping Medusa",
			owner,
			count
		)
	)
	local gotBatteries, batteries = pcall(function()
		return self._assetIndex:batteryRepository():getAll()
	end)
	if gotBatteries then
		for i = 1, #batteries do
			pcall(Medusa.Services.BatteryActivationService.erectGroup, batteries[i].GroupName)
		end
	else
		self._logger:error(string.format("getAll failed during shutdown: %s", tostring(batteries)))
	end
	self:_stopRuntime()
end

--- Stops recurring work and releases every runtime subscription owned by this network.
--- @return boolean stopped True after owned runtime work is released
function Medusa.Core.IadsNetwork:stop()
	self:_stopRuntime()
	self._logger:info("stopped")
	return true
end

--- Refreshes the shared crew-suppression context for one mission time.
--- @param now number Current mission time in seconds
--- @return table context Crew-suppression operation context
function Medusa.Core.IadsNetwork:_updateCrewSuppressionContext(now)
	local ctx = self._crewSuppressionCtx
	ctx.networkId = self._id
	ctx.batteryRepository = self._assetIndex:batteryRepository()
	ctx.trackStore = self._trackManager:getStore()
	ctx.barrageState = self._aaaBarrageState
	ctx.doctrine = self._doctrine
	ctx.suppressibleUnitGeoGrid = self._assetIndex:suppressibleUnitGeoGrid()
	ctx.now = now
	return ctx
end

--- Logs the active doctrine for operator diagnosis.
function Medusa.Core.IadsNetwork:_logDoctrine()
	local d = self._doctrine
	if not d then
		return
	end
	self._logger:info("doctrine = " .. TableToString(d))
end

--- Requests one battery readiness state and reports whether every wrapper returned true.
--- @param battery table Battery entity
--- @param desiredState string Requested activation state
--- @param now number Current mission time in seconds
--- @return boolean ready True when the requested state is confirmed
local function applyReadinessState(battery, desiredState, now)
	if battery.ActivationState == desiredState then
		return true
	end
	if desiredState == Medusa.Constants.ActivationState.STATE_WARM then
		return Medusa.Services.BatteryActivationService.goWarm(battery, now)
	end
	return Medusa.Services.BatteryActivationService.goCold(battery, now)
end

--- Keeps local defenses on their fixed defaults while C2-controlled batteries use current doctrine.
--- @param battery table Battery entity
--- @param batteryIndex number Battery position in the initialization snapshot
--- @param batteryCount number Total batteries in the initialization snapshot
--- @param doctrine table Active doctrine
--- @param now number Current mission time in seconds
--- @return string desiredState Requested activation state
local function desiredInitialReadiness(battery, batteryIndex, batteryCount, doctrine, now)
	local defaults = Medusa.Constants.SystemTypeDefaults[battery.Role]
	local defaultState = defaults and defaults.DefaultActivationState or Medusa.Constants.ActivationState.STATE_COLD
	if
		not defaults
		or battery.Role == Medusa.Constants.BatteryRole.MANPAD
		or Medusa.Entities.Battery.isIndependentAaa(battery)
	then
		return defaultState
	end
	return Medusa.Services.EmconService.getDesiredBatteryState(battery, batteryIndex, batteryCount, doctrine, now)
end

-- Asset discovery and admission

--- Attaches the discovery listener that admits validated mission groups into this network.
function Medusa.Core.IadsNetwork:_attachDiscoveryListener()
	local stores = {
		sensors = self._assetIndex:sensors(),
		batteries = self._assetIndex:batteries(),
		c2Nodes = self._assetIndex:c2Nodes(),
		manpads = self._assetIndex:manpads(),
	}
	local hierarchy = self._hierarchy
	local networkId = self._id
	local logger = self._logger
	local spatialIndex = self._spatialIndex
	local batteryRepository = self._assetIndex:batteryRepository()
	local harmSystems = self._harmCapableSystems
	local doctrine = self._doctrine
	local crewSkillIndex = self._crewSkillIndex

	local iads = self
	--- Assigns a newly admitted asset to its committed cluster partition in conservative degraded mode.
	--- @param dto table Validated discovery record
	local function assignConservativePartition(dto)
		local byCluster = iads._partitionSnapshot and iads._partitionSnapshot.PartitionByCluster or nil
		if not byCluster or next(byCluster) == nil then
			return
		end
		local clusterKey = hierarchy:clusterKeyForGroup(dto.groupId)
		local partition = byCluster[clusterKey]
		if not partition then
			return
		end
		local sensors = stores.sensors:getByGroupName(dto.groupName)
		for i = 1, #sensors do
			sensors[i].PartitionKey = partition.Key
		end
		local battery = batteryRepository:getByGroupId(dto.groupId)
		if battery then
			battery.PartitionKey = partition.Key
			battery.CoordinationState = Medusa.Constants.CoordinationState.DEGRADED
		end
	end

	--- Returns current scalar unit identities for a live group, or nil when none are available.
	--- @param groupName string DCS group name
	--- @return table[]|nil units Current unit identities, or nil when unavailable
	local function liveGroupUnits(groupName)
		local units = GetGroupUnits(groupName)
		if type(units) ~= "table" or #units == 0 then
			return nil
		end
		local records = {}
		for i = 1, #units do
			local unitId = GetUnitID(units[i])
			local nameOk, unitName = pcall(units[i].getName, units[i])
			if unitId then
				records[#records + 1] = { UnitId = unitId, UnitName = nameOk and unitName or nil }
			end
		end
		return records
	end

	--- Reports whether current live membership differs from the stored battery incarnation.
	--- @param battery table Battery entity
	--- @param liveUnits table[]|nil Current live unit identities
	--- @return boolean changed True when membership differs
	local function batteryMembersChanged(battery, liveUnits)
		if not liveUnits or #liveUnits ~= #(battery.Units or {}) then
			return liveUnits ~= nil
		end
		local liveById = {}
		for i = 1, #liveUnits do
			liveById[liveUnits[i].UnitId] = liveUnits[i]
		end
		for i = 1, #battery.Units do
			local unit = battery.Units[i]
			local live = liveById[unit.UnitId]
			if not live or (live.UnitName and unit.UnitName ~= live.UnitName) then
				return true
			end
		end
		return false
	end

	--- Retires one superseded battery incarnation through its existing lifecycle owners.
	--- @param battery table Superseded battery entity
	local function retireBattery(battery)
		Medusa.Services.CrewSuppressionService.cancelRecovery(battery)
		if battery.Role == Medusa.Constants.BatteryRole.MANPAD then
			Medusa.Services.ManpadService.cancelPendingWake(battery)
		elseif battery.Role == Medusa.Constants.BatteryRole.AAA then
			battery.OperationalStatus = Medusa.Constants.BatteryOperationalStatus.DESTROYED
			Medusa.Services.AaaService.cleanupBattery({
				barrageState = iads._aaaBarrageState,
				trackStore = iads._trackManager:getStore(),
				now = GetTime(),
			}, battery)
		end
		Medusa.Entities.Battery.releaseTrack(battery, iads._trackManager:getStore())
		batteryRepository:remove(battery.BatteryId)
		spatialIndex:removeBattery(battery.BatteryId)
		hierarchy:removeGroup(battery.GroupId)
		iads:_clearPollGroupStateIfUnused(battery.GroupName)
	end

	--- Retires battery incarnations that conflict with one live discovery record.
	--- @param dto table Validated discovery record
	--- @param liveUnits table[]|nil Current live unit identities
	local function retireSupersededBatteries(dto, liveUnits)
		local byGroupId = batteryRepository:getByGroupId(dto.groupId)
		local byGroupName = batteryRepository:getByGroupName(dto.groupName)
		if byGroupId and byGroupId ~= byGroupName then
			retireBattery(byGroupId)
		end
		if
			byGroupName
			and (
				byGroupName.GroupId ~= dto.groupId
				or byGroupName.GroupName ~= dto.groupName
				or batteryMembersChanged(byGroupName, liveUnits)
			)
		then
			retireBattery(byGroupName)
		end
		if liveUnits then
			for i = 1, #liveUnits do
				local owner = batteryRepository:getByUnitId(liveUnits[i].UnitId)
				if owner and owner.GroupName ~= dto.groupName then
					retireBattery(owner)
				end
			end
		end
	end

	--- Restores providers and sensors for a group that already has a current aggregate.
	--- @param dto table Validated discovery record
	--- @return boolean restored True when an existing aggregate owns the group
	local function restoreExistingGroup(dto)
		local existingNode = stores.c2Nodes:getByNodeName(dto.groupName)
		if existingNode then
			local providers = existingNode.Providers or {}
			for i = 1, #providers do
				local provider = providers[i]
				local unitId = provider.UnitName and GetUnitID(provider.UnitName) or nil
				if unitId then
					stores.c2Nodes:markProviderAvailable(provider, unitId)
				end
			end
			Medusa.Services.EntityFactory.reconcileSensorsFromDTO(dto, stores, networkId, doctrine)
			assignConservativePartition(dto)
			return true
		end
		if batteryRepository:getByGroupId(dto.groupId) then
			return true
		end
		if #stores.sensors:getByGroupName(dto.groupName) == 0 then
			return false
		end
		Medusa.Services.EntityFactory.reconcileSensorsFromDTO(dto, stores, networkId, doctrine)
		if #stores.sensors:getByGroupName(dto.groupName) == 0 then
			return false
		end
		assignConservativePartition(dto)
		return true
	end

	--- Creates the managed aggregate for one new discovery record.
	--- @param dto table Validated discovery record
	--- @return string|nil classification Created aggregate type, or nil when rejected
	local function createManagedGroup(dto)
		local roles = (dto.parsed and dto.parsed.roles) and table.concat(dto.parsed.roles, ",") or ""
		local path = (dto.parsed and dto.parsed.echelonPath) and table.concat(dto.parsed.echelonPath, ".") or ""
		logger:info(string.format("added: '%s' roles=[%s] path='%s'", tostring(dto.groupName), roles, path))
		local classification
		local created, createError = pcall(function()
			if dto.parsed and dto.parsed.isHQ and hierarchy:getC2Topology() then
				local sensorCount =
					Medusa.Services.EntityFactory.reconcileSensorsFromDTO(dto, stores, networkId, doctrine)
				classification = sensorCount > 0 and "sensor" or nil
			else
				classification = Medusa.Services.EntityFactory.createFromDTO(
					dto,
					stores,
					networkId,
					harmSystems,
					doctrine,
					crewSkillIndex
				)
			end
		end)
		if created and classification then
			return classification
		end
		hierarchy:removeGroup(dto.groupId)
		logger:error(string.format("managed group rejected: %s", tostring(createError or dto.groupName)))
		return nil
	end

	--- Schedules ammunition reconciliation when a new battery has unknown inventory.
	--- @param battery table|nil Newly admitted battery entity
	local function scheduleInitialAmmoReconciliation(battery)
		if not battery or battery.AmmoKnown then
			return
		end
		for i = 1, #battery.Units do
			if Medusa.Entities.Battery.isAmmoBearingUnit(battery, battery.Units[i]) then
				iads:_markAmmoUnknown(battery.Units[i].UnitId)
				return
			end
		end
	end

	--- Synchronizes and initializes one newly admitted networked battery.
	--- @param battery table|nil Newly admitted battery entity
	local function initializeDynamicBattery(battery)
		if not battery then
			return
		end
		spatialIndex:syncBattery(battery)
		spatialIndex:syncSuppressibleUnits(battery)
		iads:_updateMaxEngagementRange(battery)
		if not iads._erectComplete then
			return
		end
		local BatteryActivationService = Medusa.Services.BatteryActivationService
		local erected = BatteryActivationService.erectGroup(battery.GroupName)
		battery.ErectPending = not erected
		battery.ErectRetryAt = erected and nil or GetTime() + 1
		local now = GetTime()
		local allBatteries = stores.batteries:getAll({})
		local batteryIndex = #allBatteries
		for i = 1, #allBatteries do
			if allBatteries[i] == battery then
				batteryIndex = i
				break
			end
		end
		local desiredState = desiredInitialReadiness(battery, batteryIndex, #allBatteries, doctrine, now)
		local ready = erected and applyReadinessState(battery, desiredState, now)
		if ready then
			logger:info(
				string.format("dynamic battery %s readiness request returned true: %s", battery.GroupName, desiredState)
			)
		end
		iads:_applyDynamicBatteryRanges(battery)
		Medusa.Services.CrewSuppressionService.applyInitialDamage(iads:_updateCrewSuppressionContext(now), battery)
	end

	--- Synchronizes and initializes one newly admitted MANPAD group.
	--- @param battery table|nil Newly admitted MANPAD battery entity
	local function initializeDynamicManpad(battery)
		if not battery then
			return
		end
		spatialIndex:syncBattery(battery)
		spatialIndex:syncSuppressibleUnits(battery)
		local now = GetTime()
		Medusa.Services.BatteryActivationService.goCold(battery, now, iads._trackManager:getStore())
		if battery.AmmoKnown and battery.TotalAmmoStatus <= 0 then
			battery.RearmCheckTime = now + Medusa.Constants.REARM_CHECK_INTERVAL_SEC
		end
		Medusa.Services.CrewSuppressionService.applyInitialDamage(iads:_updateCrewSuppressionContext(now), battery)
	end

	--- Restores or creates one discovered group without duplicating existing battery or sensor aggregates.
	--- @param dto table Validated discovery record
	--- @return boolean admitted True when the group is represented by current entities
	local function admit(dto)
		local liveUnits = liveGroupUnits(dto.groupName)
		retireSupersededBatteries(dto, liveUnits)
		hierarchy:upsertGroup(dto)
		if restoreExistingGroup(dto) then
			return true
		end
		local classification = createManagedGroup(dto)
		if not classification then
			return false
		end
		assignConservativePartition(dto)
		local admittedBattery
		if classification == "battery" then
			admittedBattery = stores.batteries:getByGroupId(dto.groupId)
		elseif classification == "manpad" then
			admittedBattery = stores.manpads:getByGroupId(dto.groupId)
		end
		scheduleInitialAmmoReconciliation(admittedBattery)
		if classification == "battery" then
			initializeDynamicBattery(admittedBattery)
		elseif classification == "manpad" then
			initializeDynamicManpad(admittedBattery)
		end
		return true
	end

	self._discovery:setListener({ onAdded = admit, onRediscovered = admit })
end

-- World-event admission

--- Estimates conservative missile flight time from engagement range and optional target altitude.
--- @param rangeMax number|nil Maximum engagement range in meters
--- @param targetAlt number|nil Target altitude in meters
--- @return number seconds Estimated flight time
local function estimateTTK(rangeMax, targetAlt)
	local C = Medusa.Constants
	local range = rangeMax or 0
	if targetAlt and targetAlt < C.TTK_ALT_CEIL_M then
		local frac
		if targetAlt <= C.TTK_ALT_FLOOR_M then
			frac = 0.5
		else
			frac = 0.5 + 0.5 * (targetAlt - C.TTK_ALT_FLOOR_M) / (C.TTK_ALT_CEIL_M - C.TTK_ALT_FLOOR_M)
		end
		range = range * frac
	end
	return range / C.SAM_AVG_MISSILE_SPEED_MPS
end

--- Reports whether unit has positive ammunition for weaponTypeName.
--- @param unit table Battery unit entity
--- @param weaponTypeName string Weapon type name
--- @return boolean available True when matching ammunition remains
local function hasMatchingAmmo(unit, weaponTypeName)
	for i = 1, #unit.AmmoTypes do
		local ammo = unit.AmmoTypes[i]
		if ammo.Count > 0 and ammo.WeaponTypeName == weaponTypeName then
			return true
		end
	end
	return false
end

--- Captures the current Medusa owner tokens for one DCS unit identifier and optional exact name.
--- @param unitId number|string|nil DCS unit identifier
--- @param unitName string|nil Exact DCS unit name
--- @return table identity Current owner identity tokens
function Medusa.Core.IadsNetwork:_captureWorldEventIdentity(unitId, unitName)
	local unitIndex = self._assetIndex:unitIndex()
	local indexedUnit, identitySource = unitIndex:resolve(unitId, unitName)
	local batteryOwner = unitIndex:getOwner(indexedUnit, UnitOwnerKind.BATTERY_UNIT)
	local sensor = unitIndex:getOwner(indexedUnit, UnitOwnerKind.SENSOR)
	local provider = unitIndex:getOwner(indexedUnit, UnitOwnerKind.COMMAND_PROVIDER)
	return {
		IdentityCaptured = true,
		IdentitySource = identitySource,
		BatteryId = batteryOwner and batteryOwner.Battery.BatteryId or nil,
		BatteryUnitName = batteryOwner and batteryOwner.Unit.UnitName or nil,
		SensorUnitId = sensor and sensor.SensorUnitId or nil,
		ProviderUnitName = provider and provider.UnitName or nil,
	}
end

--- Extends a battery flight-safety deadline without shortening existing protection.
--- @param battery table Battery entity
--- @param targetAltitude number|nil Target altitude in meters
--- @param now number Current mission time in seconds
function Medusa.Core.IadsNetwork:_extendMissileFlightDeadline(battery, targetAltitude, now)
	local deadline = now + estimateTTK(battery.EngagementRangeMax, targetAltitude)
	if not battery.MissileInFlightUntil or deadline > battery.MissileInFlightUntil then
		battery.MissileInFlightUntil = deadline
	end
end

--- Retains the conservative flight deadline when a managed SAM or MANPAD shot enters Medusa.
--- @param unitId number|string DCS firing-unit identifier
--- @param unitName string|nil Exact DCS firing-unit name
--- @param weaponTypeName string|nil Observed weapon type
--- @param batteryId string|nil Captured battery identity
--- @return boolean retained True when a current managed battery received the flight guard
function Medusa.Core.IadsNetwork:_retainShotFlight(unitId, unitName, weaponTypeName, batteryId)
	local battery, unit = self._assetIndex:batteryRepository():resolveUnit(unitId, unitName)
	if
		not battery
		or battery.Role == Medusa.Constants.BatteryRole.AAA
		or (batteryId ~= nil and battery.BatteryId ~= batteryId)
		or not Medusa.Entities.Battery.isAmmoBearingUnit(battery, unit)
		or not unit.AmmoTypes
		or #unit.AmmoTypes == 0
		or (
			battery.Role == Medusa.Constants.BatteryRole.MANPAD
			and weaponTypeName ~= nil
			and not hasMatchingAmmo(unit, weaponTypeName)
		)
	then
		return false
	end
	self:_extendMissileFlightDeadline(battery, nil, GetTime())
	return true
end

--- Creates bounded loss, shot, and kill consumers and subscribes them to the world-event buses.
--- @return boolean subscribed True when every required subscription is active
function Medusa.Core.IadsNetwork:_subscribeWorldEvents()
	if #self._worldSubscriptionIds > 0 then
		return true
	end
	local bus = HarnessWorldEventBus
	if not bus or type(bus.sub) ~= "function" or type(bus.unsub) ~= "function" then
		self._logger:error("world event bus unavailable")
		return false
	end
	local coalitionId = self._coalitionId
	local network = self
	self._worldEventBus = bus

	--- Rolls back the subscriber ID that harness 1.0.1 allocates before DCS registration completes.
	--- @param topic number DCS world-event identifier
	--- @param queue table Event consumer
	--- @param predicate fun(event: table): boolean Event-admission predicate
	--- @return boolean subscribed True when registration completed
	local function subscribe(topic, queue, predicate)
		local expectedId = type(bus._nextSubId) == "number" and bus._nextSubId or nil
		local ok, subscriptionId = pcall(bus.sub, bus, topic, queue, predicate)
		if not ok or not subscriptionId then
			if expectedId then
				pcall(bus.unsub, bus, expectedId)
			end
			network:_unsubscribeWorldEvents()
			network._logger:error(
				string.format(
					"world event subscription failed for topic %s: %s",
					tostring(topic),
					tostring(subscriptionId)
				)
			)
			return false
		end
		network._worldSubscriptionIds[#network._worldSubscriptionIds + 1] = subscriptionId
		return true
	end

	--- Validates event for cId and captures its stable unit and current Medusa owner identities.
	--- @param event table|nil Raw DCS event
	--- @param cId number Coalition identifier
	--- @return boolean accepted True when the initiator belongs to this network coalition
	local function validateEventInitiator(event, cId)
		if not event or not event.initiator then
			return false
		end
		if type(event.initiator.getCoalition) ~= "function" then
			return false
		end
		local ok, coal = pcall(event.initiator.getCoalition, event.initiator)
		if not ok or coal ~= cId then
			return false
		end
		local idOk, uid = pcall(event.initiator.getID, event.initiator)
		if not idOk or not uid then
			return false
		end
		event._unitId = uid
		local nameOk, unitName = pcall(event.initiator.getName, event.initiator)
		event._unitName = nil
		if nameOk and type(unitName) == "string" and TrimString(unitName) ~= "" then
			event._unitName = unitName
		end
		local identity = self:_captureWorldEventIdentity(uid, event._unitName)
		event._identityCaptured = true
		event._batteryId = identity.BatteryId
		event._identitySource = identity.IdentitySource
		event._sensorUnitId = identity.SensorUnitId
		event._providerUnitName = identity.ProviderUnitName
		return true
	end

	--- Admits validated death-like events and reports the captured owner identity at DEBUG level.
	--- @param event table|nil Raw DCS death-like event
	--- @return boolean accepted True when the event is relevant to this coalition
	local function deathPredicate(event)
		local accepted = validateEventInitiator(event, coalitionId)
		if accepted then
			self._logger:debug(
				string.format(
					"death event accepted: unitId=%s unitName=%s identitySource=%s batteryId=%s sensorUnitId=%s providerName=%s",
					tostring(event._unitId),
					tostring(event._unitName),
					tostring(event._identitySource),
					tostring(event._batteryId),
					tostring(event._sensorUnitId),
					tostring(event._providerUnitName)
				)
			)
		else
			self._logger:debug("death event rejected: invalid initiator or coalition mismatch")
		end
		return accepted
	end
	--- Returns the Medusa owner tokens captured when the world event entered the bus.
	--- @param event table|nil Accepted world event
	--- @return table identity Captured or currently resolved owner tokens
	local function eventIdentity(event)
		if event and event._identityCaptured then
			return {
				IdentityCaptured = true,
				IdentitySource = event._identitySource,
				BatteryId = event._batteryId,
				SensorUnitId = event._sensorUnitId,
				ProviderUnitName = event._providerUnitName,
			}
		end
		return network:_captureWorldEventIdentity(event and event._unitId, event and event._unitName)
	end
	self._deathQueue = RingBuffer(Medusa.Constants.WorldEventQueue.DEATH_CAPACITY, false)
	--- Stores one scalar death record or retains its managed unit identifier for overflow recovery.
	--- @param event table|nil Accepted death-like event
	--- @return boolean queued True when the primary queue accepted the record
	function self._deathQueue:enqueue(event)
		local identity = eventIdentity(event)
		local accepted = event
				and event._unitId
				and self:push({
					UnitId = event._unitId,
					UnitName = event._unitName,
					IdentityCaptured = true,
					BatteryId = identity.BatteryId,
					SensorUnitId = identity.SensorUnitId,
					ProviderUnitName = identity.ProviderUnitName,
				})
			or false
		if
			not accepted
			and not network:_queueDeathOverflow(event and event._unitId, event and event._unitName, identity)
		then
			Medusa.Observability.MetricsService.inc(
				"medusa_world_events_dropped_total",
				nil,
				network._deathEventMetricLabels
			)
		end
		return accepted
	end
	if not subscribe(world.event.S_EVENT_DEAD, self._deathQueue, deathPredicate) then
		return false
	end
	if not subscribe(world.event.S_EVENT_CRASH, self._deathQueue, deathPredicate) then
		return false
	end
	if
		world.event.S_EVENT_UNIT_LOST
		and not subscribe(world.event.S_EVENT_UNIT_LOST, self._deathQueue, deathPredicate)
	then
		return false
	end

	--- Admits one coalition shot and captures available weapon metadata.
	--- @param event table|nil Raw DCS shot event
	--- @return boolean accepted True when the initiator belongs to this coalition
	local function shotPredicate(event)
		if not validateEventInitiator(event, coalitionId) then
			self._logger:debug("SHOT event rejected: invalid initiator or coalition mismatch")
			return false
		end
		if event.weapon then
			local wtn = GetWeaponTypeName(event.weapon)
			if wtn then
				event._weaponTypeName = wtn
			end
		end
		self._logger:debug(
			string.format(
				"SHOT event metadata: unitId=%s unitName=%s capturedBatteryId=%s identitySource=%s weaponObjectType=%s weaponTypeName=%s",
				tostring(event._unitId),
				tostring(event._unitName),
				tostring(event._batteryId),
				tostring(event._identitySource),
				type(event.weapon),
				tostring(event._weaponTypeName)
			)
		)
		return true
	end
	self._shotQueue = RingBuffer(Medusa.Constants.WorldEventQueue.SHOT_CAPACITY, false)
	--- Retains managed flight safety, then queues the shot or marks ammunition unknown on overflow.
	--- @param event table|nil Accepted shot event
	--- @return boolean queued True when the shot queue accepted the record
	function self._shotQueue:enqueue(event)
		if not event or not event._unitId then
			return false
		end
		local identity = eventIdentity(event)
		local record = {
			UnitId = event._unitId,
			UnitName = event._unitName,
			WeaponTypeName = event._weaponTypeName,
			IdentityCaptured = true,
			BatteryId = identity.BatteryId,
		}
		network:_retainShotFlight(record.UnitId, record.UnitName, record.WeaponTypeName, record.BatteryId)
		if not record.WeaponTypeName then
			network:_markAmmoUnknown(record.UnitId, record.UnitName, record.BatteryId)
		end
		local accepted = self:push(record)
		if not accepted then
			network:_markAmmoUnknown(record.UnitId, record.UnitName, record.BatteryId)
			Medusa.Observability.MetricsService.inc(
				"medusa_world_events_dropped_total",
				nil,
				network._shotEventMetricLabels
			)
		end
		return accepted
	end
	if not subscribe(world.event.S_EVENT_SHOT, self._shotQueue, shotPredicate) then
		return false
	end

	--- Admits one coalition kill event.
	--- @param event table|nil Raw DCS kill event
	--- @return boolean accepted True when the initiator belongs to this coalition
	local function killPredicate(event)
		return validateEventInitiator(event, coalitionId)
	end
	self._killQueue = RingBuffer(Medusa.Constants.WorldEventQueue.KILL_CAPACITY, false)
	--- Stores one scalar kill record or invalidates the adaptive kill window on overflow.
	--- @param event table|nil Accepted kill event
	--- @return boolean queued True when the kill queue accepted the record
	function self._killQueue:enqueue(event)
		local identity = eventIdentity(event)
		local accepted = event
				and event._unitId
				and self:push({
					UnitId = event._unitId,
					UnitName = event._unitName,
					IdentityCaptured = true,
					BatteryId = identity.BatteryId,
				})
			or false
		if not accepted then
			network:_invalidateRollingPk()
			Medusa.Observability.MetricsService.inc(
				"medusa_world_events_dropped_total",
				nil,
				network._killEventMetricLabels
			)
		end
		return accepted
	end
	if not subscribe(world.event.S_EVENT_KILL, self._killQueue, killPredicate) then
		return false
	end

	self._logger:info("world event subscriptions active")
	return true
end

--- Removes this network's loss, shot, and kill subscriptions and clears their pending records.
function Medusa.Core.IadsNetwork:_unsubscribeWorldEvents()
	local bus = self._worldEventBus
	for i = #self._worldSubscriptionIds, 1, -1 do
		if bus then
			pcall(bus.unsub, bus, self._worldSubscriptionIds[i])
		end
		self._worldSubscriptionIds[i] = nil
	end
	self._worldEventBus = nil
	if self._deathQueue then
		self._deathQueue:clear()
	end
	if self._shotQueue then
		self._shotQueue:clear()
	end
	if self._killQueue then
		self._killQueue:clear()
	end
end

--- Registers the bounded HIT-event boundary when crew suppression is enabled.
--- @return boolean subscribed True when suppression is disabled or the subscription is active
function Medusa.Core.IadsNetwork:_subscribeSuppressionEvents()
	if self._hitSubscriptionId then
		self._logger:debug(
			string.format("crew suppression HIT subscription already active: id=%s", tostring(self._hitSubscriptionId))
		)
		return true
	end
	if not self._doctrine.CrewSuppression.Enabled then
		self._logger:debug("crew suppression HIT subscription skipped: doctrine disabled")
		return true
	end
	local network = self
	local dropReason = Medusa.Constants.CrewSuppressionDropReason
	if not self._hitQueue then
		local queue = RingBuffer(Medusa.Constants.CrewSuppression.HIT_EVENT_QUEUE_CAPACITY, true)
		--- Admits one valid HIT event into the overwriting suppression queue.
		--- @param event table|nil Raw DCS HIT event
		--- @return boolean queued True when a valid hit record was retained
		function queue:enqueue(event)
			if type(event) ~= "table" or not event.initiator or not event.target then
				network:_recordCrewSuppressionDrop(dropReason.INVALID_EVENT)
				network._logger:debug("crew suppression HIT rejected: missing initiator or target")
				return false
			end
			local targetCoalition = GetUnitCoalition(event.target)
			if targetCoalition ~= network._coalitionId then
				network:_recordCrewSuppressionDrop(dropReason.INVALID_EVENT)
				network._logger:debug(
					string.format(
						"crew suppression HIT rejected: target coalition=%s expected=%s targetType=%s",
						tostring(targetCoalition),
						tostring(network._coalitionId),
						type(event.target)
					)
				)
				return false
			end
			local targetUnitId = GetUnitID(event.target)
			if not targetUnitId then
				network:_recordCrewSuppressionDrop(dropReason.INVALID_EVENT)
				network._logger:debug("crew suppression HIT rejected: target unit ID unavailable")
				return false
			end
			local identity = network:_captureWorldEventIdentity(targetUnitId)
			local _, evicted = self:push({
				TargetUnitId = targetUnitId,
				TargetBatteryId = identity.BatteryId,
				TargetUnitName = identity.BatteryUnitName,
				ObservedAt = GetTime(),
			})
			if evicted then
				network:_recordCrewSuppressionDrop(dropReason.QUEUE_OVERFLOW)
				network._logger:debug("crew suppression HIT queue overflow: oldest record evicted")
			end
			network._logger:debug(
				string.format("crew suppression HIT queued: targetUnitId=%d depth=%d", targetUnitId, self:size())
			)
			return true
		end
		self._hitQueue = queue
	end
	self._hitEventBus = HarnessWorldEventBus
	-- Harness 1.0.1 exposes this ID as the only way to roll back a partial registration.
	local expectedId = type(self._hitEventBus._nextSubId) == "number" and self._hitEventBus._nextSubId or nil
	local ok, subscriptionId = pcall(self._hitEventBus.sub, self._hitEventBus, world.event.S_EVENT_HIT, self._hitQueue)
	if not ok or not subscriptionId then
		if expectedId then
			pcall(self._hitEventBus.unsub, self._hitEventBus, expectedId)
		end
		self._hitEventBus = nil
		self._logger:error(string.format("crew suppression HIT subscription failed: %s", tostring(subscriptionId)))
		return false
	end
	self._hitSubscriptionId = subscriptionId
	self._logger:debug(
		string.format("crew suppression HIT subscription result: id=%s", tostring(self._hitSubscriptionId))
	)
	return self._hitSubscriptionId ~= nil
end

--- Increments one bounded crew-suppression drop reason.
--- @param reason string Crew-suppression drop reason
function Medusa.Core.IadsNetwork:_recordCrewSuppressionDrop(reason)
	Medusa.Observability.MetricsService.inc("medusa_crew_suppression_dropped_events_total", nil, {
		network = self._id,
		reason = reason,
	})
end

--- Reports whether a value is a finite Lua number.
--- @param value any Candidate value
--- @return boolean valid True when value is finite
local function validFiniteNumber(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

--- Reports whether a value is a finite DCS Vec3 position.
--- @param position any Candidate position
--- @return boolean valid True when x, y, and z are finite numbers
local function validPosition(position)
	return type(position) == "table"
		and validFiniteNumber(position.x)
		and validFiniteNumber(position.y)
		and validFiniteNumber(position.z)
end

--- Reports whether a terminal-event payload matches its source and kind.
--- @param terminalEvent table Terminal-event record
--- @param kind string Terminal-event kind
--- @param source string Terminal-event source
--- @return boolean valid True when the payload is valid for the source and kind
local function validTerminalKindPayload(terminalEvent, kind, source)
	if Medusa.Constants.CrewSuppressionTerminalKindBySource[source] ~= kind then
		return false
	end
	return kind ~= Medusa.Constants.CrewSuppressionTerminalKind.EXPLOSIVE
		or (validFiniteNumber(terminalEvent.EffectiveExplosiveMassKg) and terminalEvent.EffectiveExplosiveMassKg > 0)
end

--- Validates and queues one terminal weapon observation for crew-suppression processing.
--- @param terminalEvent table|nil Terminal-event record
--- @return boolean queued True when the record was retained
function Medusa.Core.IadsNetwork:enqueueTerminalEvent(terminalEvent)
	local source = terminalEvent and terminalEvent.Source
	local kind = terminalEvent and terminalEvent.Kind
	if not self._running or not self._doctrine or not self._doctrine.CrewSuppression.Enabled then
		self._logger:debug("terminal event ignored: crew suppression inactive")
		return false
	end
	if
		type(terminalEvent) ~= "table"
		or not validFiniteNumber(terminalEvent.TerminalEventId)
		or terminalEvent.TerminalEventId <= 0
		or not validPosition(terminalEvent.Position)
		or not validFiniteNumber(terminalEvent.ObservedAt)
		or Medusa.Constants.CrewSuppressionTerminalKind[kind] ~= kind
		or Medusa.Constants.CrewSuppressionTerminalSource[source] ~= source
	then
		self:_recordCrewSuppressionDrop(Medusa.Constants.CrewSuppressionDropReason.INVALID_EVENT)
		self._logger:debug("terminal event rejected at IADS boundary")
		return false
	end
	if not validTerminalKindPayload(terminalEvent, kind, source) then
		self:_recordCrewSuppressionDrop(Medusa.Constants.CrewSuppressionDropReason.INVALID_EVENT)
		self._logger:debug("terminal event rejected: kind payload mismatch")
		return false
	end
	local accepted = self._terminalEventQueue:push({
		TerminalEventId = terminalEvent.TerminalEventId,
		Kind = kind,
		Position = { x = terminalEvent.Position.x, y = terminalEvent.Position.y, z = terminalEvent.Position.z },
		EffectiveExplosiveMassKg = kind == Medusa.Constants.CrewSuppressionTerminalKind.EXPLOSIVE
				and terminalEvent.EffectiveExplosiveMassKg
			or nil,
		ObservedAt = terminalEvent.ObservedAt,
		Source = source,
	})
	if not accepted then
		self:_recordCrewSuppressionDrop(Medusa.Constants.CrewSuppressionDropReason.QUEUE_OVERFLOW)
		self._logger:debug(
			string.format(
				"terminal-event queue full: rejected id=%s kind=%s depth=%d",
				tostring(terminalEvent.TerminalEventId),
				kind,
				self._terminalEventQueue:size()
			)
		)
		return false
	end
	self._logger:debug(
		string.format(
			"terminal event queued: id=%s kind=%s source=%s depth=%d",
			tostring(terminalEvent.TerminalEventId),
			kind,
			source,
			self._terminalEventQueue:size()
		)
	)
	return true
end

-- Deferred event processing and entity reconciliation

--- Advances bounded terminal-event evaluation work.
--- @param taskBudget number Maximum completed terminal-event tasks
--- @param visitBudget number Maximum affected-unit visits
--- @return number steps Completed terminal-event tasks
--- @return number visits Affected units inspected
function Medusa.Core.IadsNetwork:_processTerminalEvents(taskBudget, visitBudget)
	local steps = 0
	local visits = 0
	local now = GetTime()
	local ctx = self:_updateCrewSuppressionContext(now)
	while steps < taskBudget and visits < visitBudget do
		if
			self._activeTerminalEvent
			and now - self._activeTerminalEvent.TerminalEvent.ObservedAt
				> Medusa.Constants.CrewSuppression.IMPACT_MAX_AGE_SEC
		then
			self:_recordCrewSuppressionDrop(Medusa.Constants.CrewSuppressionDropReason.IMPACT_EXPIRED)
			self._logger:debug(
				string.format(
					"active terminal event expired: id=%s",
					tostring(self._activeTerminalEvent.TerminalEvent.TerminalEventId)
				)
			)
			self._activeTerminalEvent = nil
			steps = steps + 1
		end
		if steps >= taskBudget then
			break
		end
		if not self._activeTerminalEvent then
			local terminalEvent = self._terminalEventQueue:pop()
			if not terminalEvent then
				break
			end
			if now - terminalEvent.ObservedAt > Medusa.Constants.CrewSuppression.IMPACT_MAX_AGE_SEC then
				self:_recordCrewSuppressionDrop(Medusa.Constants.CrewSuppressionDropReason.IMPACT_EXPIRED)
				self._logger:debug(
					string.format("terminal event expired: id=%s", tostring(terminalEvent.TerminalEventId))
				)
				steps = steps + 1
			else
				local work = Medusa.Services.CrewSuppressionService.beginTerminalEvent(ctx, terminalEvent)
				if work then
					self._activeTerminalEvent = work
				else
					self:_recordCrewSuppressionDrop(Medusa.Constants.CrewSuppressionDropReason.INVALID_EVENT)
					self._logger:debug(
						string.format(
							"terminal event evaluation rejected: id=%s",
							tostring(terminalEvent.TerminalEventId)
						)
					)
					steps = steps + 1
				end
			end
		end
		if self._activeTerminalEvent then
			local visited, complete = Medusa.Services.CrewSuppressionService.continueTerminalEvent(
				ctx,
				self._activeTerminalEvent,
				visitBudget - visits,
				self._terminalUnitBuffer
			)
			visits = visits + visited
			steps = steps + 1
			if complete then
				self._activeTerminalEvent = nil
			end
		end
	end
	Medusa.Observability.MetricsService.set(
		"medusa_crew_suppression_impact_queue_depth",
		self._terminalEventQueue:size(),
		self._metricLabels
	)
	return steps, visits
end

--- Processes due shared weapon observations when terminal-event ownership is active.
--- @param now number Current mission time in seconds
--- @return number processed Weapon records processed
function Medusa.Core.IadsNetwork:_runBlackBoxWeaponObservations(now)
	if not self._blackBoxWeaponStore or not self._blackBoxWeaponStore:isStarted() or not self._blackBoxTerminalSink then
		return 0
	end
	return Medusa.Services.BlackBoxService.updateDue(self._blackBoxWeaponStore, now, self._blackBoxTerminalSink)
end

--- Removes the crew-suppression subscription and clears its deferred work.
function Medusa.Core.IadsNetwork:_unsubscribeSuppressionEvents()
	local subscriptionId = self._hitSubscriptionId
	local bus = self._hitEventBus
	self._hitSubscriptionId = nil
	self._hitEventBus = nil
	if subscriptionId and bus then
		pcall(bus.unsub, bus, subscriptionId)
	end
	if self._hitQueue then
		self._hitQueue:clear()
	end
	self._terminalEventQueue:clear()
	self._activeTerminalEvent = nil
	self._logger:debug("crew suppression HIT subscription removed and queue cleared")
end

--- Processes a bounded number of queued crew-suppression HIT records.
--- @param limit number Maximum records processed
--- @return number processed Records consumed
function Medusa.Core.IadsNetwork:_processHitEvents(limit)
	if not self._hitQueue or self._hitQueue:isEmpty() then
		Medusa.Observability.MetricsService.set("medusa_crew_suppression_event_queue_depth", 0, self._metricLabels)
		return 0
	end
	local processed = 0
	local now = GetTime()
	local ctx = self:_updateCrewSuppressionContext(now)
	while processed < limit and not self._hitQueue:isEmpty() do
		local record = self._hitQueue:pop()
		local age = now - record.ObservedAt
		if age <= Medusa.Constants.CrewSuppression.HIT_EVENT_MAX_AGE_SEC then
			self._logger:debug(
				string.format("processing crew suppression HIT: targetUnitId=%d age=%.3fs", record.TargetUnitId, age)
			)
			local battery, unit = ctx.batteryRepository:resolveUnit(record.TargetUnitId, record.TargetUnitName)
			local ownerMatches = record.TargetBatteryId ~= nil
				and battery ~= nil
				and battery.BatteryId == record.TargetBatteryId
				and unit ~= nil
				and unit.UnitName == record.TargetUnitName
			local applied = false
			if ownerMatches then
				applied = Medusa.Services.CrewSuppressionService.processDamage(ctx, unit.UnitId)
			else
				self:_recordCrewSuppressionDrop(Medusa.Constants.CrewSuppressionDropReason.UNMANAGED_TARGET)
				self._logger:debug(
					string.format(
						"damage evaluation rejected: unitId=%s is not the captured owner",
						record.TargetUnitId
					)
				)
			end
			self._logger:debug(
				string.format(
					"crew suppression HIT processed: targetUnitId=%d applied=%s",
					record.TargetUnitId,
					tostring(applied)
				)
			)
		else
			self:_recordCrewSuppressionDrop(Medusa.Constants.CrewSuppressionDropReason.EXPIRED_EVENT)
			self._logger:debug(
				string.format("crew suppression HIT expired: targetUnitId=%d age=%.3fs", record.TargetUnitId, age)
			)
		end
		processed = processed + 1
	end
	Medusa.Observability.MetricsService.set(
		"medusa_crew_suppression_event_queue_depth",
		self._hitQueue:size(),
		self._metricLabels
	)
	return processed
end

--- Processes at most limit queued death records and returns the number consumed.
--- @param limit number Maximum records processed
--- @return number processed Records consumed
function Medusa.Core.IadsNetwork:_processDeathEvents(limit)
	if not self._deathQueue or self._deathQueue:isEmpty() then
		return 0
	end
	local processed = 0
	while processed < limit and not self._deathQueue:isEmpty() do
		local event = self._deathQueue:pop()
		if event and event.UnitId then
			self._logger:debug(string.format("processing death event: unitId=%s", tostring(event.UnitId)))
			self:_handleUnitDeath(event.UnitId, event.UnitName, event)
		else
			self._logger:debug("death event ignored: unit ID unavailable")
		end
		processed = processed + 1
	end
	return processed
end

--- Returns the coalescing key for one captured death-event owner identity.
--- @param unitId number|string DCS unit identifier
--- @param unitName string|nil Exact DCS unit name
--- @param identity table|nil Captured Medusa owner tokens
--- @return string key Stable pending-death key
local function deathIdentityKey(unitId, unitName, identity)
	return table.concat({
		tostring(unitId),
		tostring(unitName or ""),
		tostring(identity and identity.BatteryId or ""),
		tostring(identity and identity.SensorUnitId or ""),
		tostring(identity and identity.ProviderUnitName or ""),
	}, "\31")
end

--- Retains or coalesces one death identity and reports whether terminal overflow was avoided.
--- @param unitId number|string|nil DCS unit identifier
--- @param unitName string|nil Exact DCS unit name
--- @param identity table|nil Captured Medusa owner tokens
--- @return boolean retained True when the identity is pending in recovery
function Medusa.Core.IadsNetwork:_queueDeathOverflow(unitId, unitName, identity)
	if not unitId then
		return false
	end
	identity = identity or self:_captureWorldEventIdentity(unitId, unitName)
	local key = deathIdentityKey(unitId, unitName, identity)
	if self._deathOverflowSet[key] then
		return true
	end
	if
		self._deathOverflowQueue:push({
			UnitId = unitId,
			UnitName = unitName,
			IdentityKey = key,
			IdentityCaptured = true,
			BatteryId = identity.BatteryId,
			SensorUnitId = identity.SensorUnitId,
			ProviderUnitName = identity.ProviderUnitName,
		})
	then
		self._deathOverflowSet[key] = true
		return true
	end
	return false
end

--- Processes at most limit retained death-overflow identities.
--- @param limit number Maximum identities processed
--- @return number processed Identities consumed
function Medusa.Core.IadsNetwork:_processDeathOverflow(limit)
	local processed = 0
	while processed < limit and not self._deathOverflowQueue:isEmpty() do
		local record = self._deathOverflowQueue:pop()
		self._deathOverflowSet[record.IdentityKey] = nil
		self:_handleUnitDeath(record.UnitId, record.UnitName, record)
		processed = processed + 1
	end
	return processed
end

--- Marks the battery that owns unitId as ammunition-unknown and schedules bounded reconciliation.
--- @param unitId number|string DCS unit identifier
--- @param unitName string|nil Exact DCS unit name
--- @param batteryId string|nil Captured battery identity
--- @return boolean scheduled True when a current battery was scheduled
function Medusa.Core.IadsNetwork:_markAmmoUnknown(unitId, unitName, batteryId)
	local battery = self._assetIndex:batteryRepository():resolveUnit(unitId, unitName)
	if not battery or (batteryId ~= nil and battery.BatteryId ~= batteryId) then
		return false
	end
	battery.AmmoKnown = false
	if not self._ammoReconcileSet[battery.BatteryId] then
		self._ammoReconcileSet[battery.BatteryId] = true
		self._ammoReconcileIds[#self._ammoReconcileIds + 1] = battery.BatteryId
		battery.AmmoReconcileNextAt = nil
	end
	battery.AmmoReconcileCursor = 0
	battery.AmmoReconcileFailed = false
	return true
end

--- Quarantines response work immediately when an AAA battery becomes ineligible.
--- @param battery table|nil Battery entity
--- @param now number Current mission time in seconds
--- @return boolean clean True when no ineligible response claim remains
function Medusa.Core.IadsNetwork:_cleanupIneligibleAaa(battery, now)
	if
		not battery
		or battery.Role ~= Medusa.Constants.BatteryRole.AAA
		or (
			battery.OperationalStatus == Medusa.Constants.BatteryOperationalStatus.ACTIVE
			and Medusa.Entities.Battery.hasKnownAmmo(battery)
		)
	then
		return true
	end
	return Medusa.Services.AaaService.cleanupBattery({
		barrageState = self._aaaBarrageState,
		trackStore = self._trackManager:getStore(),
		now = now,
	}, battery)
end

--- Reconciles one ammunition-bearing unit for battery at DCS mission time now and reports battery completion.
--- @param battery table Battery entity
--- @param now number Current mission time in seconds
--- @return boolean complete True when the battery reconciliation is complete
function Medusa.Core.IadsNetwork:_reconcileBatteryAmmo(battery, now)
	local units = battery.Units or {}
	local cursor = (battery.AmmoReconcileCursor or 0) + 1
	local unit = units[cursor]
	if unit and Medusa.Entities.Battery.isAmmoBearingUnit(battery, unit) then
		if unit.UnitName then
			local ammoTypes, ammoCount, known = Medusa.Services.EntityFactory.extractAmmo(unit.UnitName, battery.Role)
			if known then
				unit.AmmoTypes = ammoTypes
				unit.AmmoCount = ammoCount
			else
				battery.AmmoReconcileFailed = true
			end
		else
			battery.AmmoReconcileFailed = true
		end
	end
	battery.AmmoReconcileCursor = cursor

	if cursor < #units then
		return false
	end
	if battery.AmmoReconcileFailed then
		battery.AmmoReconcileCursor = 0
		battery.AmmoReconcileFailed = false
		battery.AmmoReconcileNextAt = now + Medusa.Constants.WorldEventQueue.AMMO_RECONCILIATION_RETRY_SEC
		return false
	end
	battery.AmmoKnown = true
	battery.AmmoReconcileCursor = nil
	battery.AmmoReconcileFailed = nil
	battery.AmmoReconcileNextAt = nil
	Medusa.Entities.Battery.recomputeState(battery)
	self:_cleanupIneligibleAaa(battery, now)
	if battery.TotalAmmoStatus <= 0 then
		if battery.Role == Medusa.Constants.BatteryRole.MANPAD then
			Medusa.Services.ManpadService.cancelPendingWake(battery)
		end
		battery.RearmCheckTime = now + Medusa.Constants.REARM_CHECK_INTERVAL_SEC
	end
	return true
end

--- Processes at most limit pending ammunition units at DCS mission time now and returns the work count.
--- @param limit number Maximum battery reconciliation steps
--- @param now number Current mission time in seconds
--- @return number processed Reconciliation steps consumed
function Medusa.Core.IadsNetwork:_processAmmoReconciliation(limit, now)
	local processed = 0
	while processed < limit and #self._ammoReconcileIds > 0 do
		if self._ammoReconcileCursor > #self._ammoReconcileIds then
			self._ammoReconcileCursor = 1
		end
		local index = self._ammoReconcileCursor
		local batteryId = self._ammoReconcileIds[index]
		local battery = self._assetIndex:batteryRepository():get(batteryId)
		local complete = not battery
		if battery and (not battery.AmmoReconcileNextAt or now >= battery.AmmoReconcileNextAt) then
			complete = self:_reconcileBatteryAmmo(battery, now)
		end
		if complete then
			self._ammoReconcileSet[batteryId] = nil
			self._ammoReconcileIds[index] = self._ammoReconcileIds[#self._ammoReconcileIds]
			self._ammoReconcileIds[#self._ammoReconcileIds] = nil
		else
			self._ammoReconcileCursor = index + 1
		end
		processed = processed + 1
	end
	return processed
end

--- Clears per-group polling cursors after the last current sensor or battery owner leaves.
--- @param groupName string DCS group name
--- @return boolean cleared True when no poll-source owner remains
function Medusa.Core.IadsNetwork:_clearPollGroupStateIfUnused(groupName)
	if self._assetIndex:batteryRepository():getByGroupName(groupName) then
		return false
	end
	if #self._assetIndex:sensors():getByGroupName(groupName) > 0 then
		return false
	end
	self._sensorDetectionOffsets[groupName] = nil
	self._pollDetectionAccum[groupName] = nil
	return true
end

--- Retires hierarchy and discovery identity after no managed owner retains the group.
--- @param groupId number|string DCS group identifier
--- @param groupName string DCS group name
--- @return boolean retired True when the group identity was removed
function Medusa.Core.IadsNetwork:_retireGroupIdentity(groupId, groupName)
	if self._assetIndex:batteryRepository():getByGroupId(groupId) then
		return false
	end
	if #self._assetIndex:sensors():getByGroupName(groupName) > 0 then
		return false
	end
	if self._assetIndex:c2Nodes():getByNodeName(groupName) then
		return false
	end
	self._hierarchy:removeGroup(groupId)
	self._discovery:forget(groupId)
	self:_clearPollGroupStateIfUnused(groupName)
	return true
end

--- Removes matching command-provider and sensor ownership for one unit loss.
--- @param indexedUnit table|nil Indexed unit identity
--- @param unitId number|string DCS unit identifier
--- @param identity table|nil Captured Medusa owner tokens
--- @return boolean handled True when an infrastructure owner was removed or disabled
function Medusa.Core.IadsNetwork:_handleInfrastructureUnitDeath(indexedUnit, unitId, identity)
	local unitIndex = self._assetIndex:unitIndex()
	local handled = false
	local provider = unitIndex:getOwner(indexedUnit, UnitOwnerKind.COMMAND_PROVIDER)
	if
		provider
		and (not identity or identity.ProviderUnitName == provider.UnitName)
		and self._assetIndex:c2Nodes():setProviderUnavailable(provider)
	then
		handled = true
		self._logger:info(
			string.format("command provider unavailable: %s (unitId=%s)", provider.UnitName, tostring(unitId))
		)
	end
	local sensorStore = self._assetIndex:sensors()
	local sensor = unitIndex:getOwner(indexedUnit, UnitOwnerKind.SENSOR)
	if sensor and (not identity or identity.SensorUnitId == sensor.SensorUnitId) then
		handled = true
		sensorStore:remove(sensor.SensorUnitId)
		self:_retireGroupIdentity(sensor.GroupId, sensor.GroupName)
		self._logger:info(string.format("sensor destroyed: %s (unitId=%s)", sensor.UnitName, tostring(unitId)))
	end
	return handled
end

--- Removes one exact unit from its battery and selects a new position anchor when required.
--- @param battery table Battery entity
--- @param destroyedUnit table Battery unit entity
function Medusa.Core.IadsNetwork:_removeBatteryUnit(battery, destroyedUnit)
	local storedUnitId = destroyedUnit.UnitId
	self._spatialIndex:removeSuppressibleUnit(storedUnitId)
	self._assetIndex:batteryRepository():removeUnit(storedUnitId)
	if battery.PositionAnchorUnitId == storedUnitId then
		local preferredRole = battery.Role == Medusa.Constants.BatteryRole.AAA and Medusa.Constants.BatteryUnitRole.AAA
			or battery.Role == Medusa.Constants.BatteryRole.MANPAD and Medusa.Constants.BatteryUnitRole.MANPAD
			or nil
		local anchor = Medusa.Entities.Battery.selectPositionAnchor(battery, preferredRole)
		battery.Position = anchor and anchor.Position or nil
	end
end

--- Reconciles MANPAD state after one current member is removed.
--- @param battery table MANPAD battery entity
--- @param destroyedUnit table Removed MANPAD unit
--- @param unitId number|string DCS unit identifier
function Medusa.Core.IadsNetwork:_handleManpadUnitDeath(battery, destroyedUnit, unitId)
	local newStatus = Medusa.Entities.Battery.recomputeState(battery)
	if newStatus == Medusa.Constants.BatteryOperationalStatus.DESTROYED then
		Medusa.Services.ManpadService.cancelPendingWake(battery)
		Medusa.Services.CrewSuppressionService.cancelRecovery(battery)
		self._assetIndex:batteryRepository():remove(battery.BatteryId)
		self._spatialIndex:removeBattery(battery.BatteryId)
		self:_retireGroupIdentity(battery.GroupId, battery.GroupName)
		self._logger:info(string.format("manpad destroyed: %s (all MANPAD soldiers dead)", battery.GroupName))
		return
	end
	if (battery.TotalAmmoStatus or 0) <= 0 then
		Medusa.Services.ManpadService.cancelPendingWake(battery)
		battery.RearmCheckTime = GetTime() + Medusa.Constants.REARM_CHECK_INTERVAL_SEC
	end
	Medusa.Services.CrewSuppressionService.processMemberDestruction(
		self:_updateCrewSuppressionContext(GetTime()),
		battery,
		destroyedUnit
	)
	Medusa.Services.ManpadService.rebuildHeadings(battery)
	self._spatialIndex:syncBattery(battery)
	self._logger:info(string.format("manpad %s lost unit %d (%d remaining)", battery.GroupName, unitId, #battery.Units))
end

--- Removes the final unit's battery aggregate and every owned relation.
--- @param battery table Destroyed battery entity
function Medusa.Core.IadsNetwork:_retireDestroyedBattery(battery)
	Medusa.Services.CrewSuppressionService.cancelRecovery(battery)
	if battery.Role == Medusa.Constants.BatteryRole.AAA then
		Medusa.Services.AaaService.cleanupBattery({
			barrageState = self._aaaBarrageState,
			trackStore = self._trackManager:getStore(),
			now = GetTime(),
		}, battery)
	end
	Medusa.Observability.MetricsService.inc("medusa_battery_destroyed_total")
	Medusa.Entities.Battery.releaseTrack(battery, self._trackManager:getStore())
	self._assetIndex:batteryRepository():remove(battery.BatteryId)
	self._spatialIndex:removeBattery(battery.BatteryId)
	self:_retireGroupIdentity(battery.GroupId, battery.GroupName)
	self._logger:info(string.format("battery destroyed: %s (all units dead)", battery.GroupName))
end

--- Reconciles control, spatial state, and degradation for a surviving battery.
--- @param battery table Surviving battery entity
--- @param destroyedUnit table Removed battery unit
--- @param unitId number|string DCS unit identifier
--- @param wasRadarDirectedAaa boolean True when AAA used radar direction before the loss
--- @param previousStatus string Operational status before recomputation
function Medusa.Core.IadsNetwork:_updateSurvivingBatteryAfterUnitDeath(
	battery,
	destroyedUnit,
	unitId,
	wasRadarDirectedAaa,
	previousStatus
)
	if battery.Role == Medusa.Constants.BatteryRole.AAA then
		Medusa.Services.CrewSuppressionService.processMemberDestruction(
			self:_updateCrewSuppressionContext(GetTime()),
			battery,
			destroyedUnit
		)
		self:_cleanupIneligibleAaa(battery, GetTime())
		Medusa.Services.AaaService.rebuildHeadings(battery)
		if wasRadarDirectedAaa and Medusa.Entities.Battery.isIndependentAaa(battery) then
			Medusa.Entities.Battery.releaseTrack(battery, self._trackManager:getStore())
		end
	end
	self._spatialIndex:syncBattery(battery)
	self._logger:info(
		string.format("battery %s lost unit %d (%d remaining)", battery.GroupName, unitId, #battery.Units)
	)
	if battery.OperationalStatus ~= previousStatus then
		self._logger:info(
			string.format("battery %s status: %s -> %s", battery.GroupName, previousStatus, battery.OperationalStatus)
		)
	end
	local degradation = Medusa.Entities.Battery.classifyDegradation(battery)
	if degradation then
		local result = Medusa.Entities.Battery.applyDegradedBehavior(battery, degradation, {
			batteryRepository = self._assetIndex:batteryRepository(),
			geoGrid = self._networkedGeoGrid,
			trackStore = self._trackManager:getStore(),
		})
		if result == "weapons_free" then
			self._logger:info(
				string.format("battery %s TELARs weapons free (CP still coordinating)", battery.GroupName)
			)
		end
	end
end

--- Recomputes one surviving or destroyed non-MANPAD battery after a member loss.
--- @param battery table Battery entity
--- @param destroyedUnit table Removed battery unit
--- @param unitId number|string DCS unit identifier
--- @param wasRadarDirectedAaa boolean True when AAA used radar direction before the loss
function Medusa.Core.IadsNetwork:_handleBatteryUnitDeath(battery, destroyedUnit, unitId, wasRadarDirectedAaa)
	if battery.HarmDefenseCapacity > 0 then
		battery.HarmDefenseCapacity =
			Medusa.Services.EntityFactory.computeHarmDefenseCapacity(battery, self._harmCapableSystems)
	end
	local previousStatus = battery.OperationalStatus
	if Medusa.Entities.Battery.recomputeState(battery) == Medusa.Constants.BatteryOperationalStatus.DESTROYED then
		self:_retireDestroyedBattery(battery)
		return
	end
	self:_updateSurvivingBatteryAfterUnitDeath(battery, destroyedUnit, unitId, wasRadarDirectedAaa, previousStatus)
end

--- Applies a unit loss only to Medusa owners that still match the captured DCS unit identity.
--- @param unitId number|string DCS unit identifier
--- @param unitName string|nil Exact DCS unit name
--- @param identity table|nil Captured Medusa owner tokens
function Medusa.Core.IadsNetwork:_handleUnitDeath(unitId, unitName, identity)
	self._logger:debug(string.format("resolving death event: unitId=%s", tostring(unitId)))
	local unitIndex = self._assetIndex:unitIndex()
	local indexedUnit = unitIndex:resolve(unitId, unitName)
	local handled = self:_handleInfrastructureUnitDeath(indexedUnit, unitId, identity)
	local batteryOwner = unitIndex:getOwner(indexedUnit, UnitOwnerKind.BATTERY_UNIT)
	local battery = batteryOwner and batteryOwner.Battery or nil
	local destroyedUnit = batteryOwner and batteryOwner.Unit or nil
	if not battery or (identity and identity.BatteryId ~= battery.BatteryId) then
		if not handled then
			self._logger:debug(string.format("death event ignored: unitId=%s is not managed", tostring(unitId)))
		end
		return
	end
	self._logger:debug(
		string.format(
			"death event matched battery %s: unitId=%s role=%s members=%d",
			battery.GroupName or battery.BatteryId,
			tostring(unitId),
			tostring(battery.Role),
			#(battery.Units or {})
		)
	)
	local wasRadarDirectedAaa = Medusa.Entities.Battery.isRadarDirectedAaa(battery)
	self:_removeBatteryUnit(battery, destroyedUnit)
	if battery.Role == Medusa.Constants.BatteryRole.MANPAD then
		self:_handleManpadUnitDeath(battery, destroyedUnit, unitId)
		return
	end
	self:_handleBatteryUnitDeath(battery, destroyedUnit, unitId, wasRadarDirectedAaa)
end

--- Processes at most limit queued shot records and returns the number consumed.
--- @param limit number Maximum records processed
--- @return number processed Records consumed
function Medusa.Core.IadsNetwork:_processShotEvents(limit)
	if not self._shotQueue or self._shotQueue:isEmpty() then
		return 0
	end
	local processed = 0
	while processed < limit and not self._shotQueue:isEmpty() do
		local event = self._shotQueue:pop()
		if event and event.UnitId then
			self:_handleShot(event.UnitId, event.WeaponTypeName, event.UnitName, event)
		end
		processed = processed + 1
	end
	return processed
end

--- Processes at most limit queued kill records and returns the number consumed.
--- @param limit number Maximum records processed
--- @return number processed Records consumed
function Medusa.Core.IadsNetwork:_processKillEvents(limit)
	if not self._killQueue or self._killQueue:isEmpty() then
		return 0
	end
	local processed = 0
	while processed < limit and not self._killQueue:isEmpty() do
		local event = self._killQueue:pop()
		if event and event.UnitId then
			local battery, unit = self._assetIndex:batteryRepository():resolveUnit(event.UnitId, event.UnitName)
			if
				battery
				and (not event.UnitName or unit.UnitName == event.UnitName)
				and (not event.IdentityCaptured or event.BatteryId == battery.BatteryId)
			then
				Medusa.Observability.MetricsService.inc("medusa_kills_total")
				if
					battery.Role ~= Medusa.Constants.BatteryRole.MANPAD
					and not Medusa.Entities.Battery.isIndependentAaa(battery)
				then
					self:_recordKillOutcome()
				end
				self._logger:info(string.format("battery %s scored a kill", battery.GroupName))
			end
		end
		processed = processed + 1
	end
	return processed
end

--- Resolves one shot to the battery incarnation captured when the event entered Medusa.
--- @param unitId number|string DCS firing-unit identifier
--- @param unitName string|nil Exact DCS firing-unit name
--- @param identity table|nil Captured battery identity
--- @return table|nil battery Current battery entity
--- @return table|nil unit Current battery unit
function Medusa.Core.IadsNetwork:_resolveShotOwner(unitId, unitName, identity)
	local battery, unit, identitySource = self._assetIndex:batteryRepository():resolveUnit(unitId, unitName)
	if not battery then
		self._logger:debug(
			string.format(
				"SHOT attribution ignored: reason=%s unitId=%s observedUnitName=%s capturedBatteryId=%s",
				identitySource,
				tostring(unitId),
				tostring(unitName),
				tostring(identity and identity.BatteryId)
			)
		)
		return nil, nil
	end
	if identity and identity.IdentityCaptured and identity.BatteryId ~= battery.BatteryId then
		self._logger:debug(
			string.format(
				"SHOT attribution rejected: reason=battery-id-mismatch unitId=%s observedUnitName=%s capturedBatteryId=%s currentBatteryId=%s currentGroupName=%s currentUnitName=%s",
				tostring(unitId),
				tostring(unitName),
				tostring(identity.BatteryId),
				tostring(battery.BatteryId),
				tostring(battery.GroupName),
				tostring(unit.UnitName)
			)
		)
		return nil, nil
	end
	return battery, unit
end

--- Validates local-defense shot attribution and returns the role and ammunition facts used by processing.
--- @param battery table Current battery entity
--- @param unit table Current battery unit
--- @param unitId number|string DCS firing-unit identifier
--- @param weaponTypeName string|nil Observed weapon type
--- @return boolean accepted True when the current unit can own the shot
--- @return boolean isManpad True when the battery is a MANPAD group
--- @return boolean isLocallyManaged True when MANPAD or independent AAA policy owns the shot
--- @return boolean hasAmmoMetadata True when the unit has ammunition descriptors
function Medusa.Core.IadsNetwork:_validateAttributedShot(battery, unit, unitId, weaponTypeName)
	local isManpad = battery.Role == Medusa.Constants.BatteryRole.MANPAD
	local isIndependentAaa = Medusa.Entities.Battery.isIndependentAaa(battery)
	local isLocallyManaged = isManpad or isIndependentAaa
	if isLocallyManaged and not Medusa.Entities.Battery.isAmmoBearingUnit(battery, unit) then
		self._logger:debug(
			string.format(
				"SHOT attribution ignored: reason=local-unit-not-ammo-bearing unitId=%s currentBatteryId=%s currentGroupName=%s currentUnitName=%s",
				tostring(unitId),
				tostring(battery.BatteryId),
				tostring(battery.GroupName),
				tostring(unit.UnitName)
			)
		)
		return false, isManpad, isLocallyManaged, false
	end
	local hasAmmoMetadata = unit.AmmoTypes and #unit.AmmoTypes > 0
	if
		isLocallyManaged
		and weaponTypeName ~= nil
		and (not hasAmmoMetadata or not hasMatchingAmmo(unit, weaponTypeName))
	then
		self._logger:debug(
			string.format(
				"SHOT attribution ignored: reason=weapon-not-in-local-ammunition unitId=%s weaponTypeName=%s currentBatteryId=%s currentGroupName=%s currentUnitName=%s",
				tostring(unitId),
				tostring(weaponTypeName),
				tostring(battery.BatteryId),
				tostring(battery.GroupName),
				tostring(unit.UnitName)
			)
		)
		return false, isManpad, isLocallyManaged, hasAmmoMetadata
	end
	return true, isManpad, isLocallyManaged, hasAmmoMetadata
end

--- Records one accepted shot and any last-chance salvo consumption.
--- @param battery table Firing battery entity
--- @param isLocallyManaged boolean True when local-defense policy owns the shot
--- @param now number Current mission time in seconds
function Medusa.Core.IadsNetwork:_recordShotCounters(battery, isLocallyManaged, now)
	Medusa.Observability.MetricsService.inc("medusa_shots_fired_total")
	battery.ShotsFired = battery.ShotsFired + 1
	battery.LastShotTime = now
	if not isLocallyManaged then
		self:_recordShotOutcome(0)
	end
	if
		not isLocallyManaged
		and battery.LastChanceTrackId
		and battery.LastChanceShotsRemaining
		and battery.LastChanceShotsRemaining > 0
	then
		battery.LastChanceShotsRemaining = battery.LastChanceShotsRemaining - 1
		Medusa.Observability.MetricsService.inc("medusa_last_chance_fired_total")
	end
end

--- Refines the flight-safety deadline from the current assigned target altitude.
--- @param battery table Firing battery entity
--- @param isLocallyManaged boolean True when local-defense policy owns the shot
--- @param engagementRange number|nil Engagement range captured before state recomputation
--- @param now number Current mission time in seconds
function Medusa.Core.IadsNetwork:_updateShotFlightDeadline(battery, isLocallyManaged, engagementRange, now)
	local targetAlt = nil
	if not isLocallyManaged and battery.CurrentTargetTrackId then
		local track = self._trackManager:getStore():get(battery.CurrentTargetTrackId)
		if track and track.Position then
			targetAlt = track.Position.y
		end
	end
	local deadline = now + estimateTTK(engagementRange, targetAlt)
	if not battery.MissileInFlightUntil or deadline > battery.MissileInFlightUntil then
		battery.MissileInFlightUntil = deadline
	end
end

--- Dispatches one accepted local-defense shot to its MANPAD or AAA policy owner.
--- @param battery table Firing battery entity
--- @param unit table Firing battery unit
--- @param isManpad boolean True when the battery is a MANPAD group
--- @param now number Current mission time in seconds
function Medusa.Core.IadsNetwork:_dispatchLocalDefenseShot(battery, unit, isManpad, now)
	if isManpad then
		Medusa.Services.ManpadService.onShot(battery, now)
	elseif battery.Role == Medusa.Constants.BatteryRole.AAA then
		Medusa.Services.AaaService.onShot({
			networkId = self._id,
			barrageState = self._aaaBarrageState,
			batteryStore = self._assetIndex:batteries(),
			trackStore = self._trackManager:getStore(),
			localGeoGrid = self._assetIndex:localGeoGrid(),
			doctrine = self._doctrine,
		}, battery, unit, now)
	end
end

--- Schedules rearm work when an accepted shot consumes the final known round.
--- @param battery table Firing battery entity
--- @param isManpad boolean True when the battery is a MANPAD group
--- @param previousAmmo number Known ammunition count before the shot
--- @param now number Current mission time in seconds
function Medusa.Core.IadsNetwork:_scheduleRearmAfterShot(battery, isManpad, previousAmmo, now)
	self:_cleanupIneligibleAaa(battery, now)
	if previousAmmo > 0 and battery.TotalAmmoStatus <= 0 then
		if isManpad then
			Medusa.Services.ManpadService.cancelPendingWake(battery)
		end
		battery.RearmCheckTime = now + Medusa.Constants.REARM_CHECK_INTERVAL_SEC
		if isManpad then
			Medusa.Observability.MetricsService.inc("medusa_manpad_winchester_total")
		end
	end
end

--- Logs one processed shot and applies the readiness transition caused by ammunition loss.
--- @param battery table Firing battery entity
--- @param isManpad boolean True when the battery is a MANPAD group
--- @param weaponTypeName string Observed weapon type
--- @param previousStatus string Operational status before the shot
--- @param newStatus string Operational status after the shot
--- @param now number Current mission time in seconds
function Medusa.Core.IadsNetwork:_finishShotState(battery, isManpad, weaponTypeName, previousStatus, newStatus, now)
	self._logger:info(
		string.format(
			"battery %s fired %s (%d remaining)",
			battery.GroupName,
			weaponTypeName or "unknown",
			battery.TotalAmmoStatus
		)
	)
	if newStatus ~= previousStatus then
		self._logger:info(string.format("battery %s status: %s -> %s", battery.GroupName, previousStatus, newStatus))
		if not isManpad and battery.TotalAmmoStatus <= 0 then
			if Medusa.Services.BatteryActivationService.goGreen(battery, now, self._trackManager:getStore()) then
				battery.RearmCheckTime = now + Medusa.Constants.REARM_CHECK_INTERVAL_SEC
			end
		end
	end
end

--- Applies weaponTypeName for unitId only when unitName and identity match its current battery.
--- @param unitId number|string DCS firing-unit identifier
--- @param weaponTypeName string|nil Observed weapon type
--- @param unitName string|nil Exact DCS firing-unit name
--- @param identity table|nil Captured battery identity
function Medusa.Core.IadsNetwork:_handleShot(unitId, weaponTypeName, unitName, identity)
	local battery, unit = self:_resolveShotOwner(unitId, unitName, identity)
	if not battery then
		return
	end
	local accepted, isManpad, isLocallyManaged, hasAmmoMetadata =
		self:_validateAttributedShot(battery, unit, unitId, weaponTypeName)
	if not accepted then
		return
	end
	local now = GetTime()
	self:_recordShotCounters(battery, isLocallyManaged, now)
	if not hasAmmoMetadata or weaponTypeName == nil then
		self:_markAmmoUnknown(unitId, unitName, battery.BatteryId)
		self._logger:info(string.format("battery %s fired; ammunition metadata unavailable", battery.GroupName))
		return
	end
	local previousAmmo = battery.TotalAmmoStatus or 0
	local engagementRange = battery.EngagementRangeMax
	self:_decrementAmmo(unit, weaponTypeName)
	self:_updateShotFlightDeadline(battery, isLocallyManaged, engagementRange, now)
	local previousStatus = battery.OperationalStatus
	local newStatus = Medusa.Entities.Battery.recomputeState(battery)
	self:_dispatchLocalDefenseShot(battery, unit, isManpad, now)
	self:_scheduleRearmAfterShot(battery, isManpad, previousAmmo, now)
	self:_finishShotState(battery, isManpad, weaponTypeName, previousStatus, newStatus, now)
end

--- Adds one unresolved shot to the adaptive probability-of-kill window.
--- @param outcome number Shot outcome value
function Medusa.Core.IadsNetwork:_recordShotOutcome(outcome)
	local C = Medusa.Constants
	local buf = self._rollingPkBuffer
	self._rollingPkIndex = (self._rollingPkIndex % C.ROLLING_PK_WINDOW) + 1
	buf[self._rollingPkIndex] = outcome
	if self._rollingPkCount < C.ROLLING_PK_WINDOW then
		self._rollingPkCount = self._rollingPkCount + 1
	end
	self._lastRollingPkEventTime = GetTime()
	if self._rollingPkCount >= C.ROLLING_PK_WINDOW and self._doctrine.RollingPkEnabled then
		self:_updateEffectivePkFloor()
	end
end

--- Applies one observed kill to the newest unresolved adaptive shot.
function Medusa.Core.IadsNetwork:_recordKillOutcome()
	local buf = self._rollingPkBuffer
	local idx = self._rollingPkIndex
	local C = Medusa.Constants
	for _ = 1, self._rollingPkCount do
		if buf[idx] == 0 then
			buf[idx] = 1
			if self._rollingPkCount >= C.ROLLING_PK_WINDOW and self._doctrine.RollingPkEnabled then
				self:_updateEffectivePkFloor()
			end
			return
		end
		idx = idx - 1
		if idx < 1 then
			idx = C.ROLLING_PK_WINDOW
		end
	end
end

--- Invalidates this network's adaptive probability-of-kill history after an unknown kill outcome.
function Medusa.Core.IadsNetwork:_invalidateRollingPk()
	self._rollingPkBuffer = {}
	self._rollingPkIndex = 0
	self._rollingPkCount = 0
	self._lastRollingPkEventTime = 0
	self._effectivePkFloor = self._doctrine.PkFloor
	self._doctrine.EffectivePkFloor = self._effectivePkFloor
end

--- Recomputes the effective probability-of-kill floor from the current adaptive window.
function Medusa.Core.IadsNetwork:_updateEffectivePkFloor()
	local C = Medusa.Constants
	local sum = 0
	for i = 1, self._rollingPkCount do
		sum = sum + self._rollingPkBuffer[i]
	end
	local rollingPk = sum / self._rollingPkCount
	local target = self._doctrine.TargetKillRate
	local floor = self._doctrine.PkFloor
	local current = self._effectivePkFloor
	if rollingPk > target then
		current = math.max(floor, current - C.ROLLING_PK_STEP)
	elseif rollingPk < target then
		current = math.min(C.ROLLING_PK_CEILING, current + C.ROLLING_PK_STEP)
	end
	self._effectivePkFloor = current
	self._doctrine.EffectivePkFloor = current
end

--- Decays the adaptive probability-of-kill floor toward doctrine after inactivity.
--- @param now number Current mission time in seconds
function Medusa.Core.IadsNetwork:_decayEffectivePkFloor(now)
	if not self._doctrine.RollingPkEnabled then
		return
	end
	if self._lastRollingPkEventTime == 0 then
		return
	end
	local floor = self._doctrine.PkFloor
	local current = self._effectivePkFloor
	if current <= floor then
		return
	end
	local dt = now - self._lastRollingPkEventTime
	if dt <= 0 then
		return
	end
	local decayed = floor + (current - floor) * math.exp(-dt / Medusa.Constants.ROLLING_PK_DECAY_TAU)
	self._effectivePkFloor = math.max(floor, decayed)
	self._doctrine.EffectivePkFloor = self._effectivePkFloor
end

--- Decrements the matching ammunition record for one observed shot.
--- @param unit table Battery unit entity
--- @param weaponTypeName string Observed weapon type
function Medusa.Core.IadsNetwork:_decrementAmmo(unit, weaponTypeName)
	for i = 1, #unit.AmmoTypes do
		local at = unit.AmmoTypes[i]
		if at.Count > 0 and at.WeaponTypeName == weaponTypeName then
			at.Count = at.Count - 1
			unit.AmmoCount = unit.AmmoCount - 1
			return
		end
	end
	self._logger:error(
		string.format("ammo type '%s' not found on unit, using fallback decrement", weaponTypeName or "unknown")
	)
	for i = 1, #unit.AmmoTypes do
		local at = unit.AmmoTypes[i]
		if at.Count > 0 then
			at.Count = at.Count - 1
			unit.AmmoCount = unit.AmmoCount - 1
			return
		end
	end
end

Medusa.Core.IadsNetwork._rearmBuffer = {}

--- Checks at most two due batteries and retains retry state until readiness wrappers return true.
--- @param now number Current mission time in seconds
function Medusa.Core.IadsNetwork:_checkRearming(now)
	local batteries = self._assetIndex:batteryRepository():getAll(Medusa.Core.IadsNetwork._rearmBuffer)
	local checked = 0
	for i = 1, #batteries do
		if checked >= 2 then
			break
		end
		local battery = batteries[i]
		if battery.RearmCheckTime and now >= battery.RearmCheckTime then
			checked = checked + 1
			local rearmed = false
			if battery.Units then
				for j = 1, #battery.Units do
					local unit = battery.Units[j]
					if unit.UnitName and Medusa.Entities.Battery.isAmmoBearingUnit(battery, unit) then
						local newAmmo, newCount = Medusa.Services.EntityFactory.extractAmmo(unit.UnitName, battery.Role)
						if newCount > 0 then
							rearmed = true
							unit.AmmoTypes = newAmmo
							unit.AmmoCount = newCount
						end
					end
				end
			end
			if rearmed then
				Medusa.Entities.Battery.recomputeState(battery)
				local returnedToService = true
				if battery.Role == Medusa.Constants.BatteryRole.MANPAD then
					if battery.ActivationState ~= Medusa.Constants.ActivationState.STATE_COLD then
						returnedToService =
							Medusa.Services.BatteryActivationService.goCold(battery, now, self._trackManager:getStore())
					end
					if returnedToService then
						Medusa.Services.ManpadService.onRearmed(battery, now)
					end
				else
					battery.HarmDefenseCapacity =
						Medusa.Services.EntityFactory.computeHarmDefenseCapacity(battery, self._harmCapableSystems)
					local desiredState = desiredInitialReadiness(battery, i, #batteries, self._doctrine, now)
					returnedToService = applyReadinessState(battery, desiredState, now)
				end
				if returnedToService then
					battery.RearmCheckTime = nil
					self._logger:info(
						string.format(
							"battery %s rearmed (%d rounds), returning to service",
							battery.GroupName,
							battery.TotalAmmoStatus
						)
					)
				else
					battery.RearmCheckTime = now + Medusa.Constants.REARM_CHECK_INTERVAL_SEC
				end
			else
				battery.RearmCheckTime = now + Medusa.Constants.REARM_CHECK_INTERVAL_SEC
			end
		end
	end
end

-- Bootstrap and initial readiness

--- Requests early erect commands and records each battery that still needs a returned full sequence.
function Medusa.Core.IadsNetwork:_fastErectBatteries()
	local BatteryActivationService = Medusa.Services.BatteryActivationService
	local batteries = self._assetIndex:batteries():getAll()
	local erected = 0
	for i = 1, #batteries do
		local battery = batteries[i]
		if BatteryActivationService.erectGroup(battery.GroupName) then
			battery.ErectPending = false
			battery.ErectRetryAt = nil
			erected = erected + 1
		else
			battery.ErectPending = true
		end
	end
	self._logger:info(string.format("fast erect: %d battery wrapper requests returned true", erected))
end

--- Retries at most limit due dynamic erect sequences at DCS mission time now and returns the attempt count.
--- @param limit number Maximum batteries attempted
--- @param now number Current mission time in seconds
--- @return number attempted Batteries attempted
function Medusa.Core.IadsNetwork:_retryPendingErects(limit, now)
	local batteries = self._assetIndex:batteries():getAll()
	local attempted = 0
	for i = 1, #batteries do
		if attempted >= limit then
			break
		end
		local battery = batteries[i]
		if battery.ErectPending and (not battery.ErectRetryAt or now >= battery.ErectRetryAt) then
			attempted = attempted + 1
			if Medusa.Services.BatteryActivationService.erectGroup(battery.GroupName) then
				battery.ErectPending = false
				battery.ErectRetryAt = nil
				local desiredState = desiredInitialReadiness(battery, i, #batteries, self._doctrine, now)
				applyReadinessState(battery, desiredState, now)
			else
				battery.ErectRetryAt = now + 1
			end
		end
	end
	return attempted
end

--- Applies mission-start damage suppression to every local-defense battery.
--- @param now number Current mission time in seconds
function Medusa.Core.IadsNetwork:_applyInitialCrewSuppression(now)
	local batteries = self._assetIndex:batteryRepository():getAll()
	local ctx = self:_updateCrewSuppressionContext(now)
	for i = 1, #batteries do
		Medusa.Services.CrewSuppressionService.applyInitialDamage(ctx, batteries[i])
	end
end

--- Requests initial readiness for all batteries and reports whether every wrapper returned true.
--- @return boolean ready True when every initial readiness sequence returned true
function Medusa.Core.IadsNetwork:_initializeBatteryStates()
	local batteries = self._assetIndex:batteries():getAll()
	local now = GetTime()
	local coldCount = 0
	local warmCount = 0
	local skipped = 0

	for i = 1, #batteries do
		local battery = batteries[i]
		local desiredState = desiredInitialReadiness(battery, i, #batteries, self._doctrine, now)
		local erected = battery.ErectPending == false
		if not erected then
			erected = Medusa.Services.BatteryActivationService.erectGroup(battery.GroupName)
			battery.ErectPending = not erected
		end
		local ok = erected and applyReadinessState(battery, desiredState, now)
		if ok then
			if desiredState == Medusa.Constants.ActivationState.STATE_WARM then
				warmCount = warmCount + 1
			else
				coldCount = coldCount + 1
			end
		else
			skipped = skipped + 1
		end
	end
	self._logger:info(
		string.format(
			"initialized %d batteries (%d COLD, %d WARM), skipped %d",
			coldCount + warmCount,
			coldCount,
			warmCount,
			skipped
		)
	)
	return skipped == 0
end

--- Adds one battery position for each previously unseen unit type.
--- @param battery table Battery entity
--- @param typePositions table<string, table> Probe positions keyed by unit type
local function _collectBatteryUnitPositions(battery, typePositions)
	if not battery.Units then
		return
	end
	for j = 1, #battery.Units do
		local unit = battery.Units[j]
		if unit.UnitTypeName and not typePositions[unit.UnitTypeName] and battery.Position then
			typePositions[unit.UnitTypeName] = battery.Position
		end
	end
end

--- Reads directly available airborne sensor ranges before dynamic probing.
function Medusa.Core.IadsNetwork:_probeAirborneSensors()
	local sensors = self._assetIndex:sensors():getAll()
	for i = 1, #sensors do
		local sensor = sensors[i]
		if sensor.IsAirborne and sensor.UnitName and not sensor.DetectionRangeMax then
			local unit = GetUnit(sensor.UnitName)
			local sensorsTable = unit and GetUnitSensors(unit)
			if sensorsTable then
				local caps = self._probingService:_parseSensors(sensorsTable)
				if caps and caps.detectionRangeMax then
					sensor.DetectionRangeMax = caps.detectionRangeMax
					self._logger:info(
						string.format(
							"airborne sensor '%s' detection range: %.0fm (%.1fnm)",
							sensor.GroupName,
							caps.detectionRangeMax,
							caps.detectionRangeMax / 1852
						)
					)
				end
			end
		end
	end
end

--- Collects one representative probe position for each unresolved unit type.
--- @return table<string, table> typePositions Probe positions keyed by unit type
function Medusa.Core.IadsNetwork:_collectProbeTargets()
	local typePositions = {}
	local sensors = self._assetIndex:sensors():getAll()
	for i = 1, #sensors do
		local sensor = sensors[i]
		if
			not sensor.IsAirborne
			and sensor.UnitTypeName
			and sensor.Position
			and not typePositions[sensor.UnitTypeName]
		then
			typePositions[sensor.UnitTypeName] = sensor.Position
		end
	end
	local batteries = self._assetIndex:batteries():getAll()
	for i = 1, #batteries do
		_collectBatteryUnitPositions(batteries[i], typePositions)
	end
	return typePositions
end

--- Synchronizes managed batteries and suppressible units into their spatial indexes.
function Medusa.Core.IadsNetwork:_populateGeoGrid()
	local batteries = self._assetIndex:batteries():getAll()
	local maxRange = 0
	local maxSpread = 0
	local networkedCount = 0
	local localCount = 0
	for i = 1, #batteries do
		local b = batteries[i]
		self._spatialIndex:syncBattery(b)
		self._spatialIndex:syncSuppressibleUnits(b)
		if self._spatialIndex:isNetworkedBattery(b) then
			networkedCount = networkedCount + 1
			local r = b.EngagementRangeMax or 0
			if r > maxRange then
				maxRange = r
			end
			local s = b.ClusterSpreadRadius or 0
			if s > maxSpread then
				maxSpread = s
			end
		else
			localCount = localCount + 1
		end
	end
	self._maxEngagementRange = math.max(math.ceil((maxRange + maxSpread) / 10000) * 10000, 10000)

	local manpads = self._assetIndex:manpads():getAll()
	for i = 1, #manpads do
		self._spatialIndex:syncBattery(manpads[i])
		self._spatialIndex:syncSuppressibleUnits(manpads[i])
	end
	localCount = localCount + #manpads

	self._logger:info(
		string.format(
			"geogrid: %d networked, %d local defenses indexed, maxEngagementRange=%dm",
			networkedCount,
			localCount,
			self._maxEngagementRange
		)
	)
end

--- Raises the network query radius to cover a networked battery and its cluster spread.
--- @param battery table Battery entity
function Medusa.Core.IadsNetwork:_updateMaxEngagementRange(battery)
	if not self._spatialIndex:isNetworkedBattery(battery) then
		return
	end
	local r = battery.EngagementRangeMax or 0
	local s = battery.ClusterSpreadRadius or 0
	local effective = math.max(math.ceil((r + s) / 10000) * 10000, 10000)
	if effective > self._maxEngagementRange then
		self._maxEngagementRange = effective
		self._logger:info(string.format("maxEngagementRange updated to %dm", effective))
	end
end

--- Runs one discovery scan and logs newly admitted hierarchy state.
--- @return boolean succeeded True when the DCS group listing succeeded
function Medusa.Core.IadsNetwork:_runScanAndLog()
	local added, succeeded = self._discovery:scanOnce()
	if (added or 0) > 0 then
		self._logger:info(string.format("discovery: added=%d", added))
		self._logger:info(string.format("hierarchy tree:\n%s", self._hierarchy:renderTree()))
	end
	return succeeded
end

--- Logs the periodic operator summary for managed assets and sensor detections.
--- @param now number Current mission time in seconds
function Medusa.Core.IadsNetwork:_logAssetSummary(now)
	if (now - self._lastAssetLogTime) < self._assetLogIntervalSec then
		return
	end
	self._lastAssetLogTime = now
	local trackCount = self._trackManager and self._trackManager:getStore():count() or 0
	local sensorNames = self._assetIndex:sensors():getUniqueGroupNames()
	local accum = self._pollDetectionAccum
	local sensorParts = {}
	for i = 1, #sensorNames do
		local n = sensorNames[i]
		sensorParts[i] = string.format("  %s: %d detections", n, accum[n] or 0)
		accum[n] = 0
	end
	local sensorDetail = #sensorParts > 0 and ("\n" .. table.concat(sensorParts, "\n")) or ""
	self._logger:info(
		string.format(
			"status: batteries=%d, sensors=%d, c2nodes=%d, tracks=%d%s",
			self._assetIndex:batteries():count(),
			self._assetIndex:sensors():count(),
			self._assetIndex:c2Nodes():count(),
			trackCount,
			sensorDetail
		)
	)
end

-- Partition refresh and sensor polling

--- Returns the current partition-keyed sensor and battery radar sources eligible for polling.
--- @return table[] sources Poll-source records
function Medusa.Core.IadsNetwork:_buildPollList()
	local list = {}
	local sensorNames = self._assetIndex:sensors():getUniqueGroupNames()
	for i = 1, #sensorNames do
		local groupName = sensorNames[i]
		local sensors = self._assetIndex:sensors():getByGroupName(groupName)
		local sensor = nil
		for j = 1, #sensors do
			if sensors[j].PartitionKey then
				sensor = sensors[j]
				break
			end
		end
		if sensor then
			list[#list + 1] = {
				groupName = groupName,
				sourceType = trackSourceForSensor(sensor),
				partitionKey = sensor.PartitionKey,
			}
		end
	end
	local AS = Medusa.Constants.ActivationState
	local datalink = self._doctrine and self._doctrine.BatteryTargetDatalink
	local batteries = self._assetIndex:batteries():getAll()
	for i = 1, #batteries do
		local b = batteries[i]
		local canReport = b.ActivationState == AS.STATE_HOT
			or (b.ActivationState == AS.STATE_WARM and Medusa.Entities.Battery.hasSearchRadar(b))
		local localAcquisition = b.CoordinationState == Medusa.Constants.CoordinationState.DEGRADED and canReport
		if
			b.PartitionKey
			and (
				b.IsActingAsEWR
				or localAcquisition
				or (datalink and canReport and not Medusa.Entities.Battery.isIndependentAaa(b))
			)
		then
			list[#list + 1] = {
				groupName = b.GroupName,
				sourceType = trackSourceForBattery(b),
				partitionKey = b.PartitionKey,
			}
		end
	end
	return list
end

--- Publishes one staged partition snapshot or restores every changed Medusa field on failure.
--- @param pending table Completed partition refresh state
function Medusa.Core.IadsNetwork:_commitPartitionRefresh(pending)
	local sensorStore = self._assetIndex:sensors()
	local batteryRepository = self._assetIndex:batteryRepository()
	if
		sensorStore:count() > Medusa.Constants.C2.MAX_SENSORS
		or batteryRepository:count() > Medusa.Constants.C2.MAX_BATTERIES
	then
		error("partition publication population exceeds supported capacity")
	end
	local sensorChanges = {}
	local stagedSensors = {}
	for i = 1, #pending.Sensors do
		local captured = pending.Sensors[i]
		local sensor = sensorStore:get(captured.SensorUnitId)
		if sensor then
			stagedSensors[sensor.SensorUnitId] = true
			sensorChanges[#sensorChanges + 1] = {
				Sensor = sensor,
				PreviousPartitionKey = sensor.PartitionKey,
				PartitionKey = captured.PartitionKey,
			}
		end
	end
	local currentSensors = sensorStore:getAll({})
	for i = 1, #currentSensors do
		local sensor = currentSensors[i]
		if not stagedSensors[sensor.SensorUnitId] then
			local clusterKey = self._hierarchy:clusterKeyForGroup(sensor.GroupId)
			local partition = pending.PartitionByCluster[clusterKey]
			if not partition then
				error(string.format("no committed partition for dynamic sensor cluster '%s'", tostring(clusterKey)))
			end
			sensorChanges[#sensorChanges + 1] = {
				Sensor = sensor,
				PreviousPartitionKey = sensor.PartitionKey,
				PartitionKey = partition.Key,
			}
		end
	end
	local trackStore = self._trackManager:getStore()
	local batteryChanges = {}
	local assignmentReleases = {}
	local stagedBatteries = {}
	--- Stages one live battery's partition and control state and records any assignment that becomes invalid.
	--- @param battery table Battery entity
	--- @param partitionKey string Committed partition key
	--- @param coordinationState string Committed coordination state
	local function stageBattery(battery, partitionKey, coordinationState)
		batteryChanges[#batteryChanges + 1] = {
			Battery = battery,
			PreviousPartitionKey = battery.PartitionKey,
			PreviousCoordinationState = battery.CoordinationState,
			PartitionKey = partitionKey,
			CoordinationState = coordinationState,
		}
		local track = battery.CurrentTargetTrackId and trackStore:get(battery.CurrentTargetTrackId) or nil
		local candidate = setmetatable({
			PartitionKey = partitionKey,
			CoordinationState = coordinationState,
		}, { __index = battery })
		if track and not Medusa.Entities.Battery.canAcceptTrack(candidate, track, self._doctrine) then
			assignmentReleases[#assignmentReleases + 1] = {
				Battery = battery,
				Track = track,
				LastAssignmentChangeTime = battery.LastAssignmentChangeTime,
			}
		end
	end
	for i = 1, #pending.Batteries do
		local captured = pending.Batteries[i]
		local battery = batteryRepository:get(captured.BatteryId)
		if battery then
			stagedBatteries[battery.BatteryId] = true
			stageBattery(battery, captured.PartitionKey, captured.CoordinationState)
		end
	end
	local currentBatteries = batteryRepository:getAll({})
	local previousPartitionState =
		describePartitionState(self._partitionSnapshot and self._partitionSnapshot.PartitionByCluster, currentBatteries)
	for i = 1, #currentBatteries do
		local battery = currentBatteries[i]
		if not stagedBatteries[battery.BatteryId] then
			local clusterKey = self._hierarchy:clusterKeyForGroup(battery.GroupId)
			local partition = pending.PartitionByCluster[clusterKey]
			if not partition then
				error(string.format("no committed partition for dynamic battery cluster '%s'", tostring(clusterKey)))
			end
			stageBattery(battery, partition.Key, Medusa.Constants.CoordinationState.DEGRADED)
		end
	end
	if pending.ProviderOverflowCount > 0 then
		Medusa.Observability.MetricsService.inc(
			"medusa_partition_provider_overflow_total",
			pending.ProviderOverflowCount
		)
	end
	local previousSnapshot = self._partitionSnapshot
	local committed, failure = pcall(function()
		for i = 1, #sensorChanges do
			local change = sensorChanges[i]
			change.Sensor.PartitionKey = change.PartitionKey
		end
		for i = 1, #batteryChanges do
			local change = batteryChanges[i]
			change.Battery.PartitionKey = change.PartitionKey
			change.Battery.CoordinationState = change.CoordinationState
		end
		for i = 1, #assignmentReleases do
			Medusa.Entities.Battery.releaseTrack(assignmentReleases[i].Battery, trackStore)
		end
		self._partitionSnapshot = { PartitionByCluster = pending.PartitionByCluster }
	end)
	if committed then
		local partitionState = describePartitionState(pending.PartitionByCluster, currentBatteries)
		if partitionState ~= previousPartitionState then
			self._logger:info("partition state changed: " .. partitionState)
		end
		return
	end
	for i = 1, #sensorChanges do
		local change = sensorChanges[i]
		change.Sensor.PartitionKey = change.PreviousPartitionKey
	end
	for i = 1, #batteryChanges do
		local change = batteryChanges[i]
		change.Battery.PartitionKey = change.PreviousPartitionKey
		change.Battery.CoordinationState = change.PreviousCoordinationState
	end
	for i = 1, #assignmentReleases do
		local release = assignmentReleases[i]
		Medusa.Entities.Battery.assignTrack(
			release.Battery,
			release.Track,
			release.LastAssignmentChangeTime,
			trackStore
		)
	end
	self._partitionSnapshot = previousSnapshot
	error(failure)
end

--- Starts or advances one bounded partition refresh step at DCS mission time now.
--- @param now number Current mission time in seconds
function Medusa.Core.IadsNetwork:_runPartitionStep(now)
	if not self._partitionRefresh and now < self._nextPartitionRefreshAt then
		return
	end
	local ctx = self._partitionCtx
	if not self._partitionRefresh then
		Medusa.Observability.MetricsService.inc("medusa_partition_refresh_attempts_total")
		local ok, pending = pcall(Medusa.Services.PartitionService.begin, ctx, self._partitionSnapshot)
		if not ok then
			Medusa.Observability.MetricsService.inc("medusa_partition_refresh_failures_total")
			self._logger:error(string.format("partition refresh failed to start: %s", tostring(pending)))
			self._nextPartitionRefreshAt = now + Medusa.Constants.C2.REFRESH_INTERVAL_SEC
			return
		end
		self._partitionRefresh = pending
		self._nextPartitionRefreshAt = now + Medusa.Constants.C2.REFRESH_INTERVAL_SEC
	end
	local ok, done = pcall(Medusa.Services.PartitionService.step, self._partitionRefresh)
	if not ok then
		Medusa.Observability.MetricsService.inc("medusa_partition_refresh_failures_total")
		self._logger:error(string.format("partition refresh step failed: %s", tostring(done)))
		self._partitionRefresh = nil
		self._nextPartitionRefreshAt = now + Medusa.Constants.C2.REFRESH_INTERVAL_SEC
		return
	end
	if done then
		local committed, commitError = pcall(self._commitPartitionRefresh, self, self._partitionRefresh)
		if not committed then
			Medusa.Observability.MetricsService.inc("medusa_partition_refresh_failures_total")
			self._logger:error(string.format("partition refresh commit failed: %s", tostring(commitError)))
			self._partitionRefresh = nil
			self._nextPartitionRefreshAt = now + Medusa.Constants.C2.REFRESH_INTERVAL_SEC
			return
		end
		self._partitionRefresh = nil
	end
end

--- Publishes the conservative cluster-local partition snapshot and reports initialization success.
--- @return boolean initialized True when the bootstrap snapshot committed
function Medusa.Core.IadsNetwork:_initializePartitionSnapshot()
	Medusa.Observability.MetricsService.inc("medusa_partition_refresh_attempts_total")
	local ok, failure = pcall(function()
		local snapshot = Medusa.Services.PartitionService.bootstrap(self._partitionCtx)
		self:_commitPartitionRefresh(snapshot)
	end)
	if not ok then
		Medusa.Observability.MetricsService.inc("medusa_partition_refresh_failures_total")
		self._logger:error(string.format("partition bootstrap failed: %s", tostring(failure)))
		return false
	end
	return true
end

--- Records whether the current members of one sensor group have a usable controller observation.
--- @param groupName string DCS group name
--- @param available boolean Controller observation availability
function Medusa.Core.IadsNetwork:_setSensorGroupControllerAvailable(groupName, available)
	local sensors = self._assetIndex:sensors():getByGroupName(groupName)
	for i = 1, #sensors do
		sensors[i].ControllerAvailable = available
	end
end

--- Refreshes airborne positions and retries missing fixed-sensor positions without removing identities.
function Medusa.Core.IadsNetwork:_updateSensorPositions()
	local sensors = self._assetIndex:sensors():getAll()
	for i = 1, #sensors do
		local s = sensors[i]
		if (s.IsAirborne or s.PositionAvailable == false) and s.UnitName then
			local pos = GetUnitPosition(s.UnitName)
			if pos then
				s.Position = pos
				s.PositionAvailable = true
			else
				s.PositionAvailable = false
			end
		end
	end
end

--- Polls the bounded next slice of eligible radar sources and submits their partition-keyed reports.
function Medusa.Core.IadsNetwork:_pollSensors()
	local now = GetTime()
	self:_updateSensorPositions()
	local pollList = self:_buildPollList()
	local count = #pollList
	if count == 0 then
		return
	end
	local budget = self._sensorPollBudget
	local polled = 0
	local idx = self._sensorPollIndex
	local accum = self._pollDetectionAccum
	local totalDetections = 0
	local remainingDetections = Medusa.Constants.C2.DETECTION_PROCESSING_BUDGET
	while polled < budget and polled < count and remainingDetections > 0 do
		if idx > count then
			idx = 1
		end
		local source = pollList[idx]
		local name = source.groupName
		local reports, inspected, nextOffset = self._sensorPollingService:pollSensor(
			name,
			now,
			source.sourceType,
			source.partitionKey,
			remainingDetections,
			self._sensorDetectionOffsets[name] or 1
		)
		if not reports then
			self:_setSensorGroupControllerAvailable(name, false)
		else
			self:_setSensorGroupControllerAvailable(name, true)
			self._sensorDetectionOffsets[name] = nextOffset
			remainingDetections = remainingDetections - inspected
			accum[name] = (accum[name] or 0) + #reports
			if #reports == 0 then
				Medusa.Observability.MetricsService.inc("medusa_sensor_empty_polls_total")
			end
			totalDetections = totalDetections + #reports
			for i = 1, #reports do
				self._trackManager:processReport(reports[i], now)
			end
		end
		idx = idx + 1
		polled = polled + 1
	end
	self._sensorPollIndex = idx
	if totalDetections > 0 then
		Medusa.Observability.MetricsService.inc("medusa_detections_total", totalDetections)
	end
end

--[[
Assignment pipeline (one phase per assignment interval):
  Phase 0 - Classify:  track identification + aircraft type assessment (chunked)
  Phase 1 - HARM:      HARM detection (chunked) + response + point defense (full pass)
  Phase 2 - Assign:    EMCON self-assign + WTA + retry goHot (full pass, greedy)
  Phase 3 - Maintain:  handoff eval + deactivation checks (chunked) + HARM cleanup
  Phase 4 - EMCON:     emission control policy (full pass)

Each chunked phase drains its queue up to its declared budget.
When the queue empties, the next invocation refills from the current store snapshot.
]]

local _phaseNames = { [0] = "classify", "harm", "assign", "maintain", "emcon" }

--- Records one recurring owner's consecutive result and enters safe stop at the configured limit.
--- @param network Medusa.Core.IadsNetwork Network owner
--- @param failures table<any, number> Consecutive-failure counters
--- @param key any Failure-counter key
--- @param owner string Recurring-work owner name
--- @param ok boolean Operation result
--- @param failure any Failure value
--- @return boolean succeeded True when the operation succeeded
local function recordRecurringResult(network, failures, key, owner, ok, failure)
	if ok then
		failures[key] = 0
		return true
	end
	local count = (failures[key] or 0) + 1
	failures[key] = count
	if count == 1 or count % 100 == 0 then
		network._logger:error(string.format("%s failed (%dx): %s", owner, count, tostring(failure)))
	end
	if count >= network._failureLimit then
		network:_stopAfterPersistentFailure(owner, count)
	end
	return false
end

--- Runs the next assignment-pipeline phase and advances the round-robin phase cursor.
--- @return boolean succeeded True when the selected phase completed
function Medusa.Core.IadsNetwork:_runPhase()
	local ctx = self._ctx
	ctx.trackStore = self._trackManager:getStore()
	ctx.batteryStore = self._assetIndex:batteries()
	ctx.batteryRepository = self._assetIndex:batteryRepository()
	ctx.manpadStore = self._assetIndex:manpads()
	ctx.networkedGeoGrid = self._assetIndex:networkedGeoGrid()
	ctx.localGeoGrid = self._assetIndex:localGeoGrid()
	ctx.geoGrid = ctx.networkedGeoGrid
	ctx.spatialIndex = self._spatialIndex
	ctx.sensorStore = self._assetIndex:sensors()
	ctx.now = GetTime()
	ctx.maxRange = self._maxEngagementRange
	ctx.doctrine = self._doctrine
	ctx.borderPolygons = self._borderPolygons
	ctx.adizPolygon = self._adizPolygon
	ctx.coalitionId = self._coalitionId
	ctx.hpt = Medusa.hpTimer
	ctx.MS = Medusa.Observability.MetricsService
	local phase = self._assignmentPhase
	local ok, err
	if phase == 0 then
		ok, err = pcall(self._phaseClassify, self, ctx)
	elseif phase == 1 then
		ok, err = pcall(self._phaseHarmAndPD, self, ctx)
	elseif phase == 2 then
		ok, err = pcall(self._phaseAssign, self, ctx)
	elseif phase == 3 then
		ok, err = pcall(self._phaseMaintain, self, ctx)
	elseif phase == 4 then
		ok, err = pcall(self._phaseEmcon, self, ctx)
	end

	local succeeded = recordRecurringResult(
		self,
		self._phaseFailures,
		phase,
		"phase " .. tostring(_phaseNames[phase] or phase),
		ok,
		err
	)
	ctx.MS.set("medusa_phase_failures_consecutive", self._phaseFailures[phase] or 0, _phaseLabels[phase])

	self._assignmentPhase = (phase + 1) % 5
	return succeeded
end

-- Phase 0

--- Advances bounded track classification and aircraft-type assessment work.
--- @param ctx table Shared assignment-pipeline context
function Medusa.Core.IadsNetwork:_phaseClassify(ctx)
	local TC = Medusa.Services.TrackClassifier
	local step = self._classifyStep
	local t1 = ctx.hpt()

	local guiltEnabled = not ctx.doctrine or ctx.doctrine.GuiltByAssociation ~= false

	local allTracks = ctx.trackStore:getAll(_assignBatteryBuffer)
	local freshCycle = step:fill(allTracks)
	if freshCycle then
		TC.clearPromotedBuffer()
	end

	local processed = 0
	for _ = 1, step.budget do
		local track = step:next()
		if not track then
			break
		end
		local promotion = TC.classifyTrack(track, ctx)
		if promotion then
			TC._promotedBuffer[#TC._promotedBuffer + 1] = promotion
		end
		TC.assessSingleAircraftType(track)
		processed = processed + 1
	end

	if step:isEmpty() and guiltEnabled then
		TC.flushGuiltByAssociation(allTracks, ctx)
	end

	logChunk(self, ctx.MS, "classify", processed, step:remaining())
	ctx.MS.observe("medusa_classification_duration_seconds", ctx.hpt() - t1)
end

-- Phase 1

--- Advances prioritized HARM assessment, response, and point-defense work.
--- @param ctx table Shared assignment-pipeline context
function Medusa.Core.IadsNetwork:_phaseHarmAndPD(ctx)
	local HDS = Medusa.Services.HarmDetectionService
	local step = self._harmDetectStep
	local t1 = ctx.hpt()

	local allTracks = ctx.trackStore:getAll(_assignBatteryBuffer)
	local trackCount = #allTracks
	local ballisticDt, ballisticMaxT, threatRadiusM = HDS.getAssessContext(ctx)

	local totalBudget = math.max(step.budget, math.ceil(trackCount * 0.25))

	-- Build priority keys: confirmed HARMs first, then altitude times speed.
	local AAT = Medusa.Constants.AssessedAircraftType
	local keys = self._harmPriorityKeys
	local sortBuf = self._harmSortBuffer
	for i = 1, trackCount do
		local track = allTracks[i]
		if track.AssessedAircraftType == AAT.HARM then
			keys[i] = math.huge
		else
			local vel = track.Velocity
			local alt = track.Position and track.Position.y or 0
			local speed = vel and VecLength2D(vel) or 0
			keys[i] = alt * speed
		end
		sortBuf[i] = i
	end
	-- Clear excess entries from previous tick
	for i = trackCount + 1, #sortBuf do
		sortBuf[i] = nil
	end
	for i = trackCount + 1, #keys do
		keys[i] = nil
	end

	-- Sort indices descending by priority key
	table.sort(sortBuf, function(a, b)
		return keys[a] > keys[b]
	end)

	-- Pass 1: Priority tier -- top 1/3, evaluated every tick
	local priorityCount = math.ceil(trackCount / 3)
	local priorityProcessed = 0
	for i = 1, priorityCount do
		local track = allTracks[sortBuf[i]]
		if track and track.LifecycleState == _LS.ACTIVE then
			HDS.assessSingleTrack(
				track,
				allTracks,
				ctx.geoGrid,
				ctx.batteryStore,
				ballisticDt,
				ballisticMaxT,
				threatRadiusM
			)
			priorityProcessed = priorityProcessed + 1
		end
	end

	-- Pass 2: Normal tier -- remaining tracks, chunked
	local normalBuf = self._harmNormalBuffer
	local normalCount = 0
	for i = priorityCount + 1, trackCount do
		local track = allTracks[sortBuf[i]]
		if track then
			normalCount = normalCount + 1
			normalBuf[normalCount] = track
		end
	end
	for i = normalCount + 1, #normalBuf do
		normalBuf[i] = nil
	end
	step:fill(normalBuf)

	local minNormalBudget = math.floor(step.budget / 3)
	local remainingBudget = totalBudget - priorityProcessed
	local normalBudget = math.max(minNormalBudget, remainingBudget)
	local normalProcessed = 0
	for _ = 1, normalBudget do
		local track = step:next()
		if not track then
			break
		end
		HDS.assessSingleTrack(
			track,
			allTracks,
			ctx.geoGrid,
			ctx.batteryStore,
			ballisticDt,
			ballisticMaxT,
			threatRadiusM
		)
		normalProcessed = normalProcessed + 1
	end

	logChunk(self, ctx.MS, "harm_detect", priorityProcessed + normalProcessed, step:remaining())

	-- Full-pass: HARM response + derived point defense (usually few HARMs, not worth chunking)
	Medusa.Services.HarmResponseService.executeResponse(ctx)

	ctx.MS.observe("medusa_harm_eval_duration_seconds", ctx.hpt() - t1)
end

-- Phase 2

--- Applies target assignment and point-defense engagement policy using the current phase context ctx.
--- @param ctx table Shared assignment-pipeline context
function Medusa.Core.IadsNetwork:_phaseAssign(ctx)
	local TargetAssigner = Medusa.Services.TargetAssigner
	local BAS = Medusa.Services.BatteryActivationService
	local t1 = ctx.hpt()

	local autoAssignments = TargetAssigner.emconSelfAssign(ctx)
	for i = 1, #autoAssignments do
		local a = autoAssignments[i]
		local battery = ctx.batteryStore:get(a.batteryId)
		local track = ctx.trackStore:get(a.trackId)
		if
			battery
			and (battery.ActivationState == Medusa.Constants.ActivationState.STATE_HOT or BAS.goHot(battery, ctx.now))
		then
			self._logger:info(
				string.format(
					"battery %s HOT (EMCON self-assign) for track %s",
					battery.GroupName,
					Medusa.Entities.Track.displayId(track)
				)
			)
		elseif battery then
			Medusa.Entities.Battery.releaseTrack(battery, ctx.trackStore, track)
		end
	end

	local assignments = TargetAssigner.assignTargets(ctx)
	for i = 1, #assignments do
		local a = assignments[i]
		local track = ctx.trackStore:get(a.trackId)
		if track and track.Position then
			Medusa.Services.ManpadService.cueFromIADS(ctx, track.Position, track)
		end
		local battery = ctx.batteryStore:get(a.batteryId)
		if
			battery
			and (battery.ActivationState == Medusa.Constants.ActivationState.STATE_HOT or BAS.goHot(battery, ctx.now))
		then
			self._logger:info(
				string.format("battery %s HOT for track %s", a.batteryId, Medusa.Entities.Track.displayId(track))
			)
		elseif battery then
			Medusa.Entities.Battery.releaseTrack(battery, ctx.trackStore, track)
		end
	end

	local AS = Medusa.Constants.ActivationState
	local allBatteries = ctx.batteryStore:getAll(_assignBatteryBuffer)
	for i = 1, #allBatteries do
		local battery = allBatteries[i]
		if battery.CurrentTargetTrackId and battery.ActivationState ~= AS.STATE_HOT then
			if BAS.goHot(battery, ctx.now) then
				local track = ctx.trackStore:get(battery.CurrentTargetTrackId)
				self._logger:info(
					string.format(
						"battery %s HOT for track %s (retry)",
						battery.BatteryId,
						Medusa.Entities.Track.displayId(track)
					)
				)
			else
				Medusa.Entities.Battery.releaseTrack(battery, ctx.trackStore)
			end
		end
	end

	ctx.MS.observe("medusa_assignment_duration_seconds", ctx.hpt() - t1)
	ctx.MS.inc("medusa_engagements_assigned_total", #autoAssignments + #assignments)
end

-- Phase 3

--- Advances bounded handoff and deactivation work and clears expired HARM shutdowns.
--- @param ctx table Shared assignment-pipeline context
function Medusa.Core.IadsNetwork:_phaseMaintain(ctx)
	local TargetAssigner = Medusa.Services.TargetAssigner
	local BAS = Medusa.Services.BatteryActivationService
	local t1 = ctx.hpt()

	local allBatteries = ctx.batteryStore:getAll(_assignBatteryBuffer)

	-- Chunked handoff evaluation
	local handoffStep = self._handoffStep
	handoffStep:fill(allBatteries)
	local handoffProcessed = 0
	for _ = 1, handoffStep.budget do
		local battery = handoffStep:next()
		if not battery then
			break
		end
		local result = TargetAssigner.evaluateSingleHandoff(battery, ctx)
		if result then
			local bat = ctx.batteryStore:get(result.batteryId)
			if bat then
				local track = ctx.trackStore:get(result.trackId)
				Medusa.Entities.Battery.releaseTrack(bat, ctx.trackStore)
				bat.LastAssignmentChangeTime = ctx.now
				Medusa.Entities.Battery.beginLastChance(bat, result.trackId, ctx.doctrine.HoldDownSec or 15)
				ctx.MS.inc("medusa_last_chance_activated_total")
				self._logger:info(
					string.format(
						"battery %s released track %s (last-chance)",
						bat.GroupName,
						Medusa.Entities.Track.displayId(track)
					)
				)
			end
		end
		handoffProcessed = handoffProcessed + 1
	end
	logChunk(self, ctx.MS, "handoff", handoffProcessed, handoffStep:remaining())

	-- Chunked deactivation checks
	local deactStep = self._deactivationStep
	deactStep:fill(allBatteries)
	local deactProcessed = 0
	for _ = 1, deactStep.budget do
		local battery = deactStep:next()
		if not battery then
			break
		end
		local result = TargetAssigner.checkSingleDeactivation(battery, ctx)
		if result then
			Medusa.Entities.Battery.releaseTrack(result.battery, ctx.trackStore)
			if BAS.goCold(result.battery, ctx.now, ctx.trackStore) then
				self._logger:info(string.format("battery %s deactivated (%s)", result.battery.GroupName, result.reason))
			end
		end
		deactProcessed = deactProcessed + 1
	end
	logChunk(self, ctx.MS, "deactivation", deactProcessed, deactStep:remaining())

	-- Full-pass: clear expired HARM shutdowns
	for i = 1, #allBatteries do
		local battery = allBatteries[i]
		if battery.HarmShutdownUntil and ctx.now >= battery.HarmShutdownUntil then
			battery.HarmShutdownUntil = nil
		end
	end

	ctx.MS.observe("medusa_handoff_duration_seconds", ctx.hpt() - t1)
end

-- Phase 4

--- Applies emission-control policy and adaptive probability-of-kill decay.
--- @param ctx table Shared assignment-pipeline context
function Medusa.Core.IadsNetwork:_phaseEmcon(ctx)
	local t1 = ctx.hpt()
	Medusa.Services.EmconService.applyPolicy(ctx, self)
	self:_decayEffectivePkFloor(ctx.now)
	ctx.MS.observe("medusa_emcon_duration_seconds", ctx.hpt() - t1)
end

--- Runs one contained MANPAD evaluation and records its recurring result.
--- @return boolean succeeded True when the MANPAD evaluation completed
function Medusa.Core.IadsNetwork:_runManpadPhase()
	local ctx = self._manpadCtx
	ctx.manpadStore = self._assetIndex:manpads()
	ctx.trackStore = self._trackManager:getStore()
	ctx.networkedGeoGrid = self._assetIndex:networkedGeoGrid()
	ctx.localGeoGrid = self._assetIndex:localGeoGrid()
	ctx.now = GetTime()
	ctx.posture = self._doctrine and self._doctrine.Posture or Medusa.Constants.Posture.HOT_WAR
	ctx.doctrine = self._doctrine
	ctx.coalitionId = self._coalitionId
	local MS = Medusa.Observability.MetricsService
	local hpt = Medusa.hpTimer
	local t1 = hpt()

	local ok, err = pcall(Medusa.Services.ManpadService.evaluate, ctx)
	MS.observe("medusa_manpad_eval_duration_seconds", hpt() - t1)
	return recordRecurringResult(self, self._periodicFailures, "manpad", "manpad phase", ok, err)
end

--- Runs one contained AAA evaluation and records its recurring result.
--- @return boolean succeeded True when the AAA evaluation completed
function Medusa.Core.IadsNetwork:_runAaaPhase()
	local ctx = self._aaaCtx
	ctx.networkId = self._id
	ctx.barrageState = self._aaaBarrageState
	ctx.batteryStore = self._assetIndex:batteries()
	ctx.trackStore = self._trackManager:getStore()
	ctx.localGeoGrid = self._assetIndex:localGeoGrid()
	ctx.spatialIndex = self._spatialIndex
	ctx.now = GetTime()
	ctx.posture = self._doctrine and self._doctrine.Posture or Medusa.Constants.Posture.HOT_WAR
	ctx.doctrine = self._doctrine
	ctx.coalitionId = self._coalitionId
	local MS = Medusa.Observability.MetricsService
	local hpt = Medusa.hpTimer
	local t1 = hpt()
	local ok, err = pcall(Medusa.Services.AaaService.evaluate, ctx)
	MS.observe("medusa_aaa_eval_duration_seconds", hpt() - t1)
	return recordRecurringResult(self, self._periodicFailures, "aaa", "AAA phase", ok, err)
end

--- Refreshes a bounded unit-position slice and reconciles confirmed unit deaths.
--- @return boolean succeeded True when the refresh operation completed
function Medusa.Core.IadsNetwork:_runUnitPositionRefreshPhase()
	local ok, visited, refreshed, aaaRefreshed, manpadRefreshed =
		pcall(Medusa.Services.CrewPerceptionService.refreshUnitPositions, {
			batteryRepository = self._assetIndex:batteryRepository(),
			spatialIndex = self._spatialIndex,
			now = GetTime(),
			budget = Medusa.Constants.CrewSuppression.UNIT_POSITION_REFRESH_BUDGET,
			--- Reconciles one exact battery-unit identity after a confirmed death observation.
			--- @param battery table Battery entity
			--- @param unit table Battery unit entity
			onUnitConfirmedDead = function(battery, unit)
				self:_handleUnitDeath(unit.UnitId, unit.UnitName, { BatteryId = battery.BatteryId })
			end,
		})
	if not recordRecurringResult(self, self._periodicFailures, "unitPositions", "unit-position phase", ok, visited) then
		return false
	end
	if refreshed > 0 then
		Medusa.Observability.MetricsService.inc("medusa_battery_unit_position_refreshes_total", refreshed)
	end
	if aaaRefreshed > 0 then
		Medusa.Observability.MetricsService.inc("medusa_aaa_position_refreshes_total", aaaRefreshed)
	end
	if manpadRefreshed > 0 then
		Medusa.Observability.MetricsService.inc("medusa_manpad_position_refreshes_total", manpadRefreshed)
	end
	self._logger:trace(string.format("unit position refresh: visited=%d refreshed=%d", visited, refreshed))
	self:_recordRecurringWork("unit_refresh", visited, 0, 0)
	return true
end

--- Applies cached detection ranges and requests probing for unresolved dynamic battery types.
--- @param battery table Newly admitted battery entity
function Medusa.Core.IadsNetwork:_applyDynamicBatteryRanges(battery)
	local probing = self._probingService
	local iads = self
	local maxDetRange = nil
	local uncachedTypes = nil
	local uncachedCount = 0
	for i = 1, #battery.Units do
		local unit = battery.Units[i]
		local typeName = unit.UnitTypeName
		if Medusa.Entities.Battery.canSupplyDetectionRange(battery, unit) and typeName then
			local caps = probing:getCapabilities(typeName)
			if caps and caps.detectionRangeMax then
				if not maxDetRange or caps.detectionRangeMax > maxDetRange then
					maxDetRange = caps.detectionRangeMax
				end
			elseif caps == nil then
				uncachedCount = uncachedCount + 1
				if not uncachedTypes then
					uncachedTypes = {}
				end
				uncachedTypes[typeName] = true
			end
		end
	end

	if maxDetRange then
		battery.DetectionRangeMax = maxDetRange
		Medusa.Entities.Battery.computeEngagementRange(battery)
		self._spatialIndex:syncBattery(battery)
		self:_updateMaxEngagementRange(battery)
		self._logger:info(
			string.format("dynamic battery %s: applied cached detection range %.0fm", battery.GroupName, maxDetRange)
		)
	end

	if uncachedCount == 0 then
		return
	end

	if not Medusa.Config:get().AllowDynamicProbing then
		self._logger:info(
			string.format(
				"dynamic battery %s: %d unit types not in probe cache (AllowDynamicProbing=false)",
				battery.GroupName,
				uncachedCount
			)
		)
		return
	end

	local typePositions = {}
	for typeName in pairs(uncachedTypes) do
		typePositions[typeName] = battery.Position
	end

	probing:probeAll(typePositions, function()
		iads:_onProbingComplete()
	end)
end

--- Applies completed probe results to current sensors, batteries, and spatial ranges.
function Medusa.Core.IadsNetwork:_onProbingComplete()
	local probing = self._probingService
	local sensorCount = probing:applySensorRanges(self._assetIndex:sensors())
	local batteryCount = probing:applyBatteryRanges(self._assetIndex:batteries())
	self._logger:info(
		string.format("probing complete: applied ranges to %d sensors, %d batteries", sensorCount, batteryCount)
	)
	local batteries = self._assetIndex:batteries():getAll()
	for i = 1, #batteries do
		self._spatialIndex:syncBattery(batteries[i])
		self:_updateMaxEngagementRange(batteries[i])
	end
end

--- Applies initial battery control policy and reports whether every required wrapper returned true.
--- @return boolean complete True when initial control policy is confirmed
function Medusa.Core.IadsNetwork:_completeErectInitialization()
	local statesReady = false
	local ok, err = pcall(function()
		statesReady = self:_initializeBatteryStates()
		if not statesReady then
			return
		end
		local initCtx = {
			batteryStore = self._assetIndex:batteries(),
			sensorStore = self._assetIndex:sensors(),
			geoGrid = self._assetIndex:networkedGeoGrid(),
			doctrine = self._doctrine,
			now = GetTime(),
		}
		Medusa.Services.EmconService.updateSamAsEwrSelection(initCtx)
		Medusa.Services.PointDefenseService.reconcileProviders(initCtx)
	end)
	if not ok then
		self._logger:error(string.format("erect initialization failed: %s", tostring(err)))
		return false
	end
	if not statesReady then
		self._logger:error("erect initialization incomplete: a battery wrapper returned false")
		return false
	end
	self._erectComplete = true
	self._erectReadyAt = nil
	self._erectRetryAt = nil
	self._logger:info("erect complete: doctrine states applied")
	return true
end

--- Completes every required mission bootstrap step before operational ticks can run.
--- @param now number Current mission time in seconds
--- @return boolean complete True when bootstrap state is published
function Medusa.Core.IadsNetwork:_completeBootstrap(now)
	if not self:_runScanAndLog() then
		return false
	end
	self._hierarchy:freezeC2Topology()
	if not self:_initializePartitionSnapshot() then
		error("partition bootstrap did not publish a snapshot")
	end
	self._nextPartitionRefreshAt = now
	self:_populateGeoGrid()
	self:_fastErectBatteries()
	self:_applyInitialCrewSuppression(now)
	self:_probeAirborneSensors()
	local typePositions = self:_collectProbeTargets()
	if next(typePositions) then
		self._probingService:probeAll(typePositions, function()
			self:_onProbingComplete()
		end)
	end
	self._erectReadyAt = now + 60
	self._bootstrapComplete = true
	self._bootstrapRetryAt = nil
	return true
end

-- Recurring scheduler

--- Advances bootstrap and reports whether normal operational work can run in this tick.
--- @param now number Current mission time in seconds
--- @return boolean operational True when bootstrap was already complete
function Medusa.Core.IadsNetwork:_advanceBootstrap(now)
	if self._bootstrapComplete then
		return true
	end
	if self._bootstrapRetryAt and now < self._bootstrapRetryAt then
		return false
	end
	local ok, completed = pcall(self._completeBootstrap, self, now)
	if not ok or not completed then
		self._bootstrapRetryAt = now + Medusa.Constants.C2.BOOTSTRAP_RETRY_SEC
		if not ok then
			error(completed)
		end
		return false
	end
	self._tickCounter = self._tickCounter + 1
	return false
end

--- Retries initial doctrine readiness when its erect delay and retry deadline are due.
--- @param now number Current mission time in seconds
function Medusa.Core.IadsNetwork:_retryErectInitialization(now)
	if
		not self._erectComplete
		and self._erectReadyAt
		and now >= self._erectReadyAt
		and (not self._erectRetryAt or now >= self._erectRetryAt)
		and not self:_completeErectInitialization()
	then
		self._erectRetryAt = now + 1
	end
end

--- Publishes the current bounded queue depths for this network.
--- @param metricsService table Metrics service
function Medusa.Core.IadsNetwork:_publishQueueDepthMetrics(metricsService)
	metricsService.set(
		"medusa_world_event_queue_depth",
		self._deathQueue:size() + self._deathOverflowQueue:size(),
		self._deathEventMetricLabels
	)
	metricsService.set("medusa_world_event_queue_depth", self._shotQueue:size(), self._shotEventMetricLabels)
	metricsService.set("medusa_world_event_queue_depth", self._killQueue:size(), self._killEventMetricLabels)
	metricsService.set(
		"medusa_world_event_queue_depth",
		self._discovery:pendingDynamicAdds(),
		self._birthEventMetricLabels
	)
	metricsService.set("medusa_ammo_reconciliation_queue_depth", #self._ammoReconcileIds, self._metricLabels)
end

--- Advances bounded event, ammunition, rearm, and partition work for one tick.
--- @param now number Current mission time in seconds
--- @param metricsService table Metrics service
function Medusa.Core.IadsNetwork:_processDeferredWork(now, metricsService)
	self._discovery:processDynamicAdds(Medusa.Constants.WorldEventQueue.BIRTH_PROCESSING_BUDGET)
	self:_processDeathEvents(Medusa.Constants.WorldEventQueue.DEATH_PROCESSING_BUDGET)
	self:_processDeathOverflow(Medusa.Constants.WorldEventQueue.DEATH_OVERFLOW_RECOVERY_BUDGET)
	self:_processHitEvents(Medusa.Constants.CrewSuppression.HIT_EVENT_PROCESSING_BUDGET)
	self:_processTerminalEvents(
		Medusa.Constants.CrewSuppression.IMPACT_PROCESSING_BUDGET,
		Medusa.Constants.CrewSuppression.IMPACT_UNIT_VISIT_BUDGET
	)
	self:_processShotEvents(Medusa.Constants.WorldEventQueue.SHOT_PROCESSING_BUDGET)
	self:_processKillEvents(Medusa.Constants.WorldEventQueue.KILL_PROCESSING_BUDGET)
	self:_processAmmoReconciliation(Medusa.Constants.WorldEventQueue.AMMO_RECONCILIATION_BUDGET, now)
	if self._erectComplete and now >= self._nextErectRetrySweepAt then
		self._nextErectRetrySweepAt = now + 1
		self:_retryPendingErects(2, now)
	end
	self:_publishQueueDepthMetrics(metricsService)
	self:_checkRearming(now)
	self:_runPartitionStep(now)
end

--- Polls sensors and prunes stale tracks while recording each operation duration.
--- @param now number Current mission time in seconds
--- @param highPrecisionTime fun(): number High-precision timer
--- @param metricsService table Metrics service
function Medusa.Core.IadsNetwork:_pollAndPruneTracks(now, highPrecisionTime, metricsService)
	local startedAt = highPrecisionTime()
	self:_pollSensors()
	metricsService.observe("medusa_poll_sensors_duration_seconds", highPrecisionTime() - startedAt)
	startedAt = highPrecisionTime()
	self._trackManager:pruneStale(now)
	metricsService.observe("medusa_prune_stale_duration_seconds", highPrecisionTime() - startedAt)
end

--- Runs each operational phase that is due for the current tick counter.
--- @return boolean succeeded True when every due phase completed
function Medusa.Core.IadsNetwork:_runDueOperationalPhases()
	if self._erectComplete and (self._tickCounter % self._assignmentInterval) == 0 and not self:_runPhase() then
		return false
	end
	if self._erectComplete and (self._tickCounter % self._manpadInterval) == 0 and not self:_runManpadPhase() then
		return false
	end
	if self._erectComplete and (self._tickCounter % self._aaaInterval) == 0 and not self:_runAaaPhase() then
		return false
	end
	if
		self._erectComplete
		and (self._tickCounter % self._unitPosRefreshInterval) == 0
		and not self:_runUnitPositionRefreshPhase()
	then
		return false
	end
	return true
end

--- Executes one bounded network tick at the current DCS mission time.
function Medusa.Core.IadsNetwork:tick()
	if not self._running then
		return
	end

	local MetricsService = Medusa.Observability.MetricsService
	MetricsService.setContext(self._metricLabels)
	MetricsService.inc("medusa_ticks_total")

	local now = GetTime()
	local hpt = Medusa.hpTimer
	local t0 = hpt()
	local memBefore = collectgarbage("count")
	self:_runBlackBoxWeaponObservations(now)

	if not self:_advanceBootstrap(now) then
		return
	end
	self._tickCounter = self._tickCounter + 1
	self:_retryErectInitialization(now)
	self:_processDeferredWork(now, MetricsService)
	self:_pollAndPruneTracks(now, hpt, MetricsService)
	if not self:_runDueOperationalPhases() then
		return
	end

	if (self._tickCounter % 4) == 0 then
		self:_logAssetSummary(now)
	end
	self:_logRecurringWorkSummary(now)

	MetricsService.set("medusa_tick_memory_before_kb", memBefore)
	MetricsService.set("medusa_tick_memory_after_kb", collectgarbage("count"))
	MetricsService.observe("medusa_tick_duration_seconds", hpt() - t0)
end

--- Registers the next protected network tick and enters safe stop if no timer handle is returned.
--- @return boolean scheduled True when DCS returned a timer handle
function Medusa.Core.IadsNetwork:_scheduleNext()
	local registered, timerId = pcall(ScheduleOnce, self._tickCallback, nil, self._tickIntervalSec)
	if not registered or not timerId then
		self:_stopRuntime()
		pcall(
			self._logger.error,
			self._logger,
			string.format(
				"tick scheduling failed; Medusa stopped without raising into the mission: %s",
				tostring(timerId)
			)
		)
		return false
	end
	self._timerId = timerId
	return true
end

--- Contains one recurring callback, records failure, and preserves or safely stops timer ownership.
function Medusa.Core.IadsNetwork:_onTick()
	local contained, failure = pcall(function()
		if not self._running then
			return
		end
		local ok, err = pcall(self.tick, self)
		if not ok then
			self._tickFailures = self._tickFailures + 1
			if self._tickFailures == 1 or self._tickFailures % 100 == 0 then
				self._logger:error(
					string.format("tick %d failed (%dx): %s", self._tickCounter, self._tickFailures, tostring(err))
				)
			end
			if self._tickFailures >= self._failureLimit then
				self:_stopAfterPersistentFailure("network tick", self._tickFailures)
				return
			end
		else
			self._tickFailures = 0
		end
		Medusa.Observability.MetricsService.set("medusa_tick_failures_consecutive", self._tickFailures)
		if self._running then
			self:_scheduleNext()
		end
	end)
	if contained then
		return
	end
	self:_stopRuntime()
	pcall(
		self._logger.error,
		self._logger,
		string.format("tick callback finalization failed; Medusa stopped: %s", tostring(failure))
	)
end

-- Public read-only accessors

--- Returns this network's hierarchy owner.
--- @return Medusa.Services.HierarchyService hierarchy Hierarchy owner
function Medusa.Core.IadsNetwork:getHierarchy()
	return self._hierarchy
end

--- Returns this network's track manager.
--- @return Medusa.Services.TrackManager trackManager Track manager
function Medusa.Core.IadsNetwork:getTrackManager()
	return self._trackManager
end

--- Returns the aggregate store access point for this network.
--- @return table assetIndex Asset index
function Medusa.Core.IadsNetwork:getAssetIndex()
	return self._assetIndex
end

--- Returns this network's active doctrine.
--- @return table doctrine Active doctrine
function Medusa.Core.IadsNetwork:getDoctrine()
	return self._doctrine
end

--- Returns configured border polygons in DCS ground coordinates.
--- @return table[] polygons Border polygons as ground Vec3 lists
function Medusa.Core.IadsNetwork:getBorderPolygons()
	return self._borderPolygons
end

--- Returns configured border polygons in latitude and longitude coordinates.
--- @return table[] polygons Border polygons as latitude-longitude point lists
function Medusa.Core.IadsNetwork:getBorderPolygonsLL()
	return self._borderPolygonsLL
end

--- Returns the active doctrine posture or the safe default posture.
--- @return string posture Doctrine posture
function Medusa.Core.IadsNetwork:getPosture()
	return self._doctrine and self._doctrine.Posture or Medusa.Constants.Posture.HOT_WAR
end
