require("_header")
require("entities.Entities")

--[[
             █████╗ ██╗██████╗ ██████╗  █████╗ ███████╗███████╗
            ██╔══██╗██║██╔══██╗██╔══██╗██╔══██╗██╔════╝██╔════╝
            ███████║██║██████╔╝██████╔╝███████║███████╗█████╗
            ██╔══██║██║██╔══██╗██╔══██╗██╔══██║╚════██║██╔══╝
            ██║  ██║██║██║  ██║██████╔╝██║  ██║███████║███████╗
            ╚═╝  ╚═╝╚═╝╚═╝  ╚═╝╚═════╝ ╚═╝  ╚═╝╚══════╝╚══════╝

    What this entity does
    - Holds data for an airfield used in GCI interceptor operations: name, position, and inventory.

    How others use it
    - Reserved for future use by GCI services that will launch and manage interceptor flights.
--]]

Medusa.Entities.Airbase = {}

function Medusa.Entities.Airbase.new(data)
	if not data then
		error("data table is required")
	end
	if data.NetworkId == nil then
		error("missing required field: NetworkId")
	end
	if data.AirbaseName == nil then
		error("missing required field: AirbaseName")
	end

	return {
		AirbaseId = data.AirbaseId or NewULID(),
		NetworkId = data.NetworkId,
		AirbaseName = data.AirbaseName,
		Position = data.Position,
		AvailableInterceptorInventory = data.AvailableInterceptorInventory,
		InterceptorServiceZoneName = data.InterceptorServiceZoneName,
		InterceptorServiceRangeKm = data.InterceptorServiceRangeKm,
		StaticInventory = data.StaticInventory,
	}
end
