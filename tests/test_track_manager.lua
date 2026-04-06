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
require("services.TrackManager")

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

function TestTrackManagerProcessReport:test_processReport_createsNewTrack()
	local track = self.mgr:processReport(makeReport())

	lu.assertNotNil(track)
	lu.assertNotNil(track.TrackId)
	lu.assertEquals(track.NetworkId, "net-1")
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

-- == TestTrackManagerPruneStale ==

TestTrackManagerPruneStale = {}

function TestTrackManagerPruneStale:setUp()
	setupMocks()
	self.mgr = Medusa.Services.TrackManager:new()
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

-- == TestTrackManagerEventBus ==

TestTrackManagerEventBus = {}

function TestTrackManagerEventBus:setUp()
	setupMocks()
end

function TestTrackManagerEventBus:test_eventBus_subscriberReceivesTrackCreated()
	local mgr = Medusa.Services.TrackManager:new()
	local receivedEvents = Queue()
	mgr:getEventBus():subscribe("TrackCreated", receivedEvents)

	mgr:processReport(makeReport())

	local event = receivedEvents:dequeue()
	lu.assertNotNil(event)
	lu.assertEquals(event.id, "TrackCreated")
	lu.assertNotNil(event.TrackId)
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
