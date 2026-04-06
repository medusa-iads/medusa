require("_header")
require("entities.Entities")
require("core.Constants")

--[[
            ███████╗███████╗███╗   ██╗███████╗ ██████╗ ██████╗     ██╗   ██╗███╗   ██╗██╗████████╗
            ██╔════╝██╔════╝████╗  ██║██╔════╝██╔═══██╗██╔══██╗    ██║   ██║████╗  ██║██║╚══██╔══╝
            ███████╗█████╗  ██╔██╗ ██║███████╗██║   ██║██████╔╝    ██║   ██║██╔██╗ ██║██║   ██║
            ╚════██║██╔══╝  ██║╚██╗██║╚════██║██║   ██║██╔══██╗    ██║   ██║██║╚██╗██║██║   ██║
            ███████║███████╗██║ ╚████║███████║╚██████╔╝██║  ██║    ╚██████╔╝██║ ╚████║██║   ██║
            ╚══════╝╚══════╝╚═╝  ╚═══╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝     ╚═════╝ ╚═╝  ╚═══╝╚═╝   ╚═╝

    What this entity does
    - Holds data for a single EWR or GCI sensor unit: detection range, position, type, and operational status.

    How others use it
    - EntityFactory creates SensorUnit instances from discovered EWR/GCI groups.
    - SensorPollingService iterates sensors to poll DCS detections; EmconService controls their radar state.
--]]

Medusa.Entities.SensorUnit = {}

function Medusa.Entities.SensorUnit.new(data)
	if not data then
		error("data table is required")
	end
	if data.NetworkId == nil then
		error("missing required field: NetworkId")
	end
	if data.UnitId == nil then
		error("missing required field: UnitId")
	end
	if data.UnitName == nil then
		error("missing required field: UnitName")
	end

	if data.GroupId == nil then
		error("missing required field: GroupId")
	end
	if data.GroupName == nil then
		error("missing required field: GroupName")
	end

	return {
		SensorUnitId = data.SensorUnitId or NewULID(),
		NetworkId = data.NetworkId,
		UnitId = data.UnitId,
		UnitName = data.UnitName,
		GroupId = data.GroupId,
		GroupName = data.GroupName,
		UnitTypeName = data.UnitTypeName,
		HierarchyPath = data.HierarchyPath,
		SensorType = data.SensorType or "EWR",
		Position = data.Position,
		DetectionRangeMax = data.DetectionRangeMax,
		DetectionAltitudeMax = data.DetectionAltitudeMax,
		DetectionAltitudeMin = data.DetectionAltitudeMin,
		OperationalStatus = data.OperationalStatus or Medusa.Constants.UnitOperationalStatus.ACTIVE,
		IsAirborne = data.IsAirborne or false,
		RadarStatus = data.RadarStatus or "DARK",
		Connectivity = data.Connectivity or "CONNECTED",
		HarmDetectionChance = data.HarmDetectionChance,
		ServiceRangeKm = data.ServiceRangeKm,
		LastScanTime = data.LastScanTime,
		PowerNodeId = data.PowerNodeId,
		ConnectionNodeId = data.ConnectionNodeId,
		DetectableTargetTypes = data.DetectableTargetTypes,
		GciServicedAirbaseIds = data.GciServicedAirbaseIds,
	}
end
