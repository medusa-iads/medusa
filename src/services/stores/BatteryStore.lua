require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")
require("entities.Battery")

--[[
            ██████╗  █████╗ ████████╗████████╗███████╗██████╗ ██╗   ██╗    ███████╗████████╗ ██████╗ ██████╗ ███████╗
            ██╔══██╗██╔══██╗╚══██╔══╝╚══██╔══╝██╔════╝██╔══██╗╚██╗ ██╔╝    ██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗██╔════╝
            ██████╔╝███████║   ██║      ██║   █████╗  ██████╔╝ ╚████╔╝     ███████╗   ██║   ██║   ██║██████╔╝█████╗
            ██╔══██╗██╔══██║   ██║      ██║   ██╔══╝  ██╔══██╗  ╚██╔╝      ╚════██║   ██║   ██║   ██║██╔══██╗██╔══╝
            ██████╔╝██║  ██║   ██║      ██║   ███████╗██║  ██║   ██║       ███████║   ██║   ╚██████╔╝██║  ██║███████╗
            ╚═════╝ ╚═╝  ╚═╝   ╚═╝      ╚═╝   ╚══════╝╚═╝  ╚═╝   ╚═╝       ╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝

    What this store does
    - Stores all Battery entities and owns BatteryId, GroupId, and UnitId indexes.
    - Exposes structurally isolated views for standard batteries and MANPAD groups.

    How others use it
    - EntityFactory adds discovered groups through the applicable view.
    - IadsNetwork uses the root repository for identity lifecycle and passes views to role-specific services.
--]]

Medusa.Services.BatteryStore = {}

local BR = Medusa.Constants.BatteryRole

local StoreView = {}

local function clear(outputTable)
	for i = #outputTable, 1, -1 do
		outputTable[i] = nil
	end
end

local function isManpad(battery)
	return battery.Role == BR.MANPAD
end

function StoreView:add(battery)
	if isManpad(battery) ~= self._isManpad then
		error(string.format("battery %s belongs to a different repository view", tostring(battery.BatteryId)))
	end
	self._repository:add(battery)
end

function StoreView:get(batteryId)
	local battery = self._repository:get(batteryId)
	if battery and isManpad(battery) == self._isManpad then
		return battery
	end
	return nil
end

function StoreView:getByGroupId(groupId)
	local battery = self._repository:getByGroupId(groupId)
	if battery and isManpad(battery) == self._isManpad then
		return battery
	end
	return nil
end

function StoreView:remove(batteryId)
	if not self:get(batteryId) then
		return nil
	end
	return self._repository:remove(batteryId)
end

function StoreView:getAll(outputTable)
	local result = outputTable or {}
	if outputTable then
		clear(outputTable)
	end
	local ids = self._isManpad and self._repository._manpadIds or self._repository._batteryIds
	for batteryId in pairs(ids) do
		result[#result + 1] = self._repository._byId[batteryId]
	end
	return result
end

function StoreView:count()
	if self._isManpad then
		return self._repository._manpadCount
	end
	return self._repository._batteryCount
end

function Medusa.Services.BatteryStore:new()
	local o = {
		_byId = {},
		_byGroupId = {},
		_byUnitId = {},
		_batteryIds = {},
		_manpadIds = {},
		_count = 0,
		_batteryCount = 0,
		_manpadCount = 0,
		_logger = Medusa.Logger:ns("BatteryStore"),
	}
	setmetatable(o, { __index = self })
	o._batteryView = setmetatable({ _repository = o, _isManpad = false }, { __index = StoreView })
	o._manpadView = setmetatable({ _repository = o, _isManpad = true }, { __index = StoreView })
	return o
end

function Medusa.Services.BatteryStore:batteries()
	return self._batteryView
end

function Medusa.Services.BatteryStore:manpads()
	return self._manpadView
end

function Medusa.Services.BatteryStore:add(battery)
	Medusa.Entities.Battery.validateManpadState(battery.Role, battery.Manpad)
	Medusa.Entities.Battery.validateAaaState(battery.Role, battery.Aaa)
	if self._byId[battery.BatteryId] then
		error(string.format("duplicate BatteryId: %s", battery.BatteryId))
	end
	if battery.GroupId and self._byGroupId[battery.GroupId] then
		error(string.format("duplicate GroupId: %s", tostring(battery.GroupId)))
	end

	local units = battery.Units or {}
	local newUnitIds = {}
	for i = 1, #units do
		local unitId = units[i].UnitId
		if unitId then
			if newUnitIds[unitId] or self._byUnitId[unitId] then
				error(string.format("duplicate UnitId: %s", tostring(unitId)))
			end
			newUnitIds[unitId] = true
		end
	end

	self._byId[battery.BatteryId] = battery
	if battery.GroupId then
		self._byGroupId[battery.GroupId] = battery.BatteryId
	end
	for i = 1, #units do
		local unit = units[i]
		if unit.UnitId then
			self._byUnitId[unit.UnitId] = { Battery = battery, Unit = unit }
		end
	end

	if isManpad(battery) then
		self._manpadIds[battery.BatteryId] = true
		self._manpadCount = self._manpadCount + 1
	else
		self._batteryIds[battery.BatteryId] = true
		self._batteryCount = self._batteryCount + 1
	end
	self._count = self._count + 1

	self._logger:debug(
		string.format(
			"added battery %s (groupId=%s, count=%d)",
			battery.BatteryId,
			tostring(battery.GroupId),
			self._count
		)
	)
end

function Medusa.Services.BatteryStore:get(batteryId)
	return self._byId[batteryId]
end

function Medusa.Services.BatteryStore:getByGroupId(groupId)
	local batteryId = self._byGroupId[groupId]
	if not batteryId then
		return nil
	end
	return self._byId[batteryId]
end

function Medusa.Services.BatteryStore:getByUnitId(unitId)
	local indexed = self._byUnitId[unitId]
	if not indexed then
		return nil
	end
	return indexed.Battery, indexed.Unit
end

function Medusa.Services.BatteryStore:removeUnit(unitId)
	local indexed = self._byUnitId[unitId]
	if not indexed then
		return nil
	end

	local units = indexed.Battery.Units or {}
	for i = 1, #units do
		if units[i] == indexed.Unit then
			table.remove(units, i)
			break
		end
	end
	self._byUnitId[unitId] = nil
	return indexed.Battery, indexed.Unit
end

function Medusa.Services.BatteryStore:remove(batteryId)
	local battery = self._byId[batteryId]
	if not battery then
		return nil
	end

	self._byId[batteryId] = nil
	if battery.GroupId then
		self._byGroupId[battery.GroupId] = nil
	end
	local units = battery.Units or {}
	for i = 1, #units do
		if units[i].UnitId then
			self._byUnitId[units[i].UnitId] = nil
		end
	end

	if isManpad(battery) then
		self._manpadIds[batteryId] = nil
		self._manpadCount = self._manpadCount - 1
	else
		self._batteryIds[batteryId] = nil
		self._batteryCount = self._batteryCount - 1
	end
	self._count = self._count - 1

	self._logger:debug(string.format("removed battery %s (count=%d)", batteryId, self._count))
	return battery
end

function Medusa.Services.BatteryStore:getAll(outputTable)
	local result = outputTable or {}
	if outputTable then
		clear(outputTable)
	end
	for _, battery in pairs(self._byId) do
		result[#result + 1] = battery
	end
	return result
end

function Medusa.Services.BatteryStore:count()
	return self._count
end
