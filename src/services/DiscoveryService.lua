require("_header")
require("services.Services")
require("core.Config")
require("services.GroupNameParser")
require("core.Constants")
require("core.Logger")

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
---@field _birthSubId number|nil
---@field new fun(self: Medusa.Services.DiscoveryService, provider?: table, opts?: table): Medusa.Services.DiscoveryService
---@field setListener fun(self: Medusa.Services.DiscoveryService, listener: table)
---@field attachToHierarchy fun(self: Medusa.Services.DiscoveryService, hierarchy: Medusa.Services.HierarchyService): function
---@field scanOnce fun(self: Medusa.Services.DiscoveryService): number
---@field enableDynamicAdds fun(self: Medusa.Services.DiscoveryService): boolean
---@field processDynamicAdds fun(self: Medusa.Services.DiscoveryService, maxPerTick?: number): number
Medusa.Services.DiscoveryService = {}

function Medusa.Services.DiscoveryService:new(provider, opts)
	local o = {
		_provider = provider,
		_listener = nil,
		_knownById = {},
		_logger = Medusa.Logger:ns(
			string.format(
				"%sServices.Discovery",
				(opts and opts.id) and string.format("%s | ", tostring(opts.id)) or ""
			)
		),
		_coalitionId = opts and opts.coalitionId or nil,
		_prefix = opts and opts.prefix or nil,
		_birthQueue = nil,
		_birthSubId = nil,
	}
	setmetatable(o, { __index = self })
	return o
end

function Medusa.Services.DiscoveryService:setListener(listener)
	self._listener = listener
end

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

function Medusa.Services.DiscoveryService:_defaultProviderList(coalitionId, knownById)
	local results = {}
	local coalitionNum = coalitionId or 0

	local groups = GetCoalitionGroups(coalitionNum, nil)
	if not groups or type(groups) ~= "table" then
		return results
	end
	for _, g in ipairs(groups) do
		local name = GetGroupName(g)
		if name then
			local id = GetGroupID(name)
			if id and not knownById[id] then
				local category = GetGroupCategoryEx(g)
				results[#results + 1] = {
					groupId = id,
					groupName = name,
					coalitionId = coalitionNum,
					category = category or "",
				}
			end
		end
	end
	return results
end

function Medusa.Services.DiscoveryService:scanOnce()
	local coalitionId = self._coalitionId
	local prefix = self._prefix

	local list = (self._provider and self._provider.list)
		or function(arg)
			return self:_defaultProviderList(arg, self._knownById)
		end
	local infos = list(coalitionId)
	local added = 0

	for _, info in ipairs(infos) do
		if not self._knownById[info.groupId] then
			local parsed = Medusa.Services.GroupNameParser:parse(info.groupName, prefix)
			if parsed and parsed.isManaged then
				local dto = self:_buildDto(info, parsed)
				self._knownById[info.groupId] = dto
				added = added + 1
				if self._listener and self._listener.onAdded then
					self._listener.onAdded(dto)
				end
			end
		end
	end
	return added
end

--- Enable dynamic discovery via HarnessWorldEventBus birth events
function Medusa.Services.DiscoveryService:enableDynamicAdds()
	if self._birthQueue then
		return true
	end
	-- Use a dedicated queue per event type
	self._birthQueue = Queue()
	local topic = world and world.event and world.event.S_EVENT_BIRTH or nil
	if not topic then
		self._logger:error("world.event.S_EVENT_BIRTH not found; dynamic adds disabled")
		return false
	end
	local prefix = self._prefix or ""
	local prefixDot = prefix .. "."

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
		if type(prefix) == "string" and #prefix > 0 then
			if not StringStartsWith(groupName, prefixDot) then
				self._logger:trace(
					string.format("groupName: %s does not start with IADS prefix: %s", groupName, prefix)
				)
				return false
			end
		end
		local gCoalId = GetGroupCoalition(groupName)
		if gCoalId == nil then
			self._logger:debug(string.format("no coalition found for groupName: %s", groupName))
			return false
		end
		if gCoalId ~= self._coalitionId then
			self._logger:trace(
				string.format(
					"group coalition: %s not equal to IADS coalition: %s",
					tostring(gCoalId),
					tostring(self._coalitionId)
				)
			)
			return false
		end
		return true
	end

	local bus = HarnessWorldEventBus or InitHarnessWorldEventBus()
	if not bus or type(bus.sub) ~= "function" then
		self._logger:error("event bus unavailable; dynamic adds disabled")
		return false
	end
	local subId = bus:sub(topic, self._birthQueue, predicate)
	if not subId then
		return false
	end
	self._birthSubId = subId
	self._logger:info("dynamic adds enabled (birth subscription active)")
	return true
end

function Medusa.Services.DiscoveryService:_processDiscoveredGroup(groupName, group, prefix)
	local id = GetGroupID(groupName)
	if not id or self._knownById[id] then
		return
	end
	local parsed = Medusa.Services.GroupNameParser:parse(groupName, prefix)
	if not parsed or not parsed.isManaged then
		return
	end
	local category = GetGroupCategoryEx(group) or ""
	local info = { groupId = id, groupName = groupName, coalitionId = self._coalitionId, category = category }
	local dto = self:_buildDto(info, parsed)
	self._knownById[id] = dto
	if self._listener and self._listener.onAdded then
		self._logger:trace(string.format("adding dto for group: %s", groupName))
		self._listener.onAdded(dto)
	end
end

--- Process a limited number of pending dynamic add events per tick
---@param maxPerTick number|nil
function Medusa.Services.DiscoveryService:processDynamicAdds(maxPerTick)
	local q = self._birthQueue
	if not q or not q.dequeue then
		return 0
	end
	local processed = 0
	local limit = (type(maxPerTick) == "number" and maxPerTick > 0) and maxPerTick or 4
	local prefix = self._prefix or ""
	while (not q:isEmpty()) and processed < limit do
		local event = q:dequeue()
		processed = processed + 1
		self._logger:trace(string.format("processing event: %s", tostring(event)))
		local initiator = event and event.initiator
		if not initiator or not initiator.getName then
			-- noop
		else
			local ok, unitName = pcall(initiator.getName, initiator)
			if ok and unitName then
				local group = GetUnitGroup(unitName)
				local groupName = group and GetGroupName(group) or nil
				if groupName then
					self:_processDiscoveredGroup(groupName, group, prefix)
				end
			end
		end
	end
	if processed > 0 then
		self._logger:debug(string.format("processed: %d of %d events, remaining: %d", processed, limit, q:size()))
	end
	return processed
end
