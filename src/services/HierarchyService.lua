require("_header")
require("services.Services")
require("dependencies.harness")

--[[
            ██╗  ██╗██╗███████╗██████╗  █████╗ ██████╗  ██████╗██╗  ██╗██╗   ██╗    ███████╗███████╗██████╗ ██╗   ██╗██╗ ██████╗███████╗
            ██║  ██║██║██╔════╝██╔══██╗██╔══██╗██╔══██╗██╔════╝██║  ██║╚██╗ ██╔╝    ██╔════╝██╔════╝██╔══██╗██║   ██║██║██╔════╝██╔════╝
            ███████║██║█████╗  ██████╔╝███████║██████╔╝██║     ███████║ ╚████╔╝     ███████╗█████╗  ██████╔╝██║   ██║██║██║     █████╗  
            ██╔══██║██║██╔══╝  ██╔══██╗██╔══██║██╔══██╗██║     ██╔══██║  ╚██╔╝      ╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██║██║     ██╔══╝  
            ██║  ██║██║███████╗██║  ██║██║  ██║██║  ██║╚██████╗██║  ██║   ██║       ███████║███████╗██║  ██║ ╚████╔╝ ██║╚██████╗███████╗
            ╚═╝  ╚═╝╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝       ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚═╝ ╚═════╝╚══════╝
                                                                                                                                        
                                                                                                                                    
    What this service does
    - Maintains the command hierarchy tree that maps echelon paths to groups.
    - Uses a Trie and Set to store paths and group membership for fast lookup.
    - Supports add, remove, lookup, and tree rendering for logging.

    How others use it
    - IadsNetwork feeds discovery results into upsertGroup to build the command tree at startup.
    - MetricsSnapshotService reads the tree to report hierarchy size in Prometheus gauges.
]]

---@class Medusa.Services.HierarchyService
---@field _hierarchyIndex table
---@field _nodesByKey table<string, table>
---@field _byGroupId table<number, { key: string }>
---@field new fun(self: Medusa.Services.HierarchyService): Medusa.Services.HierarchyService
---@field upsertGroup fun(self: Medusa.Services.HierarchyService, dto: Medusa.Services.DiscoveryServiceDTO): boolean
---@field removeGroup fun(self: Medusa.Services.HierarchyService, groupId: number): boolean
---@field getNode fun(self: Medusa.Services.HierarchyService, pathSegments: string[]): table|nil
---@field getTree fun(self: Medusa.Services.HierarchyService): table
Medusa.Services.HierarchyService = {}

function Medusa.Services.HierarchyService:new()
	local o = {
		_hierarchyIndex = Trie(),
		_nodesByKey = {},
		_byGroupId = {},
	}
	setmetatable(o, { __index = self })
	return o
end

---@param pathSegments string[]
---@return string
function Medusa.Services.HierarchyService:_keyFromPath(pathSegments)
	if not pathSegments or #pathSegments == 0 then
		return ""
	end
	return table.concat(pathSegments, ".")
end

---@param key string
---@return table|nil
function Medusa.Services.HierarchyService:_getNodeByKey(key)
	return self._nodesByKey[key]
end

---@param dto Medusa.Services.DiscoveryServiceDTO
---@return boolean
function Medusa.Services.HierarchyService:upsertGroup(dto)
	if not dto or not dto.groupId or not dto.parsed then
		return false
	end
	local path = dto.parsed.echelonPath or {}
	local key = self:_keyFromPath(path)
	local node = self:_getNodeByKey(key)
	if not node then
		node = { key = key, groupsSet = Set(), groupInfo = {} }
		self._hierarchyIndex:insert(key)
		self._nodesByKey[key] = node
	end
	node.groupsSet:add(dto.groupId)
	node.groupInfo[dto.groupId] = {
		groupId = dto.groupId,
		groupName = dto.groupName,
		roles = dto.parsed.roles or {},
		isHQ = dto.parsed.isHQ or false,
	}
	self._byGroupId[dto.groupId] = { key = key }
	return true
end

---@param groupId number
---@return boolean
function Medusa.Services.HierarchyService:removeGroup(groupId)
	local ref = self._byGroupId[groupId]
	if not ref then
		return false
	end
	local node = self:_getNodeByKey(ref.key)
	if node then
		node.groupInfo[groupId] = nil
		node.groupsSet:remove(groupId)
		if node.groupsSet:isEmpty() then
			self._hierarchyIndex:delete(ref.key)
			self._nodesByKey[ref.key] = nil
		end
	end
	self._byGroupId[groupId] = nil
	return true
end

---@param pathSegments string[]
---@return table
function Medusa.Services.HierarchyService:getNode(pathSegments)
	local key = self:_keyFromPath(pathSegments)
	local node = self:_getNodeByKey(key)
	if node then
		return node
	end
	-- lazily materialize empty node for callers that want a handle to the path
	local created = { key = key, groupsSet = Set(), groupInfo = {} }
	self._hierarchyIndex:insert(key, created)
	self._nodesByKey[key] = created
	return created
end

---@return table
function Medusa.Services.HierarchyService:getTree()
	return self._hierarchyIndex
end

---@return table[]
function Medusa.Services.HierarchyService:listNodes()
	local out = {}
	for key, node in pairs(self._nodesByKey) do
		local size = 0
		if node and node.groupsSet and node.groupsSet.size then
			size = node.groupsSet:size()
		end
		out[#out + 1] = { key = key, size = size }
	end
	table.sort(out, function(a, b)
		return tostring(a.key) < tostring(b.key)
	end)
	return out
end

---@return table
function Medusa.Services.HierarchyService:_buildHierarchyTree()
	local root = { name = "", size = 0, children = {} }
	for key, node in pairs(self._nodesByKey) do
		local size = 0
		if node and node.groupsSet and node.groupsSet.size then
			size = node.groupsSet:size()
		end
		local parts = {}
		if key and #key > 0 then
			for seg in string.gmatch(key, "[^%.]+") do
				parts[#parts + 1] = seg
			end
		end
		local cursor = root
		for i = 1, #parts do
			local seg = parts[i]
			cursor.children[seg] = cursor.children[seg] or { name = seg, size = 0, children = {} }
			cursor = cursor.children[seg]
		end
		cursor.size = size
	end
	return root
end

local function sortedKeys(children)
	local ks = {}
	for k, _ in pairs(children) do
		ks[#ks + 1] = k
	end
	table.sort(ks, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return ks
end

local function walkTree(node, prefix, lines)
	local ks = sortedKeys(node.children)
	for idx = 1, #ks do
		local name = ks[idx]
		local child = node.children[name]
		local connector = "|__ "
		lines[#lines + 1] =
			string.format("%s%s%s(%s)", prefix, connector, tostring(child.name), tostring(child.size or 0))
		local nextPrefix = prefix .. ((idx == #ks) and "    " or "|   ")
		walkTree(child, nextPrefix, lines)
	end
end

---@return string
function Medusa.Services.HierarchyService:renderTree()
	local root = self:_buildHierarchyTree()
	local lines = {}

	local hasChildren = false
	for _ in pairs(root.children) do
		hasChildren = true
		break
	end
	if (root.size or 0) > 0 or not hasChildren then
		lines[#lines + 1] = string.format("(root)(%s)", tostring(root.size or 0))
	end
	walkTree(root, "", lines)

	if #lines == 0 then
		return "(empty)"
	end
	return table.concat(lines, "\n")
end
