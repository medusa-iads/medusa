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
    - Holds command-center identity and the fixed provider set whose availability controls its edge.

    How others use it
    - EntityFactory creates C2Node instances from discovered HQ groups.
    - HierarchyService and C2NodeStore manage these nodes to represent the command tree.
--]]

Medusa.Entities.C2Node = {}

--- Creates the command-center node and its mission-selected provider identities from data.
function Medusa.Entities.C2Node.new(data)
	if not data then
		error("data table is required")
	end
	if data.NodeName == nil then
		error("missing required field: NodeName")
	end

	return {
		NodeName = data.NodeName,
		GroupId = data.GroupId,
		Providers = data.Providers or {},
	}
end

--- Returns whether node has at least one selected provider that remains available.
function Medusa.Entities.C2Node.hasAvailableProvider(node)
	local providers = node and node.Providers or {}
	for i = 1, #providers do
		if providers[i].Available == true then
			return true
		end
	end
	return false
end
