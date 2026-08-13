local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Battery")
require("services.Services")
require("services.stores.BatteryStore")
require("services.AssetIndex")
require("services.ManpadService")
require("services.MetricsService")
require("services.BatteryActivationService")
require("core.IadsNetwork")
local ManpadTest = require("manpad_test_support")

-- ============================================================
-- Shared mock infrastructure
-- ============================================================

local _origGetTime
local _origScheduleOnce
local _origCancelSchedule
local _mockTime

local function installMocks()
	_mockTime = 1000
	_origGetTime = GetTime
	_origScheduleOnce = ScheduleOnce
	_origCancelSchedule = CancelSchedule

	GetTime = function()
		return _mockTime
	end
	ScheduleOnce = function(fn, args, delay)
		return "mock-timer"
	end
	CancelSchedule = function(id)
		return true
	end
end

local function restoreMocks()
	GetTime = _origGetTime
	ScheduleOnce = _origScheduleOnce
	CancelSchedule = _origCancelSchedule
end

-- ============================================================
-- Battery / MANPAD builders
-- ============================================================

local _seq = 0
local function nextSeq()
	_seq = _seq + 1
	return _seq
end

local function makeManpadBattery(overrides)
	local id = nextSeq()
	local bat = {
		BatteryId = string.format("mpbat-%d", id),
		GroupId = id * 100,
		GroupName = string.format("manpad-group-%d", id),
		NetworkId = "test-net",
		Role = Medusa.Constants.BatteryRole.MANPAD,
		Units = {},
		MissileInFlightUntil = nil,
		ShotsFired = 0,
		LastShotTime = nil,
		TotalAmmoStatus = 2,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
		AmmoDepletedBehavior = Medusa.Constants.BatteryOperationalStatus.REARMING,
		Manpad = {
			SleepWakeState = "ASLEEP",
			WakeReason = "NONE",
			WakeTimerId = nil,
			AlertCycleCount = 0,
			LastAlertedTime = nil,
			AudioCueRangeM = 3000,
			HotUntil = nil,
			CooldownUntil = nil,
			AlertStartTime = nil,
			UnitHeadings = {},
			UnitHeadingCount = 0,
		},
	}
	return ManpadTest.applyManpadOverrides(bat, overrides)
end

local function makeRegularBattery(overrides)
	local id = nextSeq()
	local bat = Medusa.Entities.Battery.new({
		NetworkId = "test-net",
		GroupId = id * 100,
		GroupName = string.format("sa6-group-%d", id),
	})
	bat.Units = {}
	if overrides then
		for k, v in pairs(overrides) do
			bat[k] = v
		end
	end
	return bat
end

local function makeUnit(unitId, role, weaponTypeName)
	return Medusa.Entities.Battery.newUnit({
		UnitId = unitId,
		UnitName = string.format("unit-%d", unitId),
		Roles = { role },
		AmmoCount = 2,
		AmmoTypes = {
			{
				WeaponTypeName = weaponTypeName,
				Count = 2,
				RangeMax = 5000,
			},
		},
	})
end

-- ============================================================
-- Minimal IadsNetwork fixture
-- ============================================================

local COAL_RED = (coalition and coalition.side and coalition.side.RED) or 1

local function makeIads()
	local iads = Medusa.Core.IadsNetwork:new({
		id = "T",
		coalitionId = COAL_RED,
		prefix = "iads",
	})
	iads:initialize()
	iads._running = true
	return iads
end

local function injectManpad(iads, unitIds, sleepWakeState)
	local manpadStore = iads:getAssetIndex():manpads()
	local bat = makeManpadBattery({
		Manpad = { SleepWakeState = sleepWakeState or "HOT" },
	})
	bat.Units = {}
	for i, uid in ipairs(unitIds) do
		local u = makeUnit(uid, Medusa.Constants.BatteryUnitRole.MANPAD, "SA-18 Grouse")
		table.insert(bat.Units, u)
	end
	Medusa.Entities.Battery.recomputeState(bat)
	manpadStore:add(bat)
	return bat
end

local function injectBattery(iads, unitIds)
	local batteryStore = iads:getAssetIndex():batteries()
	local bat = makeRegularBattery()
	bat.Role = Medusa.Constants.BatteryRole.SR_SAM
	bat.Units = {}
	bat.ShotsFired = 0
	for i, uid in ipairs(unitIds) do
		local u = makeUnit(uid, Medusa.Constants.BatteryUnitRole.LAUNCHER, "SA-6")
		table.insert(bat.Units, u)
	end
	Medusa.Entities.Battery.recomputeState(bat)
	batteryStore:add(bat)
	return bat
end

-- ============================================================
-- 1. ManpadService.onShot — MANPAD policy hook
-- ============================================================

TestManpadServiceOnShot = {}

function TestManpadServiceOnShot:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
end

function TestManpadServiceOnShot:tearDown()
	restoreMocks()
end

function TestManpadServiceOnShot:test_onShot_doesNotOwnSharedBatteryFields()
	local bat = makeManpadBattery({ Manpad = { SleepWakeState = "ASLEEP" } })
	bat.ShotsFired = 2
	Medusa.Services.ManpadService.onShot(bat, 500)
	lu.assertIsNil(bat.LastShotTime)
	lu.assertIsNil(bat.MissileInFlightUntil)
	lu.assertEquals(bat.ShotsFired, 2)
end

-- HOT state resets HotUntil within [min, max] AND resets AlertStartTime
function TestManpadServiceOnShot:test_onShot_hot_resetsHotSubfields()
	local now = 1000
	local bat = makeManpadBattery({ Manpad = { SleepWakeState = "HOT" } })
	Medusa.Services.ManpadService.onShot(bat, now)
	local C = Medusa.Constants
	lu.assertNotNil(bat.Manpad.HotUntil, "HotUntil must not be nil after onShot while HOT")
	local delta = bat.Manpad.HotUntil - now
	lu.assertTrue(
		delta >= C.Manpad.HOT_MIN_SEC,
		string.format("HotUntil delta (%d) must be >= Manpad.HOT_MIN_SEC", delta)
	)
	lu.assertTrue(
		delta <= C.Manpad.HOT_MAX_SEC,
		string.format("HotUntil delta (%d) must be <= Manpad.HOT_MAX_SEC", delta)
	)
	lu.assertEquals(bat.Manpad.AlertStartTime, now, "AlertStartTime must be set to now when HOT")
end

-- Non-HOT state does NOT touch Manpad sub-table
function TestManpadServiceOnShot:test_onShot_nonHot_manpadSubtableUntouched()
	local bat = makeManpadBattery({ Manpad = { SleepWakeState = "ALERT", HotUntil = 99, AlertStartTime = 55 } })
	Medusa.Services.ManpadService.onShot(bat, 200)
	lu.assertEquals(bat.Manpad.HotUntil, 99, "HotUntil must be unchanged in ALERT")
	lu.assertEquals(bat.Manpad.AlertStartTime, 55, "AlertStartTime must be unchanged in ALERT")
	lu.assertIsNil(bat.LastShotTime)
end

function TestManpadServiceOnShot:test_onShot_winchester_expiresHotState()
	local bat = makeManpadBattery({
		TotalAmmoStatus = 0,
		Manpad = { SleepWakeState = "HOT", HotUntil = 9999 },
	})

	Medusa.Services.ManpadService.onShot(bat, 200)

	lu.assertEquals(bat.Manpad.HotUntil, 200)
end

-- ============================================================
-- 2. IadsNetwork._handleShot MANPAD dispatch
-- ============================================================

TestIadsNetworkHandleShot = {}

local _origGetUnitDesc

function TestIadsNetworkHandleShot:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	_origGetUnitDesc = GetUnitDesc
	GetUnitDesc = function()
		return { attributes = { ["SAM LL"] = true } }
	end
	if Medusa.Services.MetricsService._registry then
		Medusa.Services.MetricsService._registry = {}
	end
end

function TestIadsNetworkHandleShot:tearDown()
	restoreMocks()
	GetUnitDesc = _origGetUnitDesc
end

function TestIadsNetworkHandleShot:test_handleShot_manpad_usesSharedAmmoPathAndPolicyHook()
	local iads = makeIads()
	local bat = injectManpad(iads, { 200 }, "HOT")

	local capturedBattery = nil
	local origOnShot = Medusa.Services.ManpadService.onShot
	Medusa.Services.ManpadService.onShot = function(battery, now)
		capturedBattery = battery
	end

	local decrementCalled = false
	local origDecrement = iads._decrementAmmo
	iads._decrementAmmo = function(...)
		decrementCalled = true
		if origDecrement then
			return origDecrement(...)
		end
	end

	local origInc = Medusa.Services.MetricsService.inc
	Medusa.Services.MetricsService.inc = function() end

	iads:_handleShot(200, "SA-18 Grouse")

	Medusa.Services.ManpadService.onShot = origOnShot
	iads._decrementAmmo = origDecrement
	Medusa.Services.MetricsService.inc = origInc

	lu.assertNotNil(capturedBattery, "ManpadService.onShot must be called for a MANPAD unit")
	lu.assertIs(capturedBattery, bat, "onShot must receive the MANPAD battery record")
	lu.assertTrue(decrementCalled, "MANPAD shots must use shared ammo accounting")
	lu.assertEquals(bat.TotalAmmoStatus, 1)
	lu.assertEquals(bat.ShotsFired, 1)
	lu.assertEquals(bat.LastShotTime, 1000)
	lu.assertEquals(iads._rollingPkCount, 0)
end

-- Regular battery unit shot → ManpadService.onShot NOT called
function TestIadsNetworkHandleShot:test_handleShot_regularBattery_doesNotCallOnShot()
	local iads = makeIads()
	local bat = injectBattery(iads, { 300 })

	local onShotCalled = false
	local origOnShot = Medusa.Services.ManpadService.onShot
	Medusa.Services.ManpadService.onShot = function(...)
		onShotCalled = true
	end

	iads:_handleShot(300, "SA-6")

	Medusa.Services.ManpadService.onShot = origOnShot

	lu.assertFalse(onShotCalled, "ManpadService.onShot must NOT be called for a non-MANPAD unit")
	lu.assertEquals(bat.ShotsFired, 1)
	lu.assertEquals(iads._rollingPkCount, 1)
	lu.assertEquals(iads._rollingPkBuffer[1], 0)
end

function TestIadsNetworkHandleShot:test_handleShot_nonManpadCompanionDoesNotTriggerMissilePolicy()
	local iads = makeIads()
	local store = iads:getAssetIndex():manpads()
	local bat = makeManpadBattery({ Manpad = { SleepWakeState = "HOT", HotUntil = 1400 } })
	bat.Units = {
		makeUnit(310, Medusa.Constants.BatteryUnitRole.MANPAD, "SA-18 Grouse"),
		makeUnit(311, Medusa.Constants.BatteryUnitRole.OTHER, "Rifle"),
	}
	Medusa.Entities.Battery.recomputeState(bat)
	store:add(bat)
	local ammoBefore = bat.TotalAmmoStatus

	iads:_handleShot(311, "Rifle")

	lu.assertEquals(bat.TotalAmmoStatus, ammoBefore)
	lu.assertEquals(bat.ShotsFired, 0)
	lu.assertIsNil(bat.LastShotTime)
	lu.assertIsNil(bat.MissileInFlightUntil)
	lu.assertEquals(bat.Manpad.HotUntil, 1400)
end

function TestIadsNetworkHandleShot:test_handleShot_manpadRifleShotDoesNotConsumeMissile()
	local iads = makeIads()
	local bat = injectManpad(iads, { 312 }, "HOT")
	local ammoBefore = bat.TotalAmmoStatus

	iads:_handleShot(312, "Rifle")

	lu.assertEquals(bat.TotalAmmoStatus, ammoBefore)
	lu.assertEquals(bat.ShotsFired, 0)
	lu.assertIsNil(bat.LastShotTime)
	lu.assertIsNil(bat.MissileInFlightUntil)
	lu.assertEquals(iads._rollingPkCount, 0)
end

function TestIadsNetworkHandleShot:test_manpad_winchester_rearms_and_returns_alert()
	local iads = makeIads()
	local bat = injectManpad(iads, { 301 }, "HOT")
	local unit = bat.Units[1]
	unit.AmmoCount = 1
	unit.AmmoTypes[1].Count = 1
	Medusa.Entities.Battery.recomputeState(bat)

	local originalInc = Medusa.Services.MetricsService.inc
	local originalGetUnitAmmo = GetUnitAmmo
	local originalGoCold = Medusa.Services.BatteryActivationService.goCold
	local winchesterCount = 0
	Medusa.Services.MetricsService.inc = function(metricName)
		if metricName == "medusa_manpad_winchester_total" then
			winchesterCount = winchesterCount + 1
		end
	end

	local ok, err = pcall(function()
		iads:_handleShot(301, "SA-18 Grouse")
		lu.assertEquals(bat.TotalAmmoStatus, 0)
		lu.assertEquals(bat.OperationalStatus, Medusa.Constants.BatteryOperationalStatus.REARMING)
		lu.assertEquals(bat.Manpad.HotUntil, 1000)
		lu.assertEquals(bat.RearmCheckTime, 1000 + Medusa.Constants.REARM_CHECK_INTERVAL_SEC)

		GetUnitAmmo = function(unitName)
			return {
				{
					count = 2,
					desc = {
						typeName = "SA-18 Grouse",
						displayName = "SA-18 Grouse",
						missileCategory = 1,
						rangeMaxAltMax = 5000,
						rangeMaxAltMin = 5000,
						rangeMin = 100,
						altMax = 3500,
						altMin = 0,
						Nmax = 8,
					},
				},
			}
		end
		Medusa.Services.BatteryActivationService.goCold = function()
			return true
		end
		iads:_checkRearming(bat.RearmCheckTime)
	end)

	Medusa.Services.MetricsService.inc = originalInc
	GetUnitAmmo = originalGetUnitAmmo
	Medusa.Services.BatteryActivationService.goCold = originalGoCold

	lu.assertTrue(ok, tostring(err))
	lu.assertEquals(winchesterCount, 1)
	lu.assertEquals(bat.TotalAmmoStatus, 2)
	lu.assertEquals(bat.Manpad.SleepWakeState, Medusa.Constants.Manpad.SleepWakeState.ALERT)
	lu.assertIsNil(bat.RearmCheckTime)
end

function TestIadsNetworkHandleShot:test_manpad_gunAmmoDoesNotCompleteRearm()
	local iads = makeIads()
	local bat = injectManpad(iads, { 302 }, "HOT")
	local unit = bat.Units[1]
	unit.AmmoCount = 0
	unit.AmmoTypes[1].Count = 0
	Medusa.Entities.Battery.recomputeState(bat)
	bat.RearmCheckTime = 1000

	local originalGetUnitAmmo = GetUnitAmmo
	GetUnitAmmo = function()
		return {
			{
				count = 30,
				desc = {
					typeName = "Rifle",
					displayName = "Rifle",
					rangeMaxAltMax = 500,
					rangeMaxAltMin = 500,
				},
			},
		}
	end

	iads:_checkRearming(1000)
	GetUnitAmmo = originalGetUnitAmmo

	lu.assertEquals(bat.TotalAmmoStatus, 0)
	lu.assertEquals(bat.OperationalStatus, Medusa.Constants.BatteryOperationalStatus.REARMING)
	lu.assertEquals(bat.RearmCheckTime, 1000 + Medusa.Constants.REARM_CHECK_INTERVAL_SEC)
end

function TestIadsNetworkHandleShot:test_manpadKillDoesNotCompleteRegularBatteryShot()
	local iads = makeIads()
	injectBattery(iads, { 320 })
	injectManpad(iads, { 321 }, "HOT")
	iads:_handleShot(320, "SA-6")

	iads._killQueue:enqueue({ _unitId = 321 })
	iads:_processKillEvents(1)

	lu.assertEquals(iads._rollingPkCount, 1)
	lu.assertEquals(iads._rollingPkBuffer[1], 0)

	iads._killQueue:enqueue({ _unitId = 320 })
	iads:_processKillEvents(1)

	lu.assertEquals(iads._rollingPkBuffer[1], 1)
end

-- ============================================================
-- 3. IadsNetwork._handleUnitDeath MANPAD guard
-- ============================================================

TestIadsNetworkHandleUnitDeathManpad = {}

function TestIadsNetworkHandleUnitDeathManpad:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	_origGetUnitDesc = GetUnitDesc
	GetUnitDesc = function()
		return { attributes = { ["SAM LL"] = true } }
	end
end

function TestIadsNetworkHandleUnitDeathManpad:tearDown()
	restoreMocks()
	GetUnitDesc = _origGetUnitDesc
end

-- MANPAD unit dies, team still has remaining soldiers → unit removed from roster, manpad stays
function TestIadsNetworkHandleUnitDeathManpad:test_death_manpad_oneOfThree_manpadStaysInStore()
	local iads = makeIads()
	local bat = injectManpad(iads, { 210, 211, 212 }, "HOT")
	local manpadStore = iads:getAssetIndex():manpads()

	iads._deathQueue:enqueue({
		_unitId = 210,
		initiator = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
	iads:_processDeathEvents(2)

	lu.assertEquals(#bat.Units, 2, "2 units must remain after 1-of-3 soldier death")
	lu.assertEquals(manpadStore:count(), 1, "MANPAD must stay in store when soldiers remain")
end

-- Full MANPAD team dies → manpad removed from stores.manpads AND from GeoGrid
function TestIadsNetworkHandleUnitDeathManpad:test_death_manpad_lastSoldier_removedFromStoreAndGrid()
	local iads = makeIads()
	local bat = injectManpad(iads, { 220 }, "ALERT")
	local manpadStore = iads:getAssetIndex():manpads()

	local removedId = nil
	local origGeoGrid = iads._geoGrid
	iads._geoGrid = {
		remove = function(self, id)
			removedId = id
		end,
		add = function() end,
		queryRadius = function()
			return {}
		end,
	}

	iads._deathQueue:enqueue({
		_unitId = 220,
		initiator = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
	iads:_processDeathEvents(2)

	iads._geoGrid = origGeoGrid

	lu.assertEquals(manpadStore:count(), 0, "MANPAD view must be empty after last soldier dies")
	lu.assertNotNil(removedId, "geoGrid:remove must be called when last MANPAD soldier dies")
	lu.assertEquals(removedId, bat.BatteryId, "geoGrid:remove must be called with the MANPAD's BatteryId")
end

-- ============================================================
-- 4. Repository unit index
-- ============================================================

TestIadsNetworkRepositoryUnitIndex = {}

function TestIadsNetworkRepositoryUnitIndex:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	_origGetUnitDesc = GetUnitDesc
	GetUnitDesc = function()
		return { attributes = { ["SAM LL"] = true } }
	end
end

function TestIadsNetworkRepositoryUnitIndex:tearDown()
	restoreMocks()
	GetUnitDesc = _origGetUnitDesc
end

function TestIadsNetworkRepositoryUnitIndex:test_manpadUnits_areIndexedOnAdd()
	local iads = makeIads()
	local manpadStore = iads:getAssetIndex():manpads()
	local repository = iads:getAssetIndex():batteryRepository()

	local bat = makeManpadBattery()
	bat.Units = {
		makeUnit(200, Medusa.Constants.BatteryUnitRole.MANPAD, "SA-18 Grouse"),
		makeUnit(201, Medusa.Constants.BatteryUnitRole.MANPAD, "SA-18 Grouse"),
	}
	manpadStore:add(bat)

	local firstBattery, firstUnit = repository:getByUnitId(200)
	local secondBattery, secondUnit = repository:getByUnitId(201)

	lu.assertIs(firstBattery, bat)
	lu.assertEquals(firstUnit.UnitId, 200)
	lu.assertIs(secondBattery, bat)
	lu.assertEquals(secondUnit.UnitId, 201)
end

TestIadsNetworkManpadAssignmentCue = {}

function TestIadsNetworkManpadAssignmentCue:test_every_target_assignment_cues_manpads()
	local iads = makeIads()
	local TargetAssigner = Medusa.Services.TargetAssigner
	local ManpadService = Medusa.Services.ManpadService
	local originalEmconSelfAssign = TargetAssigner.emconSelfAssign
	local originalAssignTargets = TargetAssigner.assignTargets
	local originalCue = ManpadService.cueFromIADS
	local cues = {}

	TargetAssigner.emconSelfAssign = function()
		return {}
	end
	TargetAssigner.assignTargets = function()
		return {
			{ batteryId = "sead-battery", trackId = "sead-track" },
			{ batteryId = "greedy-battery", trackId = "greedy-track" },
		}
	end
	ManpadService.cueFromIADS = function(ctx, position)
		cues[#cues + 1] = position
	end

	local tracks = {
		["sead-track"] = { Position = { x = 1, y = 2, z = 3 } },
		["greedy-track"] = { Position = { x = 4, y = 5, z = 6 } },
	}
	local ok, err = pcall(function()
		iads:_phaseAssign({
			now = 50,
			trackStore = {
				get = function(self, trackId)
					return tracks[trackId]
				end,
			},
			batteryStore = iads:getAssetIndex():batteries(),
			manpadStore = iads:getAssetIndex():manpads(),
			hpt = function()
				return 0
			end,
			MS = {
				observe = function() end,
				inc = function() end,
			},
		})
	end)

	TargetAssigner.emconSelfAssign = originalEmconSelfAssign
	TargetAssigner.assignTargets = originalAssignTargets
	ManpadService.cueFromIADS = originalCue

	lu.assertTrue(ok, tostring(err))
	lu.assertEquals(#cues, 2)
	lu.assertIs(cues[1], tracks["sead-track"].Position)
	lu.assertIs(cues[2], tracks["greedy-track"].Position)
end
