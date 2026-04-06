require("_header")
require("services.Services")
require("core.Logger")

--[[
            ██████╗  █████╗ ████████╗████████╗███████╗██████╗ ██╗   ██╗    ███████╗████████╗ ██████╗ ██████╗ ███████╗
            ██╔══██╗██╔══██╗╚══██╔══╝╚══██╔══╝██╔════╝██╔══██╗╚██╗ ██╔╝    ██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗██╔════╝
            ██████╔╝███████║   ██║      ██║   █████╗  ██████╔╝ ╚████╔╝     ███████╗   ██║   ██║   ██║██████╔╝█████╗
            ██╔══██╗██╔══██║   ██║      ██║   ██╔══╝  ██╔══██╗  ╚██╔╝      ╚════██║   ██║   ██║   ██║██╔══██╗██╔══╝
            ██████╔╝██║  ██║   ██║      ██║   ███████╗██║  ██║   ██║       ███████║   ██║   ╚██████╔╝██║  ██║███████╗
            ╚═════╝ ╚═╝  ╚═╝   ╚═╝      ╚═╝   ╚══════╝╚═╝  ╚═╝   ╚═╝       ╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝

    What this store does
    - Stores Battery entities indexed by BatteryId and GroupId for fast lookup.

    How others use it
    - EntityFactory adds batteries after creation; most services read batteries via getAll or get.
--]]

Medusa.Services.BatteryStore = {}

function Medusa.Services.BatteryStore:new()
	local o = {
		_byId = {},
		_byGroupId = {},
		_count = 0,
		_logger = Medusa.Logger:ns("BatteryStore"),
	}
	setmetatable(o, { __index = self })
	return o
end

function Medusa.Services.BatteryStore:add(battery)
	if self._byId[battery.BatteryId] then
		error(string.format("duplicate BatteryId: %s", battery.BatteryId))
	end

	self._byId[battery.BatteryId] = battery
	self._byGroupId[battery.GroupId] = battery.BatteryId
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

function Medusa.Services.BatteryStore:remove(batteryId)
	local battery = self._byId[batteryId]
	if not battery then
		return nil
	end

	self._byId[batteryId] = nil
	self._byGroupId[battery.GroupId] = nil
	self._count = self._count - 1

	self._logger:debug(string.format("removed battery %s (count=%d)", batteryId, self._count))
	return battery
end

function Medusa.Services.BatteryStore:getAll(outputTable)
	local result = outputTable or {}
	if outputTable then
		for i = #outputTable, 1, -1 do
			outputTable[i] = nil
		end
	end
	for _, battery in pairs(self._byId) do
		result[#result + 1] = battery
	end
	return result
end

function Medusa.Services.BatteryStore:count()
	return self._count
end
