require("_header")
require("services.Services")
require("services.BlackBoxService")
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

function Medusa.Services.SensorPollingService:new(doctrine)
	local o = {
		_logger = Medusa.Logger:ns("SensorPollingService"),
		_lastScanned = {},
		_lastCleanup = 0,
		_doctrine = doctrine,
	}
	setmetatable(o, { __index = self })
	return o
end

function Medusa.Services.SensorPollingService:_buildReport(entry, now)
	local obj = entry.object
	if not obj then
		return nil
	end

	local networkId = obj.id_
	if not networkId then
		return nil
	end

	if
		self._lastScanned[networkId]
		and (now - self._lastScanned[networkId]) < self._doctrine.PerTrackScanUpdateRate
	then
		return nil
	end

	local okCat, cat = pcall(obj.getCategory, obj)
	if not okCat or (cat ~= Object.Category.UNIT and cat ~= Object.Category.WEAPON) then
		return nil
	end

	Medusa.Services.BlackBoxService.cacheFromObject(networkId, obj)

	local okPos, pos = pcall(obj.getPoint, obj)
	if not okPos or not pos then
		return nil
	end

	local okVel, vel = pcall(obj.getVelocity, obj)
	if not okVel or not vel then
		return nil
	end

	self._lastScanned[networkId] = now
	return {
		NetworkId = networkId,
		Position = { x = pos.x, y = pos.y, z = pos.z },
		Velocity = { x = vel.x, y = vel.y, z = vel.z },
	}
end

function Medusa.Services.SensorPollingService:pollSensor(groupName, now)
	if now - self._lastCleanup > self._doctrine.SensorCleanupSec then
		for id, ts in pairs(self._lastScanned) do
			if now - ts > self._doctrine.SensorCleanupSec then
				self._lastScanned[id] = nil
			end
		end
		self._lastCleanup = now
	end

	local controller = GetGroupController(groupName)
	if not controller then
		return nil
	end

	local detections = GetControllerDetectedTargets(controller)
	if not detections then
		return {}
	end

	local reports = {}
	for i = 1, #detections do
		local report = self:_buildReport(detections[i], now)
		if report then
			reports[#reports + 1] = report
		end
	end

	return reports
end
