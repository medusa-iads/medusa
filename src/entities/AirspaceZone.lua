require("_header")
require("entities.Entities")

--[[
             █████╗ ██╗██████╗ ███████╗██████╗  █████╗  ██████╗███████╗    ███████╗ ██████╗ ███╗   ██╗███████╗
            ██╔══██╗██║██╔══██╗██╔════╝██╔══██╗██╔══██╗██╔════╝██╔════╝    ╚══███╔╝██╔═══██╗████╗  ██║██╔════╝
            ███████║██║██████╔╝███████╗██████╔╝███████║██║     █████╗        ███╔╝ ██║   ██║██╔██╗ ██║█████╗
            ██╔══██║██║██╔══██╗╚════██║██╔═══╝ ██╔══██║██║     ██╔══╝       ███╔╝  ██║   ██║██║╚██╗██║██╔══╝
            ██║  ██║██║██║  ██║███████║██║     ██║  ██║╚██████╗███████╗    ███████╗╚██████╔╝██║ ╚████║███████╗
            ╚═╝  ╚═╝╚═╝╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝  ╚═╝ ╚═════╝╚══════╝    ╚══════╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝

    What this entity does
    - Holds data for a named airspace zone: name, kind, geometry, and network membership.

    How others use it
    - Reserved for future use by engagement and ROE services that will apply zone-based rules.
--]]

Medusa.Entities.AirspaceZone = {}

function Medusa.Entities.AirspaceZone.new(data)
	if not data then
		error("data table is required")
	end
	if data.ZoneName == nil then
		error("missing required field: ZoneName")
	end
	if data.NetworkId == nil then
		error("missing required field: NetworkId")
	end
	if data.Geometry == nil then
		error("missing required field: Geometry")
	end

	return {
		NetworkId = data.NetworkId,
		ZoneName = data.ZoneName,
		Kind = data.Kind or "FRIENDLY",
		Geometry = data.Geometry,
	}
end
