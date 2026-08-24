require("_header")
require("services.Services")
require("core.Constants")

--[[
██╗   ██╗███╗   ██╗██╗████████╗    ██╗███╗   ██╗██████╗ ███████╗██╗  ██╗
██║   ██║████╗  ██║██║╚══██╔══╝    ██║████╗  ██║██╔══██╗██╔════╝╚██╗██╔╝
██║   ██║██╔██╗ ██║██║   ██║       ██║██╔██╗ ██║██║  ██║█████╗   ╚███╔╝
██║   ██║██║╚██╗██║██║   ██║       ██║██║╚██╗██║██║  ██║██╔══╝   ██╔██╗
╚██████╔╝██║ ╚████║██║   ██║       ██║██║ ╚████║██████╔╝███████╗██╔╝ ██╗
 ╚═════╝ ╚═╝  ╚═══╝╚═╝   ╚═╝       ╚═╝╚═╝  ╚═══╝╚═════╝ ╚══════╝╚═╝  ╚═╝

]]

Medusa.Services.UnitIndex = {}

local OwnerKind = Medusa.Constants.UnitOwnerKind
local validOwnerKinds = {
	[OwnerKind.BATTERY_UNIT] = true,
	[OwnerKind.SENSOR] = true,
	[OwnerKind.COMMAND_PROVIDER] = true,
}

local function identitiesConflict(left, right)
	return left ~= nil and right ~= nil and left ~= right
end

local function removeRegisteredId(index, identity, unitId)
	if not unitId then
		return
	end
	local count = identity.RegisteredUnitIds[unitId]
	if not count then
		return
	end
	if count > 1 then
		identity.RegisteredUnitIds[unitId] = count - 1
		return
	end
	identity.RegisteredUnitIds[unitId] = nil
	if identity.EventUnitId ~= unitId and index._byUnitId[unitId] == identity then
		index._byUnitId[unitId] = nil
	end
end

local function addRegisteredId(index, identity, unitId)
	if not unitId then
		return
	end
	identity.RegisteredUnitIds[unitId] = (identity.RegisteredUnitIds[unitId] or 0) + 1
	index._byUnitId[unitId] = identity
end

--- Creates one per-IADS index for managed DCS unit identity and Medusa owner projections.
function Medusa.Services.UnitIndex:new()
	local o = {
		_byUnitId = {},
		_byUnitName = {},
		_byOwner = {},
	}
	setmetatable(o, { __index = self })
	return o
end

--- Validates that data can attach one owner without conflicting with a current physical unit identity.
function Medusa.Services.UnitIndex:validateRegistration(data)
	if not data or not validOwnerKinds[data.OwnerKind] then
		return false, "invalid owner kind"
	end
	if type(data.Owner) ~= "table" then
		return false, "owner table is required"
	end
	if data.UnitId == nil and data.UnitName == nil then
		return false, "unit ID or unit name is required"
	end

	local byId = data.UnitId and self._byUnitId[data.UnitId] or nil
	local byName = data.UnitName and self._byUnitName[data.UnitName] or nil
	if byId and byName and byId ~= byName then
		return false, "unit ID and unit name have different owners"
	end
	local identity = byId or byName
	if identity then
		if identitiesConflict(identity.UnitName, data.UnitName) then
			return false, "unit name conflicts with current identity"
		end
		if
			identitiesConflict(identity.GroupId, data.GroupId)
			and (identity.GroupName == nil or data.GroupName == nil or identity.GroupName ~= data.GroupName)
		then
			return false, "group ID conflicts with current identity"
		end
		if identitiesConflict(identity.GroupName, data.GroupName) then
			return false, "group name conflicts with current identity"
		end
		local currentOwner = identity.Owners[data.OwnerKind]
		if currentOwner and currentOwner ~= data.Owner then
			return false, "owner kind already belongs to current identity"
		end
	end

	local ownerRegistration = self._byOwner[data.Owner]
	if ownerRegistration and (ownerRegistration.Identity ~= identity or ownerRegistration.Kind ~= data.OwnerKind) then
		return false, "owner already belongs to another identity"
	end
	return true
end

--- Attaches one Medusa owner to a validated physical unit identity.
function Medusa.Services.UnitIndex:register(data)
	local valid, reason = self:validateRegistration(data)
	if not valid then
		error("managed unit registration failed: " .. reason)
	end

	local identity = (data.UnitId and self._byUnitId[data.UnitId])
		or (data.UnitName and self._byUnitName[data.UnitName])
	if not identity then
		identity = {
			UnitName = data.UnitName,
			GroupId = data.GroupId,
			GroupName = data.GroupName,
			RegisteredUnitIds = {},
			Owners = {},
		}
	elseif self._byOwner[data.Owner] then
		return identity
	end

	if not identity.UnitName and data.UnitName then
		identity.UnitName = data.UnitName
	end
	if data.GroupId then
		identity.GroupId = data.GroupId
	end
	if not identity.GroupName and data.GroupName then
		identity.GroupName = data.GroupName
	end
	if identity.UnitName then
		self._byUnitName[identity.UnitName] = identity
	end
	identity.Owners[data.OwnerKind] = data.Owner
	self._byOwner[data.Owner] = {
		Identity = identity,
		Kind = data.OwnerKind,
		UnitId = data.UnitId,
	}
	addRegisteredId(self, identity, data.UnitId)
	return identity
end

--- Resolves a current unit ID or one exact-name event alias without accepting conflicting identity data.
function Medusa.Services.UnitIndex:resolve(unitId, unitName)
	local byId = unitId and self._byUnitId[unitId] or nil
	if byId then
		if identitiesConflict(byId.UnitName, unitName) then
			return nil, "identity-conflict"
		end
		if byId.RegisteredUnitIds[unitId] then
			return byId, "unit-id"
		end
		return byId, "cached-unit-id"
	end

	local byName = unitName and self._byUnitName[unitName] or nil
	if not byName then
		return nil, "not-found"
	end
	if unitId then
		local previousAlias = byName.EventUnitId
		if
			previousAlias
			and not byName.RegisteredUnitIds[previousAlias]
			and self._byUnitId[previousAlias] == byName
		then
			self._byUnitId[previousAlias] = nil
		end
		byName.EventUnitId = unitId
		self._byUnitId[unitId] = byName
	end
	return byName, "unit-name"
end

--- Returns the Medusa projection of ownerKind attached to identity.
function Medusa.Services.UnitIndex:getOwner(identity, ownerKind)
	return identity and identity.Owners[ownerKind] or nil
end

--- Returns ownerKind only when that owner registered unitId rather than inheriting it from another role or alias.
function Medusa.Services.UnitIndex:getRegisteredOwner(unitId, ownerKind)
	local identity = unitId and self._byUnitId[unitId] or nil
	local owner = self:getOwner(identity, ownerKind)
	local registration = owner and self._byOwner[owner] or nil
	if registration and registration.UnitId == unitId then
		return owner
	end
	return nil
end

--- Removes one owner and retires the physical identity after its final projection leaves.
function Medusa.Services.UnitIndex:unregister(ownerKind, owner)
	local registration = self._byOwner[owner]
	if not registration or registration.Kind ~= ownerKind then
		return false
	end
	local identity = registration.Identity
	self._byOwner[owner] = nil
	identity.Owners[ownerKind] = nil
	removeRegisteredId(self, identity, registration.UnitId)

	if next(identity.Owners) ~= nil then
		return true
	end
	if identity.UnitName and self._byUnitName[identity.UnitName] == identity then
		self._byUnitName[identity.UnitName] = nil
	end
	if identity.EventUnitId and self._byUnitId[identity.EventUnitId] == identity then
		self._byUnitId[identity.EventUnitId] = nil
	end
	for registeredId in pairs(identity.RegisteredUnitIds) do
		if self._byUnitId[registeredId] == identity then
			self._byUnitId[registeredId] = nil
		end
	end
	return true
end

--- Moves one owner's registered DCS unit identifier without changing its physical identity or other roles.
function Medusa.Services.UnitIndex:replaceUnitId(ownerKind, owner, unitId)
	local registration = self._byOwner[owner]
	if not registration or registration.Kind ~= ownerKind then
		return false, "owner is not registered"
	end
	local identity = registration.Identity
	local currentIdentity = unitId and self._byUnitId[unitId] or nil
	if currentIdentity and currentIdentity ~= identity then
		return false, "unit ID belongs to another identity"
	end
	if registration.UnitId == unitId then
		return true
	end
	removeRegisteredId(self, identity, registration.UnitId)
	registration.UnitId = unitId
	addRegisteredId(self, identity, unitId)
	return true
end
