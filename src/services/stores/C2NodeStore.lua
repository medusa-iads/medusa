require("_header")
require("services.Services")
require("core.Logger")

--[[
             ██████╗██████╗     ███╗   ██╗ ██████╗ ██████╗ ███████╗    ███████╗████████╗ ██████╗ ██████╗ ███████╗
            ██╔════╝╚════██╗    ████╗  ██║██╔═══██╗██╔══██╗██╔════╝    ██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗██╔════╝
            ██║      █████╔╝    ██╔██╗ ██║██║   ██║██║  ██║█████╗      ███████╗   ██║   ██║   ██║██████╔╝█████╗
            ██║     ██╔═══╝     ██║╚██╗██║██║   ██║██║  ██║██╔══╝      ╚════██║   ██║   ██║   ██║██╔══██╗██╔══╝
            ╚██████╗███████╗    ██║ ╚████║╚██████╔╝██████╔╝███████╗    ███████║   ██║   ╚██████╔╝██║  ██║███████╗
             ╚═════╝╚══════╝    ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝    ╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝

    What this store does
    - Stores C2Node entities indexed by C2NodeId and NodeName for fast lookup.

    How others use it
    - EntityFactory adds C2 nodes after creation; HierarchyService and IadsNetwork read them.
--]]

Medusa.Services.C2NodeStore = {}

function Medusa.Services.C2NodeStore:new()
	local o = {
		_byId = {},
		_byNodeName = {},
		_count = 0,
		_logger = Medusa.Logger:ns("C2NodeStore"),
	}
	setmetatable(o, { __index = self })
	return o
end

function Medusa.Services.C2NodeStore:add(c2node)
	if self._byId[c2node.C2NodeId] then
		error(string.format("duplicate C2NodeId: %s", c2node.C2NodeId))
	end
	if c2node.NodeName ~= nil and self._byNodeName[c2node.NodeName] then
		error(string.format("duplicate NodeName: %s", c2node.NodeName))
	end

	self._byId[c2node.C2NodeId] = c2node
	if c2node.NodeName ~= nil then
		self._byNodeName[c2node.NodeName] = c2node.C2NodeId
	end
	self._count = self._count + 1

	self._logger:debug(
		string.format(
			"added c2node %s (nodeName=%s, count=%d)",
			c2node.C2NodeId,
			tostring(c2node.NodeName),
			self._count
		)
	)
end

function Medusa.Services.C2NodeStore:get(c2nodeId)
	return self._byId[c2nodeId]
end

function Medusa.Services.C2NodeStore:getByNodeName(nodeName)
	local c2nodeId = self._byNodeName[nodeName]
	if not c2nodeId then
		return nil
	end
	return self._byId[c2nodeId]
end

function Medusa.Services.C2NodeStore:remove(c2nodeId)
	local c2node = self._byId[c2nodeId]
	if not c2node then
		return nil
	end

	self._byId[c2nodeId] = nil
	if c2node.NodeName ~= nil then
		self._byNodeName[c2node.NodeName] = nil
	end
	self._count = self._count - 1

	self._logger:debug(string.format("removed c2node %s (count=%d)", c2nodeId, self._count))
	return c2node
end

function Medusa.Services.C2NodeStore:getAll(outputTable)
	local result = outputTable or {}
	if outputTable then
		for i = #outputTable, 1, -1 do
			outputTable[i] = nil
		end
	end
	for _, c2node in pairs(self._byId) do
		result[#result + 1] = c2node
	end
	return result
end

function Medusa.Services.C2NodeStore:count()
	return self._count
end
