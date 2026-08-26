local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("core.Config")
require("entities.Entities")
require("entities.Track")
require("services.Services")
require("services.stores.TrackStore")
require("services.TrackDisplayIdAllocator")
require("services.SpatialQuery")
require("services.TargetAssigner")
require("services.TrackManager")
require("entities.Battery")
require("services.stores.BatteryStore")

-- == Helpers ==

local mockTime = 1000
local ulidCounter = 0

local function setupMocks()
	mockTime = 1000
	ulidCounter = 0
	GetTime = function()
		return mockTime
	end
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
	-- Config needs to be initialized for getSmoothedVelocityWindowSec / getTrackMemoryDurationSec
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
end

local function makeReport(overrides)
	local base = {
		NetworkId = "net-1",
		SourceType = Medusa.Constants.TrackSource.EARLY_WARNING_RADAR,
		Position = { x = 1000, y = 500, z = 2000 },
		Velocity = { x = 100, y = 0, z = 50 },
	}
	if overrides then
		for k, v in pairs(overrides) do
			base[k] = v
		end
	end
	return base
end

-- == TestTrackManagerProcessReport ==

TestTrackManagerProcessReport = {}

function TestTrackManagerProcessReport:setUp()
	setupMocks()
	self.mgr = Medusa.Services.TrackManager:new()
end

function TestTrackManagerProcessReport:test_processReport_doesNotPersistDcsObjectMetadata()
	local track = self.mgr:processReport(makeReport({
		ObjectCategory = Object.Category.UNIT,
		UnitCategory = Unit.Category.AIRPLANE,
	}))

	lu.assertNotNil(track)
	lu.assertNotNil(track.TrackId)
	lu.assertEquals(track.NetworkId, "net-1")
	lu.assertIsNil(track.ObjectCategory)
	lu.assertIsNil(track.UnitCategory)
	lu.assertEquals(self.mgr:getStore():count(), 1)
end

function TestTrackManagerProcessReport:test_processReport_updatesExistingTrack()
	self.mgr:processReport(makeReport())

	mockTime = 1010
	local track = self.mgr:processReport(makeReport({
		Position = { x = 2000, y = 600, z = 3000 },
		Velocity = { x = 200, y = 10, z = 100 },
	}))

	lu.assertEquals(track.Position.x, 2000)
	lu.assertEquals(track.Velocity.x, 200)
	lu.assertEquals(self.mgr:getStore():count(), 1)
end

function TestTrackManagerProcessReport:test_processReport_calculatesSmoothedVelocity()
	self.mgr:processReport(makeReport())

	mockTime = 1010
	local track = self.mgr:processReport(makeReport({
		Velocity = { x = 200, y = 0, z = 100 },
	}))

	lu.assertNotNil(track.SmoothedVelocity)
end

function TestTrackManagerProcessReport:test_processReport_derivesManeuverState()
	self.mgr:processReport(makeReport())

	mockTime = 1010
	local track = self.mgr:processReport(makeReport({
		Velocity = { x = 200, y = 0, z = 100 },
	}))

	lu.assertNotNil(track.ManeuverState)
end

function TestTrackManagerProcessReport:test_processReport_returnsTrack()
	local track = self.mgr:processReport(makeReport())

	lu.assertNotNil(track)
	lu.assertEquals(track.NetworkId, "net-1")
	lu.assertEquals(track.DisplayTrackId, "AE0001")
end

function TestTrackManagerProcessReport:test_capacity_rejection_does_not_publish_track_ownership()
	local store = self.mgr:getStore()
	for i = 1, Medusa.Constants.TRACK_CAPACITY do
		store:add(Medusa.Entities.Track.new({
			TrackId = "capacity-track-" .. tostring(i),
			Position = { x = i, y = 0, z = 0 },
			Velocity = { x = 1, y = 0, z = 0 },
			NetworkId = "capacity-network",
		}))
	end

	lu.assertNil(self.mgr:processReport(makeReport()))
	lu.assertEquals(store:count(), Medusa.Constants.TRACK_CAPACITY)
	lu.assertEquals(self.mgr._trackIdBySourceKey, {})
end

function TestTrackManagerProcessReport:test_processReport_uses_originating_source_prefix()
	local track = self.mgr:processReport(makeReport({ SourceType = Medusa.Constants.TrackSource.AWACS }))

	lu.assertEquals(track.DisplayTrackId, "AW0001")
	lu.assertEquals(track.OriginSourceType, Medusa.Constants.TrackSource.AWACS)
end

function TestTrackManagerProcessReport:test_source_handoff_retains_originating_display_id()
	local track = self.mgr:processReport(makeReport({ SourceType = Medusa.Constants.TrackSource.AWACS }))
	local displayId = track.DisplayTrackId

	local updated = self.mgr:processReport(makeReport({ SourceType = Medusa.Constants.TrackSource.SAM_BATTERY }))

	lu.assertEquals(updated.DisplayTrackId, displayId)
	lu.assertEquals(updated.OriginSourceType, Medusa.Constants.TrackSource.AWACS)
end

function TestTrackManagerProcessReport:test_classification_change_retains_display_id()
	local track = self.mgr:processReport(makeReport())

	self.mgr:getStore():updateIdentification(track.TrackId, Medusa.Constants.TrackIdentification.BOGEY)

	lu.assertEquals(track.DisplayTrackId, "AE0001")
end

function TestTrackManagerProcessReport:test_processReport_nilReport()
	local result = self.mgr:processReport(nil)
	lu.assertNil(result)
end

function TestTrackManagerProcessReport:test_processReport_missingFields()
	lu.assertNil(self.mgr:processReport({ NetworkId = "n" }))
	lu.assertNil(self.mgr:processReport({ Position = { x = 0, y = 0, z = 0 } }))
	lu.assertNil(self.mgr:processReport({ Velocity = { x = 0, y = 0, z = 0 } }))
end

function TestTrackManagerProcessReport:test_processReport_rejects_nonfinite_vectors_before_store_admission()
	lu.assertNil(self.mgr:processReport(makeReport({ Position = { x = 0 / 0, y = 0, z = 0 } })))
	lu.assertNil(self.mgr:processReport(makeReport({ Velocity = { x = "invalid", y = 0, z = 0 } })))
	lu.assertEquals(self.mgr:getStore():count(), 0)
	lu.assertEquals(self.mgr._trackIdBySourceKey, {})
end

function TestTrackManagerProcessReport:test_spatial_admission_failure_rolls_back_track_store()
	local store = Medusa.Services.TrackStore:new()
	local mgr = Medusa.Services.TrackManager:new({
		store = store,
		geoGrid = {
			add = function()
				return false
			end,
		},
	})

	lu.assertNil(mgr:processReport(makeReport()))
	lu.assertEquals(store:count(), 0)
	lu.assertEquals(mgr._trackIdBySourceKey, {})
end

-- == TestTrackManagerPruneStale ==

TestTrackManagerPruneStale = {}

function TestTrackManagerPruneStale:setUp()
	setupMocks()
	self.originalInfo = env.info
	self.originalLogLevel = Medusa.Logger:getLevel()
	self.infoMessages = {}
	env.info = function(message)
		self.infoMessages[#self.infoMessages + 1] = message
	end
	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.INFO)
	self.mgr = Medusa.Services.TrackManager:new()
end

function TestTrackManagerPruneStale:tearDown()
	env.info = self.originalInfo
	Medusa.Logger:setLevel(self.originalLogLevel)
end

function TestTrackManagerPruneStale:test_pruneStale_activeBecomeStale()
	self.mgr:processReport(makeReport())

	-- Advance past the track memory duration (default 60s)
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)

	local track = self.mgr:getStore():get(self.mgr:getStore():getAll()[1].TrackId)
	lu.assertEquals(track.LifecycleState, Medusa.Constants.TrackLifecycleState.STALE)
end

function TestTrackManagerPruneStale:test_pruneStale_staleBecomesExpired()
	self.mgr:processReport(makeReport())

	-- First prune: ACTIVE -> STALE
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)

	-- Second prune: STALE -> removed (track is still old)
	self.mgr:pruneStale(pruneTime)

	lu.assertEquals(self.mgr:getStore():count(), 0)
end

function TestTrackManagerPruneStale:test_lifecycle_transitions_log_once_at_info()
	local track = self.mgr:processReport(makeReport())
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	mockTime = pruneTime + 1
	self.mgr:processReport(makeReport())
	pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	local transitions = {}
	for i = 1, #self.infoMessages do
		if string.find(self.infoMessages[i], "lifecycle", 1, true) then
			transitions[#transitions + 1] = self.infoMessages[i]
		end
	end
	lu.assertEquals(#transitions, 4)
	lu.assertStrContains(transitions[1], "track AE0001 lifecycle ACTIVE -> STALE reason=memory timeout")
	lu.assertStrContains(transitions[2], "track AE0001 lifecycle STALE -> ACTIVE reason=observation resumed")
	lu.assertStrContains(transitions[3], "track AE0001 lifecycle ACTIVE -> STALE reason=memory timeout")
	lu.assertStrContains(transitions[4], "track AE0001 lifecycle STALE -> EXPIRED reason=memory expired")
	lu.assertEquals(track.LifecycleState, Medusa.Constants.TrackLifecycleState.EXPIRED)
end

function TestTrackManagerPruneStale:test_expiry_releases_battery_assignment_before_removal()
	local batteryRepository = Medusa.Services.BatteryStore:new()
	local site = Medusa.Entities.Battery.new({ NetworkId = "N", GroupId = 71, GroupName = "battery" })
	batteryRepository:add(site)
	local mgr = Medusa.Services.TrackManager:new({ batteryRepository = batteryRepository })
	local assignedTrack = mgr:processReport(makeReport())
	Medusa.Entities.Battery.assignTrack(site, assignedTrack, mockTime, mgr:getStore())

	local pruneTime = mockTime + 61
	mgr:pruneStale(pruneTime)
	mgr:pruneStale(pruneTime)

	lu.assertNil(site.CurrentTargetTrackId)
	lu.assertTrue(assignedTrack.AssignedBatteryIds:isEmpty())
end

function TestTrackManagerPruneStale:test_expiry_starts_deactivation_hold_down()
	local batteryRepository = Medusa.Services.BatteryStore:new()
	local site = Medusa.Entities.Battery.new({
		NetworkId = "N",
		GroupId = 72,
		GroupName = "battery",
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
	})
	batteryRepository:add(site)
	local mgr = Medusa.Services.TrackManager:new({ batteryRepository = batteryRepository })
	local assignedTrack = mgr:processReport(makeReport())
	Medusa.Entities.Battery.assignTrack(site, assignedTrack, mockTime, mgr:getStore())

	local releaseTime = mockTime + 61
	mgr:pruneStale(releaseTime)
	mgr:pruneStale(releaseTime)

	lu.assertEquals(site.LastAssignmentChangeTime, releaseTime)
	lu.assertNil(Medusa.Services.TargetAssigner.checkSingleDeactivation(site, {
		trackStore = mgr:getStore(),
		doctrine = { HoldDownSec = 5 },
		now = releaseTime + 4,
	}))
end

function TestTrackManagerPruneStale:test_pruneStale_activeStaysActive()
	self.mgr:processReport(makeReport())

	-- Prune within the threshold: track should remain ACTIVE
	local pruneTime = mockTime + 30
	self.mgr:pruneStale(pruneTime)

	local tracks = self.mgr:getStore():getAll()
	lu.assertEquals(tracks[1].LifecycleState, Medusa.Constants.TrackLifecycleState.ACTIVE)
end

function TestTrackManagerPruneStale:test_pruneStale_emitsTrackBecameStale()
	local receivedEvents = Queue()
	self.mgr:getEventBus():subscribe("TrackBecameStale", receivedEvents)

	self.mgr:processReport(makeReport())

	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)

	local event = receivedEvents:dequeue()
	lu.assertNotNil(event)
	lu.assertEquals(event.id, "TrackBecameStale")
end

function TestTrackManagerPruneStale:test_pruneStale_emitsTrackRemoved()
	local receivedEvents = Queue()
	self.mgr:getEventBus():subscribe("TrackRemoved", receivedEvents)

	self.mgr:processReport(makeReport())

	-- Two prunes: first makes STALE, second removes
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	local event = receivedEvents:dequeue()
	lu.assertNotNil(event)
	lu.assertEquals(event.id, "TrackRemoved")
end

function TestTrackManagerPruneStale:test_pruneStale_removesFromNetworkIdIndex()
	self.mgr:processReport(makeReport({ NetworkId = "net-reuse" }))

	-- Expire the track
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)
	lu.assertEquals(self.mgr:getStore():count(), 0)

	-- Same NetworkId should create a new track
	mockTime = pruneTime + 10
	local track = self.mgr:processReport(makeReport({ NetworkId = "net-reuse" }))
	lu.assertNotNil(track)
	lu.assertEquals(self.mgr:getStore():count(), 1)
end

function TestTrackManagerPruneStale:test_reassociation_retains_display_id_with_new_canonical_id()
	local original = self.mgr:processReport(makeReport({ SourceType = Medusa.Constants.TrackSource.AWACS }))
	local originalCanonicalId = original.TrackId
	local originalDisplayId = original.DisplayTrackId
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	mockTime = pruneTime + 10
	local reacquired = self.mgr:processReport(makeReport({
		SourceType = Medusa.Constants.TrackSource.SAM_BATTERY,
		Position = { x = 1100, y = 500, z = 2100 },
	}))

	lu.assertNotEquals(reacquired.TrackId, originalCanonicalId)
	lu.assertEquals(reacquired.DisplayTrackId, originalDisplayId)
	lu.assertEquals(reacquired.OriginSourceType, Medusa.Constants.TrackSource.AWACS)
end

function TestTrackManagerPruneStale:test_reassociation_uses_projected_position()
	local original = self.mgr:processReport(makeReport({ SourceType = Medusa.Constants.TrackSource.AWACS }))
	original.TrackIdentification = Medusa.Constants.TrackIdentification.BANDIT
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	mockTime = pruneTime + 10
	local reacquired = self.mgr:processReport(makeReport({
		SourceType = Medusa.Constants.TrackSource.SAM_BATTERY,
		Position = { x = 8200, y = 500, z = 5600 },
	}))

	lu.assertEquals(reacquired.TrackIdentification, Medusa.Constants.TrackIdentification.BANDIT)
	lu.assertEquals(reacquired.OriginSourceType, Medusa.Constants.TrackSource.AWACS)
end

function TestTrackManagerPruneStale:test_reassociation_preserves_identification_transition_time()
	local original = self.mgr:processReport(makeReport())
	original.TrackIdentification = Medusa.Constants.TrackIdentification.BANDIT
	original.LastIdentificationTime = mockTime
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	mockTime = pruneTime + 10
	local reacquired = self.mgr:processReport(makeReport({
		Position = { x = 1100, y = 500, z = 2100 },
	}))

	lu.assertEquals(reacquired.TrackIdentification, Medusa.Constants.TrackIdentification.BANDIT)
	lu.assertEquals(reacquired.LastIdentificationTime, 1000)
end

function TestTrackManagerPruneStale:test_reassociation_starts_with_fresh_harm_evidence()
	local original = self.mgr:processReport(makeReport())
	original.HarmAssessment = {
		label = "CLEARED",
		llr = -24.82,
		scanCount = 21,
	}
	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	mockTime = pruneTime + 10
	local reacquired = self.mgr:processReport(makeReport({
		Position = { x = 1100, y = 500, z = 2100 },
	}))

	lu.assertNil(reacquired.HarmAssessment)
	lu.assertNil(reacquired.HarmLikelihoodScore)
	lu.assertFalse(reacquired.IsHarmLauncher)
end

function TestTrackManagerPruneStale:test_partition_retirement_removes_tracks_without_dormant_reassociation()
	local retired = self.mgr:processReport(makeReport({
		NetworkId = "retired-contact",
		PartitionKey = "partition-old",
	}))
	local retained = self.mgr:processReport(makeReport({
		NetworkId = "retained-contact",
		PartitionKey = "partition-current",
	}))

	local retiredCount = self.mgr:retirePartitionIncarnations({ ["partition-current"] = true }, mockTime)

	lu.assertEquals(retiredCount, 1)
	lu.assertNil(self.mgr:getStore():get(retired.TrackId))
	lu.assertEquals(self.mgr:getStore():get(retained.TrackId), retained)
	lu.assertNil(self.mgr._trackIdBySourceKey["retired-contact\001partition-old"])
	lu.assertNil(self.mgr._dormant["retired-contact\001partition-old"])

	local reacquired = self.mgr:processReport(makeReport({
		NetworkId = "retired-contact",
		PartitionKey = "partition-current",
	}))
	lu.assertNotNil(reacquired)
	lu.assertNotEquals(reacquired.TrackId, retired.TrackId)
	lu.assertNotEquals(reacquired.DisplayTrackId, retired.DisplayTrackId)
end

-- == TestTrackManagerMergeSplit ==

TestTrackManagerMergeSplit = {}

function TestTrackManagerMergeSplit:setUp()
	setupMocks()
	self.allocator = Medusa.Services.TrackDisplayIdAllocator:new()
	self.mgr = Medusa.Services.TrackManager:new({
		displayIdAllocator = self.allocator,
	})
end

function TestTrackManagerMergeSplit:test_merge_retains_survivor_id_and_absorbed_alias()
	local survivor = self.mgr:processReport(makeReport({ NetworkId = "survivor" }))
	local absorbed = self.mgr:processReport(makeReport({ NetworkId = "absorbed" }))

	local merged = self.mgr:mergeTracks(survivor.TrackId, absorbed.TrackId, mockTime)

	lu.assertEquals(merged.DisplayTrackId, survivor.DisplayTrackId)
	lu.assertEquals(merged.DisplayTrackIdAliases, { absorbed.DisplayTrackId })
	lu.assertNil(self.mgr:getStore():get(absorbed.TrackId))
end

function TestTrackManagerMergeSplit:test_merge_transfers_assignments_to_survivor()
	local batteryRepository = Medusa.Services.BatteryStore:new()
	local site = Medusa.Entities.Battery.new({ NetworkId = "N", GroupId = 72, GroupName = "battery" })
	batteryRepository:add(site)
	local mgr = Medusa.Services.TrackManager:new({
		batteryRepository = batteryRepository,
		displayIdAllocator = self.allocator,
	})
	local survivor = mgr:processReport(makeReport({ NetworkId = "survivor" }))
	local absorbed = mgr:processReport(makeReport({ NetworkId = "absorbed" }))
	Medusa.Entities.Battery.assignTrack(site, absorbed, mockTime, mgr:getStore())

	mgr:mergeTracks(survivor.TrackId, absorbed.TrackId, mockTime + 1)

	lu.assertEquals(site.CurrentTargetTrackId, survivor.TrackId)
	lu.assertTrue(survivor.AssignedBatteryIds:contains(site.BatteryId))
	lu.assertTrue(absorbed.AssignedBatteryIds:isEmpty())
end

function TestTrackManagerMergeSplit:test_merge_alias_remains_reserved_until_survivor_is_dropped()
	local sourceType = Medusa.Constants.TrackSource.EARLY_WARNING_RADAR
	local survivor = self.mgr:processReport(makeReport({ NetworkId = "survivor" }))
	local absorbed = self.mgr:processReport(makeReport({ NetworkId = "absorbed" }))
	self.mgr:mergeTracks(survivor.TrackId, absorbed.TrackId, mockTime)
	for _ = 3, Medusa.Services.TrackDisplayIdAllocator.MAX_NUMBER do
		self.allocator:allocate(sourceType)
	end

	lu.assertErrorMsgContains("display ID pool exhausted", function()
		self.allocator:allocate(sourceType)
	end)

	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime + Medusa.Constants.TRACK_REASSOC_TTL_SEC + 1)

	lu.assertEquals(self.allocator:allocate(sourceType), survivor.DisplayTrackId)
	lu.assertEquals(self.allocator:allocate(sourceType), absorbed.DisplayTrackId)
end

function TestTrackManagerMergeSplit:test_expiry_removes_all_merged_network_mappings()
	local survivor = self.mgr:processReport(makeReport({ NetworkId = "survivor" }))
	local absorbed = self.mgr:processReport(makeReport({ NetworkId = "absorbed" }))
	self.mgr:mergeTracks(survivor.TrackId, absorbed.TrackId, mockTime)

	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)

	lu.assertNil(self.mgr._trackIdBySourceKey.survivor)
	lu.assertNil(self.mgr._trackIdBySourceKey.absorbed)
end

function TestTrackManagerMergeSplit:test_merged_alias_survives_dormant_reassociation()
	local survivor = self.mgr:processReport(makeReport({ NetworkId = "survivor" }))
	local absorbed = self.mgr:processReport(makeReport({ NetworkId = "absorbed" }))
	local survivorDisplayId = survivor.DisplayTrackId
	local absorbedDisplayId = absorbed.DisplayTrackId
	self.mgr:mergeTracks(survivor.TrackId, absorbed.TrackId, mockTime)

	local pruneTime = mockTime + 61
	self.mgr:pruneStale(pruneTime)
	self.mgr:pruneStale(pruneTime)
	mockTime = pruneTime + 10
	local reacquired = self.mgr:processReport(makeReport({
		NetworkId = "survivor",
		Position = { x = 1100, y = 500, z = 2100 },
	}))

	lu.assertEquals(reacquired.DisplayTrackId, survivorDisplayId)
	lu.assertEquals(reacquired.DisplayTrackIdAliases, { absorbedDisplayId })
end

function TestTrackManagerMergeSplit:test_split_retains_continuing_id_and_allocates_new_id()
	local continuing = self.mgr:processReport(makeReport({ NetworkId = "continuing" }))

	local child = self.mgr:splitTrack(continuing.TrackId, makeReport({ NetworkId = "child" }), mockTime)

	lu.assertEquals(continuing.DisplayTrackId, "AE0001")
	lu.assertEquals(child.DisplayTrackId, "AE0002")
	lu.assertNotEquals(child.TrackId, continuing.TrackId)
end

TestTrackManagerDisplayLogging = {}

function TestTrackManagerDisplayLogging:setUp()
	setupMocks()
	self.originalInfo = env.info
	self.originalLogLevel = Medusa.Logger:getLevel()
	self.messages = {}
	env.info = function(message)
		self.messages[#self.messages + 1] = message
	end
	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.INFO)
	self.mgr = Medusa.Services.TrackManager:new()
end

function TestTrackManagerDisplayLogging:tearDown()
	env.info = self.originalInfo
	Medusa.Logger:setLevel(self.originalLogLevel)
end

function TestTrackManagerDisplayLogging:test_merge_log_uses_display_id_and_retains_absorbed_alias()
	local survivor = self.mgr:processReport(makeReport({ NetworkId = "survivor" }))
	local absorbed = self.mgr:processReport(makeReport({ NetworkId = "absorbed" }))

	self.mgr:mergeTracks(survivor.TrackId, absorbed.TrackId, mockTime)

	local message = self.messages[#self.messages]
	lu.assertStrContains(message, "merged track AE0002 into track AE0001; retained AE0002 as an alias")
	lu.assertNotStrContains(message, "ULID-")
end

-- == TestTrackManagerEventBus ==

TestTrackManagerEventBus = {}

function TestTrackManagerEventBus:setUp()
	setupMocks()
end

function TestTrackManagerEventBus:test_eventBus_subscriberReceivesTrackCreated()
	local mgr = Medusa.Services.TrackManager:new()
	local receivedEvents = Queue()
	mgr:getEventBus():subscribe("TrackCreated", receivedEvents)

	local track = mgr:processReport(makeReport())

	local event = receivedEvents:dequeue()
	lu.assertNotNil(event)
	lu.assertEquals(event.id, "TrackCreated")
	lu.assertEquals(event.TrackId, track.TrackId)
	lu.assertNotEquals(event.TrackId, track.DisplayTrackId)
	lu.assertNotNil(event.timestamp)
end

function TestTrackManagerEventBus:test_eventBus_subscriberReceivesTrackUpdated()
	local mgr = Medusa.Services.TrackManager:new()
	local receivedEvents = Queue()
	mgr:getEventBus():subscribe("TrackUpdated", receivedEvents)

	mgr:processReport(makeReport())

	mockTime = 1010
	mgr:processReport(makeReport({ Velocity = { x = 200, y = 0, z = 100 } }))

	local event = receivedEvents:dequeue()
	lu.assertNotNil(event)
	lu.assertEquals(event.id, "TrackUpdated")
	lu.assertNotNil(event.Position)
	lu.assertNotNil(event.Velocity)
end

function TestTrackManagerEventBus:test_eventBus_customEventBus()
	local customBus = EventBus()
	local mgr = Medusa.Services.TrackManager:new({ eventBus = customBus })

	lu.assertEquals(mgr:getEventBus(), customBus)

	local receivedEvents = Queue()
	customBus:subscribe("TrackCreated", receivedEvents)

	mgr:processReport(makeReport())

	local event = receivedEvents:dequeue()
	lu.assertNotNil(event)
	lu.assertEquals(event.id, "TrackCreated")
end
