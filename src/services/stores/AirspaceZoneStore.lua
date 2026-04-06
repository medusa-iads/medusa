require("_header")
require("services.Services")
require("core.Logger")

--[[
             █████╗ ██╗██████╗ ███████╗██████╗  █████╗  ██████╗███████╗    ███████╗ ██████╗ ███╗   ██╗███████╗
            ██╔══██╗██║██╔══██╗██╔════╝██╔══██╗██╔══██╗██╔════╝██╔════╝    ╚══███╔╝██╔═══██╗████╗  ██║██╔════╝
            ███████║██║██████╔╝███████╗██████╔╝███████║██║     █████╗        ███╔╝ ██║   ██║██╔██╗ ██║█████╗
            ██╔══██║██║██╔══██╗╚════██║██╔═══╝ ██╔══██║██║     ██╔══╝       ███╔╝  ██║   ██║██║╚██╗██║██╔══╝
            ██║  ██║██║██║  ██║███████║██║     ██║  ██║╚██████╗███████╗    ███████╗╚██████╔╝██║ ╚████║███████╗
            ╚═╝  ╚═╝╚═╝╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝  ╚═╝ ╚═════╝╚══════╝    ╚══════╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝
            ███████╗████████╗ ██████╗ ██████╗ ███████╗
            ██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗██╔════╝
            ███████╗   ██║   ██║   ██║██████╔╝█████╗
            ╚════██║   ██║   ██║   ██║██╔══██╗██╔══╝
            ███████║   ██║   ╚██████╔╝██║  ██║███████╗
            ╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝

    What this store does
    - Stores AirspaceZone entities indexed by name and kind for fast lookup.

    How others use it
    - Reserved for future use by engagement services that will apply zone-based ROE.
--]]

Medusa.Services.AirspaceZoneStore = {}

function Medusa.Services.AirspaceZoneStore:new()
	local o = {
		_byName = {},
		_byKind = {},
		_count = 0,
		_logger = Medusa.Logger:ns("AirspaceZoneStore"),
	}
	setmetatable(o, { __index = self })
	return o
end

function Medusa.Services.AirspaceZoneStore:add(zone)
	if self._byName[zone.ZoneName] then
		error(string.format("duplicate ZoneName: %s", zone.ZoneName))
	end

	self._byName[zone.ZoneName] = zone
	self._count = self._count + 1

	local kind = zone.Kind
	if not self._byKind[kind] then
		self._byKind[kind] = {}
	end
	self._byKind[kind][zone.ZoneName] = zone

	self._logger:debug(string.format("added zone %s (kind=%s, count=%d)", zone.ZoneName, kind, self._count))
end

function Medusa.Services.AirspaceZoneStore:get(zoneName)
	return self._byName[zoneName]
end

function Medusa.Services.AirspaceZoneStore:getByKind(kind, outputTable)
	local kindIndex = self._byKind[kind]
	if not kindIndex then
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
	for _, zone in pairs(kindIndex) do
		result[#result + 1] = zone
	end
	return result
end

function Medusa.Services.AirspaceZoneStore:remove(zoneName)
	local zone = self._byName[zoneName]
	if not zone then
		return nil
	end

	self._byName[zoneName] = nil
	self._count = self._count - 1

	local kindIndex = self._byKind[zone.Kind]
	if kindIndex then
		kindIndex[zoneName] = nil
		if next(kindIndex) == nil then
			self._byKind[zone.Kind] = nil
		end
	end

	self._logger:debug(string.format("removed zone %s (count=%d)", zoneName, self._count))
	return zone
end

function Medusa.Services.AirspaceZoneStore:getAll(outputTable)
	local result = outputTable or {}
	if outputTable then
		for i = #outputTable, 1, -1 do
			outputTable[i] = nil
		end
	end
	for _, zone in pairs(self._byName) do
		result[#result + 1] = zone
	end
	return result
end

function Medusa.Services.AirspaceZoneStore:count()
	return self._count
end
