local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("core.Logger")
require("entities.Entities")
require("entities.Battery")
require("services.Services")
require("services.stores.BatteryStore")
require("services.stores.TrackStore")
require("services.BatteryActivationService")
require("services.SpatialQuery")
require("services.PointDefenseService")
require("services.HarmResponseService")

local AS = Medusa.Constants.ActivationState
local BOS = Medusa.Constants.BatteryOperationalStatus
local C = Medusa.Constants
local LS = Medusa.Constants.TrackLifecycleState
local HRS = Medusa.Services.HarmResponseService

local function setupMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()

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
	local data = {
		NetworkId = "net-1",
		GroupId = 100,
		GroupName = "SAM-1",
		ActivationState = AS.STATE_WARM,
		OperationalStatus = BOS.ACTIVE,
		StateChangeHoldDownSec = 0,
		Position = { x = 0, y = 0, z = 0 },
	}
	if overrides then
		for k, v in pairs(overrides) do
			data[k] = v
		end
	end
	return Medusa.Entities.Battery.new(data)
end

local function makeTrack(overrides)
	local track = {
		TrackId = "track-1",
		TrackIdentification = "HOSTILE",
		LifecycleState = LS.ACTIVE,
		AssessedAircraftType = "HARM",
		Position = { x = 10000, y = 5000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	}
	if overrides then
		for k, v in pairs(overrides) do
			track[k] = v
		end
	end
	return track
end

local function makeMockGeoGrid(batteryStore)
	return {
		queryRadius = function(_, _, _, _)
			local ids = {}
			local all = batteryStore:getAll({})
			for i = 1, #all do
				ids[all[i].BatteryId] = true
			end
			return { BatteryIds = ids }
		end,
	}
end

local function makeStores(batteries, tracks)
	local batteryStore = Medusa.Services.BatteryStore:new()
	for i = 1, #batteries do
		batteryStore:add(batteries[i])
	end
	local trackStore = Medusa.Services.TrackStore:new()
	for i = 1, #tracks do
		trackStore:add(tracks[i])
	end
	local geoGrid = makeMockGeoGrid(batteryStore)
	return batteryStore, trackStore, geoGrid
end

-- == TestIgnoreStrategy ==

TestIgnoreStrategy = {}

function TestIgnoreStrategy:setUp()
	setupMocks()
	self.ulidCounter = 0
	NewULID = function()
		self.ulidCounter = self.ulidCounter + 1
		return string.format("ULID-%d", self.ulidCounter)
	end
end

function TestIgnoreStrategy:test_ignoreReturnsZero()
	local b = makeBattery()
	local t = makeTrack()
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t })
	local doctrine = { HARMResponse = "IGNORE" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 0)
	lu.assertNil(b.HarmShutdownUntil)
end

function TestIgnoreStrategy:test_activeDefensePriorityWithoutPDShutsBatteryDown()
	local b = makeBattery()
	local t = makeTrack()
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t })
	local doctrine = { HARMResponse = "SHUTDOWN_UNLESS_PD" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 1)
end

function TestIgnoreStrategy:test_activeDefensePriorityWithPDSkipsShutdown()
	local pdBattery = makeBattery({
		GroupId = 200,
		GroupName = "PD-1",
		IsPointDefense = true,
		HarmCapableUnitCount = 4,
		TotalAmmoStatus = 8,
		Position = { x = 100, y = 0, z = 0 },
	})
	local hvaBattery = makeBattery({ PointDefenseProviderId = pdBattery.BatteryId })
	local t = makeTrack()
	local batteryStore, trackStore, geoGrid = makeStores({ hvaBattery, pdBattery }, { t })
	local doctrine = { HARMResponse = "SHUTDOWN_UNLESS_PD" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 0)
	lu.assertNil(hvaBattery.HarmShutdownUntil)
end

function TestIgnoreStrategy:test_pdProviderDestroyedFallsBackToShutdown()
	local pdBattery = makeBattery({
		GroupId = 200,
		GroupName = "PD-1",
		OperationalStatus = BOS.DESTROYED,
		Position = { x = 100, y = 0, z = 0 },
	})
	local hvaBattery = makeBattery({ PointDefenseProviderId = pdBattery.BatteryId })
	local t = makeTrack()
	local batteryStore, trackStore, geoGrid = makeStores({ hvaBattery, pdBattery }, { t })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 1)
	lu.assertNotNil(hvaBattery.HarmShutdownUntil)
end

function TestIgnoreStrategy:test_pdProviderAmmoDepletedFallsBackToShutdown()
	local pdBattery = makeBattery({
		GroupId = 200,
		GroupName = "PD-1",
		IsPointDefense = true,
		HarmCapableUnitCount = 4,
		TotalAmmoStatus = 0,
		Position = { x = 100, y = 0, z = 0 },
	})
	local hvaBattery = makeBattery({ PointDefenseProviderId = pdBattery.BatteryId })
	local t = makeTrack()
	local batteryStore, trackStore, geoGrid = makeStores({ hvaBattery, pdBattery }, { t })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 1)
	lu.assertNotNil(hvaBattery.HarmShutdownUntil)
end

-- == TestLocalizedShutdown ==

TestLocalizedShutdown = {}

function TestLocalizedShutdown:setUp()
	setupMocks()
	self.ulidCounter = 0
	NewULID = function()
		self.ulidCounter = self.ulidCounter + 1
		return string.format("ULID-%d", self.ulidCounter)
	end
end

function TestLocalizedShutdown:test_shutsDownClosestBatteryInPath()
	local b = makeBattery({ Position = { x = 0, y = 0, z = 0 } })
	local t = makeTrack({
		Position = { x = 10000, y = 5000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 1)
	lu.assertEquals(b.ActivationState, AS.STATE_COLD)
	lu.assertNotNil(b.HarmShutdownUntil)
end

function TestLocalizedShutdown:test_skipsDestroyedBattery()
	local b = makeBattery({ OperationalStatus = BOS.DESTROYED })
	local t = makeTrack({
		Position = { x = 10000, y = 5000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 0)
end

function TestLocalizedShutdown:test_skipsInoperativeBattery()
	local b = makeBattery({ OperationalStatus = BOS.INOPERATIVE })
	local t = makeTrack({
		Position = { x = 10000, y = 5000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 0)
end

function TestLocalizedShutdown:test_skipsBatteryAlreadyInShutdown()
	local b = makeBattery({ Position = { x = 0, y = 0, z = 0 } })
	b.HarmShutdownUntil = 200
	local t = makeTrack({
		Position = { x = 10000, y = 5000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 0)
end

function TestLocalizedShutdown:test_skipsBatteryBehindArm()
	local b = makeBattery({ Position = { x = 20000, y = 0, z = 0 } })
	local t = makeTrack({
		Position = { x = 10000, y = 5000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 0)
end

function TestLocalizedShutdown:test_skipsBatteryOutsideThreatRadius()
	local b = makeBattery({ Position = { x = 0, y = 0, z = 0 } })
	local t = makeTrack({
		Position = { x = 100000, y = 5000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE", HARMShutdownM = 5000 }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 0)
end

function TestLocalizedShutdown:test_picksSmallestCpaBatteryWhenTwoInPath()
	-- HARM diving from (10000,5000,0) toward x=-inf: bOnTrack is directly in path (CPA~0),
	-- bOffset is off to the side (larger CPA). CPA-based selection picks bOnTrack.
	local bOffset = makeBattery({ Position = { x = 0, y = 0, z = 5000 }, GroupName = "SAM-1", GroupId = 101 })
	local bOnTrack = makeBattery({ Position = { x = 5000, y = 0, z = 0 }, GroupName = "SAM-2", GroupId = 102 })
	local t = makeTrack({
		Position = { x = 10000, y = 5000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	local batteryStore, trackStore, geoGrid = makeStores({ bOffset, bOnTrack }, { t })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 1)
	lu.assertNotNil(bOnTrack.HarmShutdownUntil)
	lu.assertNil(bOffset.HarmShutdownUntil)
end

function TestLocalizedShutdown:test_skipsNonHarmTrack()
	local b = makeBattery({ Position = { x = 0, y = 0, z = 0 } })
	local t = makeTrack({ AssessedAircraftType = "FIGHTER" })
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 0)
end

function TestLocalizedShutdown:test_skipsStaleTrack()
	local b = makeBattery({ Position = { x = 0, y = 0, z = 0 } })
	local t = makeTrack({ LifecycleState = LS.STALE })
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 0)
end

function TestLocalizedShutdown:test_alreadyColdBatterySetsFlag()
	local b = makeBattery({
		ActivationState = AS.STATE_COLD,
		Position = { x = 0, y = 0, z = 0 },
	})
	local t = makeTrack({
		Position = { x = 10000, y = 5000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 1)
	lu.assertEquals(b.ActivationState, AS.STATE_COLD)
	lu.assertNotNil(b.HarmShutdownUntil)
end

function TestLocalizedShutdown:test_defaultStrategyIsLocalizedShutdown()
	local b = makeBattery({ Position = { x = 0, y = 0, z = 0 } })
	local t = makeTrack({
		Position = { x = 10000, y = 5000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t })
	local doctrine = {}
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 1)
end

function TestLocalizedShutdown:test_noVelocityFallbackTTI()
	local b = makeBattery({ Position = { x = 0, y = 0, z = 0 } })
	local t = makeTrack({
		Position = { x = 5000, y = 5000, z = 0 },
		Velocity = nil,
		SmoothedVelocity = { x = -300, y = -50, z = 0 },
	})
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 1)
end

function TestLocalizedShutdown:test_skipsBatteryWithNoPosition()
	local b = makeBattery({ Position = nil })
	b.Position = nil
	local t = makeTrack({
		Position = { x = 10000, y = 5000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 0)
end

-- == TestShutdownTiming ==

TestShutdownTiming = {}

function TestShutdownTiming:setUp()
	setupMocks()
	self.ulidCounter = 0
	NewULID = function()
		self.ulidCounter = self.ulidCounter + 1
		return string.format("ULID-%d", self.ulidCounter)
	end
end

function TestShutdownTiming:test_shutdownUntilIncludesSafetyMargin()
	local b = makeBattery({ Position = { x = 0, y = 0, z = 0 } })
	local t = makeTrack({
		Position = { x = 3000, y = 5000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t })
	local now = 100
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	HRS.executeResponse(trackStore, batteryStore, doctrine, now, geoGrid)
	lu.assertNotNil(b.HarmShutdownUntil)
	lu.assertTrue(b.HarmShutdownUntil > now + C.HARM_SHUTDOWN_SAFETY_MARGIN_SEC)
end

function TestShutdownTiming:test_shutdownUntilUsesSmoothedVelocity()
	local b = makeBattery({ Position = { x = 0, y = 0, z = 0 } })
	local t = makeTrack({
		Position = { x = 3000, y = 5000, z = 0 },
		Velocity = { x = -100, y = -10, z = 0 },
		SmoothedVelocity = { x = -600, y = -50, z = 0 },
	})
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t })
	local now = 100
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	HRS.executeResponse(trackStore, batteryStore, doctrine, now, geoGrid)
	lu.assertNotNil(b.HarmShutdownUntil)
	lu.assertTrue(b.HarmShutdownUntil < now + 30)
end

-- == TestMultipleHarmTracks ==

TestMultipleHarmTracks = {}

function TestMultipleHarmTracks:setUp()
	setupMocks()
	self.ulidCounter = 0
	NewULID = function()
		self.ulidCounter = self.ulidCounter + 1
		return string.format("ULID-%d", self.ulidCounter)
	end
end

function TestMultipleHarmTracks:test_twoTracksShutDownTwoBatteries()
	local b1 = makeBattery({ Position = { x = 0, y = 0, z = 0 }, GroupName = "SAM-1", GroupId = 101 })
	local b2 = makeBattery({ Position = { x = 0, y = 0, z = 5000 }, GroupName = "SAM-2", GroupId = 102 })
	local t1 = makeTrack({
		TrackId = "track-1",
		Position = { x = 10000, y = 5000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	local t2 = makeTrack({
		TrackId = "track-2",
		Position = { x = 10000, y = 5000, z = 5000 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	local batteryStore, trackStore, geoGrid = makeStores({ b1, b2 }, { t1, t2 })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 2)
end

function TestMultipleHarmTracks:test_secondTrackSkipsAlreadyShutdownBattery()
	local b = makeBattery({ Position = { x = 0, y = 0, z = 0 } })
	local t1 = makeTrack({
		TrackId = "track-1",
		Position = { x = 10000, y = 5000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	local t2 = makeTrack({
		TrackId = "track-2",
		Position = { x = 8000, y = 5000, z = 0 },
		Velocity = { x = -300, y = -50, z = 0 },
	})
	local batteryStore, trackStore, geoGrid = makeStores({ b }, { t1, t2 })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	local shutdowns = HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid)
	lu.assertEquals(shutdowns, 1)
end

-- == TestEmptyInputs ==

TestEmptyInputs = {}

function TestEmptyInputs:setUp()
	setupMocks()
	self.ulidCounter = 0
	NewULID = function()
		self.ulidCounter = self.ulidCounter + 1
		return string.format("ULID-%d", self.ulidCounter)
	end
end

function TestEmptyInputs:test_noTracksReturnsZero()
	local b = makeBattery()
	local batteryStore, trackStore, geoGrid = makeStores({ b }, {})
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	lu.assertEquals(HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid), 0)
end

function TestEmptyInputs:test_noBatteriesReturnsZero()
	local t = makeTrack()
	local batteryStore, trackStore, geoGrid = makeStores({}, { t })
	local doctrine = { HARMResponse = "ACTIVE_DEFENSE" }
	lu.assertEquals(HRS.executeResponse(trackStore, batteryStore, doctrine, 100, geoGrid), 0)
end
