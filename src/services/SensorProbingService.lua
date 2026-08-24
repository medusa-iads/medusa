require("_header")
require("services.Services")
require("core.Logger")
require("entities.Battery")

--[[
            ███████╗███████╗███╗   ██╗███████╗ ██████╗ ██████╗     ██████╗ ██████╗  ██████╗ ██████╗ ██╗███╗   ██╗ ██████╗
            ██╔════╝██╔════╝████╗  ██║██╔════╝██╔═══██╗██╔══██╗    ██╔══██╗██╔══██╗██╔═══██╗██╔══██╗██║████╗  ██║██╔════╝
            ███████╗█████╗  ██╔██╗ ██║███████╗██║   ██║██████╔╝    ██████╔╝██████╔╝██║   ██║██████╔╝██║██╔██╗ ██║██║  ███╗
            ╚════██║██╔══╝  ██║╚██╗██║╚════██║██║   ██║██╔══██╗    ██╔═══╝ ██╔══██╗██║   ██║██╔══██╗██║██║╚██╗██║██║   ██║
            ███████║███████╗██║ ╚████║███████║╚██████╔╝██║  ██║    ██║     ██║  ██║╚██████╔╝██████╔╝██║██║ ╚████║╚██████╔╝
            ╚══════╝╚══════╝╚═╝  ╚═══╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝    ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝╚═╝  ╚═══╝ ╚═════╝

    What this service does
    - Works around a DCS bug where getSensors() returns incorrect data for multi-unit groups.
    - Spawns temporary single-unit groups to probe each unit type's actual sensor capabilities.
    - Caches probe results so each unit type is only probed once per mission.

    https://forum.dcs.world/topic/286121-getsensors-returns-sensors-for-different-unit/

--]]

Medusa.Services.SensorProbingService = {}

--- Creates the mission-scoped probe coordinator and its empty capability cache.
function Medusa.Services.SensorProbingService:new(coalitionId)
	local o = {
		_coalitionId = coalitionId,
		_countryId = nil,
		_cache = {},
		_pending = {},
		_pendingCount = 0,
		_completionCallbacks = {},
		_logger = Medusa.Logger:ns("SensorProbingService"),
		_pollCallback = nil,
		_pollScheduled = false,
	}
	setmetatable(o, { __index = self })
	o._pollCallback = function()
		o._pollScheduled = false
		local ok, err = pcall(o._pollPendingProbes, o)
		if not ok then
			pcall(o._abortPendingProbes, o, string.format("poll callback failed: %s", tostring(err)))
		end
	end
	return o
end

--- Starts probes for uncached unit types and calls onComplete after every probe resolves or aborts.
function Medusa.Services.SensorProbingService:probeAll(typePositions, onComplete)
	if not next(typePositions) then
		if onComplete then
			onComplete()
		end
		return
	end

	if onComplete then
		self._completionCallbacks[#self._completionCallbacks + 1] = onComplete
	end
	self:_resolveCountryId()

	local count = 0
	for typeName, position in pairs(typePositions) do
		if self._cache[typeName] == nil and not self._pending[typeName] then
			count = count + 1
			self:_spawnProbe(typeName, position)
		end
	end
	if count > 0 then
		self._logger:info(string.format("probing %d unique unit types", count))
	end
	if self._pendingCount == 0 then
		self:_completeAll()
	elseif not self._pollScheduled and not self:_schedulePoll() then
		self:_abortPendingProbes("initial poll scheduling failed")
	end
end

function Medusa.Services.SensorProbingService:getCapabilities(typeName)
	return self._cache[typeName]
end

function Medusa.Services.SensorProbingService:applySensorRanges(sensorStore)
	local sensors = sensorStore:getAll()
	local updated = 0
	for i = 1, #sensors do
		local sensor = sensors[i]
		if sensor.UnitTypeName then
			local caps = self._cache[sensor.UnitTypeName]
			if caps and caps.detectionRangeMax then
				sensor.DetectionRangeMax = caps.detectionRangeMax
				updated = updated + 1
			end
		end
	end
	return updated
end

local function _maxRangeForBattery(battery, cache)
	if not battery.Units then
		return nil
	end
	local maxRange = nil
	for j = 1, #battery.Units do
		local unit = battery.Units[j]
		if Medusa.Entities.Battery.canSupplyDetectionRange(battery, unit) and unit.UnitTypeName then
			local caps = cache[unit.UnitTypeName]
			if caps and caps.detectionRangeMax then
				if not maxRange or caps.detectionRangeMax > maxRange then
					maxRange = caps.detectionRangeMax
				end
			end
		end
	end
	return maxRange
end

function Medusa.Services.SensorProbingService:applyBatteryRanges(batteryStore)
	local batteries = batteryStore:getAll()
	local updated = 0
	for i = 1, #batteries do
		local battery = batteries[i]
		local maxRange = _maxRangeForBattery(battery, self._cache)
		if maxRange then
			battery.DetectionRangeMax = maxRange
			Medusa.Entities.Battery.computeEngagementRange(battery)
			updated = updated + 1
		end
	end
	return updated
end

local function _rangeFromSensor(sensorData)
	if type(sensorData) ~= "table" then
		return nil
	end
	local distAir = sensorData.detectionDistanceAir
	if distAir then
		local upper = distAir.upperHemisphere
		if upper and upper.headOn then
			return upper.headOn
		end
	end
	return sensorData.detectionDistanceMaximal
end

function Medusa.Services.SensorProbingService:_parseSensors(sensorsTable)
	if not sensorsTable then
		return nil
	end
	local maxRange = nil
	for _, categorySensors in pairs(sensorsTable) do
		if type(categorySensors) == "table" then
			for _, sensorData in pairs(categorySensors) do
				local range = _rangeFromSensor(sensorData)
				if range and (not maxRange or range > maxRange) then
					maxRange = range
				end
			end
		end
	end
	if not maxRange then
		return nil
	end
	return { detectionRangeMax = maxRange }
end

--- Removes one completed probe and completes the batch when no probe remains.
function Medusa.Services.SensorProbingService:_onProbeComplete(typeName)
	self._pendingCount = self._pendingCount - 1
	self._pending[typeName] = nil
	if self._pendingCount <= 0 then
		self:_completeAll()
	end
end

--- Finalizes the active probe batch and invokes its completion callback once.
function Medusa.Services.SensorProbingService:_completeAll()
	local callbacks = self._completionCallbacks
	self._completionCallbacks = {}
	for i = 1, #callbacks do
		local ok, err = pcall(callbacks[i])
		if not ok then
			self._logger:error(string.format("probe completion callback failed: %s", tostring(err)))
		end
	end
end

--- Cancels every pending probe after a boundary failure and completes the batch safely.
function Medusa.Services.SensorProbingService:_abortPendingProbes(reason)
	self._logger:error(reason)
	self._pollScheduled = false
	local pending = self._pending
	self._pending = {}
	self._pendingCount = 0
	for typeName, entry in pairs(pending) do
		self._cache[typeName] = false
		local cleaned, cleanupError = pcall(function()
			local probeGroup = GetGroup(entry.groupName)
			if probeGroup then
				DestroyGroup(probeGroup)
			end
		end)
		if not cleaned then
			self._logger:error(string.format("probe cleanup failed for '%s': %s", typeName, tostring(cleanupError)))
		end
	end
	self:_completeAll()
end

--- Reports whether registration returned a timer handle for the next probe poll.
function Medusa.Services.SensorProbingService:_schedulePoll()
	if self._pollScheduled then
		return true
	end
	local registered, timerId = pcall(ScheduleOnce, self._pollCallback, nil, 1.0)
	self._pollScheduled = registered and timerId ~= nil
	return self._pollScheduled
end

function Medusa.Services.SensorProbingService:_resolveCountryId()
	if self._countryId then
		return
	end
	if self._coalitionId == 1 then
		self._countryId = country.id.RUSSIA
	else
		self._countryId = country.id.USA
	end
end

--- Spawns one hidden probe group and reports whether its DCS group became available.
function Medusa.Services.SensorProbingService:_spawnProbe(typeName, position)
	local probeName = string.format("MEDUSA_PROBE_%s_%04d", typeName:gsub("[^%w]", "_"), math.random(1000, 9999))
	local unitEntry =
		BuildUnitEntry(typeName, probeName .. "_u1", position.x, position.z, 0, 0, { skill = "Excellent" })
	if not unitEntry then
		self._logger:error(string.format("failed to build unit entry for type '%s'", typeName))
		self._cache[typeName] = false
		return false
	end

	local groupData = BuildGroupData(probeName, "Ground Nothing", { unitEntry }, nil, { visible = false })
	if not groupData then
		self._logger:error(string.format("failed to build group data for type '%s'", typeName))
		self._cache[typeName] = false
		return false
	end
	groupData.hidden = true

	local group = AddCoalitionGroup(self._countryId, 2, groupData)
	if not group then
		self._logger:error(string.format("failed to spawn probe for type '%s'", typeName))
		self._cache[typeName] = false
		return false
	end

	self._pending[typeName] = { groupName = probeName, pollCount = 0 }
	self._pendingCount = self._pendingCount + 1

	return true
end

--- Detects probe readiness, schedules its query, and reports whether processing may continue.
function Medusa.Services.SensorProbingService:_checkProbeReady(typeName, entry)
	local units = GetGroupUnits(entry.groupName)
	if not units or #units == 0 then
		return true
	end
	local registered, timerId = pcall(ScheduleOnce, function()
		local ok, err = pcall(self._queryProbe, self, typeName)
		if not ok then
			self._logger:error(string.format("probe query callback failed for '%s': %s", typeName, tostring(err)))
			local pending = self._pending[typeName]
			if pending then
				self._cache[typeName] = false
				self:_onProbeComplete(typeName)
			end
		end
	end, nil, 0.1)
	if not registered or not timerId then
		self._logger:error(string.format("probe query scheduling failed for '%s'", typeName))
		self._cache[typeName] = false
		self:_onProbeComplete(typeName)
	end
	return false
end

--- Advances pending probes and keeps the recurring poll alive only while work remains.
function Medusa.Services.SensorProbingService:_pollPendingProbes()
	local stillPending = false
	for typeName, entry in pairs(self._pending) do
		entry.pollCount = entry.pollCount + 1
		if entry.pollCount >= 10 then
			self._logger:error(string.format("probe timeout for type '%s'", typeName))
			self._cache[typeName] = false
			self:_onProbeComplete(typeName)
		else
			stillPending = self:_checkProbeReady(typeName, entry) or stillPending
		end
	end
	if stillPending then
		if not self:_schedulePoll() then
			self:_abortPendingProbes("follow-up poll scheduling failed")
		end
	end
end

--- Reads and caches one probe group's sensor capabilities, then releases its group.
function Medusa.Services.SensorProbingService:_queryProbe(typeName)
	local entry = self._pending[typeName]
	if not entry then
		return
	end

	local ok, caps = pcall(function()
		local units = GetGroupUnits(entry.groupName)
		if units and #units > 0 then
			local sensorsTable = GetUnitSensors(units[1])
			local result = self:_parseSensors(sensorsTable)
			if result then
				local m = result.detectionRangeMax
				self._logger:debug(string.format("[%s] detection: %dm (%.1fnm)", typeName, m, m / 1852))
			else
				self._logger:debug(string.format("[%s] no detection", typeName))
			end
			return result
		else
			self._logger:error(string.format("probe units gone for type '%s'", typeName))
			return nil
		end
	end)
	self._cache[typeName] = (ok and caps) or false
	if not ok then
		self._logger:error(string.format("probe query failed for '%s': %s", typeName, tostring(caps)))
	end

	local cleaned, cleanupError = pcall(function()
		local probeGroup = GetGroup(entry.groupName)
		if probeGroup then
			DestroyGroup(probeGroup)
		end
	end)
	if not cleaned then
		self._logger:error(string.format("probe cleanup failed for '%s': %s", typeName, tostring(cleanupError)))
	end
	self:_onProbeComplete(typeName)
end
