require("_header")
require("services.Services")
require("core.Logger")

--[[
            ███████╗███████╗███╗   ██╗███████╗ ██████╗ ██████╗     ██╗   ██╗███╗   ██╗██╗████████╗    ███████╗████████╗ ██████╗ ██████╗ ███████╗
            ██╔════╝██╔════╝████╗  ██║██╔════╝██╔═══██╗██╔══██╗    ██║   ██║████╗  ██║██║╚══██╔══╝    ██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗██╔════╝
            ███████╗█████╗  ██╔██╗ ██║███████╗██║   ██║██████╔╝    ██║   ██║██╔██╗ ██║██║   ██║       ███████╗   ██║   ██║   ██║██████╔╝█████╗
            ╚════██║██╔══╝  ██║╚██╗██║╚════██║██║   ██║██╔══██╗    ██║   ██║██║╚██╗██║██║   ██║       ╚════██║   ██║   ██║   ██║██╔══██╗██╔══╝
            ███████║███████╗██║ ╚████║███████║╚██████╔╝██║  ██║    ╚██████╔╝██║ ╚████║██║   ██║       ███████║   ██║   ╚██████╔╝██║  ██║███████╗
            ╚══════╝╚══════╝╚═╝  ╚═══╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝     ╚═════╝ ╚═╝  ╚═══╝╚═╝   ╚═╝       ╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝

    What this store does
    - Stores SensorUnit entities indexed by ID, unit ID, type, and group name for fast lookup.
    - Provides unique group name listing for EMCON group-level operations.

    How others use it
    - EntityFactory adds sensors after creation; SensorPollingService and EmconService read them each tick.
--]]

Medusa.Services.SensorUnitStore = {}

function Medusa.Services.SensorUnitStore:new()
	local o = {
		_byId = {},
		_byUnitId = {},
		_byType = {},
		_byGroupName = {},
		_count = 0,
		_groupNamesCache = {},
		_groupNamesDirty = true,
		_logger = Medusa.Logger:ns("SensorUnitStore"),
	}
	setmetatable(o, { __index = self })
	return o
end

function Medusa.Services.SensorUnitStore:add(sensor)
	if self._byId[sensor.SensorUnitId] then
		error(string.format("duplicate SensorUnitId: %s", sensor.SensorUnitId))
	end
	if self._byUnitId[sensor.UnitId] then
		error(string.format("duplicate UnitId: %s", tostring(sensor.UnitId)))
	end

	self._byId[sensor.SensorUnitId] = sensor
	self._byUnitId[sensor.UnitId] = sensor.SensorUnitId
	self._count = self._count + 1

	local sensorType = sensor.SensorType
	if not self._byType[sensorType] then
		self._byType[sensorType] = {}
	end
	self._byType[sensorType][sensor.SensorUnitId] = sensor

	local groupName = sensor.GroupName
	if groupName then
		if not self._byGroupName[groupName] then
			self._byGroupName[groupName] = {}
		end
		self._byGroupName[groupName][sensor.SensorUnitId] = sensor
	end
	self._groupNamesDirty = true

	self._logger:debug(
		string.format(
			"added sensor %s (unitId=%s, type=%s, count=%d)",
			sensor.SensorUnitId,
			tostring(sensor.UnitId),
			sensorType,
			self._count
		)
	)
end

function Medusa.Services.SensorUnitStore:get(sensorUnitId)
	return self._byId[sensorUnitId]
end

function Medusa.Services.SensorUnitStore:getByUnitId(unitId)
	local sensorUnitId = self._byUnitId[unitId]
	if not sensorUnitId then
		return nil
	end
	return self._byId[sensorUnitId]
end

function Medusa.Services.SensorUnitStore:getByType(sensorType, outputTable)
	local typeIndex = self._byType[sensorType]
	if not typeIndex then
		if outputTable then
			for i = #outputTable, 1, -1 do
				outputTable[i] = nil
			end
		end
		return outputTable or {}
	end
	local result = outputTable or {}
	if outputTable then
		for i = #outputTable, 1, -1 do
			outputTable[i] = nil
		end
	end
	for _, sensor in pairs(typeIndex) do
		result[#result + 1] = sensor
	end
	return result
end

function Medusa.Services.SensorUnitStore:remove(sensorUnitId)
	local sensor = self._byId[sensorUnitId]
	if not sensor then
		return nil
	end

	self._byId[sensorUnitId] = nil
	self._byUnitId[sensor.UnitId] = nil
	self._count = self._count - 1

	local typeIndex = self._byType[sensor.SensorType]
	if typeIndex then
		typeIndex[sensorUnitId] = nil
		if next(typeIndex) == nil then
			self._byType[sensor.SensorType] = nil
		end
	end

	local groupIndex = self._byGroupName[sensor.GroupName]
	if groupIndex then
		groupIndex[sensorUnitId] = nil
		if next(groupIndex) == nil then
			self._byGroupName[sensor.GroupName] = nil
		end
	end
	self._groupNamesDirty = true

	self._logger:debug(string.format("removed sensor %s (count=%d)", sensorUnitId, self._count))
	return sensor
end

function Medusa.Services.SensorUnitStore:removeByGroupName(groupName)
	local groupIndex = self._byGroupName[groupName]
	if not groupIndex then
		return 0
	end
	local ids = {}
	for id in pairs(groupIndex) do
		ids[#ids + 1] = id
	end
	for i = 1, #ids do
		self:remove(ids[i])
	end
	return #ids
end

function Medusa.Services.SensorUnitStore:getByGroupName(groupName, outputTable)
	local groupIndex = self._byGroupName[groupName]
	if not groupIndex then
		if outputTable then
			for i = #outputTable, 1, -1 do
				outputTable[i] = nil
			end
		end
		return outputTable or {}
	end
	local result = outputTable or {}
	if outputTable then
		for i = #outputTable, 1, -1 do
			outputTable[i] = nil
		end
	end
	for _, sensor in pairs(groupIndex) do
		result[#result + 1] = sensor
	end
	return result
end

function Medusa.Services.SensorUnitStore:getUniqueGroupNames()
	if not self._groupNamesDirty then
		return self._groupNamesCache
	end
	local cache = self._groupNamesCache
	for i = #cache, 1, -1 do
		cache[i] = nil
	end
	for groupName in pairs(self._byGroupName) do
		cache[#cache + 1] = groupName
	end
	self._groupNamesDirty = false
	return cache
end

function Medusa.Services.SensorUnitStore:getAll(outputTable)
	local result = outputTable or {}
	if outputTable then
		for i = #outputTable, 1, -1 do
			outputTable[i] = nil
		end
	end
	for _, sensor in pairs(self._byId) do
		result[#result + 1] = sensor
	end
	return result
end

function Medusa.Services.SensorUnitStore:count()
	return self._count
end
