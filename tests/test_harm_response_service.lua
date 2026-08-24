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
require("services.HarmResponseService")

local AS = Medusa.Constants.ActivationState
local BOS = Medusa.Constants.BatteryOperationalStatus
local BR = Medusa.Constants.BatteryRole
local C = Medusa.Constants
local HDS = Medusa.Constants.HarmDefenseState
local HRS = Medusa.Services.HarmResponseService
local LS = Medusa.Constants.TrackLifecycleState

local sequence = 0

local function setupMocks()
	sequence = 0
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	GetTime = function()
		return 100
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
	local data = {
		BatteryId = "battery-" .. tostring(sequence + 1),
		NetworkId = "net-1",
		GroupId = sequence + 1,
		GroupName = "battery-" .. tostring(sequence + 1),
		Role = BR.LR_SAM,
		ActivationState = AS.STATE_WARM,
		OperationalStatus = BOS.ACTIVE,
		StateChangeHoldDownSec = 0,
		Position = { x = 0, y = 0, z = 0 },
		WeaponRangeMax = 30000,
		EngagementRangeMax = 30000,
		EngagementRangeMin = 0,
		EngagementAltitudeMin = 0,
		EngagementAltitudeMax = 30000,
		PkRangeOptimal = 15000,
		PkRangeSigma = 30000,
		HarmDefenseCapacity = 0,
		TotalAmmoStatus = 8,
		AmmoKnown = true,
		PartitionKey = "partition-a",
		CoordinationState = C.CoordinationState.COORDINATED,
	}
	for key, value in pairs(overrides or {}) do
		data[key] = value
	end
	sequence = sequence + 1
	return Medusa.Entities.Battery.new(data)
end

local function makeHarm(id, x, z, partition)
	return Medusa.Entities.Track.new({
		TrackId = id,
		NetworkId = "net-1",
		PartitionKey = partition or "partition-a",
		Position = { x = x or 10000, y = 1000, z = z or 0 },
		Velocity = { x = -300, y = -10, z = 0 },
		LifecycleState = LS.ACTIVE,
		TrackIdentification = "HOSTILE",
		AssessedAircraftType = C.AssessedAircraftType.HARM,
	})
end

local function makeContext(batteries, tracks, doctrine)
	local batteryStore = Medusa.Services.BatteryStore:new()
	local trackStore = Medusa.Services.TrackStore:new()
	local grid = GeoGrid(10000, { "Battery", "Track" })
	for i = 1, #batteries do
		batteryStore:add(batteries[i])
		grid:add("Battery", batteries[i].BatteryId, batteries[i].Position)
	end
	for i = 1, #tracks do
		trackStore:add(tracks[i])
		grid:add("Track", tracks[i].TrackId, tracks[i].Position)
	end
	return {
		batteryStore = batteryStore,
		trackStore = trackStore,
		geoGrid = grid,
		doctrine = doctrine,
		now = 100,
	}
end

TestHarmResponseCapacity = {}

function TestHarmResponseCapacity:setUp()
	setupMocks()
end

function TestHarmResponseCapacity:test_ignore_clears_prior_claim_without_commanding_battery()
	local battery = makeBattery({ HarmDefenseCapacity = 4, HarmDefenseState = HDS.SELF_DEFENDING })
	local ctx = makeContext({ battery }, { makeHarm("harm-1") }, { HARMResponse = C.HarmResponseStrategy.IGNORE })

	lu.assertEquals(HRS.executeResponse(ctx), 0)
	lu.assertNil(battery.HarmDefenseState)
	lu.assertNil(battery.HarmShutdownUntil)
end

function TestHarmResponseCapacity:test_available_capacity_must_strictly_exceed_threats_before_attempt()
	local battery = makeBattery({ HarmDefenseCapacity = 2 })
	local first = makeHarm("harm-1", 10000, -200)
	local second = makeHarm("harm-2", 10000, 200)
	local readinessCalls = 0
	ControllerSetROE = function()
		readinessCalls = readinessCalls + 1
		return true
	end
	local ctx = makeContext(
		{ battery },
		{ first, second },
		{ HARMResponse = C.HarmResponseStrategy.AUTO_DEFENSE, HARMShutdownM = 5000 }
	)

	lu.assertEquals(HRS.executeResponse(ctx), 1)
	lu.assertEquals(battery.HarmDefenseAvailableCapacity, 2)
	lu.assertEquals(battery.HarmDefenseCommittedCapacity, 0)
	lu.assertEquals(battery.HarmDefenseThreats, 2)
	lu.assertEquals(readinessCalls, 1)
	lu.assertEquals(battery.HarmDefenseState, HDS.SUPPRESSED)
end

function TestHarmResponseCapacity:test_success_requires_committed_hot_assigned_capacity()
	local battery = makeBattery({ HarmDefenseCapacity = 4 })
	local harm = makeHarm("harm-1")
	local ctx = makeContext(
		{ battery },
		{ harm },
		{ HARMResponse = C.HarmResponseStrategy.AUTO_DEFENSE, HARMShutdownM = 5000 }
	)

	lu.assertEquals(HRS.executeResponse(ctx), 0)
	lu.assertEquals(battery.HarmDefenseAvailableCapacity, 4)
	lu.assertEquals(battery.HarmDefenseCommittedCapacity, 4)
	lu.assertEquals(battery.CurrentTargetTrackId, harm.TrackId)
	lu.assertEquals(battery.ActivationState, AS.STATE_HOT)
	lu.assertEquals(battery.HarmDefenseState, HDS.INTERCEPTING)
end

function TestHarmResponseCapacity:test_failed_hot_attempt_rolls_back_assignment_and_shuts_down()
	local battery = makeBattery({ HarmDefenseCapacity = 4 })
	local harm = makeHarm("harm-1")
	local firstRoeCall = true
	ControllerSetROE = function()
		if firstRoeCall then
			firstRoeCall = false
			return false
		end
		return true
	end
	local ctx = makeContext(
		{ battery },
		{ harm },
		{ HARMResponse = C.HarmResponseStrategy.AUTO_DEFENSE, HARMShutdownM = 5000 }
	)

	lu.assertEquals(HRS.executeResponse(ctx), 1)
	lu.assertEquals(battery.HarmDefenseAvailableCapacity, 4)
	lu.assertEquals(battery.HarmDefenseCommittedCapacity, 0)
	lu.assertNil(battery.CurrentTargetTrackId)
	lu.assertFalse(harm.AssignedBatteryIds:contains(battery.BatteryId))
	lu.assertEquals(battery.HarmDefenseState, HDS.SUPPRESSED)
end

function TestHarmResponseCapacity:test_partial_point_defense_commitment_below_threshold_shuts_site_down()
	local protected = makeBattery({ BatteryId = "protected", GroupName = "protected", HarmDefenseCapacity = 0 })
	local firstProvider = makeBattery({
		BatteryId = "provider-a",
		GroupName = "provider-a",
		Role = BR.SR_SAM,
		Position = { x = 100, y = 0, z = 0 },
		HarmDefenseCapacity = 1.5,
	})
	local secondProvider = makeBattery({
		BatteryId = "provider-b",
		GroupName = "provider-b",
		Role = BR.SR_SAM,
		Position = { x = -100, y = 0, z = 0 },
		HarmDefenseCapacity = 1.5,
	})
	local first = makeHarm("harm-1", 10000, -200)
	local second = makeHarm("harm-2", 10000, 200)
	ControllerSetROE = function(controller)
		return controller.name ~= "provider-b"
	end
	local ctx = makeContext(
		{ protected, firstProvider, secondProvider },
		{ first, second },
		{ HARMResponse = C.HarmResponseStrategy.AUTO_DEFENSE, HARMShutdownM = 5000 }
	)

	lu.assertEquals(HRS.executeResponse(ctx), 1)
	lu.assertEquals(protected.HarmDefenseAvailableCapacity, 3)
	lu.assertEquals(protected.HarmDefenseCommittedCapacity, 1.5)
	lu.assertNil(secondProvider.CurrentTargetTrackId)
	lu.assertEquals(protected.HarmDefenseState, HDS.SUPPRESSED)
end

function TestHarmResponseCapacity:test_viable_proximity_point_defense_can_keep_site_active()
	local protected = makeBattery({ BatteryId = "protected", GroupName = "protected", HarmDefenseCapacity = 0 })
	local provider = makeBattery({
		BatteryId = "provider",
		GroupName = "provider",
		Role = BR.SR_SAM,
		Position = { x = 100, y = 0, z = 0 },
		HarmDefenseCapacity = 4,
	})
	local harm = makeHarm("harm-1")
	local ctx = makeContext(
		{ protected, provider },
		{ harm },
		{ HARMResponse = C.HarmResponseStrategy.SHUTDOWN_UNLESS_PD, HARMShutdownM = 5000 }
	)

	lu.assertEquals(HRS.executeResponse(ctx), 0)
	lu.assertTrue(provider.IsPointDefense)
	lu.assertEquals(provider.CurrentTargetTrackId, harm.TrackId)
	lu.assertEquals(protected.HarmDefenseAvailableCapacity, 4)
	lu.assertEquals(protected.HarmDefenseCommittedCapacity, 4)
	lu.assertEquals(protected.HarmDefenseState, HDS.PD_PROTECTED)
end

function TestHarmResponseCapacity:test_unknown_ammo_and_cross_partition_capacity_are_excluded()
	local protected = makeBattery({ BatteryId = "protected", HarmDefenseCapacity = 0 })
	local unknown = makeBattery({
		BatteryId = "unknown",
		Role = BR.SR_SAM,
		Position = { x = 100, y = 0, z = 0 },
		HarmDefenseCapacity = 8,
		AmmoKnown = false,
	})
	local crossPartition = makeBattery({
		BatteryId = "cross",
		Role = BR.SR_SAM,
		Position = { x = 200, y = 0, z = 0 },
		HarmDefenseCapacity = 8,
		PartitionKey = "partition-b",
	})
	local ctx = makeContext(
		{ protected, unknown, crossPartition },
		{ makeHarm("harm-1") },
		{ HARMResponse = C.HarmResponseStrategy.AUTO_DEFENSE, HARMShutdownM = 5000 }
	)

	lu.assertEquals(HRS.executeResponse(ctx), 1)
	lu.assertEquals(protected.HarmDefenseAvailableCapacity, 0)
	lu.assertEquals(protected.HarmDefenseCommittedCapacity, 0)
end

function TestHarmResponseCapacity:test_inferred_launcher_is_not_counted_as_a_harm()
	local battery = makeBattery({ HarmDefenseCapacity = 4 })
	local launcher = makeHarm("launcher")
	launcher.AssessedAircraftType = C.AssessedAircraftType.FIGHTER
	launcher.IsSeadThreat = true
	launcher.IsHarmLauncher = true
	local ctx = makeContext(
		{ battery },
		{ launcher },
		{ HARMResponse = C.HarmResponseStrategy.AUTO_DEFENSE, HARMShutdownM = 5000 }
	)

	lu.assertEquals(HRS.executeResponse(ctx), 0)
	lu.assertEquals(battery.HarmDefenseThreats, 0)
	lu.assertNil(battery.HarmDefenseState)
end
