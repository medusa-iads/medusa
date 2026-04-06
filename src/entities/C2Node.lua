require("_header")
require("entities.Entities")

--[[
             ██████╗██████╗     ███╗   ██╗ ██████╗ ██████╗ ███████╗
            ██╔════╝╚════██╗    ████╗  ██║██╔═══██╗██╔══██╗██╔════╝
            ██║      █████╔╝    ██╔██╗ ██║██║   ██║██║  ██║█████╗
            ██║     ██╔═══╝     ██║╚██╗██║██║   ██║██║  ██║██╔══╝
            ╚██████╗███████╗    ██║ ╚████║╚██████╔╝██████╔╝███████╗
             ╚═════╝╚══════╝    ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝

    What this entity does
    - Holds data for a command post node: name, echelon, position, and network membership.

    How others use it
    - EntityFactory creates C2Node instances from discovered HQ groups.
    - HierarchyService and C2NodeStore manage these nodes to represent the command tree.
--]]

Medusa.Entities.C2Node = {}

function Medusa.Entities.C2Node.new(data)
	if not data then
		error("data table is required")
	end
	if data.NetworkId == nil then
		error("missing required field: NetworkId")
	end

	return {
		C2NodeId = data.C2NodeId or NewULID(),
		NetworkId = data.NetworkId,
		NodeName = data.NodeName,
		EchelonName = data.EchelonName,
		UnitHandleId = data.UnitHandleId,
		Position = data.Position,
	}
end
