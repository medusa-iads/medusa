require("_header")
require("core.Core")
require("core.Config")
require("core.Logger")
require("services.DiscoveryService")
require("services.HierarchyService")
require("services.TrackManager")
require("entities.Battery")
require("services.stores.BatteryStore")
require("services.SensorPollingService")
require("services.TargetAssigner")
require("services.TrackClassifier")
require("services.BatteryActivationService")
require("services.EmconService")
require("services.HarmDetectionService")
require("services.HarmResponseService")
require("services.EntityFactory")
require("services.AssetIndex")
require("services.stores.SensorUnitStore")
require("services.SensorProbingService")
require("services.stores.C2NodeStore")
require("services.stores.AirspaceZoneStore")
require("services.stores.AirbaseStore")
require("services.stores.InterceptorGroupStore")
require("entities.Doctrine")
require("services.PointDefenseService")
require("services.MetricsService")
require("services.BlackBoxService")
require("services.MetricsSnapshotService")

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
---@field _lastScanTime number
---@field new fun(self: Medusa.Core.IadsNetwork): Medusa.Core.IadsNetwork
---@field initialize fun(self: Medusa.Core.IadsNetwork): boolean
---@field start fun(self: Medusa.Core.IadsNetwork): boolean
---@field stop fun(self: Medusa.Core.IadsNetwork): boolean
---@field tick fun(self: Medusa.Core.IadsNetwork)
---@field getHierarchy fun(self: Medusa.Core.IadsNetwork): Medusa.Services.HierarchyService

Medusa.Core.IadsNetwork = {}

Medusa.Core.IadsNetwork._assignBatteryBuffer = {}
local _assignBatteryBuffer = Medusa.Core.IadsNetwork._assignBatteryBuffer

--- ChunkStep: queue-based chunked work processor.
--- Fills from a snapshot when drained, processes up to budget items per tick.
--- Items that fail the isValid check are silently skipped on dequeue.
local ChunkStep = {}
ChunkStep.__index = ChunkStep

function ChunkStep.new(budget, isValid)
	return setmetatable({ _queue = Queue(), budget = budget, _isValid = isValid }, ChunkStep)
end

function ChunkStep:fill(items)
	if not self._queue:isEmpty() then
		return false
	end
	for i = 1, #items do
		self._queue:enqueue(items[i])
	end
	return true
end

function ChunkStep:next()
	while not self._queue:isEmpty() do
		local item = self._queue:dequeue()
		if not self._isValid or self._isValid(item) then
			return item
		end
	end
	return nil
end

function ChunkStep:isEmpty()
	return self._queue:isEmpty()
end

function ChunkStep:remaining()
	return self._queue:size()
end

local _chunkLabels = {
	classify = { phase = "classify" },
	harm_detect = { phase = "harm_detect" },
	handoff = { phase = "handoff" },
	deactivation = { phase = "deactivation" },
}

local _LS = Medusa.Constants.TrackLifecycleState
local function _isTrackAlive(track)
	return track and track.LifecycleState == _LS.ACTIVE
end

local function logChunk(logger, MS, phaseName, processed, remaining)
	logger:debug(string.format("phase %s: processed %d, queued %d", phaseName, processed, remaining))
	local labels = _chunkLabels[phaseName]
	MS.set("medusa_chunk_processed", processed, labels)
	MS.set("medusa_chunk_queued", remaining, labels)
end

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
		_trackManager = nil,
		_assetIndex = nil,
		_doctrine = nil,
		_sensorPollingService = nil,
		_sensorPollIndex = 1,
		_sensorPollBudget = 3,
		_assignmentInterval = 2,
		_assignmentPhase = 0,
		_tickCounter = 0,
		_lastScanTime = 0,
		_pollDetectionAccum = {},
		_lastAssetLogTime = 0,
		_assetLogIntervalSec = 300,
		_timerId = nil,
		_tickIntervalSec = (opts and opts.tick) or 0.1,
		_probingService = nil,
		_deathQueue = nil,
		_shotQueue = nil,
		_killQueue = nil,
		_geoGrid = nil,
		_maxEngagementRange = 0,
		_unitIdIndex = {},
		_erectComplete = false,
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
	}
	o._logger = Medusa.Logger:ns(string.format("%s | Core.IadsNetwork", tostring(o._id)))
	o._discovery = Medusa.Services.DiscoveryService:new(nil, {
		id = o._id,
		coalitionId = o._coalitionId,
		prefix = o._prefix,
	})
	setmetatable(o, { __index = self })
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

function Medusa.Core.IadsNetwork:initialize()
	if self._initialized then
		return true
	end
	self._logger:info(
		string.format("config: coalitionId=%s, prefix='%s'", tostring(self._coalitionId), tostring(self._prefix))
	)

	local batteryStore = Medusa.Services.BatteryStore:new()
	local sensorStore = Medusa.Services.SensorUnitStore:new()
	local c2NodeStore = Medusa.Services.C2NodeStore:new()
	local zoneStore = Medusa.Services.AirspaceZoneStore:new()
	local airbaseStore = Medusa.Services.AirbaseStore:new()
	local interceptorStore = Medusa.Services.InterceptorGroupStore:new()

	self._geoGrid = GeoGrid(10000, { "Battery", "Track" })
	self._trackManager = Medusa.Services.TrackManager:new({ geoGrid = self._geoGrid })

	self._assetIndex = Medusa.Services.AssetIndex.new({
		sensors = sensorStore,
		batteries = batteryStore,
		c2Nodes = c2NodeStore,
		zones = zoneStore,
		airbases = airbaseStore,
		interceptors = interceptorStore,
		tracks = self._trackManager:getStore(),
		geoGrid = self._geoGrid,
	})

	self._probingService = Medusa.Services.SensorProbingService:new(self._coalitionId)
	self._doctrine = Medusa.Config:getDoctrine(self._doctrineKey)

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
	self:_subscribeWorldEvents()

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

	self._initialized = true

	local netLabel = { "network" }
	Medusa.Services.MetricsSnapshotService.register(netLabel)

	local initTime = GetTime()
	self._lastScanTime = initTime - 1
	self._lastAssetLogTime = initTime - self._assetLogIntervalSec + 30
	self._logger:info("initialized")
	return true
end

function Medusa.Core.IadsNetwork:start()
	if not self._initialized then
		self:initialize()
	end
	self._running = true
	self._logger:info("started")
	self._discovery:enableDynamicAdds()
	self:_onTick()
	return true
end

function Medusa.Core.IadsNetwork:stop()
	self._running = false
	self._logger:info("stopped")
	if self._timerId then
		CancelSchedule(self._timerId)
		self._timerId = nil
	end
	return true
end

function Medusa.Core.IadsNetwork:_logDoctrine()
	local d = self._doctrine
	if not d then
		return
	end
	self._logger:info("doctrine = " .. TableToString(d))
end

function Medusa.Core.IadsNetwork:_attachDiscoveryListener()
	local stores = {
		sensors = self._assetIndex:sensors(),
		batteries = self._assetIndex:batteries(),
		c2Nodes = self._assetIndex:c2Nodes(),
	}
	local hierarchy = self._hierarchy
	local networkId = self._id
	local logger = self._logger
	local geoGrid = self._geoGrid
	local unitIdIndex = self._unitIdIndex
	local harmSystems = self._harmCapableSystems
	local doctrine = self._doctrine

	local iads = self
	self._discovery:setListener({
		onAdded = function(dto)
			-- Skip if this group already has a battery or sensor
			if stores.batteries:getByGroupId(dto.groupId) then
				return
			end
			hierarchy:upsertGroup(dto)
			local roles = (dto.parsed and dto.parsed.roles) and table.concat(dto.parsed.roles, ",") or ""
			local path = (dto.parsed and dto.parsed.echelonPath) and table.concat(dto.parsed.echelonPath, ".") or ""
			logger:info(string.format("added: '%s' roles=[%s] path='%s'", tostring(dto.groupName), roles, path))

			local classification =
				Medusa.Services.EntityFactory.createFromDTO(dto, stores, networkId, harmSystems, doctrine)
			if classification == "battery" then
				local battery = stores.batteries:getByGroupId(dto.groupId)
				if battery then
					if battery.Position and geoGrid then
						geoGrid:add("Battery", battery.BatteryId, battery.Position)
					end
					if battery.Units then
						for j = 1, #battery.Units do
							unitIdIndex[battery.Units[j].UnitId] = { battery = battery, unitIdx = j }
						end
					end
					if iads._erectComplete then
						local BatteryActivationService = Medusa.Services.BatteryActivationService
						BatteryActivationService.erectGroup(battery.GroupName)
						local STD = Medusa.Constants.SystemTypeDefaults
						local defaults = STD[battery.Role]
						local defaultState = defaults and defaults.DefaultActivationState or "STATE_COLD"
						local now = GetTime()
						if defaultState == Medusa.Constants.ActivationState.STATE_WARM then
							BatteryActivationService.goWarm(battery, now)
						else
							BatteryActivationService.goCold(battery, now)
						end
						logger:info(
							string.format("initialized dynamic battery %s as %s", battery.GroupName, defaultState)
						)
					end
				end
			end
		end,
	})
end

function Medusa.Core.IadsNetwork:_subscribeWorldEvents()
	local bus = HarnessWorldEventBus
	local coalitionId = self._coalitionId

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
		if idOk and uid then
			event._unitId = uid
		end
		return true
	end

	local function deathPredicate(event)
		return validateEventInitiator(event, coalitionId)
	end
	self._deathQueue = Queue()
	bus:sub(world.event.S_EVENT_DEAD, self._deathQueue, deathPredicate)
	bus:sub(world.event.S_EVENT_CRASH, self._deathQueue, deathPredicate)

	local function shotPredicate(event)
		if not validateEventInitiator(event, coalitionId) then
			return false
		end
		if event.weapon then
			local wtOk, wtn = pcall(event.weapon.getTypeName, event.weapon)
			if wtOk and wtn then
				event._weaponTypeName = wtn
			end
		end
		return true
	end
	self._shotQueue = Queue()
	bus:sub(world.event.S_EVENT_SHOT, self._shotQueue, shotPredicate)

	local function killPredicate(event)
		return validateEventInitiator(event, coalitionId)
	end
	self._killQueue = Queue()
	bus:sub(world.event.S_EVENT_KILL, self._killQueue, killPredicate)

	self._logger:info("world event subscriptions active")
end

function Medusa.Core.IadsNetwork:_processDeathEvents(limit)
	if not self._deathQueue or self._deathQueue:isEmpty() then
		return 0
	end
	local processed = 0
	while processed < limit and not self._deathQueue:isEmpty() do
		local event = self._deathQueue:dequeue()
		if event and event._unitId then
			self:_handleUnitDeath(event._unitId)
		end
		processed = processed + 1
	end
	return processed
end

function Medusa.Core.IadsNetwork:_handleUnitDeath(unitId)
	local sensorStore = self._assetIndex:sensors()
	local sensor = sensorStore:getByUnitId(unitId)
	if sensor then
		sensorStore:remove(sensor.SensorUnitId)
		self._logger:info(string.format("sensor destroyed: %s (unitId=%d)", sensor.UnitName, unitId))
		return
	end

	local battery, unitIdx = self:_findBatteryUnit(unitId)
	if not battery then
		return
	end
	table.remove(battery.Units, unitIdx)
	self._unitIdIndex[unitId] = nil
	for j = 1, #battery.Units do
		self._unitIdIndex[battery.Units[j].UnitId] = { battery = battery, unitIdx = j }
	end
	if battery.HarmCapableUnitCount > 0 then
		battery.HarmCapableUnitCount =
			Medusa.Services.EntityFactory.computeHarmCapableCount(battery, self._harmCapableSystems)
	end

	local prevStatus = battery.OperationalStatus
	local newStatus = Medusa.Entities.Battery.recomputeState(battery)

	if newStatus == Medusa.Constants.BatteryOperationalStatus.DESTROYED then
		Medusa.Services.MetricsService.inc("medusa_battery_destroyed_total")
		Medusa.Entities.Battery.releaseTrack(battery, self._trackManager:getStore())
		for j = 1, #battery.Units do
			self._unitIdIndex[battery.Units[j].UnitId] = nil
		end
		self._assetIndex:batteries():remove(battery.BatteryId)
		self._geoGrid:remove(battery.BatteryId)
		self._logger:info(string.format("battery destroyed: %s (all units dead)", battery.GroupName))
	else
		self._logger:info(
			string.format("battery %s lost unit %d (%d remaining)", battery.GroupName, unitId, #battery.Units)
		)
		if newStatus ~= prevStatus then
			self._logger:info(string.format("battery %s status: %s -> %s", battery.GroupName, prevStatus, newStatus))
		end
		local degradation = Medusa.Entities.Battery.classifyDegradation(battery)
		if degradation then
			local context = {
				batteryStore = self._assetIndex:batteries(),
				geoGrid = self._geoGrid,
				unitIdIndex = self._unitIdIndex,
				trackStore = self._trackManager:getStore(),
			}
			local result = Medusa.Entities.Battery.applyDegradedBehavior(battery, degradation, context)
			if result == "weapons_free" then
				self._logger:info(
					string.format("battery %s TELARs weapons free (CP still coordinating)", battery.GroupName)
				)
			end
		end
	end
end

function Medusa.Core.IadsNetwork:_processShotEvents(limit)
	if not self._shotQueue or self._shotQueue:isEmpty() then
		return 0
	end
	local processed = 0
	while processed < limit and not self._shotQueue:isEmpty() do
		local event = self._shotQueue:dequeue()
		if event and event._unitId then
			self:_handleShot(event._unitId, event._weaponTypeName)
		end
		processed = processed + 1
	end
	return processed
end

function Medusa.Core.IadsNetwork:_processKillEvents(limit)
	if not self._killQueue or self._killQueue:isEmpty() then
		return 0
	end
	local processed = 0
	while processed < limit and not self._killQueue:isEmpty() do
		local event = self._killQueue:dequeue()
		if event and event._unitId then
			local battery = self:_findBatteryUnit(event._unitId)
			if battery then
				Medusa.Services.MetricsService.inc("medusa_kills_total")
				self:_recordKillOutcome()
				self._logger:info(string.format("battery %s scored a kill", battery.GroupName))
			end
		end
		processed = processed + 1
	end
	return processed
end

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

function Medusa.Core.IadsNetwork:_handleShot(unitId, weaponTypeName)
	local battery, unitIdx = self:_findBatteryUnit(unitId)
	if not battery then
		return
	end
	Medusa.Services.MetricsService.inc("medusa_shots_fired_total")
	battery.ShotsFired = battery.ShotsFired + 1
	if unitIdx > #battery.Units then
		return
	end
	local unit = battery.Units[unitIdx]
	if not unit.AmmoTypes or #unit.AmmoTypes == 0 then
		return
	end
	self:_decrementAmmo(unit, weaponTypeName)
	local now = GetTime()
	battery.LastShotTime = now
	self:_recordShotOutcome(0)
	if battery.LastChanceTrackId and battery.LastChanceShotsRemaining and battery.LastChanceShotsRemaining > 0 then
		battery.LastChanceShotsRemaining = battery.LastChanceShotsRemaining - 1
		Medusa.Services.MetricsService.inc("medusa_last_chance_fired_total")
	end

	local targetAlt = nil
	if battery.CurrentTargetTrackId then
		local track = self._trackManager:getStore():get(battery.CurrentTargetTrackId)
		if track and track.Position then
			targetAlt = track.Position.y
		end
	end
	local ttk = estimateTTK(battery.EngagementRangeMax, targetAlt)
	battery.MissileInFlightUntil = now + ttk

	local prevStatus = battery.OperationalStatus
	local newStatus = Medusa.Entities.Battery.recomputeState(battery)

	self._logger:info(
		string.format(
			"battery %s fired %s (%d remaining)",
			battery.GroupName,
			weaponTypeName or "unknown",
			battery.TotalAmmoStatus
		)
	)
	if newStatus ~= prevStatus then
		self._logger:info(string.format("battery %s status: %s -> %s", battery.GroupName, prevStatus, newStatus))
		if battery.TotalAmmoStatus <= 0 then
			if Medusa.Services.BatteryActivationService.goGreen(battery, now, self._trackManager:getStore()) then
				battery.RearmCheckTime = now + Medusa.Constants.REARM_CHECK_INTERVAL_SEC
			end
		end
	end
end

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

function Medusa.Core.IadsNetwork:_checkRearming(now)
	local batteries = self._assetIndex:batteries():getAll(Medusa.Core.IadsNetwork._rearmBuffer)
	local STD = Medusa.Constants.SystemTypeDefaults
	local BatteryActivationService = Medusa.Services.BatteryActivationService
	local LAUNCHER_ROLES = Medusa.Constants.LAUNCHER_ROLES
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
					if unit.UnitName and LAUNCHER_ROLES[unit.Roles and unit.Roles[1]] then
						local ammoTable = GetUnitAmmo(unit.UnitName)
						if ammoTable then
							local unitTotal = 0
							for k = 1, #ammoTable do
								unitTotal = unitTotal + (ammoTable[k].count or 0)
							end
							if unitTotal > 0 then
								rearmed = true
								local newAmmo, newCount = Medusa.Services.EntityFactory.extractAmmo(unit.UnitName)
								unit.AmmoTypes = newAmmo or {}
								unit.AmmoCount = newCount
							end
						end
					end
				end
			end
			if rearmed then
				Medusa.Entities.Battery.recomputeState(battery)
				battery.HarmCapableUnitCount =
					Medusa.Services.EntityFactory.computeHarmCapableCount(battery, self._harmCapableSystems)
				battery.RearmCheckTime = nil
				local defaults = STD[battery.Role]
				local defaultState = defaults and defaults.DefaultActivationState or "STATE_COLD"
				if defaultState == Medusa.Constants.ActivationState.STATE_WARM then
					BatteryActivationService.goWarm(battery, now)
				else
					BatteryActivationService.goCold(battery, now)
				end
				self._pdReassignNeeded = true
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
		end
	end
end

function Medusa.Core.IadsNetwork:_populateUnitIdIndex()
	self._unitIdIndex = {}
	local batteries = self._assetIndex:batteries():getAll()
	for i = 1, #batteries do
		local battery = batteries[i]
		if battery.Units then
			for j = 1, #battery.Units do
				self._unitIdIndex[battery.Units[j].UnitId] = { battery = battery, unitIdx = j }
			end
		end
	end
end

function Medusa.Core.IadsNetwork:_findBatteryUnit(unitId)
	local entry = self._unitIdIndex[unitId]
	if entry then
		return entry.battery, entry.unitIdx
	end
	-- Fallback: linear scan for units added outside normal discovery flow
	local batteries = self._assetIndex:batteries():getAll()
	for i = 1, #batteries do
		local battery = batteries[i]
		if battery.Units then
			for j = 1, #battery.Units do
				if battery.Units[j].UnitId == unitId then
					self._unitIdIndex[battery.Units[j].UnitId] = { battery = battery, unitIdx = j }
					return battery, j
				end
			end
		end
	end
	return nil
end

local function _applyDefaultState(battery, BatteryActivationService, defaultState, now)
	if defaultState == Medusa.Constants.ActivationState.STATE_WARM then
		return BatteryActivationService.goWarm(battery, now), "warm"
	end
	return BatteryActivationService.goCold(battery, now), "cold"
end

--- Triggers the DCS erect animation on all batteries so subsequent state transitions are instant.
function Medusa.Core.IadsNetwork:_fastErectBatteries()
	local BatteryActivationService = Medusa.Services.BatteryActivationService
	local batteries = self._assetIndex:batteries():getAll()
	local erected = 0
	for i = 1, #batteries do
		if BatteryActivationService.erectGroup(batteries[i].GroupName) then
			erected = erected + 1
		end
	end
	self._logger:info(string.format("fast erect: %d batteries pre-activated", erected))
end

function Medusa.Core.IadsNetwork:_initializeBatteryStates()
	local batteries = self._assetIndex:batteries():getAll()
	local BatteryActivationService = Medusa.Services.BatteryActivationService
	local STD = Medusa.Constants.SystemTypeDefaults
	local now = GetTime()
	local coldCount = 0
	local warmCount = 0
	local skipped = 0

	for i = 1, #batteries do
		local battery = batteries[i]
		local defaults = STD[battery.Role]
		local defaultState = defaults and defaults.DefaultActivationState or "STATE_COLD"
		local ok, label = _applyDefaultState(battery, BatteryActivationService, defaultState, now)
		if ok then
			if label == "warm" then
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
end

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

function Medusa.Core.IadsNetwork:_populateGeoGrid()
	local batteries = self._assetIndex:batteries():getAll()
	local maxRange = 0
	local maxSpread = 0
	for i = 1, #batteries do
		local b = batteries[i]
		if b.Position then
			self._geoGrid:add("Battery", b.BatteryId, b.Position)
		end
		local r = b.EngagementRangeMax or 0
		if r > maxRange then
			maxRange = r
		end
		local s = b.ClusterSpreadRadius or 0
		if s > maxSpread then
			maxSpread = s
		end
	end
	self._maxEngagementRange = math.max(math.ceil((maxRange + maxSpread) / 10000) * 10000, 10000)
	self._logger:info(
		string.format("geogrid: %d batteries indexed, maxEngagementRange=%dm", #batteries, self._maxEngagementRange)
	)
end

function Medusa.Core.IadsNetwork:_runScanAndLog()
	local added = self._discovery:scanOnce()
	if (added or 0) > 0 then
		self._logger:info(string.format("discovery: added=%d", added))
		self._logger:debug(string.format("hierarchy tree:\n%s", self._hierarchy:renderTree()))
	end
end

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

function Medusa.Core.IadsNetwork:_buildPollList()
	local list = {}
	local sensorNames = self._assetIndex:sensors():getUniqueGroupNames()
	for i = 1, #sensorNames do
		list[#list + 1] = sensorNames[i]
	end
	local AS = Medusa.Constants.ActivationState
	local datalink = self._doctrine and self._doctrine.BatteryTargetDatalink
	local batteries = self._assetIndex:batteries():getAll()
	for i = 1, #batteries do
		local b = batteries[i]
		if b.IsActingAsEWR or (datalink and b.ActivationState == AS.STATE_HOT) then
			list[#list + 1] = b.GroupName
		end
	end
	return list
end

function Medusa.Core.IadsNetwork:_updateAirborneSensors()
	local sensors = self._assetIndex:sensors():getAll()
	for i = 1, #sensors do
		local s = sensors[i]
		if s.IsAirborne and s.UnitName then
			local pos = GetUnitPosition(s.UnitName)
			if pos then
				s.Position = pos
			end
		end
	end
end

function Medusa.Core.IadsNetwork:_pollSensors()
	local now = GetTime()
	self:_updateAirborneSensors()
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
	while polled < budget and polled < count do
		if idx > count then
			idx = 1
		end
		local name = pollList[idx]
		local reports = self._sensorPollingService:pollSensor(name, now)
		accum[name] = (accum[name] or 0) + #reports
		if #reports == 0 then
			Medusa.Services.MetricsService.inc("medusa_sensor_empty_polls_total")
		end
		totalDetections = totalDetections + #reports
		for i = 1, #reports do
			self._trackManager:processReport(reports[i], now)
		end
		idx = idx + 1
		polled = polled + 1
	end
	self._sensorPollIndex = idx
	if totalDetections > 0 then
		Medusa.Services.MetricsService.inc("medusa_detections_total", totalDetections)
	end
end

--[[
Assignment pipeline (distributed across 5 phases, one phase per assignment tick):
  Phase 0 - Classify:  track identification + aircraft type assessment (chunked)
  Phase 1 - HARM:      HARM detection (chunked) + response + point defense (full pass)
  Phase 2 - Assign:    EMCON self-assign + WTA + retry goHot (full pass, greedy)
  Phase 3 - Maintain:  handoff eval + deactivation checks (chunked) + HARM cleanup
  Phase 4 - EMCON:     emission control policy (chunked)

Each ChunkStep drains its queue up to budget items per tick.
When the queue empties, the next invocation refills from the current store snapshot.
Full pipeline cycle = 5 assignment ticks = 10 ticks = 1 second at 10 Hz.
]]

local _phaseNames = { [0] = "classify", "harm", "assign", "maintain", "emcon" }

function Medusa.Core.IadsNetwork:_runPhase()
	local phase = self._assignmentPhase
	local trackStore = self._trackManager:getStore()
	local batteryStore = self._assetIndex:batteries()
	local geoGrid = self._assetIndex:geoGrid()
	local now = GetTime()
	local maxRange = self._maxEngagementRange
	local hpt = Medusa.hpTimer
	local MS = Medusa.Services.MetricsService

	local ok, err
	if phase == 0 then
		ok, err = pcall(self._phaseClassify, self, trackStore, batteryStore, geoGrid, now, maxRange, hpt, MS)
	elseif phase == 1 then
		ok, err = pcall(self._phaseHarmAndPD, self, trackStore, batteryStore, geoGrid, now, hpt, MS)
	elseif phase == 2 then
		ok, err = pcall(self._phaseAssign, self, trackStore, batteryStore, geoGrid, now, maxRange, hpt, MS)
	elseif phase == 3 then
		ok, err = pcall(self._phaseMaintain, self, trackStore, batteryStore, now, hpt, MS)
	elseif phase == 4 then
		ok, err = pcall(self._phaseEmcon, self, batteryStore, now, hpt, MS)
	end

	if not ok then
		self._phaseFailures[phase] = (self._phaseFailures[phase] or 0) + 1
		local count = self._phaseFailures[phase]
		if count == 1 or count % 100 == 0 then
			self._logger:error(
				string.format("phase %s failed (%dx): %s", _phaseNames[phase] or phase, count, tostring(err))
			)
		end
	else
		self._phaseFailures[phase] = 0
	end
	MS.set("medusa_phase_failures_consecutive", self._phaseFailures[phase] or 0, { phase = _phaseNames[phase] })

	self._assignmentPhase = (phase + 1) % 5
end

-- Phase 0: Track classification + aircraft type (chunked by track)
function Medusa.Core.IadsNetwork:_phaseClassify(trackStore, batteryStore, geoGrid, now, maxRange, hpt, MS)
	local TC = Medusa.Services.TrackClassifier
	local step = self._classifyStep
	local t1 = hpt()

	local posture = self._doctrine and self._doctrine.Posture or Medusa.Constants.Posture.HOT_WAR
	local hasBorders = self._borderPolygons and #self._borderPolygons > 0
	local guiltEnabled = not self._doctrine or self._doctrine.GuiltByAssociation ~= false

	local allTracks = trackStore:getAll(_assignBatteryBuffer)
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
		local promotion = TC.classifyTrack(
			track,
			trackStore,
			posture,
			hasBorders,
			guiltEnabled,
			self._borderPolygons,
			self._adizPolygon,
			self._coalitionId,
			now,
			geoGrid,
			batteryStore,
			maxRange
		)
		if promotion then
			TC._promotedBuffer[#TC._promotedBuffer + 1] = promotion
		end
		TC.assessSingleAircraftType(track)
		processed = processed + 1
	end

	if step:isEmpty() and guiltEnabled then
		TC.flushGuiltByAssociation(allTracks, trackStore, now)
	end

	logChunk(self._logger, MS, "classify", processed, step:remaining())
	MS.observe("medusa_classification_duration_seconds", hpt() - t1)
end

-- Phase 1: HARM detection (chunked) + response + point defense (full pass)
function Medusa.Core.IadsNetwork:_phaseHarmAndPD(trackStore, batteryStore, geoGrid, now, hpt, MS)
	local HDS = Medusa.Services.HarmDetectionService
	local step = self._harmDetectStep
	local t1 = hpt()

	local allTracks = trackStore:getAll(_assignBatteryBuffer)
	step:fill(allTracks)

	local states, ballisticDt, ballisticMaxT = HDS.getAssessContext(trackStore, self._doctrine)
	local processed = 0
	for _ = 1, step.budget do
		local track = step:next()
		if not track then
			break
		end
		HDS.assessSingleTrack(track, allTracks, geoGrid, batteryStore, states, ballisticDt, ballisticMaxT)
		processed = processed + 1
	end

	logChunk(self._logger, MS, "harm_detect", processed, step:remaining())

	-- Full-pass: HARM response + PD (usually few HARMs, not worth chunking)
	Medusa.Services.HarmResponseService.executeResponse(trackStore, batteryStore, self._doctrine, now, geoGrid)
	local pdReleased = Medusa.Services.PointDefenseService.releaseOrphanedDefenders(batteryStore)
	if pdReleased > 0 or self._pdReassignNeeded then
		Medusa.Services.PointDefenseService.autoAssignShorad(batteryStore, geoGrid)
		self._pdReassignNeeded = false
	end
	Medusa.Services.PointDefenseService.engageThreats(trackStore, batteryStore, geoGrid, now)

	MS.observe("medusa_harm_eval_duration_seconds", hpt() - t1)
end

-- Phase 2: EMCON self-assign + WTA assignment + retry goHot (full pass, greedy)
function Medusa.Core.IadsNetwork:_phaseAssign(trackStore, batteryStore, geoGrid, now, maxRange, hpt, MS)
	local TargetAssigner = Medusa.Services.TargetAssigner
	local BAS = Medusa.Services.BatteryActivationService
	local t1 = hpt()

	local autoAssignments =
		TargetAssigner.emconSelfAssign(trackStore, batteryStore, self._doctrine, now, geoGrid, maxRange)
	for i = 1, #autoAssignments do
		local a = autoAssignments[i]
		local battery = batteryStore:get(a.batteryId)
		if battery and BAS.goHot(battery, now) then
			self._logger:info(
				string.format("battery %s HOT (EMCON self-assign) for track %s", battery.GroupName, a.trackId)
			)
		end
	end

	local assignments = TargetAssigner.assignTargets(trackStore, batteryStore, maxRange, self._doctrine, now, geoGrid)
	for i = 1, #assignments do
		local a = assignments[i]
		local battery = batteryStore:get(a.batteryId)
		if battery and BAS.goHot(battery, now) then
			self._logger:info(string.format("battery %s HOT for track %s", a.batteryId, a.trackId))
		end
	end

	local AS = Medusa.Constants.ActivationState
	local allBatteries = batteryStore:getAll(_assignBatteryBuffer)
	for i = 1, #allBatteries do
		local battery = allBatteries[i]
		if battery.CurrentTargetTrackId and battery.ActivationState ~= AS.STATE_HOT then
			if BAS.goHot(battery, now) then
				self._logger:info(
					string.format(
						"battery %s HOT for track %s (retry)",
						battery.BatteryId,
						battery.CurrentTargetTrackId
					)
				)
			end
		end
	end

	MS.observe("medusa_assignment_duration_seconds", hpt() - t1)
	MS.inc("medusa_engagements_assigned_total", #autoAssignments + #assignments)
end

-- Phase 3: Handoff evaluation + deactivation checks (chunked) + HARM cleanup
function Medusa.Core.IadsNetwork:_phaseMaintain(trackStore, batteryStore, now, hpt, MS)
	local TargetAssigner = Medusa.Services.TargetAssigner
	local BAS = Medusa.Services.BatteryActivationService
	local t1 = hpt()

	local allBatteries = batteryStore:getAll(_assignBatteryBuffer)
	local geoGrid = self._assetIndex:geoGrid()
	local maxRange = self._maxEngagementRange

	-- Chunked handoff evaluation
	local handoffStep = self._handoffStep
	handoffStep:fill(allBatteries)
	local handoffProcessed = 0
	for _ = 1, handoffStep.budget do
		local battery = handoffStep:next()
		if not battery then
			break
		end
		local result = TargetAssigner.evaluateSingleHandoff(
			battery,
			trackStore,
			batteryStore,
			self._doctrine,
			now,
			geoGrid,
			maxRange
		)
		if result then
			local bat = batteryStore:get(result.batteryId)
			if bat then
				Medusa.Entities.Battery.releaseTrack(bat, trackStore)
				bat.LastAssignmentChangeTime = now
				Medusa.Entities.Battery.beginLastChance(bat, result.trackId, self._doctrine.HoldDownSec or 15)
				MS.inc("medusa_last_chance_activated_total")
				self._logger:info(
					string.format("battery %s released track %s (last-chance)", bat.GroupName, result.trackId)
				)
			end
		end
		handoffProcessed = handoffProcessed + 1
	end
	logChunk(self._logger, MS, "handoff", handoffProcessed, handoffStep:remaining())

	-- Chunked deactivation checks
	local deactStep = self._deactivationStep
	deactStep:fill(allBatteries)
	local deactProcessed = 0
	for _ = 1, deactStep.budget do
		local battery = deactStep:next()
		if not battery then
			break
		end
		local result = TargetAssigner.checkSingleDeactivation(battery, trackStore, self._doctrine, now)
		if result then
			Medusa.Entities.Battery.releaseTrack(result.battery, trackStore)
			if BAS.goCold(result.battery, now, trackStore) then
				self._logger:info(string.format("battery %s deactivated (%s)", result.battery.GroupName, result.reason))
			end
		end
		deactProcessed = deactProcessed + 1
	end
	logChunk(self._logger, MS, "deactivation", deactProcessed, deactStep:remaining())

	-- Full-pass: clear expired HARM shutdowns
	for i = 1, #allBatteries do
		local battery = allBatteries[i]
		if battery.HarmShutdownUntil and now >= battery.HarmShutdownUntil then
			battery.HarmShutdownUntil = nil
		end
	end

	MS.observe("medusa_handoff_duration_seconds", hpt() - t1)
end

-- Phase 4: EMCON policy (full pass, index-dependent rotation math prevents chunking)
function Medusa.Core.IadsNetwork:_phaseEmcon(batteryStore, now, hpt, MS)
	local t1 = hpt()
	Medusa.Services.EmconService.applyPolicy(batteryStore, self._assetIndex:sensors(), self._doctrine, now, self)
	self:_decayEffectivePkFloor(now)
	MS.observe("medusa_emcon_duration_seconds", hpt() - t1)
end

function Medusa.Core.IadsNetwork:_onProbingComplete()
	local probing = self._probingService
	local sensorCount = probing:applySensorRanges(self._assetIndex:sensors())
	local batteryCount = probing:applyBatteryRanges(self._assetIndex:batteries())
	self._logger:info(
		string.format("probing complete: applied ranges to %d sensors, %d batteries", sensorCount, batteryCount)
	)
end

function Medusa.Core.IadsNetwork:tick()
	if not self._running then
		return
	end
	self._tickCounter = self._tickCounter + 1

	local MetricsService = Medusa.Services.MetricsService
	MetricsService.setContext({ network = self._id })
	MetricsService.inc("medusa_ticks_total")

	local now = GetTime()
	local hpt = Medusa.hpTimer
	local t0 = hpt()
	local memBefore = collectgarbage("count")

	if self._tickCounter == 1 then
		self._lastScanTime = now
		self:_runScanAndLog()
		self:_populateGeoGrid()
		self:_populateUnitIdIndex()
		self:_fastErectBatteries()
		self:_probeAirborneSensors()
		local typePositions = self:_collectProbeTargets()
		if next(typePositions) then
			self._probingService:probeAll(typePositions, function()
				self:_onProbingComplete()
			end)
		end
		-- Defer doctrine state application until erect animations complete
		local network = self
		ScheduleOnce(function()
			if not network._running then
				return
			end
			network:_initializeBatteryStates()
			Medusa.Services.PointDefenseService.autoAssignShorad(network._assetIndex:batteries(), network._geoGrid)
			Medusa.Services.EmconService.applyPolicy(
				network._assetIndex:batteries(),
				network._assetIndex:sensors(),
				network._doctrine,
				GetTime(),
				network
			)
			Medusa.Services.EmconService.logSchedule(
				network._assetIndex:batteries(),
				network._assetIndex:sensors(),
				network._doctrine
			)
			network._erectComplete = true
			network._logger:info("erect complete: doctrine states applied")
		end, nil, 60)
		return
	end

	self._discovery:processDynamicAdds(2)
	self:_processDeathEvents(2)
	self:_processShotEvents(2)
	self:_processKillEvents(2)
	self:_checkRearming(now)

	local t1 = hpt()
	self:_pollSensors()
	MetricsService.observe("medusa_poll_sensors_duration_seconds", hpt() - t1)

	t1 = hpt()
	self._trackManager:pruneStale(now)
	MetricsService.observe("medusa_prune_stale_duration_seconds", hpt() - t1)

	if self._erectComplete and (self._tickCounter % self._assignmentInterval) == 0 then
		self:_runPhase()
	end

	if (self._tickCounter % 4) ~= 0 then
		MetricsService.set("medusa_tick_memory_before_kb", memBefore)
		MetricsService.set("medusa_tick_memory_after_kb", collectgarbage("count"))
		MetricsService.observe("medusa_tick_duration_seconds", hpt() - t0)
		return
	end
	if (now - self._lastScanTime) < 1 then
		MetricsService.set("medusa_tick_memory_before_kb", memBefore)
		MetricsService.set("medusa_tick_memory_after_kb", collectgarbage("count"))
		MetricsService.observe("medusa_tick_duration_seconds", hpt() - t0)
		return
	end
	self._lastScanTime = now
	self:_runScanAndLog()

	self:_logAssetSummary(now)

	MetricsService.set("medusa_tick_memory_before_kb", memBefore)
	MetricsService.set("medusa_tick_memory_after_kb", collectgarbage("count"))
	MetricsService.observe("medusa_tick_duration_seconds", hpt() - t0)
end

function Medusa.Core.IadsNetwork:_scheduleNext()
	self._timerId = ScheduleOnce(self._tickCallback, nil, self._tickIntervalSec)
end

function Medusa.Core.IadsNetwork:_onTick()
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
		if self._tickFailures >= 1000 then
			self._logger:error(
				string.format(
					"Medusa has experienced an unrecoverable failure for the last %.0f seconds. Attempting to release all batteries to autonomous DCS AI control and shutting down.",
					1000 * self._tickIntervalSec
				)
			)
			local batteries = self._assetIndex:batteries()
			for i = 1, #batteries do
				pcall(Medusa.Services.BatteryActivationService.erectGroup, batteries[i].GroupName)
			end
			self._running = false
			return
		end
	else
		self._tickFailures = 0
	end
	Medusa.Services.MetricsService.set("medusa_tick_failures_consecutive", self._tickFailures)
	self:_scheduleNext()
end

function Medusa.Core.IadsNetwork:getHierarchy()
	return self._hierarchy
end

function Medusa.Core.IadsNetwork:getTrackManager()
	return self._trackManager
end

function Medusa.Core.IadsNetwork:getAssetIndex()
	return self._assetIndex
end

function Medusa.Core.IadsNetwork:getDoctrine()
	return self._doctrine
end

function Medusa.Core.IadsNetwork:getBorderPolygons()
	return self._borderPolygons
end

function Medusa.Core.IadsNetwork:getBorderPolygonsLL()
	return self._borderPolygonsLL
end

function Medusa.Core.IadsNetwork:getPosture()
	return self._doctrine and self._doctrine.Posture or Medusa.Constants.Posture.HOT_WAR
end
