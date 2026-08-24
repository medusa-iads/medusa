require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")
require("entities.Battery")
require("services.stores.UnitIndex")

--[[
            ██████╗  █████╗ ████████╗████████╗███████╗██████╗ ██╗   ██╗    ███████╗████████╗ ██████╗ ██████╗ ███████╗
            ██╔══██╗██╔══██╗╚══██╔══╝╚══██╔══╝██╔════╝██╔══██╗╚██╗ ██╔╝    ██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗██╔════╝
            ██████╔╝███████║   ██║      ██║   █████╗  ██████╔╝ ╚████╔╝     ███████╗   ██║   ██║   ██║██████╔╝█████╗
            ██╔══██╗██╔══██║   ██║      ██║   ██╔══╝  ██╔══██╗  ╚██╔╝      ╚════██║   ██║   ██║   ██║██╔══██╗██╔══╝
            ██████╔╝██║  ██║   ██║      ██║   ███████╗██║  ██║   ██║       ███████║   ██║   ╚██████╔╝██║  ██║███████╗
            ╚═════╝ ╚═╝  ╚═╝   ╚═╝      ╚═╝   ╚══════╝╚═╝  ╚═╝   ╚═╝       ╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝

    What this store does
    - Stores all Battery entities and owns BatteryId and group indexes.
    - Exposes structurally isolated views for standard batteries and MANPAD groups.

    How others use it
    - EntityFactory adds discovered groups through the applicable view.
    - IadsNetwork uses the root repository for identity lifecycle and passes views to role-specific services.
--]]

Medusa.Services.BatteryStore = {}

local BR = Medusa.Constants.BatteryRole
local OwnerKind = Medusa.Constants.UnitOwnerKind

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

--- Returns the battery of this view type with groupName, or nil.
function StoreView:getByGroupName(groupName)
	local battery = self._repository:getByGroupName(groupName)
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

--- Creates the shared battery repository and its networked and MANPAD views.
function Medusa.Services.BatteryStore:new(unitIndex)
	local o = {
		_byId = {},
		_byGroupId = {},
		_byGroupName = {},
		_unitOrder = {},
		_positionRefreshCursor = 0,
		_batteryIds = {},
		_manpadIds = {},
		_count = 0,
		_batteryCount = 0,
		_manpadCount = 0,
		_logger = Medusa.Logger:ns("BatteryStore"),
		_unitIndex = unitIndex or Medusa.Services.UnitIndex:new(),
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

--- Publishes one validated battery into every identity and member index.
function Medusa.Services.BatteryStore:add(battery)
	Medusa.Entities.Battery.validateManpadState(battery.Role, battery.Manpad)
	Medusa.Entities.Battery.validateAaaState(battery.Role, battery.Aaa)
	if self._count >= Medusa.Constants.C2.MAX_BATTERIES then
		error(string.format("battery capacity exceeded: %d", Medusa.Constants.C2.MAX_BATTERIES))
	end
	if self._byId[battery.BatteryId] then
		error(string.format("duplicate BatteryId: %s", battery.BatteryId))
	end
	if battery.GroupId and self._byGroupId[battery.GroupId] then
		error(string.format("duplicate GroupId: %s", tostring(battery.GroupId)))
	end
	if battery.GroupName and self._byGroupName[battery.GroupName] then
		error(string.format("duplicate GroupName: %s", tostring(battery.GroupName)))
	end

	local units = battery.Units or {}
	local newUnitIds = {}
	local newUnitNames = {}
	local pendingUnitIndexes = {}
	for i = 1, #units do
		local unitId = units[i].UnitId
		local unitName = units[i].UnitName
		if unitId then
			local currentIdentity = self._unitIndex:resolve(unitId)
			local currentBatteryOwner = self._unitIndex:getOwner(currentIdentity, OwnerKind.BATTERY_UNIT)
			if newUnitIds[unitId] or currentBatteryOwner then
				error(string.format("duplicate UnitId: %s", tostring(unitId)))
			end
			newUnitIds[unitId] = true
		end
		if unitName then
			local currentIdentity = self._unitIndex:resolve(nil, unitName)
			local currentBatteryOwner = self._unitIndex:getOwner(currentIdentity, OwnerKind.BATTERY_UNIT)
			if newUnitNames[unitName] or currentBatteryOwner then
				error(string.format("duplicate UnitName: %s", tostring(unitName)))
			end
			newUnitNames[unitName] = true
		end
		if unitId then
			local indexed = {
				Battery = battery,
				Unit = units[i],
			}
			local valid, reason = self._unitIndex:validateRegistration({
				UnitId = unitId,
				UnitName = unitName,
				GroupId = battery.GroupId,
				GroupName = battery.GroupName,
				OwnerKind = OwnerKind.BATTERY_UNIT,
				Owner = indexed,
			})
			if not valid then
				error(string.format("managed battery unit identity rejected: %s", reason))
			end
			pendingUnitIndexes[i] = indexed
		end
	end

	self._byId[battery.BatteryId] = battery
	if battery.GroupId then
		self._byGroupId[battery.GroupId] = battery.BatteryId
	end
	if battery.GroupName then
		self._byGroupName[battery.GroupName] = battery.BatteryId
	end
	for i = 1, #units do
		local unit = units[i]
		if unit.UnitId then
			local refreshIndex = #self._unitOrder + 1
			local indexed = pendingUnitIndexes[i]
			indexed.RefreshIndex = refreshIndex
			self._unitOrder[refreshIndex] = indexed
			self._unitIndex:register({
				UnitId = unit.UnitId,
				UnitName = unit.UnitName,
				GroupId = battery.GroupId,
				GroupName = battery.GroupName,
				OwnerKind = OwnerKind.BATTERY_UNIT,
				Owner = indexed,
			})
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

--- Returns the active battery incarnation for groupName, or nil.
function Medusa.Services.BatteryStore:getByGroupName(groupName)
	local batteryId = self._byGroupName[groupName]
	if not batteryId then
		return nil
	end
	return self._byId[batteryId]
end

function Medusa.Services.BatteryStore:getByUnitId(unitId)
	local identity = self._unitIndex:resolve(unitId)
	local indexed = self._unitIndex:getOwner(identity, OwnerKind.BATTERY_UNIT)
	if not indexed then
		return nil
	end
	return indexed.Battery, indexed.Unit
end

--- Resolves one DCS event identity and retains its latest numeric ID alias for the matched battery member.
function Medusa.Services.BatteryStore:resolveUnit(unitId, unitName)
	local identity, source = self._unitIndex:resolve(unitId, unitName)
	local indexed = self._unitIndex:getOwner(identity, OwnerKind.BATTERY_UNIT)
	if not indexed then
		return nil, nil, source
	end
	return indexed.Battery, indexed.Unit, source
end

local function removeUnitIndex(repository, indexed)
	if not indexed then
		return nil
	end
	local order = repository._unitOrder
	local index = indexed.RefreshIndex
	local lastIndex = #order
	local moved = order[lastIndex]
	order[index] = moved
	order[lastIndex] = nil
	if moved and moved ~= indexed then
		moved.RefreshIndex = index
	end
	repository._unitIndex:unregister(OwnerKind.BATTERY_UNIT, indexed)
	if repository._positionRefreshCursor > #order then
		repository._positionRefreshCursor = 0
	end
	return indexed
end

function Medusa.Services.BatteryStore:nextUnitForPositionRefresh()
	local count = #self._unitOrder
	if count == 0 then
		self._positionRefreshCursor = 0
		return nil
	end
	self._positionRefreshCursor = (self._positionRefreshCursor % count) + 1
	local indexed = self._unitOrder[self._positionRefreshCursor]
	if not indexed then
		return nil
	end
	return indexed.Battery, indexed.Unit
end

function Medusa.Services.BatteryStore:removeUnit(unitId)
	local identity = self._unitIndex:resolve(unitId)
	local indexed = self._unitIndex:getOwner(identity, OwnerKind.BATTERY_UNIT)
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
	removeUnitIndex(self, indexed)
	return indexed.Battery, indexed.Unit
end

--- Removes one battery and all of its identity and member indexes.
function Medusa.Services.BatteryStore:remove(batteryId)
	local battery = self._byId[batteryId]
	if not battery then
		return nil
	end

	self._byId[batteryId] = nil
	if battery.GroupId then
		self._byGroupId[battery.GroupId] = nil
	end
	if battery.GroupName then
		self._byGroupName[battery.GroupName] = nil
	end
	local units = battery.Units or {}
	for i = 1, #units do
		if units[i].UnitId then
			local identity = self._unitIndex:resolve(units[i].UnitId)
			removeUnitIndex(self, self._unitIndex:getOwner(identity, OwnerKind.BATTERY_UNIT))
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
