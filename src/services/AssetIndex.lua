require("_header")
require("services.Services")

--[[
             █████╗ ███████╗███████╗███████╗████████╗    ██╗███╗   ██╗██████╗ ███████╗██╗  ██╗
            ██╔══██╗██╔════╝██╔════╝██╔════╝╚══██╔══╝    ██║████╗  ██║██╔══██╗██╔════╝╚██╗██╔╝
            ███████║███████╗███████╗█████╗     ██║       ██║██╔██╗ ██║██║  ██║█████╗   ╚███╔╝
            ██╔══██║╚════██║╚════██║██╔══╝     ██║       ██║██║╚██╗██║██║  ██║██╔══╝   ██╔██╗
            ██║  ██║███████║███████║███████╗   ██║       ██║██║ ╚████║██████╔╝███████╗██╔╝ ██╗
            ╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝   ╚═╝       ╚═╝╚═╝  ╚═══╝╚═════╝ ╚══════╝╚═╝  ╚═╝

    What this service does
    - Bundles all entity stores and the GeoGrid into one object for convenient access.
    - Provides typed accessors for batteries, sensors, tracks, C2 nodes, zones, airbases, and interceptors.

    How others use it
    - IadsNetwork creates one AssetIndex per network and passes it to services that need store access.
    - SpatialQuery, TargetAssigner, and EmconService read stores through the AssetIndex accessors.
--]]

Medusa.Services.AssetIndex = {}

function Medusa.Services.AssetIndex.new(stores)
	local o = { _stores = stores }
	setmetatable(o, { __index = Medusa.Services.AssetIndex })
	return o
end

function Medusa.Services.AssetIndex:sensors()
	return self._stores.sensors
end

function Medusa.Services.AssetIndex:batteries()
	return self._stores.batteries
end

function Medusa.Services.AssetIndex:batteryRepository()
	return self._stores.batteryRepository
end

function Medusa.Services.AssetIndex:manpads()
	return self._stores.manpads
end

function Medusa.Services.AssetIndex:c2Nodes()
	return self._stores.c2Nodes
end

function Medusa.Services.AssetIndex:zones()
	return self._stores.zones
end

function Medusa.Services.AssetIndex:airbases()
	return self._stores.airbases
end

function Medusa.Services.AssetIndex:interceptors()
	return self._stores.interceptors
end

function Medusa.Services.AssetIndex:tracks()
	return self._stores.tracks
end

function Medusa.Services.AssetIndex:geoGrid()
	return self._stores.networkedGeoGrid or self._stores.geoGrid
end

function Medusa.Services.AssetIndex:networkedGeoGrid()
	return self._stores.networkedGeoGrid or self._stores.geoGrid
end

function Medusa.Services.AssetIndex:localGeoGrid()
	return self._stores.localGeoGrid
end

function Medusa.Services.AssetIndex:spatialIndex()
	return self._stores.spatialIndex
end
