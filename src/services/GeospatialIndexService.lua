require("_header")
require("services.Services")
require("core.Constants")
require("entities.Battery")

--[[
    GEOSPATIAL INDEX SERVICE

    What this service does
    - Owns the NetworkedGeoGrid and LocalGeoGrid for one IADS network.
    - Keeps each battery in the grid that matches its current operating mode.

    How others use it
    - IadsNetwork synchronizes batteries after discovery, movement, damage, and mode changes.
    - IADS and local-defense services query the appropriate grid through AssetIndex.
--]]

Medusa.Services.GeospatialIndexService = {}

local BR = Medusa.Constants.BatteryRole
local AM = Medusa.Constants.Aaa.Mode
local Battery = Medusa.Entities.Battery
local DESTINATION = {
	NETWORKED = "NETWORKED",
	LOCAL = "LOCAL",
}

local function placement(battery)
	if battery.Role == BR.MANPAD then
		return DESTINATION.LOCAL, "Manpad"
	end
	if battery.Role ~= BR.AAA then
		return DESTINATION.NETWORKED, "Battery"
	end
	if not battery.Aaa then
		return nil
	end
	local capabilityMode = Battery.isRadarDirectedAaa(battery) and AM.RADAR_DIRECTED or AM.INDEPENDENT
	if battery.Aaa.Mode ~= capabilityMode then
		return nil
	end
	if capabilityMode == AM.RADAR_DIRECTED then
		return DESTINATION.NETWORKED, "Battery"
	end
	return DESTINATION.LOCAL, "Aaa"
end

function Medusa.Services.GeospatialIndexService:new(cellSizeMeters)
	local o = {
		_networkedGeoGrid = GeoGrid(cellSizeMeters, { "Battery", "Track" }),
		_localGeoGrid = GeoGrid(cellSizeMeters, { "Manpad", "Aaa" }),
	}
	setmetatable(o, { __index = Medusa.Services.GeospatialIndexService })
	return o
end

function Medusa.Services.GeospatialIndexService:networkedGeoGrid()
	return self._networkedGeoGrid
end

function Medusa.Services.GeospatialIndexService:localGeoGrid()
	return self._localGeoGrid
end

function Medusa.Services.GeospatialIndexService:isNetworkedBattery(battery)
	return placement(battery) == DESTINATION.NETWORKED
end

function Medusa.Services.GeospatialIndexService:withdrawBattery(batteryId)
	self._networkedGeoGrid:remove(batteryId)
	self._localGeoGrid:remove(batteryId)
end

function Medusa.Services.GeospatialIndexService:syncBattery(battery)
	self:withdrawBattery(battery.BatteryId)
	if not battery.Position then
		return false
	end
	local destination, entityType = placement(battery)
	if destination == DESTINATION.NETWORKED then
		return self._networkedGeoGrid:add(entityType, battery.BatteryId, battery.Position)
	elseif destination == DESTINATION.LOCAL then
		return self._localGeoGrid:add(entityType, battery.BatteryId, battery.Position)
	end
	return false
end

function Medusa.Services.GeospatialIndexService:removeBattery(batteryId)
	self:withdrawBattery(batteryId)
end
