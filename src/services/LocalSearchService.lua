require("_header")
require("services.Services")
require("core.Constants")
require("services.MetricsService")

--[[
    LOCAL SEARCH SERVICE

    What this service does
    - Searches DCS for hostile aircraft near eligible ground groups.
    - Enforces the shared scan budget and caches short-lived aircraft snapshots.

    How others use it
    - MANPAD and AAA services request nearby aircraft without depending on IADS tracks.
--]]

Medusa.Services.LocalSearchService = {}

local AIR_UNIT_CATEGORIES = {
	[Unit.Category.AIRPLANE] = true,
	[Unit.Category.HELICOPTER] = true,
}

local function clear(values)
	for key in pairs(values) do
		values[key] = nil
	end
end

local function getUnitName(unit)
	local ok, name = pcall(unit.getName, unit)
	if ok and type(name) == "string" and name ~= "" then
		return name
	end
	return nil
end

function Medusa.Services.LocalSearchService:new(options)
	local o = {
		coalitionId = options.coalitionId,
		searchRadiusM = options.searchRadiusM,
		quotaPerSec = options.quotaPerSec,
		cacheTtlSec = options.cacheTtlSec,
		cacheCapacity = options.cacheCapacity,
		metrics = options.metrics,
		queue = nil,
		queuedIds = nil,
		liveById = {},
		cacheByBatteryId = {},
		tokens = nil,
		tokenTime = nil,
	}
	setmetatable(o, { __index = self })
	return o
end

function Medusa.Services.LocalSearchService:setSearchRadius(rangeM)
	self.searchRadiusM = rangeM
end

function Medusa.Services.LocalSearchService:isHostileAircraft(unit)
	if not IsUnitActive(unit) then
		return false
	end
	local coalitionId = GetUnitCoalition(unit)
	if coalitionId == 0 or coalitionId == self.coalitionId then
		return false
	end
	return AIR_UNIT_CATEGORIES[GetUnitCategoryEx(unit)] == true
end

function Medusa.Services.LocalSearchService:_syncQueue(batteries)
	clear(self.liveById)
	local topologyChanged = not self.queue or not self.queuedIds or self.queue:size() ~= #batteries
	for i = 1, #batteries do
		local battery = batteries[i]
		self.liveById[battery.BatteryId] = battery
		if not topologyChanged and not self.queuedIds[battery.BatteryId] then
			topologyChanged = true
		end
	end
	if not topologyChanged then
		return
	end

	local replacement = RingBuffer(math.max(1, #batteries), false)
	local replacementIds = {}
	if self.queue then
		local count = self.queue:size()
		for _ = 1, count do
			local batteryId = self.queue:pop()
			if self.liveById[batteryId] and not replacementIds[batteryId] then
				replacement:push(batteryId)
				replacementIds[batteryId] = true
			end
		end
	end
	for i = 1, #batteries do
		local batteryId = batteries[i].BatteryId
		if not replacementIds[batteryId] then
			replacement:push(batteryId)
			replacementIds[batteryId] = true
		end
	end
	for batteryId in pairs(self.cacheByBatteryId) do
		if not self.liveById[batteryId] then
			self.cacheByBatteryId[batteryId] = nil
		end
	end
	self.queue = replacement
	self.queuedIds = replacementIds
end

function Medusa.Services.LocalSearchService:_scan(battery, now)
	local targets = RingBuffer(self.cacheCapacity, false)
	self.cacheByBatteryId[battery.BatteryId] = {
		ExpiresAt = now + self.cacheTtlSec,
		Processed = false,
		Targets = targets,
	}
	local volume = CreateSphereVolume(battery.Position, self.searchRadiusM)
	if not volume then
		return false
	end
	local startedAt = Medusa.hpTimer()
	SearchWorldObjects(Object.Category.UNIT, volume, function(unit)
		if not self:isHostileAircraft(unit) then
			return true
		end
		local unitName = getUnitName(unit)
		local position = GetUnitPosition(unit)
		if not unitName or not position then
			return true
		end
		targets:push({
			UnitName = unitName,
			Position = { x = position.x, y = position.y, z = position.z },
		})
		return not targets:isFull()
	end)
	if self.metrics and self.metrics.scansTotal then
		Medusa.Services.MetricsService.inc(self.metrics.scansTotal)
	end
	if self.metrics and self.metrics.scanDuration then
		Medusa.Services.MetricsService.observe(self.metrics.scanDuration, Medusa.hpTimer() - startedAt)
	end
	return true
end

function Medusa.Services.LocalSearchService:_replenish(now)
	if self.tokenTime == nil or now < self.tokenTime then
		self.tokens = self.quotaPerSec
	else
		self.tokens =
			math.min(self.quotaPerSec, (self.tokens or self.quotaPerSec) + (now - self.tokenTime) * self.quotaPerSec)
	end
	self.tokenTime = now
end

function Medusa.Services.LocalSearchService:refresh(batteries, now, shouldScan)
	self:_syncQueue(batteries)
	if self.metrics and self.metrics.queueDepth then
		Medusa.Services.MetricsService.set(self.metrics.queueDepth, self.queue:size())
	end
	if self.coalitionId == nil or self.queue:isEmpty() then
		return
	end
	self:_replenish(now)
	local remaining = math.floor(self.tokens)
	if remaining == 0 then
		return
	end
	local queueDepth = self.queue:size()
	for _ = 1, queueDepth do
		local batteryId = self.queue:pop()
		local battery = self.liveById[batteryId]
		if battery then
			self.queue:push(batteryId)
			local cache = self.cacheByBatteryId[batteryId]
			if
				battery.Position
				and shouldScan(battery)
				and (not cache or now >= cache.ExpiresAt)
				and self:_scan(battery, now)
			then
				self.tokens = self.tokens - 1
				remaining = remaining - 1
				if remaining == 0 then
					break
				end
			end
		end
	end
end

function Medusa.Services.LocalSearchService:getTargets(batteryId, now)
	local cache = self.cacheByBatteryId[batteryId]
	if not cache or now >= cache.ExpiresAt then
		return nil
	end
	if cache.Processed and self.metrics and self.metrics.cacheReuses then
		Medusa.Services.MetricsService.inc(self.metrics.cacheReuses)
	else
		cache.Processed = true
	end
	return cache.Targets
end

function Medusa.Services.LocalSearchService:resolve(snapshot)
	local unit = GetUnit(snapshot.UnitName)
	if not unit or not self:isHostileAircraft(unit) then
		return nil
	end
	local position = GetUnitPosition(unit)
	if not position then
		return nil
	end
	snapshot.Position.x = position.x
	snapshot.Position.y = position.y
	snapshot.Position.z = position.z
	return unit, snapshot
end
