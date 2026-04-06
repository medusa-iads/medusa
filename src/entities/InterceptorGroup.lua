require("_header")
require("entities.Entities")
require("core.Constants")

--[[
            ██╗███╗   ██╗████████╗███████╗██████╗  ██████╗███████╗██████╗ ████████╗ ██████╗ ██████╗
            ██║████╗  ██║╚══██╔══╝██╔════╝██╔══██╗██╔════╝██╔════╝██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗
            ██║██╔██╗ ██║   ██║   █████╗  ██████╔╝██║     █████╗  ██████╔╝   ██║   ██║   ██║██████╔╝
            ██║██║╚██╗██║   ██║   ██╔══╝  ██╔══██╗██║     ██╔══╝  ██╔═══╝    ██║   ██║   ██║██╔══██╗
            ██║██║ ╚████║   ██║   ███████╗██║  ██║╚██████╗███████╗██║        ██║   ╚██████╔╝██║  ██║
            ╚═╝╚═╝  ╚═══╝   ╚═╝   ╚══════╝╚═╝  ╚═╝ ╚═════╝╚══════╝╚═╝        ╚═╝    ╚═════╝ ╚═╝  ╚═╝

    What this entity does
    - Holds data for an AI interceptor flight: aircraft type, home airbase, task, and status.

    How others use it
    - Reserved for future use by GCI services that will assign and track interceptor missions.
--]]

Medusa.Entities.InterceptorGroup = {}

function Medusa.Entities.InterceptorGroup.new(data)
	if not data then
		error("data table is required")
	end
	if data.NetworkId == nil then
		error("missing required field: NetworkId")
	end
	if data.GroupId == nil then
		error("missing required field: GroupId")
	end
	if data.GroupName == nil then
		error("missing required field: GroupName")
	end
	if data.AircraftType == nil then
		error("missing required field: AircraftType")
	end
	if data.HomeAirbaseId == nil then
		error("missing required field: HomeAirbaseId")
	end

	return {
		InterceptorGroupId = data.InterceptorGroupId or NewULID(),
		NetworkId = data.NetworkId,
		GroupId = data.GroupId,
		GroupName = data.GroupName,
		AircraftType = data.AircraftType,
		NumberOfAircraft = data.NumberOfAircraft or 1,
		HomeAirbaseId = data.HomeAirbaseId,
		CurrentTask = data.CurrentTask or Medusa.Constants.InterceptorGroupTask.INTERCEPT,
		TargetTrackId = data.TargetTrackId,
		Status = data.Status or "SPAWNING",
		RearmCompleteTime = data.RearmCompleteTime,
	}
end
