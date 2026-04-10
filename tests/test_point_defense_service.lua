local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("core.Logger")
require("entities.Entities")
require("entities.Battery")
require("entities.Track")
require("services.Services")
require("services.stores.BatteryStore")
require("services.stores.TrackStore")
require("services.BatteryActivationService")
require("services.SpatialQuery")
require("services.PointDefenseService")

local AS = Medusa.Constants.ActivationState
local BOS = Medusa.Constants.BatteryOperationalStatus
local BR = Medusa.Constants.BatteryRole
local LS = Medusa.Constants.TrackLifecycleState
local PDS = Medusa.Services.PointDefenseService

local ulidCounter = 0
local groupIdCounter = 0

local function setupMocks()
	ulidCounter = 0
	groupIdCounter = 0
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()

	GetTime = function()
		return 1000
	end
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
	GetGroupController = function(name)
		return { name = name }
	end
	SetControllerOnOff = function() end
	ControllerSetROE = function() end
	ControllerSetAlarmState = function() end
	Distance2D = function(a, b)
		local dx = a.x - b.x
		local dz = a.z - b.z
		return math.sqrt(dx * dx + dz * dz)
	end
end

local function makeBattery(overrides)
	groupIdCounter = groupIdCounter + 1
	local data = {
		NetworkId = "net-1",
		GroupId = groupIdCounter,
		GroupName = string.format("SAM-%d", groupIdCounter),
		OperationalStatus = BOS.ACTIVE,
		Position = { x = 0, y = 0, z = 0 },
		Role = BR.GENERIC_SAM,
		StateChangeHoldDownSec = 0,
	}
	if overrides then
		for k, v in pairs(overrides) do
			data[k] = v
		end
	end
	return Medusa.Entities.Battery.new(data)
end

local function makeTrack(overrides)
	local data = {
		NetworkId = "net-1",
		Position = { x = 1000, y = 500, z = 2000 },
		Velocity = { x = 100, y = 0, z = 50 },
		LifecycleState = LS.ACTIVE,
		TrackIdentification = "HOSTILE",
	}
	if overrides then
		for k, v in pairs(overrides) do
			data[k] = v
		end
	end
	return Medusa.Entities.Track.new(data)
end

local function makeCtx(fields)
	return {
		trackStore = fields.trackStore,
		batteryStore = fields.batteryStore,
		geoGrid = fields.geoGrid,
		now = fields.now or 1000,
	}
end

-- == TestSetAssignment ==

TestSetAssignment = {}

function TestSetAssignment:setUp()
	setupMocks()
	self.batteryStore = Medusa.Services.BatteryStore:new()
end

function TestSetAssignment:test_links_batteries_correctly()
	local pd = makeBattery({ BatteryId = "PD-1", Role = BR.SR_SAM })
	local hva = makeBattery({ BatteryId = "HVA-1", Role = BR.LR_SAM })
	self.batteryStore:add(pd)
	self.batteryStore:add(hva)

	local ok = PDS.setAssignment("PD-1", "HVA-1", self.batteryStore)
	lu.assertTrue(ok)
	lu.assertTrue(pd.IsPointDefense)
	lu.assertEquals(pd.PointDefenseTargetId, "HVA-1")
	lu.assertEquals(hva.PointDefenseProviderId, "PD-1")
end

function TestSetAssignment:test_rejects_self_assignment()
	local pd = makeBattery({ BatteryId = "PD-1", Role = BR.SR_SAM })
	self.batteryStore:add(pd)

	local ok = PDS.setAssignment("PD-1", "PD-1", self.batteryStore)
	lu.assertFalse(ok)
end

function TestSetAssignment:test_rejects_missing_battery()
	local pd = makeBattery({ BatteryId = "PD-1", Role = BR.SR_SAM })
	self.batteryStore:add(pd)

	local ok = PDS.setAssignment("PD-1", "NONEXISTENT", self.batteryStore)
	lu.assertFalse(ok)
end

-- == TestClearAssignment ==

TestClearAssignment = {}

function TestClearAssignment:setUp()
	setupMocks()
	self.batteryStore = Medusa.Services.BatteryStore:new()
end

function TestClearAssignment:test_clears_both_sides()
	local pd = makeBattery({ BatteryId = "PD-1", Role = BR.SR_SAM })
	local hva = makeBattery({ BatteryId = "HVA-1", Role = BR.LR_SAM })
	self.batteryStore:add(pd)
	self.batteryStore:add(hva)

	PDS.setAssignment("PD-1", "HVA-1", self.batteryStore)
	PDS.clearAssignment("PD-1", self.batteryStore)

	lu.assertFalse(pd.IsPointDefense)
	lu.assertNil(pd.PointDefenseTargetId)
	lu.assertNil(hva.PointDefenseProviderId)
end

function TestClearAssignment:test_handles_missing_target_gracefully()
	local pd = makeBattery({ BatteryId = "PD-1", Role = BR.SR_SAM })
	self.batteryStore:add(pd)
	pd.IsPointDefense = true
	pd.PointDefenseTargetId = "REMOVED-TARGET"

	local ok = PDS.clearAssignment("PD-1", self.batteryStore)
	lu.assertTrue(ok)
	lu.assertFalse(pd.IsPointDefense)
	lu.assertNil(pd.PointDefenseTargetId)
end

-- == TestAutoAssignShorad ==

TestAutoAssignShorad = {}

function TestAutoAssignShorad:setUp()
	setupMocks()
	self.batteryStore = Medusa.Services.BatteryStore:new()
	self.geoGrid = GeoGrid(10000, { "Battery", "Track" })
end

function TestAutoAssignShorad:test_assigns_sr_sam_to_nearby_lr_sam()
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
	})
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 5000, y = 0, z = 5000 },
	})
	self.batteryStore:add(sr)
	self.batteryStore:add(lr)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)
	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)

	local count = PDS.autoAssignShorad(makeCtx({ batteryStore = self.batteryStore, geoGrid = self.geoGrid }))
	lu.assertEquals(count, 1)
	lu.assertTrue(sr.IsPointDefense)
	lu.assertEquals(sr.PointDefenseTargetId, "LR-1")
	lu.assertEquals(lr.PointDefenseProviderId, "SR-1")
end

function TestAutoAssignShorad:test_ignores_distant_shorad()
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 100000, y = 0, z = 100000 },
	})
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 0, y = 0, z = 0 },
	})
	self.batteryStore:add(sr)
	self.batteryStore:add(lr)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)
	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)

	local count = PDS.autoAssignShorad(makeCtx({ batteryStore = self.batteryStore, geoGrid = self.geoGrid }))
	lu.assertEquals(count, 0)
end

function TestAutoAssignShorad:test_skips_already_assigned_shorad()
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
		IsPointDefense = true,
		PointDefenseTargetId = "SOME-OTHER",
	})
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 5000, y = 0, z = 5000 },
	})
	self.batteryStore:add(sr)
	self.batteryStore:add(lr)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)
	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)

	local count = PDS.autoAssignShorad(makeCtx({ batteryStore = self.batteryStore, geoGrid = self.geoGrid }))
	lu.assertEquals(count, 0)
end

function TestAutoAssignShorad:test_skips_hva_with_existing_provider()
	local sr1 = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
	})
	local sr2 = makeBattery({
		BatteryId = "SR-2",
		Role = BR.SR_SAM,
		Position = { x = 2000, y = 0, z = 2000 },
	})
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 5000, y = 0, z = 5000 },
		PointDefenseProviderId = "SR-EXISTING",
	})
	self.batteryStore:add(sr1)
	self.batteryStore:add(sr2)
	self.batteryStore:add(lr)
	self.geoGrid:add("Battery", sr1.BatteryId, sr1.Position)
	self.geoGrid:add("Battery", sr2.BatteryId, sr2.Position)
	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)

	local count = PDS.autoAssignShorad(makeCtx({ batteryStore = self.batteryStore, geoGrid = self.geoGrid }))
	lu.assertEquals(count, 0)
end

-- == TestEngageThreats ==

TestEngageThreats = {}

function TestEngageThreats:setUp()
	setupMocks()
	self.batteryStore = Medusa.Services.BatteryStore:new()
	self.trackStore = Medusa.Services.TrackStore:new()
	self.geoGrid = GeoGrid(10000, { "Battery", "Track" })
end

function TestEngageThreats:test_pd_goes_hot_for_harm_near_protected_battery()
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 0, y = 0, z = 0 },
	})
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
		EngagementRangeMax = 20000,
		TotalAmmoStatus = 8,
	})
	-- Manually set activation state to bypass holddown
	sr.ActivationState = AS.STATE_WARM

	self.batteryStore:add(lr)
	self.batteryStore:add(sr)
	PDS.setAssignment("SR-1", "LR-1", self.batteryStore)

	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)

	local harm = makeTrack({
		TrackId = "HARM-1",
		AssessedAircraftType = "HARM",
		Position = { x = 5000, y = 3000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	self.trackStore:add(harm)
	self.geoGrid:add("Track", harm.TrackId, harm.Position)

	local count = PDS.engageThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 1)
	lu.assertEquals(sr.CurrentTargetTrackId, "HARM-1")
	lu.assertEquals(sr.ActivationState, AS.STATE_HOT)
end

function TestEngageThreats:test_skips_non_harm_tracks()
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 0, y = 0, z = 0 },
	})
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
		EngagementRangeMax = 20000,
	})
	sr.ActivationState = AS.STATE_WARM

	self.batteryStore:add(lr)
	self.batteryStore:add(sr)
	PDS.setAssignment("SR-1", "LR-1", self.batteryStore)

	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)

	local track = makeTrack({
		TrackId = "FW-1",
		AssessedAircraftType = "FIXED_WING",
		Position = { x = 5000, y = 3000, z = 0 },
	})
	self.trackStore:add(track)
	self.geoGrid:add("Track", track.TrackId, track.Position)

	local count = PDS.engageThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 0)
	lu.assertNil(sr.CurrentTargetTrackId)
end

function TestEngageThreats:test_skips_destroyed_pd_battery()
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 0, y = 0, z = 0 },
	})
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
		EngagementRangeMax = 20000,
		OperationalStatus = BOS.ACTIVE,
	})
	sr.ActivationState = AS.STATE_WARM

	self.batteryStore:add(lr)
	self.batteryStore:add(sr)
	PDS.setAssignment("SR-1", "LR-1", self.batteryStore)

	-- Destroy the PD provider after assignment
	sr.OperationalStatus = BOS.DESTROYED

	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)

	local harm = makeTrack({
		TrackId = "HARM-1",
		AssessedAircraftType = "HARM",
		Position = { x = 5000, y = 3000, z = 0 },
	})
	self.trackStore:add(harm)
	self.geoGrid:add("Track", harm.TrackId, harm.Position)

	local count = PDS.engageThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 0)
end

function TestEngageThreats:test_skips_already_engaged_pd()
	local lr = makeBattery({
		BatteryId = "LR-1",
		Role = BR.LR_SAM,
		Position = { x = 0, y = 0, z = 0 },
	})
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
		EngagementRangeMax = 20000,
		CurrentTargetTrackId = "EXISTING-TARGET",
	})
	sr.ActivationState = AS.STATE_HOT

	self.batteryStore:add(lr)
	self.batteryStore:add(sr)
	PDS.setAssignment("SR-1", "LR-1", self.batteryStore)

	self.geoGrid:add("Battery", lr.BatteryId, lr.Position)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)

	local harm = makeTrack({
		TrackId = "HARM-1",
		AssessedAircraftType = "HARM",
		Position = { x = 5000, y = 3000, z = 0 },
	})
	self.trackStore:add(harm)
	self.geoGrid:add("Track", harm.TrackId, harm.Position)

	local count = PDS.engageThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 0)
	lu.assertEquals(sr.CurrentTargetTrackId, "EXISTING-TARGET")
end

function TestEngageThreats:test_returns_zero_with_no_protected_batteries()
	local sr = makeBattery({
		BatteryId = "SR-1",
		Role = BR.SR_SAM,
		Position = { x = 1000, y = 0, z = 1000 },
		EngagementRangeMax = 20000,
	})
	sr.ActivationState = AS.STATE_WARM

	self.batteryStore:add(sr)
	self.geoGrid:add("Battery", sr.BatteryId, sr.Position)

	local count = PDS.engageThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 0)
end
