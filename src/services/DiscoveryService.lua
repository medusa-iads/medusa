require("_header")
require("services.Services")
require("core.Config")
require("services.GroupNameParser")
require("core.Constants")
require("core.Logger")
require("observability.MetricsService")

--[[
            ██████╗ ██╗███████╗ ██████╗ ██████╗ ██╗   ██╗███████╗██████╗ ██╗   ██╗    ███████╗███████╗██████╗ ██╗   ██╗██╗ ██████╗███████╗
            ██╔══██╗██║██╔════╝██╔════╝██╔═══██╗██║   ██║██╔════╝██╔══██╗╚██╗ ██╔╝    ██╔════╝██╔════╝██╔══██╗██║   ██║██║██╔════╝██╔════╝
            ██║  ██║██║███████╗██║     ██║   ██║██║   ██║█████╗  ██████╔╝ ╚████╔╝     ███████╗█████╗  ██████╔╝██║   ██║██║██║     █████╗
            ██║  ██║██║╚════██║██║     ██║   ██║╚██╗ ██╔╝██╔══╝  ██╔══██╗  ╚██╔╝      ╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██║██║     ██╔══╝
            ██████╔╝██║███████║╚██████╗╚██████╔╝ ╚████╔╝ ███████╗██║  ██║   ██║       ███████║███████╗██║  ██║ ╚████╔╝ ██║╚██████╗███████╗
            ╚═════╝ ╚═╝╚══════╝ ╚═════╝ ╚═════╝   ╚═══╝  ╚══════╝╚═╝  ╚═╝   ╚═╝       ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚═╝ ╚═════╝╚══════╝

    What this service does
    - Scans the mission for coalition groups that match the managed prefix.
    - Parses group names to extract roles, hierarchy paths, and sensor types.
    - Notifies listeners with structured DTOs and supports dynamic adds via birth events.

    How others use it
    - IadsNetwork attaches a listener that feeds discovered groups into EntityFactory and the hierarchy.
    - HierarchyService can also attach directly to receive discovery events for building the command tree.
]]

---@class Medusa.Services.DiscoveryServiceDTO
---@field groupId number
---@field groupName string
---@field coalitionId number
---@field category string
---@field parsed { isManaged: boolean, unitLabel: string|nil, roles: string[], isHQ: boolean, sensorType: string|nil, echelonPath: string[] }
Medusa.Services.DiscoveryServiceDTO = {}

---@class Medusa.Services.DiscoveryService
---@field _provider table|nil
---@field _listener table|nil
---@field _knownById table<number, Medusa.Services.DiscoveryServiceDTO>
---@field _logger table
---@field _coalitionId number|nil
---@field _prefix string|nil
---@field _birthQueue table|nil
---@field _birthEventBus table|nil
---@field _birthSubscriptionId number|nil
---@field new fun(self: Medusa.Services.DiscoveryService, provider?: table, opts?: table): Medusa.Services.DiscoveryService
---@field setListener fun(self: Medusa.Services.DiscoveryService, listener: table)
---@field attachToHierarchy fun(self: Medusa.Services.DiscoveryService, hierarchy: Medusa.Services.HierarchyService): function
---@field scanOnce fun(self: Medusa.Services.DiscoveryService): number
---@field enableDynamicAdds fun(self: Medusa.Services.DiscoveryService): boolean
---@field disableDynamicAdds fun(self: Medusa.Services.DiscoveryService): boolean
---@field processDynamicAdds fun(self: Medusa.Services.DiscoveryService, maxPerTick?: number): number
Medusa.Services.DiscoveryService = {}

--- Creates a discovery boundary for one coalition and managed group-name prefix.
function Medusa.Services.DiscoveryService:new(provider, opts)
	local o = {
		_provider = provider,
		_listener = nil,
		_knownById = {},
		_knownIdByName = {},
		_logger = Medusa.Logger:ns(string.format("%sServices.Discovery", (opts and opts.id) and string.format("%s | ", tostring(opts.id)) or "")),
		_coalitionId = opts and opts.coalitionId or nil,
		_prefix = opts and opts.prefix or nil,
		_birthMetricLabels = { network = opts and opts.id or nil, event = "BIRTH" },
		_birthQueue = nil,
		_birthOverflowQueue = nil,
		_birthEventBus = nil,
		_birthSubscriptionId = nil,
		_birthPending = {},
	}
	setmetatable(o, { __index = self })
	return o
end

--- Retires one cached group identity and reports whether it existed.
local function forgetKnown(service, groupId)
	local known = service._knownById[groupId]
	if not known then
		return false
	end
	service._knownById[groupId] = nil
	if service._knownIdByName[known.groupName] == groupId then
		service._knownIdByName[known.groupName] = nil
	end
	return true
end

--- Makes one DTO the active identity for both its group identifier and name.
local function rememberKnown(service, dto)
	local previousId = service._knownIdByName[dto.groupName]
	if previousId and previousId ~= dto.groupId then
		forgetKnown(service, previousId)
	end
	forgetKnown(service, dto.groupId)
	service._knownById[dto.groupId] = dto
	service._knownIdByName[dto.groupName] = dto.groupId
end

--- Reconciles one scalar group identity and reports whether it became newly managed.
local function reconcileGroupInfo(service, info, prefix)
	local known = service._knownById[info.groupId]
	if known and known.groupName == info.groupName then
		if service._listener and service._listener.onRediscovered then
			service._listener.onRediscovered(known)
		end
		return false
	end
	if known then
		forgetKnown(service, info.groupId)
	end
	local parsed = Medusa.Services.GroupNameParser:parse(info.groupName, prefix)
	if not parsed or not parsed.isManaged then
		return false
	end
	local dto = service:_buildDto(info, parsed)
	if service._listener and service._listener.onAdded then
		local ok, admitted = pcall(service._listener.onAdded, dto)
		if not ok or admitted == false then
			service._logger:error(string.format("managed group admission failed: %s", tostring(admitted)))
			return false
		end
	end
	rememberKnown(service, dto)
	return true
end

--- Retires one discovery identity after its managed group leaves runtime ownership.
function Medusa.Services.DiscoveryService:forget(groupId)
	return forgetKnown(self, groupId)
end

--- Replaces the listener that receives new and rediscovered managed group DTOs.
function Medusa.Services.DiscoveryService:setListener(listener)
	self._listener = listener
end

--- Routes newly discovered groups into hierarchy and returns a listener-restoration function.
function Medusa.Services.DiscoveryService:attachToHierarchy(hierarchy)
	local prev = self._listener
	self._listener = {
		onAdded = function(dto)
			hierarchy:upsertGroup(dto)
			local roles = (dto.parsed and dto.parsed.roles) and table.concat(dto.parsed.roles, ",") or ""
			local path = (dto.parsed and dto.parsed.echelonPath) and table.concat(dto.parsed.echelonPath, ".") or ""
			self._logger:info(string.format("added: '%s' roles=[%s] path='%s'", tostring(dto.groupName), roles, path))
		end,
	}
	return function()
		self._listener = prev
	end
end

---@param info table
---@param parsed table
---@return Medusa.Services.DiscoveryServiceDTO
function Medusa.Services.DiscoveryService:_buildDto(info, parsed)
	return {
		groupId = info.groupId,
		groupName = info.groupName,
		coalitionId = info.coalitionId,
		category = info.category,
		parsed = parsed,
	}
end

--- Returns the current DCS coalition group snapshot without traversing it.
function Medusa.Services.DiscoveryService:_defaultProviderList(coalitionId)
	return GetCoalitionGroups(coalitionId or 0, nil)
end

--- Converts one provider record or DCS group handle into discovery scalar data.
function Medusa.Services.DiscoveryService:_groupInfo(value)
	if type(value) == "table" and value.groupId and value.groupName then
		return value
	end
	local groupName = GetGroupName(value)
	local groupId = groupName and GetGroupID(groupName) or nil
	if not groupId then
		return nil
	end
	return {
		groupId = groupId,
		groupName = groupName,
		coalitionId = self._coalitionId,
		category = GetGroupCategoryEx(value) or "",
	}
end

--- Returns one provider-owned coalition snapshot or nil when the boundary fails.
function Medusa.Services.DiscoveryService:_listGroups()
	local list = (self._provider and self._provider.list) or function(arg)
		return self:_defaultProviderList(arg)
	end
	local ok, groups = pcall(list, self._coalitionId)
	if not ok or type(groups) ~= "table" then
		self._logger:error(string.format("discovery snapshot failed: %s", tostring(groups)))
		return nil
	end
	return groups
end

--- Scans current groups and returns the new-group count plus the snapshot-success flag.
function Medusa.Services.DiscoveryService:scanOnce()
	local prefix = self._prefix
	local groups = self:_listGroups()
	if not groups then
		return 0, false
	end
	local added = 0
	local seen = {}

	for _, group in ipairs(groups) do
		local info = self:_groupInfo(group)
		if info then
			seen[info.groupId] = true
			if reconcileGroupInfo(self, info, prefix) then
				added = added + 1
			end
		end
	end
	for groupId in pairs(self._knownById) do
		if not seen[groupId] then
			forgetKnown(self, groupId)
		end
	end
	return added, true
end

--- Subscribes one bounded, group-coalesced queue to DCS birth events and reports registration success.
function Medusa.Services.DiscoveryService:enableDynamicAdds()
	if self._birthQueue then
		return true
	end
	local topic = world and world.event and world.event.S_EVENT_BIRTH or nil
	if not topic then
		self._logger:error("world.event.S_EVENT_BIRTH not found; dynamic adds disabled")
		return false
	end
	local service = self
	local queue = RingBuffer(Medusa.Constants.WorldEventQueue.BIRTH_CAPACITY, false)
	local overflowQueue = RingBuffer(Medusa.Constants.WorldEventQueue.BIRTH_OVERFLOW_CAPACITY, false)
	--- Coalesces one managed group birth into the bounded queue and reports admission success.
	function queue:enqueue(event)
		local groupName = event and event._groupName
		if not groupName then
			return false
		end
		if service._birthPending[groupName] then
			return true
		end
		local record = { GroupName = groupName }
		local accepted = self:push(record)
		if not accepted then
			accepted = overflowQueue:push(record)
		end
		if accepted then
			service._birthPending[groupName] = true
		else
			Medusa.Observability.MetricsService.inc("medusa_world_events_dropped_total", nil, service._birthMetricLabels)
		end
		return accepted
	end
	local prefix = self._prefix or ""

	-- Predicate filters only events for our coalition and managed prefix
	local function predicate(event)
		if not event or event.id ~= topic then
			self._logger:trace(string.format("event_id %s not equal to %s.", tostring(event.id), tostring(topic)))
			return false
		end
		local initiator = event.initiator
		if not initiator or type(initiator.getName) ~= "function" then
			self._logger:trace("initiator or initiator.getName not found")
			return false
		end
		local ok, unitName = pcall(initiator.getName, initiator)
		if not ok or not unitName then
			self._logger:trace(string.format("unitName not found for initiator: %s", tostring(initiator)))
			return false
		end
		local group = GetUnitGroup(unitName)
		if not group then
			self._logger:debug(string.format("group not found for unitName: %s", tostring(unitName)))
			return false
		end
		local groupName = GetGroupName(group)
		if not groupName then
			self._logger:debug(string.format("groupName not found for group: %s", tostring(group)))
			return false
		end
		local parsed = Medusa.Services.GroupNameParser:parse(groupName, prefix)
		if not parsed.isManaged then
			self._logger:trace(string.format("groupName: %s does not match IADS prefix: %s", groupName, prefix))
			return false
		end
		local gCoalId = GetGroupCoalition(groupName)
		if gCoalId == nil then
			self._logger:debug(string.format("no coalition found for groupName: %s", groupName))
			return false
		end
		if gCoalId ~= self._coalitionId then
			self._logger:trace(string.format("group coalition: %s not equal to IADS coalition: %s", tostring(gCoalId), tostring(self._coalitionId)))
			return false
		end
		event._groupName = groupName
		return true
	end

	local bus = HarnessWorldEventBus or InitHarnessWorldEventBus()
	if not bus or type(bus.sub) ~= "function" then
		self._logger:error("event bus unavailable; dynamic adds disabled")
		return false
	end
	-- Harness 1.0.1 exposes this ID as the only way to roll back a partial registration.
	local expectedId = type(bus._nextSubId) == "number" and bus._nextSubId or nil
	local ok, subId = pcall(bus.sub, bus, topic, queue, predicate)
	if not ok or not subId then
		if expectedId then
			pcall(bus.unsub, bus, expectedId)
		end
		self._logger:error(string.format("dynamic-add subscription failed: %s", tostring(subId)))
		return false
	end
	self._birthQueue = queue
	self._birthOverflowQueue = overflowQueue
	self._birthEventBus = bus
	self._birthSubscriptionId = subId
	self._logger:info("dynamic adds enabled (birth subscription active)")
	return true
end

--- Removes the dynamic-birth subscription and clears its bounded pending work.
function Medusa.Services.DiscoveryService:disableDynamicAdds()
	if self._birthSubscriptionId and self._birthEventBus then
		pcall(self._birthEventBus.unsub, self._birthEventBus, self._birthSubscriptionId)
	end
	self._birthSubscriptionId = nil
	self._birthEventBus = nil
	if self._birthQueue then
		self._birthQueue:clear()
	end
	if self._birthOverflowQueue then
		self._birthOverflowQueue:clear()
	end
	self._birthQueue = nil
	self._birthOverflowQueue = nil
	self._birthPending = {}
	return true
end

--- Reports a live managed group as new or same-ID rediscovered state.
function Medusa.Services.DiscoveryService:_processDiscoveredGroup(groupName, group, prefix)
	local id = GetGroupID(groupName)
	if not id then
		return
	end
	local category = GetGroupCategoryEx(group) or ""
	local info = { groupId = id, groupName = groupName, coalitionId = self._coalitionId, category = category }
	if reconcileGroupInfo(self, info, prefix) then
		self._logger:trace(string.format("adding dto for group: %s", groupName))
	end
end

--- Processes at most maxPerTick queued birth records and returns the number consumed.
---@param maxPerTick number|nil
function Medusa.Services.DiscoveryService:processDynamicAdds(maxPerTick)
	local q = self._birthQueue
	local overflowQueue = self._birthOverflowQueue
	if not q then
		return 0
	end
	local processed = 0
	local limit = (type(maxPerTick) == "number" and maxPerTick > 0) and maxPerTick or 4
	local prefix = self._prefix or ""
	while processed < limit and (not q:isEmpty() or (overflowQueue and not overflowQueue:isEmpty())) do
		local event = not q:isEmpty() and q:pop() or overflowQueue:pop()
		processed = processed + 1
		self._logger:trace(string.format("processing event: %s", tostring(event)))
		local groupName = event and event.GroupName
		if groupName then
			self._birthPending[groupName] = nil
			local group = GetGroup(groupName)
			if group then
				self:_processDiscoveredGroup(groupName, group, prefix)
			end
		end
	end
	if processed > 0 then
		self._logger:debug(string.format("processed: %d of %d events, remaining: %d", processed, limit, q:size()))
	end
	return processed
end

--- Returns the current bounded birth-queue depth for network metrics.
function Medusa.Services.DiscoveryService:pendingDynamicAdds()
	local primary = self._birthQueue and self._birthQueue:size() or 0
	local overflow = self._birthOverflowQueue and self._birthOverflowQueue:size() or 0
	return primary + overflow
end
