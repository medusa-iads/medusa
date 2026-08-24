require("_header")
require("services.Services")
require("core.Logger")
require("core.Constants")
require("services.stores.UnitIndex")

--[[
             ██████╗██████╗     ███╗   ██╗ ██████╗ ██████╗ ███████╗    ███████╗████████╗ ██████╗ ██████╗ ███████╗
            ██╔════╝╚════██╗    ████╗  ██║██╔═══██╗██╔══██╗██╔════╝    ██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗██╔════╝
            ██║      █████╔╝    ██╔██╗ ██║██║   ██║██║  ██║█████╗      ███████╗   ██║   ██║   ██║██████╔╝█████╗
            ██║     ██╔═══╝     ██║╚██╗██║██║   ██║██║  ██║██╔══╝      ╚════██║   ██║   ██║   ██║██╔══██╗██╔══╝
            ╚██████╗███████╗    ██║ ╚████║╚██████╔╝██████╔╝███████╗    ███████║   ██║   ╚██████╔╝██║  ██║███████╗
             ╚═════╝╚══════╝    ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝    ╚══════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝

    What this store does
    - Stores command-center nodes by their canonical DCS group name.

    How others use it
    - EntityFactory adds C2 nodes after creation; HierarchyService and IadsNetwork read them.
--]]

Medusa.Services.C2NodeStore = {}
local OwnerKind = Medusa.Constants.UnitOwnerKind

--- Creates the bounded command-center and selected-provider indexes.
function Medusa.Services.C2NodeStore:new(unitIndex)
	local o = {
		_byNodeName = {},
		_count = 0,
		_logger = Medusa.Logger:ns("C2NodeStore"),
		_unitIndex = unitIndex or Medusa.Services.UnitIndex:new(),
	}
	setmetatable(o, { __index = self })
	return o
end

--- Publishes a command node only after every identifier passes preflight validation.
function Medusa.Services.C2NodeStore:add(c2node)
	if self._count >= Medusa.Constants.C2.MAX_COMMAND_CENTERS then
		error(string.format("command-center capacity exceeded: %d", Medusa.Constants.C2.MAX_COMMAND_CENTERS))
	end
	if c2node.NodeName == nil then
		error("missing NodeName")
	end
	if self._byNodeName[c2node.NodeName] then
		error(string.format("duplicate NodeName: %s", c2node.NodeName))
	end

	local providers = c2node.Providers or {}
	local incomingProviderIds = {}
	local incomingProviderNames = {}
	for i = 1, #providers do
		local providerId = providers[i].UnitId
		local providerName = providers[i].UnitName
		if providerId then
			local currentIdentity = self._unitIndex:resolve(providerId)
			local currentProvider = self._unitIndex:getOwner(currentIdentity, OwnerKind.COMMAND_PROVIDER)
			if incomingProviderIds[providerId] or currentProvider then
				error(string.format("duplicate command provider UnitId: %s", tostring(providerId)))
			end
			incomingProviderIds[providerId] = true
		end
		if providerName then
			if incomingProviderNames[providerName] then
				error(string.format("duplicate command provider UnitName: %s", tostring(providerName)))
			end
			incomingProviderNames[providerName] = true
		end
		if providerId or providerName then
			local valid, reason = self._unitIndex:validateRegistration({
				UnitId = providerId,
				UnitName = providerName,
				GroupId = c2node.GroupId,
				GroupName = c2node.NodeName,
				OwnerKind = OwnerKind.COMMAND_PROVIDER,
				Owner = providers[i],
			})
			if not valid then
				error(string.format("managed command-provider identity rejected: %s", reason))
			end
		end
	end

	self._byNodeName[c2node.NodeName] = c2node
	for i = 1, #providers do
		local provider = providers[i]
		if provider.UnitId or provider.UnitName then
			self._unitIndex:register({
				UnitId = provider.UnitId,
				UnitName = provider.UnitName,
				GroupId = c2node.GroupId,
				GroupName = c2node.NodeName,
				OwnerKind = OwnerKind.COMMAND_PROVIDER,
				Owner = provider,
			})
		end
	end
	self._count = self._count + 1

	self._logger:debug(string.format("added command center %s (count=%d)", c2node.NodeName, self._count))
end

function Medusa.Services.C2NodeStore:getByNodeName(nodeName)
	return self._byNodeName[nodeName]
end

--- Returns every command center, optionally reusing the supplied array.
function Medusa.Services.C2NodeStore:getAll(outputTable)
	local result = outputTable or {}
	if outputTable then
		for i = #outputTable, 1, -1 do
			outputTable[i] = nil
		end
	end
	for _, c2node in pairs(self._byNodeName) do
		result[#result + 1] = c2node
	end
	return result
end

--- Marks one already-resolved command provider unavailable.
function Medusa.Services.C2NodeStore:setProviderUnavailable(provider)
	if not provider or not provider.Available then
		return nil
	end
	provider.Available = false
	return provider
end

--- Restores one mission-selected provider and moves its unit-identifier index to unitId.
function Medusa.Services.C2NodeStore:markProviderAvailable(provider, unitId)
	if not provider or not unitId then
		return false
	end
	local previousOwner = self._unitIndex:getRegisteredOwner(unitId, OwnerKind.COMMAND_PROVIDER)
	local previousOwnerUnitId = previousOwner and previousOwner.UnitId or nil
	if previousOwner and previousOwner ~= provider then
		local released = self._unitIndex:replaceUnitId(OwnerKind.COMMAND_PROVIDER, previousOwner, nil)
		if not released then
			return false
		end
	end
	local rebound = self._unitIndex:replaceUnitId(OwnerKind.COMMAND_PROVIDER, provider, unitId)
	if not rebound then
		if previousOwner and previousOwner ~= provider then
			self._unitIndex:replaceUnitId(OwnerKind.COMMAND_PROVIDER, previousOwner, previousOwnerUnitId)
		end
		return false
	end
	if previousOwner and previousOwner ~= provider then
		previousOwner.Available = false
	end
	provider.UnitId = unitId
	provider.Available = true
	return true
end

function Medusa.Services.C2NodeStore:count()
	return self._count
end
