require("_header")
require("services.Services")
require("core.Logger")

--[[
             █████╗ ██╗██████╗ ██████╗  █████╗ ███████╗███████╗    ███████╗████████╗ ██████╗ ██████╗ ███████╗
            ██╔══██╗██║██╔══██╗██╔══██╗██╔══██╗██╔════╝██╔════╝    ██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗██╔════╝
            ███████║██║██████╔╝██████╔╝███████║███████╗█████╗      ███████╗   ██║   ██║   ██║██████╔╝█████╗
            ██╔══██║██║██╔══██╗██╔══██╗██╔══██║╚════██║██╔══╝      ╚════██║   ██║   ██║   ██║██╔══██╗██╔══╝
            ██║  ██║██║██║  ██║██████╔╝██║  ██║███████║███████╗    ███████║   ██║   ╚██████╔╝██║  ██║███████╗
            ╚═╝  ╚═╝╚═╝╚═╝  ╚═╝╚═════╝ ╚═╝  ╚═╝╚══════╝╚══════╝    ╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝

    What this store does
    - Stores Airbase entities indexed by AirbaseId and name for fast lookup.

    How others use it
    - Reserved for future use by GCI services that will manage interceptor airbases.
--]]

Medusa.Services.AirbaseStore = {}

function Medusa.Services.AirbaseStore:new()
	local o = {
		_byId = {},
		_byName = {},
		_count = 0,
		_logger = Medusa.Logger:ns("AirbaseStore"),
	}
	setmetatable(o, { __index = self })
	return o
end

function Medusa.Services.AirbaseStore:add(airbase)
	if self._byId[airbase.AirbaseId] then
		error(string.format("duplicate AirbaseId: %s", airbase.AirbaseId))
	end
	if self._byName[airbase.AirbaseName] then
		error(string.format("duplicate AirbaseName: %s", airbase.AirbaseName))
	end

	self._byId[airbase.AirbaseId] = airbase
	self._byName[airbase.AirbaseName] = airbase.AirbaseId
	self._count = self._count + 1

	self._logger:debug(
		string.format("added airbase %s (name=%s, count=%d)", airbase.AirbaseId, airbase.AirbaseName, self._count)
	)
end

function Medusa.Services.AirbaseStore:get(airbaseId)
	return self._byId[airbaseId]
end

function Medusa.Services.AirbaseStore:getByName(airbaseName)
	local airbaseId = self._byName[airbaseName]
	if not airbaseId then
		return nil
	end
	return self._byId[airbaseId]
end

function Medusa.Services.AirbaseStore:remove(airbaseId)
	local airbase = self._byId[airbaseId]
	if not airbase then
		return nil
	end

	self._byId[airbaseId] = nil
	self._byName[airbase.AirbaseName] = nil
	self._count = self._count - 1

	self._logger:debug(string.format("removed airbase %s (count=%d)", airbaseId, self._count))
	return airbase
end

function Medusa.Services.AirbaseStore:getAll(outputTable)
	local result = outputTable or {}
	if outputTable then
		for i = #outputTable, 1, -1 do
			outputTable[i] = nil
		end
	end
	for _, airbase in pairs(self._byId) do
		result[#result + 1] = airbase
	end
	return result
end

function Medusa.Services.AirbaseStore:count()
	return self._count
end
