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

--- Creates the sensor identity, capability, position, and operational state supplied by data.
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
		GroupCategory = data.GroupCategory,
		UnitTypeName = data.UnitTypeName,
		SensorType = data.SensorType or Medusa.Constants.SensorType.EWR,
		Position = data.Position,
		DetectionRangeMax = data.DetectionRangeMax,
		DetectionAltitudeMax = data.DetectionAltitudeMax,
		DetectionAltitudeMin = data.DetectionAltitudeMin,
		OperationalStatus = data.OperationalStatus or Medusa.Constants.UnitOperationalStatus.ACTIVE,
		ControllerAvailable = data.ControllerAvailable ~= false,
		PositionAvailable = data.Position ~= nil and data.PositionAvailable ~= false,
		IsAirborne = data.IsAirborne or false,
		RadarStatus = data.RadarStatus or Medusa.Constants.RadarStatus.DARK,
		EmconState = data.EmconState or Medusa.Constants.ActivationState.INITIALIZING,
		HarmDetectionChance = data.HarmDetectionChance,
		ServiceRangeKm = data.ServiceRangeKm,
		LastScanTime = data.LastScanTime,
		DetectableTargetTypes = data.DetectableTargetTypes,
		GciServicedAirbaseIds = data.GciServicedAirbaseIds,
		PartitionKey = data.PartitionKey,
	}
end

--- Reports whether the current sensor identity has usable controller and position observations.
function Medusa.Entities.SensorUnit.isAvailable(sensor)
	return sensor ~= nil
		and sensor.OperationalStatus ~= Medusa.Constants.UnitOperationalStatus.DESTROYED
		and sensor.ControllerAvailable ~= false
		and sensor.PositionAvailable ~= false
end
