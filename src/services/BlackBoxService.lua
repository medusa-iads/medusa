require("_header")
require("services.Services")

--[[
            ██████╗ ██╗      █████╗  ██████╗██╗  ██╗    ██████╗  ██████╗ ██╗  ██╗
            ██╔══██╗██║     ██╔══██╗██╔════╝██║ ██╔╝    ██╔══██╗██╔═══██╗╚██╗██╔╝
            ██████╔╝██║     ███████║██║     █████╔╝     ██████╔╝██║   ██║ ╚███╔╝
            ██╔══██╗██║     ██╔══██║██║     ██╔═██╗     ██╔══██╗██║   ██║ ██╔██╗
            ██████╔╝███████╗██║  ██║╚██████╗██║  ██╗    ██████╔╝╚██████╔╝██╔╝ ██╗
            ╚═════╝ ╚══════╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝    ╚═════╝  ╚═════╝ ╚═╝  ╚═╝

    What this service does
    - Caches DCS object metadata (type name, unit name, coalition) from live objects for later use.
    - Serves only metrics and logging; no IADS decision logic reads from this cache.
    - This is really just a brain friendly method of segregrating data that the IADS shouldn't have, but external processes (e.g. metrics) may want to use

    How others use it
    - IadsNetwork caches metadata on world events so MetricsSnapshotService can label metrics with unit names.
--]]

Medusa.Services.BlackBoxService = {}
Medusa.Services.BlackBoxService._cache = {}
function Medusa.Services.BlackBoxService.cacheFromObject(networkId, obj)
	if not networkId or Medusa.Services.BlackBoxService._cache[networkId] then
		return
	end
	local entry = {}
	local ok, val = pcall(obj.getTypeName, obj)
	if ok then
		entry.TypeName = val
	end
	ok, val = pcall(obj.getName, obj)
	if ok then
		entry.UnitName = val
	end
	ok, val = pcall(obj.getCoalition, obj)
	if ok then
		entry.CoalitionId = val
	end
	Medusa.Services.BlackBoxService._cache[networkId] = entry
end

function Medusa.Services.BlackBoxService.get(networkId)
	return Medusa.Services.BlackBoxService._cache[networkId]
end

function Medusa.Services.BlackBoxService.clear()
	Medusa.Services.BlackBoxService._cache = {}
end
