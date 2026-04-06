require("_header")
require("services.Services")

--[[
            ███████╗██████╗  █████╗ ████████╗██╗ █████╗ ██╗          ██████╗ ██╗   ██╗███████╗██████╗ ██╗   ██╗
            ██╔════╝██╔══██╗██╔══██╗╚══██╔══╝██║██╔══██╗██║         ██╔═══██╗██║   ██║██╔════╝██╔══██╗╚██╗ ██╔╝
            ███████╗██████╔╝███████║   ██║   ██║███████║██║         ██║   ██║██║   ██║█████╗  ██████╔╝ ╚████╔╝
            ╚════██║██╔═══╝ ██╔══██║   ██║   ██║██╔══██║██║         ██║   ██║██║   ██║██╔══╝  ██╔══██╗  ╚██╔╝
            ███████║██║     ██║  ██║   ██║   ██║██║  ██║███████╗    ╚██████╔╝╚██████╔╝███████╗██║  ██║   ██║
            ╚══════╝╚═╝     ╚═╝  ╚═╝   ╚═╝   ╚═╝╚═╝  ╚═╝╚══════╝     ╚═════╝  ╚═════╝ ╚══════╝╚═╝  ╚═╝   ╚═╝

    What this service does
    - Provides radius search helpers that query the GeoGrid for nearby batteries, sensors, or tracks.
    - Returns filtered result lists from the underlying stores based on spatial proximity.

    How others use it
    - TargetAssigner finds candidate batteries within range of a track using batteriesInRadius.
    - PointDefenseService and HarmDetectionService use radius queries to find nearby assets.
--]]

Medusa.Services.SpatialQuery = {}

Medusa.Services.SpatialQuery._buffer = {}
local _spatialQueryBuffer = Medusa.Services.SpatialQuery._buffer

function Medusa.Services.SpatialQuery.batteriesInRadius(geoGrid, batteryStore, pos, radiusM)
	for i = #_spatialQueryBuffer, 1, -1 do
		_spatialQueryBuffer[i] = nil
	end
	local ids = geoGrid:queryRadius(pos, radiusM, { "Battery" })
	local batteryIds = ids.BatteryIds
	if batteryIds then
		for id in pairs(batteryIds) do
			local battery = batteryStore:get(id)
			if battery then
				_spatialQueryBuffer[#_spatialQueryBuffer + 1] = battery
			end
		end
	end
	return _spatialQueryBuffer
end

--- Test whether a position is inside any of the given border zone polygons.
--- Uses the harness PointInPolygon2D ray-casting algorithm (odd crossings = inside).
--- Returns true on first match.
--- @param borderPolygons table[] List of polygon tables, each a list of {x, z} points
--- @param pos table Position with .x and .z fields
--- @return boolean inside True if pos is inside any border polygon
function Medusa.Services.SpatialQuery.pointInBorderZones(borderPolygons, pos)
	for i = 1, #borderPolygons do
		if PointInPolygon2D(pos, borderPolygons[i]) then
			return true
		end
	end
	return false
end
