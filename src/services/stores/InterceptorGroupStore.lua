require("_header")
require("services.Services")
require("core.Logger")

--[[
            ██╗███╗   ██╗████████╗███████╗██████╗  ██████╗███████╗██████╗ ████████╗ ██████╗ ██████╗
            ██║████╗  ██║╚══██╔══╝██╔════╝██╔══██╗██╔════╝██╔════╝██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗
            ██║██╔██╗ ██║   ██║   █████╗  ██████╔╝██║     █████╗  ██████╔╝   ██║   ██║   ██║██████╔╝
            ██║██║╚██╗██║   ██║   ██╔══╝  ██╔══██╗██║     ██╔══╝  ██╔═══╝    ██║   ██║   ██║██╔══██╗
            ██║██║ ╚████║   ██║   ███████╗██║  ██║╚██████╗███████╗██║        ██║   ╚██████╔╝██║  ██║
            ╚═╝╚═╝  ╚═══╝   ╚═╝   ╚══════╝╚═╝  ╚═╝ ╚═════╝╚══════╝╚═╝        ╚═╝    ╚═════╝ ╚═╝  ╚═╝
             ██████╗ ██████╗  ██████╗ ██╗   ██╗██████╗     ███████╗████████╗ ██████╗ ██████╗ ███████╗
            ██╔════╝ ██╔══██╗██╔═══██╗██║   ██║██╔══██╗    ██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗██╔════╝
            ██║  ███╗██████╔╝██║   ██║██║   ██║██████╔╝    ███████╗   ██║   ██║   ██║██████╔╝█████╗
            ██║   ██║██╔══██╗██║   ██║██║   ██║██╔═══╝     ╚════██║   ██║   ██║   ██║██╔══██╗██╔══╝
            ╚██████╔╝██║  ██║╚██████╔╝╚██████╔╝██║         ███████║   ██║   ╚██████╔╝██║  ██║███████╗
             ╚═════╝ ╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═╝         ╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝

    What this store does
    - Stores InterceptorGroup entities indexed by ID and group name for fast lookup.

    How others use it
    - Reserved for future use by GCI services that will assign and track interceptor flights.
--]]

Medusa.Services.InterceptorGroupStore = {}

function Medusa.Services.InterceptorGroupStore:new()
	local o = {
		_byId = {},
		_byGroupName = {},
		_count = 0,
		_logger = Medusa.Logger:ns("InterceptorGroupStore"),
	}
	setmetatable(o, { __index = self })
	return o
end

function Medusa.Services.InterceptorGroupStore:add(group)
	if self._byId[group.InterceptorGroupId] then
		error(string.format("duplicate InterceptorGroupId: %s", group.InterceptorGroupId))
	end
	if self._byGroupName[group.GroupName] then
		error(string.format("duplicate GroupName: %s", group.GroupName))
	end

	self._byId[group.InterceptorGroupId] = group
	self._byGroupName[group.GroupName] = group.InterceptorGroupId
	self._count = self._count + 1

	self._logger:debug(string.format("added interceptor group %s (groupName=%s, count=%d)", group.InterceptorGroupId, group.GroupName, self._count))
end

function Medusa.Services.InterceptorGroupStore:get(groupId)
	return self._byId[groupId]
end

function Medusa.Services.InterceptorGroupStore:getByGroupName(groupName)
	local groupId = self._byGroupName[groupName]
	if not groupId then
		return nil
	end
	return self._byId[groupId]
end

function Medusa.Services.InterceptorGroupStore:remove(groupId)
	local group = self._byId[groupId]
	if not group then
		return nil
	end

	self._byId[groupId] = nil
	self._byGroupName[group.GroupName] = nil
	self._count = self._count - 1

	self._logger:debug(string.format("removed interceptor group %s (count=%d)", groupId, self._count))
	return group
end

function Medusa.Services.InterceptorGroupStore:getAll(outputTable)
	local result = outputTable or {}
	if outputTable then
		for i = #outputTable, 1, -1 do
			outputTable[i] = nil
		end
	end
	for _, group in pairs(self._byId) do
		result[#result + 1] = group
	end
	return result
end

function Medusa.Services.InterceptorGroupStore:count()
	return self._count
end
