require("_header")
require("services.Services")
require("observability.MetricsService")
require("services.stores.TrackStore")
require("services.TrackDisplayIdAllocator")
require("entities.Battery")
require("entities.Track")
require("core.Constants")
require("core.Config")
require("core.Logger")

--[[
            ████████╗██████╗  █████╗  ██████╗██╗  ██╗    ███╗   ███╗ █████╗ ███╗   ██╗ █████╗  ██████╗ ███████╗██████╗
            ╚══██╔══╝██╔══██╗██╔══██╗██╔════╝██║ ██╔╝    ████╗ ████║██╔══██╗████╗  ██║██╔══██╗██╔════╝ ██╔════╝██╔══██╗
               ██║   ██████╔╝███████║██║     █████╔╝     ██╔████╔██║███████║██╔██╗ ██║███████║██║  ███╗█████╗  ██████╔╝
               ██║   ██╔══██╗██╔══██║██║     ██╔═██╗     ██║╚██╔╝██║██╔══██║██║╚██╗██║██╔══██║██║   ██║██╔══╝  ██╔══██╗
               ██║   ██║  ██║██║  ██║╚██████╗██║  ██╗    ██║ ╚═╝ ██║██║  ██║██║ ╚████║██║  ██║╚██████╔╝███████╗██║  ██║
               ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝    ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝

    What this service does
    - Creates new tracks from sensor reports and updates existing tracks with fresh position and velocity.
    - Manages track lifecycle: marks tracks as stale after a timeout and expires them after the memory window.
    - Re-associates dormant tracks when a new detection appears near a recently expired one.

    How others use it
    - SensorPollingService feeds track reports into processReport; IadsNetwork calls expireTracks each tick.
    - TrackStore and the GeoGrid are updated automatically as tracks are created, moved, or removed.
--]]

Medusa.Services.TrackManager = {}

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isFiniteVec3(value)
	return type(value) == "table" and isFinite(value.x) and isFinite(value.y) and isFinite(value.z)
end

--- Returns the source identity composed from DCS network ID and partition incarnation.
local function reportKey(report)
	if report.PartitionKey == nil then
		return report.NetworkId
	end
	return tostring(report.NetworkId) .. "\001" .. tostring(report.PartitionKey)
end

--- Releases track assignments from batteryRepository at mission time now and starts each battery hold-down.
local function releaseAssignedBatteries(track, batteryRepository, now)
	local batteryIds = track.AssignedBatteryIds:toArray()
	for i = 1, #batteryIds do
		local battery = batteryRepository and batteryRepository:get(batteryIds[i]) or nil
		if battery and battery.CurrentTargetTrackId == track.TrackId then
			if Medusa.Entities.Battery.releaseTrack(battery, nil, track) then
				battery.LastAssignmentChangeTime = now
			end
		else
			track.AssignedBatteryIds:remove(batteryIds[i])
		end
	end
end

--- Moves valid assignments from absorbed to survivor through the Battery invariant owner.
local function transferAssignedBatteries(absorbed, survivor, batteryRepository, now)
	local batteryIds = absorbed.AssignedBatteryIds:toArray()
	for i = 1, #batteryIds do
		local batteryId = batteryIds[i]
		local battery = batteryRepository and batteryRepository:get(batteryId) or nil
		if battery and battery.CurrentTargetTrackId == absorbed.TrackId then
			Medusa.Entities.Battery.releaseTrack(battery, nil, absorbed)
			Medusa.Entities.Battery.assignTrack(battery, survivor, now, nil)
		else
			absorbed.AssignedBatteryIds:remove(batteryId)
		end
	end
end

--- Creates the track lifecycle owner with source-key, dormant, spatial, and assignment dependencies.
function Medusa.Services.TrackManager:new(opts)
	local o = {
		_store = (opts and opts.store) or Medusa.Services.TrackStore:new(),
		_eventBus = (opts and opts.eventBus) or EventBus(),
		_geoGrid = (opts and opts.geoGrid) or nil,
		_trackIdBySourceKey = {},
		_dormant = {},
		_logger = Medusa.Logger:ns("TrackManager"),
		_pruneBuffer = {},
		_staleBuffer = {},
		_expiredBuffer = {},
		_displayIdAllocator = (opts and opts.displayIdAllocator) or Medusa.Services.TrackDisplayIdAllocator:new(),
		_batteryRepository = opts and opts.batteryRepository or nil,
		_trackMemoryDurationSec = Medusa.Config:getTrackMemoryDurationSec(),
		_smoothedVelocityWindowSec = Medusa.Config:getSmoothedVelocityWindowSec(),
	}
	setmetatable(o, { __index = self })
	return o
end

function Medusa.Services.TrackManager:_releaseDisplayIds(track)
	if track.DisplayTrackId then
		self._displayIdAllocator:release(track.DisplayTrackId)
	end
	local aliases = track.DisplayTrackIdAliases or {}
	for i = 1, #aliases do
		self._displayIdAllocator:release(aliases[i])
	end
end

--- Creates, updates, or reassociates the track identified by a partition-local sensor report.
function Medusa.Services.TrackManager:processReport(report, now)
	if
		not report
		or not report.NetworkId
		or not Medusa.Constants.TrackSourcePrefix[report.SourceType]
		or not isFiniteVec3(report.Position)
		or not isFiniteVec3(report.Velocity)
	then
		self._logger:error("processReport: invalid report (missing required fields)")
		return nil
	end

	now = now or GetTime()
	local sourceKey = reportKey(report)
	local existingTrackId = self._trackIdBySourceKey[sourceKey]

	if existingTrackId then
		return self:_updateExistingTrack(existingTrackId, report, now)
	end

	-- Check dormant cache for re-association
	local dormant = self._dormant[sourceKey]
	if dormant and dormant.Position then
		local dx = report.Position.x - dormant.Position.x
		local dy = report.Position.y - dormant.Position.y
		local dz = report.Position.z - dormant.Position.z
		local lastPositionError = math.sqrt(dx * dx + dy * dy + dz * dz)
		local elapsed = now - dormant.LastDetectionTime
		local predictedX = dormant.Position.x + dormant.Velocity.x * elapsed
		local predictedY = dormant.Position.y + dormant.Velocity.y * elapsed
		local predictedZ = dormant.Position.z + dormant.Velocity.z * elapsed
		dx = report.Position.x - predictedX
		dy = report.Position.y - predictedY
		dz = report.Position.z - predictedZ
		local predictedPositionError = math.sqrt(dx * dx + dy * dy + dz * dz)
		if math.min(lastPositionError, predictedPositionError) < Medusa.Constants.TRACK_REASSOC_MAX_DIST_M then
			self._dormant[sourceKey] = nil
			return self:_reassociateTrack(report, dormant, now)
		end
		self:_releaseDisplayIds(dormant)
		self._logger:debug(
			string.format(
				"dormant re-association failed for network %s: lastError=%.0fm predictedError=%.0fm > %dm",
				tostring(report.NetworkId),
				lastPositionError,
				predictedPositionError,
				Medusa.Constants.TRACK_REASSOC_MAX_DIST_M
			)
		)
		self._dormant[sourceKey] = nil
	end

	return self:_createNewTrack(report, now)
end

--- Publishes one track to every owned index and reports whether capacity allowed admission.
function Medusa.Services.TrackManager:_registerTrack(track, sourceKey, now)
	if not self._store:add(track) then
		return false, "CAPACITY"
	end
	if self._geoGrid and track.Position and self._geoGrid:add("Track", track.TrackId, track.Position) ~= true then
		self._store:remove(track.TrackId)
		return false, "SPATIAL_INDEX"
	end
	self._trackIdBySourceKey[sourceKey] = track.TrackId
	self._eventBus:publish({ id = "TrackCreated", TrackId = track.TrackId, timestamp = now })
	return true, nil
end

--- Creates a new active track from report and returns its stored entity.
function Medusa.Services.TrackManager:_createNewTrack(report, now)
	local displayTrackId = self._displayIdAllocator:allocate(report.SourceType)
	local track = Medusa.Entities.Track.new({
		NetworkId = report.NetworkId,
		PartitionKey = report.PartitionKey,
		DisplayTrackId = displayTrackId,
		OriginSourceType = report.SourceType,
		Position = report.Position,
		Velocity = report.Velocity,
	})
	local registered, failure = self:_registerTrack(track, reportKey(report), now)
	if not registered then
		self._displayIdAllocator:release(displayTrackId)
		if failure == "CAPACITY" then
			self._logger:error(string.format("track capacity exceeded: %d", Medusa.Constants.TRACK_CAPACITY))
		else
			self._logger:error("track spatial admission failed; track ownership rolled back")
		end
		return nil
	end
	Medusa.Observability.MetricsService.inc("medusa_tracks_created_total")
	self._logger:debug(
		string.format(
			"created track %s for network %s",
			Medusa.Entities.Track.displayId(track),
			tostring(report.NetworkId)
		)
	)
	return track
end

--- Restores retained classification and display identity onto a new active track incarnation.
function Medusa.Services.TrackManager:_reassociateTrack(report, dormant, now)
	local restoredAircraftType = dormant.AssessedAircraftType
	if restoredAircraftType == Medusa.Constants.AssessedAircraftType.HARM then
		restoredAircraftType = Medusa.Constants.AssessedAircraftType.UNKNOWN
	end
	local track = Medusa.Entities.Track.new({
		NetworkId = report.NetworkId,
		PartitionKey = report.PartitionKey,
		DisplayTrackId = dormant.DisplayTrackId,
		DisplayTrackIdAliases = dormant.DisplayTrackIdAliases,
		OriginSourceType = dormant.OriginSourceType,
		Position = report.Position,
		Velocity = report.Velocity,
		TrackIdentification = dormant.TrackIdentification,
		AssessedAircraftType = restoredAircraftType,
		LastIdentificationTime = dormant.LastIdentificationTime,
	})
	local sourceKey = reportKey(report)
	local registered, failure = self:_registerTrack(track, sourceKey, now)
	if not registered then
		self._dormant[sourceKey] = dormant
		if failure == "CAPACITY" then
			self._logger:error(string.format("track capacity exceeded: %d", Medusa.Constants.TRACK_CAPACITY))
		else
			self._logger:error("track spatial admission failed; dormant ownership restored")
		end
		return nil
	end
	self._logger:info(
		string.format(
			"re-associated track %s for network %s (was %s/%s)",
			Medusa.Entities.Track.displayId(track),
			tostring(report.NetworkId),
			tostring(dormant.TrackIdentification),
			tostring(dormant.AssessedAircraftType)
		)
	)
	return track
end

--- Updates one live track and republishes its derived motion state.
function Medusa.Services.TrackManager:_updateExistingTrack(trackId, report, now)
	local track = self._store:get(trackId)
	if not track then
		self._trackIdBySourceKey[reportKey(report)] = nil
		return self:_createNewTrack(report, now)
	end

	-- Order matters: update must precede smoothing, smoothing must precede maneuver derivation.
	-- SmoothedVelocity feeds Pk aspect calculation; ManeuverState feeds aircraft type classification.
	Medusa.Entities.Track.update(track, report.Position, report.Velocity, now)
	if self._geoGrid then
		self._geoGrid:updatePosition(track.TrackId, track.Position, "Track")
	end

	local windowSec = self._smoothedVelocityWindowSec
	Medusa.Entities.Track.computeSmoothedVelocity(track, windowSec)
	Medusa.Entities.Track.deriveManeuverState(track)

	self._eventBus:publish({
		id = "TrackUpdated",
		TrackId = track.TrackId,
		Position = track.Position,
		Velocity = track.Velocity,
		timestamp = now,
	})
	return track
end

--- Repoints every source key from one track ID to its survivor or nil.
function Medusa.Services.TrackManager:_remapSourceKeyMappings(fromTrackId, toTrackId)
	for sourceKey, mappedTrackId in pairs(self._trackIdBySourceKey) do
		if mappedTrackId == fromTrackId then
			self._trackIdBySourceKey[sourceKey] = toTrackId
		end
	end
end

--- Marks old tracks stale, expires older tracks, and cleans assignments and dormant history.
function Medusa.Services.TrackManager:pruneStale(now)
	local thresholdSec = self._trackMemoryDurationSec
	local cutoff = now - thresholdSec
	local tracks = self._store:getAll(self._pruneBuffer)

	local staleIds = self._staleBuffer
	for i = #staleIds, 1, -1 do
		staleIds[i] = nil
	end
	local expiredIds = self._expiredBuffer
	for i = #expiredIds, 1, -1 do
		expiredIds[i] = nil
	end
	local LS = Medusa.Constants.TrackLifecycleState

	for i = 1, #tracks do
		local track = tracks[i]
		if track.LastDetectionTime < cutoff then
			if track.LifecycleState == LS.ACTIVE then
				staleIds[#staleIds + 1] = track.TrackId
			elseif track.LifecycleState == LS.STALE then
				expiredIds[#expiredIds + 1] = track.TrackId
			end
		end
	end

	for i = 1, #staleIds do
		local track = self._store:get(staleIds[i])
		if track then
			track.LifecycleState = LS.STALE
			self._eventBus:publish({ id = "TrackBecameStale", TrackId = staleIds[i], timestamp = now })
		end
	end

	for i = 1, #expiredIds do
		local track = self._store:get(expiredIds[i])
		if track then
			releaseAssignedBatteries(track, self._batteryRepository, now)
			local age = now - track.FirstDetectionTime
			Medusa.Observability.MetricsService.observe("medusa_track_age_at_expiry_seconds", age)
			Medusa.Observability.MetricsService.observe("medusa_track_updates_at_expiry", track.UpdateCount or 0)
			Medusa.Observability.MetricsService.inc("medusa_tracks_expired_total")
			-- Save classification state for re-association
			if track.NetworkId then
				local sourceKey = reportKey(track)
				self._dormant[sourceKey] = {
					Position = track.Position,
					Velocity = track.Velocity,
					LastDetectionTime = track.LastDetectionTime,
					DisplayTrackId = track.DisplayTrackId,
					DisplayTrackIdAliases = track.DisplayTrackIdAliases,
					OriginSourceType = track.OriginSourceType,
					TrackIdentification = track.TrackIdentification,
					AssessedAircraftType = track.AssessedAircraftType,
					LastIdentificationTime = track.LastIdentificationTime,
					expiredAt = now,
				}
			else
				self:_releaseDisplayIds(track)
			end
		end
		local removed = self._store:remove(expiredIds[i])
		if removed then
			if self._geoGrid then
				self._geoGrid:remove(expiredIds[i])
			end
			self:_remapSourceKeyMappings(removed.TrackId, nil)
			self._eventBus:publish({ id = "TrackRemoved", TrackId = expiredIds[i], timestamp = now })
		end
	end

	-- Evict stale dormant entries
	for nid, d in pairs(self._dormant) do
		if now - d.expiredAt > Medusa.Constants.TRACK_REASSOC_TTL_SEC then
			self:_releaseDisplayIds(d)
			self._dormant[nid] = nil
		end
	end
end

--- Merges same-partition tracks while preserving display aliases and bidirectional assignments.
function Medusa.Services.TrackManager:mergeTracks(survivingTrackId, absorbedTrackId, now)
	if survivingTrackId == absorbedTrackId then
		error("cannot merge a track into itself")
	end
	local survivor = self._store:get(survivingTrackId)
	local absorbed = self._store:get(absorbedTrackId)
	if not survivor or not absorbed then
		error("merge requires two existing tracks")
	end
	if survivor.PartitionKey ~= absorbed.PartitionKey then
		error("cannot merge tracks from different partition incarnations")
	end
	local absorbedDisplayId = Medusa.Entities.Track.displayId(absorbed)

	Medusa.Entities.Track.addDisplayIdAlias(survivor, absorbed.DisplayTrackId)
	for i = 1, #absorbed.DisplayTrackIdAliases do
		Medusa.Entities.Track.addDisplayIdAlias(survivor, absorbed.DisplayTrackIdAliases[i])
	end
	transferAssignedBatteries(absorbed, survivor, self._batteryRepository, now or GetTime())
	self:_remapSourceKeyMappings(absorbedTrackId, survivingTrackId)
	self._store:remove(absorbedTrackId)
	if self._geoGrid then
		self._geoGrid:remove(absorbedTrackId)
	end
	self._eventBus:publish({
		id = "TracksMerged",
		TrackId = survivingTrackId,
		MergedTrackId = absorbedTrackId,
		timestamp = now or GetTime(),
	})
	self._logger:info(
		string.format(
			"merged track %s into track %s; retained %s as an alias",
			absorbedDisplayId,
			Medusa.Entities.Track.displayId(survivor),
			absorbedDisplayId
		)
	)
	return survivor
end

--- Creates the new source track for a split while retaining continuingTrackId unchanged.
function Medusa.Services.TrackManager:splitTrack(continuingTrackId, report, now)
	if not self._store:get(continuingTrackId) then
		error("split requires an existing continuing track")
	end
	if report and self._trackIdBySourceKey[reportKey(report)] then
		error("split report requires a new source-partition identity")
	end
	return self:processReport(report, now)
end

function Medusa.Services.TrackManager:getStore()
	return self._store
end

function Medusa.Services.TrackManager:getEventBus()
	return self._eventBus
end
