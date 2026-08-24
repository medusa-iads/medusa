local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("core.Logger")
require("entities.Battery")
require("entities.Track")
require("services.stores.BatteryStore")
require("services.stores.TrackStore")
require("services.BatteryActivationService")
require("services.PointDefenseService")

local scenario = require("scenario_one_syria")
local AS = Medusa.Constants.ActivationState
local BOS = Medusa.Constants.BatteryOperationalStatus
local BR = Medusa.Constants.BatteryRole
local C = Medusa.Constants
local LS = Medusa.Constants.TrackLifecycleState
local PDS = Medusa.Services.PointDefenseService

local sequence = 0
local groupSequence = 0

local function setupMocks()
	sequence = 0
	groupSequence = 0
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	GetTime = function()
		return 1000
	end
	NewULID = function()
		sequence = sequence + 1
		return "ULID-" .. sequence
	end
	GetGroupController = function(name)
		return { name = name }
	end
	SetControllerOnOff = function()
		return true
	end
	ControllerSetROE = function()
		return true
	end
	ControllerSetAlarmState = function()
		return true
	end
	SetControllerOption = function()
		return true
	end
	EnableGroupEmissions = function()
		return true
	end
	Distance2D = function(a, b)
		local dx = a.x - b.x
		local dz = a.z - b.z
		return math.sqrt(dx * dx + dz * dz)
	end
end

local function makeBattery(overrides)
	groupSequence = groupSequence + 1
	local data = {
		NetworkId = "net-1",
		GroupId = groupSequence + 100,
		GroupName = "battery-" .. tostring(groupSequence + 100),
		Role = BR.SR_SAM,
		ActivationState = AS.STATE_WARM,
		OperationalStatus = BOS.ACTIVE,
		Position = { x = 0, y = 0, z = 0 },
		WeaponRangeMax = 30000,
		EngagementRangeMax = 30000,
		EngagementRangeMin = 0,
		EngagementAltitudeMin = 0,
		EngagementAltitudeMax = 30000,
		PkRangeOptimal = 15000,
		PkRangeSigma = 30000,
		TotalAmmoStatus = 8,
		AmmoKnown = true,
		HarmDefenseCapacity = 4,
		PartitionKey = "partition-a",
		CoordinationState = C.CoordinationState.COORDINATED,
		StateChangeHoldDownSec = 0,
	}
	for key, value in pairs(overrides or {}) do
		data[key] = value
	end
	return Medusa.Entities.Battery.new(data)
end

local function makeTrack(id, position, partition)
	return Medusa.Entities.Track.new({
		TrackId = id,
		NetworkId = "net-1",
		PartitionKey = partition or "partition-a",
		Position = position,
		Velocity = { x = -300, y = -20, z = 0 },
		LifecycleState = LS.ACTIVE,
		TrackIdentification = "HOSTILE",
		AssessedAircraftType = C.AssessedAircraftType.HARM,
	})
end

local function addBattery(store, grid, battery)
	store:add(battery)
	grid:add("Battery", battery.BatteryId, battery.Position)
end

TestPointDefenseDerivation = {}

function TestPointDefenseDerivation:setUp()
	setupMocks()
	self.store = Medusa.Services.BatteryStore:new()
	self.grid = GeoGrid(10000, { "Battery", "Track" })
end

function TestPointDefenseDerivation:test_scenario_one_nearby_group_is_derived_as_point_defense()
	local protected = makeBattery({
		BatteryId = "protected",
		GroupName = "protected-site",
		Role = BR.LR_SAM,
		Position = scenario.ProtectedSite.GroupPosition,
	})
	local nearby = makeBattery({
		BatteryId = "nearby",
		GroupName = "nearby-defender",
		Position = scenario.NearbyPointDefense.GroupPosition,
	})
	local far = makeBattery({
		BatteryId = "far",
		GroupName = "far-defender",
		Position = scenario.FarPointDefense.GroupPosition,
	})
	addBattery(self.store, self.grid, protected)
	addBattery(self.store, self.grid, nearby)
	addBattery(self.store, self.grid, far)

	local count = PDS.reconcileProviders({ batteryStore = self.store, geoGrid = self.grid })

	lu.assertTrue(nearby.IsPointDefense)
	lu.assertTrue(far.IsPointDefense)
	lu.assertTrue(Distance2D(nearby.Position, protected.Position) < Distance2D(far.Position, protected.Position))
	lu.assertEquals(count, 2)
end

function TestPointDefenseDerivation:test_one_provider_can_cover_multiple_high_value_sites()
	local provider = makeBattery({ BatteryId = "provider", Position = { x = 0, y = 0, z = 0 } })
	local first = makeBattery({ BatteryId = "first", Role = BR.LR_SAM, Position = { x = 1000, y = 0, z = 0 } })
	local second = makeBattery({ BatteryId = "second", Role = BR.MR_SAM, Position = { x = 0, y = 0, z = 1000 } })
	addBattery(self.store, self.grid, provider)
	addBattery(self.store, self.grid, first)
	addBattery(self.store, self.grid, second)

	PDS.reconcileProviders({ batteryStore = self.store, geoGrid = self.grid })

	lu.assertTrue(provider.IsPointDefense)
	lu.assertTrue(PDS.canProtect(provider, first))
	lu.assertTrue(PDS.canProtect(provider, second))
end

function TestPointDefenseDerivation:test_partition_or_viability_loss_removes_derived_role()
	local provider = makeBattery({ BatteryId = "provider" })
	local protected = makeBattery({ BatteryId = "protected", Role = BR.LR_SAM, Position = { x = 1000, y = 0, z = 0 } })
	addBattery(self.store, self.grid, provider)
	addBattery(self.store, self.grid, protected)
	PDS.reconcileProviders({ batteryStore = self.store, geoGrid = self.grid })
	lu.assertTrue(provider.IsPointDefense)

	protected.PartitionKey = "partition-b"
	PDS.reconcileProviders({ batteryStore = self.store, geoGrid = self.grid })
	lu.assertFalse(provider.IsPointDefense)

	protected.PartitionKey = "partition-a"
	provider.AmmoKnown = false
	PDS.reconcileProviders({ batteryStore = self.store, geoGrid = self.grid })
	lu.assertFalse(provider.IsPointDefense)
end

function TestPointDefenseDerivation:test_independent_aaa_is_not_point_defense()
	local provider = makeBattery({
		BatteryId = "aaa",
		Role = BR.AAA,
		RadarDependencyPolicy = C.BatteryRadarDependencyPolicy.INDEPENDENT,
	})
	local protected = makeBattery({ BatteryId = "protected", Role = BR.LR_SAM, Position = { x = 1000, y = 0, z = 0 } })
	addBattery(self.store, self.grid, provider)
	addBattery(self.store, self.grid, protected)

	PDS.reconcileProviders({ batteryStore = self.store, geoGrid = self.grid })

	lu.assertFalse(provider.IsPointDefense)
end

TestPointDefenseActivation = {}

function TestPointDefenseActivation:setUp()
	setupMocks()
	self.trackStore = Medusa.Services.TrackStore:new()
	self.provider = makeBattery({ BatteryId = "provider", GroupName = "provider" })
	self.doctrine = { DegradedMode = C.NetworkDegradationPolicy.REVERT_TO_AUTONOMOUS }
end

function TestPointDefenseActivation:test_assigns_nearest_eligible_harm_with_stable_tie_break()
	local farther = makeTrack("harm-z", { x = 10000, y = 1000, z = 0 })
	local nearestLaterId = makeTrack("harm-b", { x = 1000, y = 1000, z = 0 })
	local nearestFirstId = makeTrack("harm-a", { x = 1000, y = 1000, z = 0 })
	self.trackStore:add(farther)
	self.trackStore:add(nearestLaterId)
	self.trackStore:add(nearestFirstId)

	local ready = PDS.activateClosestHarm(
		self.provider,
		{ farther, nearestLaterId, nearestFirstId },
		1000,
		self.doctrine,
		self.trackStore
	)

	lu.assertTrue(ready)
	lu.assertEquals(self.provider.CurrentTargetTrackId, "harm-a")
	lu.assertTrue(nearestFirstId.AssignedBatteryIds:contains(self.provider.BatteryId))
end

function TestPointDefenseActivation:test_failed_hot_request_releases_the_harm_assignment()
	local harm = makeTrack("harm-1", { x = 1000, y = 1000, z = 0 })
	self.trackStore:add(harm)
	ControllerSetROE = function()
		return false
	end

	local ready = PDS.activateClosestHarm(self.provider, { harm }, 1000, self.doctrine, self.trackStore)

	lu.assertFalse(ready)
	lu.assertNil(self.provider.CurrentTargetTrackId)
	lu.assertFalse(harm.AssignedBatteryIds:contains(self.provider.BatteryId))
end

function TestPointDefenseActivation:test_existing_hot_harm_assignment_is_retained_without_another_command()
	local harm = makeTrack("harm-1", { x = 1000, y = 1000, z = 0 })
	self.trackStore:add(harm)
	self.provider.ActivationState = AS.STATE_HOT
	lu.assertTrue(Medusa.Entities.Battery.assignTrack(self.provider, harm, 900, self.trackStore))
	local calls = 0
	ControllerSetROE = function()
		calls = calls + 1
		return true
	end

	lu.assertTrue(PDS.activateClosestHarm(self.provider, { harm }, 1000, self.doctrine, self.trackStore))
	lu.assertEquals(calls, 0)
	lu.assertEquals(self.provider.CurrentTargetTrackId, harm.TrackId)
end

function TestPointDefenseActivation:test_existing_warm_harm_assignment_requests_hot_readiness()
	local harm = makeTrack("harm-1", { x = 1000, y = 1000, z = 0 })
	self.trackStore:add(harm)
	lu.assertTrue(Medusa.Entities.Battery.assignTrack(self.provider, harm, 900, self.trackStore))

	lu.assertTrue(PDS.activateClosestHarm(self.provider, { harm }, 1000, self.doctrine, self.trackStore))
	lu.assertEquals(self.provider.ActivationState, AS.STATE_HOT)
	lu.assertEquals(self.provider.CurrentTargetTrackId, harm.TrackId)
	lu.assertTrue(harm.AssignedBatteryIds:contains(self.provider.BatteryId))
end

function TestPointDefenseActivation:test_harm_preempts_an_existing_aircraft_assignment()
	local aircraft = makeTrack("aircraft-1", { x = 2000, y = 1000, z = 0 })
	aircraft.AssessedAircraftType = C.AssessedAircraftType.FIGHTER
	local harm = makeTrack("harm-1", { x = 1000, y = 1000, z = 0 })
	self.trackStore:add(aircraft)
	self.trackStore:add(harm)
	lu.assertTrue(Medusa.Entities.Battery.assignTrack(self.provider, aircraft, 900, self.trackStore))

	lu.assertTrue(PDS.activateClosestHarm(self.provider, { harm }, 1000, self.doctrine, self.trackStore))
	lu.assertEquals(self.provider.CurrentTargetTrackId, harm.TrackId)
	lu.assertFalse(aircraft.AssignedBatteryIds:contains(self.provider.BatteryId))
	lu.assertTrue(harm.AssignedBatteryIds:contains(self.provider.BatteryId))
end

function TestPointDefenseActivation:test_launcher_aircraft_is_not_an_eligible_harm()
	local launcher = makeTrack("launcher", { x = 1000, y = 1000, z = 0 })
	launcher.AssessedAircraftType = C.AssessedAircraftType.FIGHTER
	launcher.IsSeadThreat = true
	launcher.IsHarmLauncher = true

	lu.assertFalse(PDS.canEngageHarm(self.provider, launcher, self.doctrine))
end

function TestPointDefenseActivation:test_scenario_one_close_defender_can_attempt_harm_inside_minimum_range()
	local protectedPosition = scenario.ProtectedSite.GroupPosition
	local providerPosition = scenario.NearbyPointDefense.GroupPosition
	local provider = makeBattery({
		BatteryId = "scenario-one-provider",
		Position = providerPosition,
		EngagementRangeMax = 12000,
		EngagementRangeMin = 1500,
		PkRangeOptimal = 6000,
		PkRangeSigma = 5000,
	})
	local harm = makeTrack("scenario-one-harm", {
		x = protectedPosition.x + 10000,
		y = 1000,
		z = protectedPosition.z,
	})
	harm.Velocity = { x = -300, y = -30, z = 0 }

	lu.assertTrue(Medusa.Services.HarmDetectionService.computeTrackCPA(harm, provider.Position) < 1500)
	lu.assertTrue(PDS.canEngageHarm(provider, harm, {}))
end
