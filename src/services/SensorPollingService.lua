require("_header")
require("services.Services")
require("services.BlackBoxService")
require("core.Constants")
require("core.Logger")

--[[
            ███████╗███████╗███╗   ██╗███████╗ ██████╗ ██████╗     ██████╗  ██████╗ ██╗     ██╗     ██╗███╗   ██╗ ██████╗
            ██╔════╝██╔════╝████╗  ██║██╔════╝██╔═══██╗██╔══██╗    ██╔══██╗██╔═══██╗██║     ██║     ██║████╗  ██║██╔════╝
            ███████╗█████╗  ██╔██╗ ██║███████╗██║   ██║██████╔╝    ██████╔╝██║   ██║██║     ██║     ██║██╔██╗ ██║██║  ███╗
            ╚════██║██╔══╝  ██║╚██╗██║╚════██║██║   ██║██╔══██╗    ██╔═══╝ ██║   ██║██║     ██║     ██║██║╚██╗██║██║   ██║
            ███████║███████╗██║ ╚████║███████║╚██████╔╝██║  ██║    ██║     ╚██████╔╝███████╗███████╗██║██║ ╚████║╚██████╔╝
            ╚══════╝╚══════╝╚═╝  ╚═══╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝    ╚═╝      ╚═════╝ ╚══════╝╚══════╝╚═╝╚═╝  ╚═══╝ ╚═════╝

    What this service does
    - Calls the DCS detection API on each sensor to get current contacts.
    - Converts raw detections into track reports with position, velocity, and coalition data.
    - Rate-limits per-track scans and cleans up stale scan entries based on doctrine settings.

    How others use it
    - IadsNetwork calls pollSensor in a round-robin budget each tick to feed reports into TrackManager.
--]]

Medusa.Services.SensorPollingService = {}

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isFiniteVec3(value)
	return type(value) == "table" and isFinite(value.x) and isFinite(value.y) and isFinite(value.z)
end

local function readField(value, key)
	return value[key]
end

local function callMethod(value, key)
	local ok, method = pcall(readField, value, key)
	if not ok or type(method) ~= "function" then
		return false, nil
	end
	return pcall(method, value)
end

function Medusa.Services.SensorPollingService:new(doctrine)
	local o = {
		_logger = Medusa.Logger:ns("SensorPollingService"),
		_lastScanned = {},
		_lastScannedOrder = RingBuffer(Medusa.Constants.C2.SENSOR_SCAN_CACHE_CAPACITY, true),
		_lastCleanup = 0,
		_doctrine = doctrine,
	}
	setmetatable(o, { __index = self })
	return o
end

--- Translates one DCS target entry into a partition-keyed Medusa sensor report or nil.
function Medusa.Services.SensorPollingService:_buildReport(entry, now, sourceType, partitionKey)
	if type(entry) ~= "table" then
		return nil
	end
	local obj = entry.object
	local objectType = type(obj)
	if objectType ~= "table" and objectType ~= "userdata" then
		return nil
	end

	local okId, networkId = pcall(readField, obj, "id_")
	if not okId or not networkId then
		return nil
	end

	local scanKey = partitionKey and (tostring(networkId) .. "\001" .. tostring(partitionKey)) or networkId
	if self._lastScanned[scanKey] and (now - self._lastScanned[scanKey]) < self._doctrine.PerTrackScanUpdateRate then
		return nil
	end

	local okCat, cat = callMethod(obj, "getCategory")
	if not okCat or (cat ~= Object.Category.UNIT and cat ~= Object.Category.WEAPON) then
		return nil
	end

	local okPos, pos = callMethod(obj, "getPoint")
	if not okPos or not isFiniteVec3(pos) then
		return nil
	end

	local okVel, vel = callMethod(obj, "getVelocity")
	if not okVel or not isFiniteVec3(vel) then
		return nil
	end

	pcall(Medusa.Services.BlackBoxService.cacheFromObject, networkId, obj)
	if not self._lastScanned[scanKey] then
		local _, evicted = self._lastScannedOrder:push(scanKey)
		if evicted then
			self._lastScanned[evicted] = nil
		end
	end
	self._lastScanned[scanKey] = now
	return {
		NetworkId = networkId,
		PartitionKey = partitionKey,
		SourceType = sourceType,
		Position = { x = pos.x, y = pos.y, z = pos.z },
		Velocity = { x = vel.x, y = vel.y, z = vel.z },
	}
end

--- Polls one bounded rotating detection slice and returns reports, inspected count, and next index.
function Medusa.Services.SensorPollingService:pollSensor(groupName, now, sourceType, partitionKey, limit, startIndex)
	sourceType = sourceType or Medusa.Constants.TrackSource.EARLY_WARNING_RADAR
	if now - self._lastCleanup > self._doctrine.SensorCleanupSec then
		local retainedOrder = RingBuffer(Medusa.Constants.C2.SENSOR_SCAN_CACHE_CAPACITY, true)
		local priorOrder = self._lastScannedOrder:toArray()
		for i = 1, #priorOrder do
			local id = priorOrder[i]
			local ts = self._lastScanned[id]
			if now - ts > self._doctrine.SensorCleanupSec then
				self._lastScanned[id] = nil
			else
				retainedOrder:push(id)
			end
		end
		self._lastScannedOrder = retainedOrder
		self._lastCleanup = now
	end

	local controller = GetGroupController(groupName)
	if not controller then
		return nil, 0, startIndex or 1
	end

	local detections = GetControllerDetectedTargets(controller)
	if type(detections) ~= "table" then
		return nil, 0, startIndex or 1
	end
	if #detections == 0 then
		return {}, 0, 1
	end

	limit = math.floor(tonumber(limit) or Medusa.Constants.C2.DETECTION_PROCESSING_BUDGET)
	if limit < 1 then
		return {}, 0, startIndex or 1
	end
	local count = #detections
	local index = math.floor(tonumber(startIndex) or 1)
	index = ((index - 1) % count) + 1
	local inspected = math.min(limit, count)
	local reports = {}
	for _ = 1, inspected do
		local report = self:_buildReport(detections[index], now, sourceType, partitionKey)
		if report then
			reports[#reports + 1] = report
		end
		index = (index % count) + 1
	end

	return reports, inspected, index
end
