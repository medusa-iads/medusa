local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("services.Services")
require("services.stores.BatteryStore")
require("services.BatteryActivationService")
require("services.ManpadService")
local ManpadTest = require("manpad_test_support")

-- ============================================================
-- Harness-signature verification (documented above tests)
-- ScheduleOnce(fn, args, delaySec) -> timerId
-- CancelSchedule(timerId) -> boolean
-- GetTime() -> number (no args, never nil)
-- ============================================================

-- ============================================================
-- Module-level mocks
-- ============================================================

local _origGoCold
local timerHarness = ManpadTest.newTimerHarness()

local function installMocks()
	timerHarness:install()
end

local function restoreMocks()
	timerHarness:restore()
end

local function saveGoCold()
	_origGoCold = Medusa.Services.BatteryActivationService.goCold
end

local function restoreGoCold()
	Medusa.Services.BatteryActivationService.goCold = _origGoCold
end

-- ============================================================
-- Battery builder
-- ============================================================

local _batterySeq = 0
local newManpadView = ManpadTest.newManpadView

local function makeManpadBattery(overrides)
	_batterySeq = _batterySeq + 1
	local bat = {
		BatteryId = string.format("bat-%d", _batterySeq),
		GroupId = _batterySeq * 100,
		GroupName = string.format("manpad-group-%d", _batterySeq),
		NetworkId = "test-network",
		Role = Medusa.Constants.BatteryRole.MANPAD,
		Position = { x = 0, y = 0, z = 0 },
		TotalAmmoStatus = 1,
		MissileInFlightUntil = nil,
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

local makeGeoGrid = ManpadTest.makeQueryGeoGrid

local function makeTrackStore()
	return {}
end

local function makeNetwork(id, manpadStore, geoGrid)
	local store = manpadStore or newManpadView()
	local grid = geoGrid or makeGeoGrid({})
	return {
		_id = id or "test-network",
		_geoGrid = grid,
		_assetIndex = {
			manpads = function(self)
				return store
			end,
		},
		_store = store,
		_ctx = { manpadStore = store, geoGrid = grid },
	}
end

local evaluateSingle = ManpadTest.evaluateSingle

TestManpadAudioCueRange = {}

function TestManpadAudioCueRange:setUp()
	self.originalRandom = math.random
end

function TestManpadAudioCueRange:tearDown()
	math.random = self.originalRandom
end

function TestManpadAudioCueRange:test_zeroRandomDrawReturnsZeroRange()
	math.random = function()
		return 0
	end
	lu.assertEquals(Medusa.Services.ManpadService.sampleAudioCueRange(), 0)
end

TestManpadFireReadiness = {}

function TestManpadFireReadiness:test_requiresHotActivationOperationalStateAndAmmo()
	local C = Medusa.Constants
	lu.assertFalse(Medusa.Services.ManpadService.canFire({}))
	local bat = makeManpadBattery({
		ActivationState = C.ActivationState.STATE_HOT,
		OperationalStatus = C.BatteryOperationalStatus.ACTIVE,
		TotalAmmoStatus = 1,
		Manpad = { SleepWakeState = C.Manpad.SleepWakeState.HOT },
	})

	lu.assertTrue(Medusa.Services.ManpadService.canFire(bat))
	bat.TotalAmmoStatus = 0
	lu.assertFalse(Medusa.Services.ManpadService.canFire(bat))
	bat.TotalAmmoStatus = 1
	bat.OperationalStatus = C.BatteryOperationalStatus.REARMING
	lu.assertFalse(Medusa.Services.ManpadService.canFire(bat))
	bat.OperationalStatus = C.BatteryOperationalStatus.ACTIVE
	bat.ActivationState = C.ActivationState.STATE_COLD
	lu.assertFalse(Medusa.Services.ManpadService.canFire(bat))
	bat.ActivationState = C.ActivationState.STATE_HOT
	bat.Manpad.SleepWakeState = C.Manpad.SleepWakeState.ALERT
	lu.assertFalse(Medusa.Services.ManpadService.canFire(bat))
end

-- ============================================================
-- 1. HOT → COOLDOWN state transitions
-- ============================================================

TestManpadHotToCooldown = {}

function TestManpadHotToCooldown:setUp()
	installMocks()
	saveGoCold()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	Medusa.Services.BatteryActivationService.goCold = function(battery, now, trackStore)
		return true
	end
end

function TestManpadHotToCooldown:tearDown()
	restoreGoCold()
	restoreMocks()
end

-- Normal: HotUntil expired, no missile in flight → HOT → COOLDOWN
function TestManpadHotToCooldown:test_hot_transitionsToCooldown_afterMissileLands()
	local bat = makeManpadBattery({
		MissileInFlightUntil = 300,
		Manpad = { SleepWakeState = "HOT", HotUntil = 100 },
	})

	local goColdCalled = false
	Medusa.Services.BatteryActivationService.goCold = function(battery, now, trackStore)
		goColdCalled = true
		battery.Manpad.SleepWakeState = "COOLDOWN"
		battery.Manpad.HotUntil = nil
		return true
	end

	evaluateSingle(bat, makeTrackStore(), makeGeoGrid({}), 400, "NORMAL")

	lu.assertTrue(goColdCalled, "goCold must be called when now >= MissileInFlightUntil")
	lu.assertEquals(bat.Manpad.SleepWakeState, "COOLDOWN", "state must be COOLDOWN after successful goCold")
	lu.assertIsNil(bat.Manpad.HotUntil, "HotUntil must be cleared after HOT → COOLDOWN transition")
end

-- MissileInFlightUntil in the future blocks HOT → COOLDOWN
function TestManpadHotToCooldown:test_hot_blockedByMissileInFlight()
	local bat = makeManpadBattery({
		MissileInFlightUntil = 300,
		Manpad = { SleepWakeState = "HOT", HotUntil = 100 },
	})

	local goColdCalled = false
	Medusa.Services.BatteryActivationService.goCold = function(...)
		goColdCalled = true
		return true
	end

	evaluateSingle(bat, makeTrackStore(), makeGeoGrid({}), 200, "NORMAL")

	lu.assertEquals(bat.Manpad.SleepWakeState, "HOT", "state must stay HOT when MissileInFlightUntil is in the future")
	lu.assertFalse(goColdCalled, "goCold must NOT be called when missile is still in flight")
end

-- goCold returning false keeps state HOT, no state pollution
function TestManpadHotToCooldown:test_hot_staysHot_whenGoColdReturnsFalse()
	local bat = makeManpadBattery({
		Manpad = { SleepWakeState = "HOT", HotUntil = 100 },
	})
	local origHotUntil = bat.Manpad.HotUntil

	Medusa.Services.BatteryActivationService.goCold = function(battery, now, trackStore)
		return false
	end

	evaluateSingle(bat, makeTrackStore(), makeGeoGrid({}), 200, "NORMAL")

	lu.assertEquals(bat.Manpad.SleepWakeState, "HOT", "state must stay HOT when goCold returns false")
	lu.assertEquals(bat.Manpad.HotUntil, origHotUntil, "HotUntil must be unchanged when goCold returns false")
	lu.assertIsNil(bat.Manpad.CooldownUntil, "CooldownUntil must remain nil when goCold returns false")
end

-- ============================================================
-- 2. COOLDOWN → ALERT state transitions
-- ============================================================

TestManpadCooldownToAlert = {}

function TestManpadCooldownToAlert:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
end

function TestManpadCooldownToAlert:tearDown()
	restoreMocks()
end

-- COOLDOWN expires → ALERT, AlertStartTime set
function TestManpadCooldownToAlert:test_cooldown_transitionsToAlert_and_clearsFields()
	local bat = makeManpadBattery({
		Manpad = {
			SleepWakeState = "COOLDOWN",
			CooldownUntil = 50,
			AlertCycleCount = 2,
			LastAlertedTime = 25,
		},
	})

	evaluateSingle(bat, makeTrackStore(), makeGeoGrid({}), 100, "NORMAL")

	lu.assertEquals(bat.Manpad.SleepWakeState, "ALERT", "state must be ALERT after COOLDOWN expires")
	lu.assertEquals(bat.Manpad.WakeReason, "RECOVERY", "COOLDOWN -> ALERT must retain the recovery reason")
	lu.assertEquals(bat.Manpad.AlertStartTime, 100, "AlertStartTime must be set to now on COOLDOWN → ALERT")
	lu.assertIsNil(bat.Manpad.CooldownUntil, "CooldownUntil must be nil after COOLDOWN → ALERT")
	lu.assertEquals(bat.Manpad.AlertCycleCount, 2)
	lu.assertEquals(bat.Manpad.LastAlertedTime, 25)
end

-- CooldownUntil in the future keeps state COOLDOWN
function TestManpadCooldownToAlert:test_cooldown_staysCooldown_beforeExpiry()
	local bat = makeManpadBattery({
		Manpad = { SleepWakeState = "COOLDOWN", CooldownUntil = 500 },
	})

	evaluateSingle(bat, makeTrackStore(), makeGeoGrid({}), 100, "NORMAL")

	lu.assertEquals(bat.Manpad.SleepWakeState, "COOLDOWN", "state must stay COOLDOWN when now < CooldownUntil")
end

-- ============================================================
-- 3. ALERT → ASLEEP idle transitions
-- ============================================================

TestManpadAlertToAsleep = {}

function TestManpadAlertToAsleep:setUp()
	installMocks()
	self.originalRandom = math.random
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
end

function TestManpadAlertToAsleep:tearDown()
	math.random = self.originalRandom
	restoreMocks()
end

-- Idle timeout with NO nearby tracks → ASLEEP
function TestManpadAlertToAsleep:test_alert_transitionsToAsleep_withEmptyQuery()
	local C = Medusa.Constants
	local now = 1000
	local bat = makeManpadBattery({
		Manpad = {
			SleepWakeState = "ALERT",
			WakeReason = "AUDIO",
			AlertStartTime = now - C.Manpad.ALERT_TIMEOUT_SEC,
		},
	})

	evaluateSingle(bat, makeTrackStore(), makeGeoGrid({}), now, "NORMAL")

	lu.assertEquals(
		bat.Manpad.SleepWakeState,
		"ASLEEP",
		"state must become ASLEEP when idle timeout expires and no tracks nearby"
	)
	lu.assertEquals(bat.Manpad.WakeReason, "NONE", "WakeReason must clear on ALERT -> ASLEEP")
	lu.assertIsNil(bat.Manpad.AlertStartTime, "AlertStartTime must be cleared on ALERT → ASLEEP")
end

function TestManpadAlertToAsleep:test_audioSensitivity_increasesFromNewSample()
	math.random = function()
		return 1
	end
	local C = Medusa.Constants
	local bat = makeManpadBattery({
		Manpad = {
			SleepWakeState = "ALERT",
			AlertCycleCount = 1,
			LastAlertedTime = 10,
			AudioCueRangeM = 2000,
			AlertStartTime = 0,
		},
	})
	evaluateSingle(bat, makeTrackStore(), makeGeoGrid({}), C.Manpad.ALERT_TIMEOUT_SEC, "NORMAL")
	lu.assertEquals(bat.Manpad.SleepWakeState, "ASLEEP")
	lu.assertEquals(bat.Manpad.AudioCueRangeM, C.Manpad.AUDIO_RANGE_MAX_M)
end

function TestManpadAlertToAsleep:test_audioSensitivity_doesNotDecreaseBeforeDecay()
	math.random = function()
		return 0
	end
	local C = Medusa.Constants
	local bat = makeManpadBattery({
		Manpad = {
			SleepWakeState = "ALERT",
			AlertCycleCount = 1,
			LastAlertedTime = 10,
			AudioCueRangeM = 5000,
			AlertStartTime = 0,
		},
	})
	evaluateSingle(bat, makeTrackStore(), makeGeoGrid({}), C.Manpad.ALERT_TIMEOUT_SEC, "NORMAL")
	lu.assertEquals(bat.Manpad.AudioCueRangeM, 5000)
end

TestManpadAlertnessDecay = {}

function TestManpadAlertnessDecay:setUp()
	installMocks()
	self.originalRandom = math.random
	math.random = function()
		return 0
	end
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
end

function TestManpadAlertnessDecay:tearDown()
	math.random = self.originalRandom
	restoreMocks()
end

function TestManpadAlertnessDecay:test_asleepCrew_resetsAtDoctrineThreshold()
	local C = Medusa.Constants
	local bat = makeManpadBattery({
		Manpad = {
			SleepWakeState = "ASLEEP",
			AlertCycleCount = 2,
			LastAlertedTime = 100,
			AudioCueRangeM = 6000,
		},
	})
	evaluateSingle(bat, makeTrackStore(), makeGeoGrid({}), 200, "NORMAL", 100)
	lu.assertEquals(bat.Manpad.AlertCycleCount, 0)
	lu.assertIsNil(bat.Manpad.LastAlertedTime)
	lu.assertEquals(bat.Manpad.AudioCueRangeM, C.Manpad.AUDIO_RANGE_MIN_M)
end

function TestManpadAlertnessDecay:test_zeroDoctrineValue_disablesDecay()
	local bat = makeManpadBattery({
		Manpad = {
			SleepWakeState = "ASLEEP",
			AlertCycleCount = 2,
			LastAlertedTime = 100,
			AudioCueRangeM = 6000,
		},
	})
	evaluateSingle(bat, makeTrackStore(), makeGeoGrid({}), 100000, "NORMAL", 0)
	lu.assertEquals(bat.Manpad.AlertCycleCount, 2)
	lu.assertEquals(bat.Manpad.LastAlertedTime, 100)
	lu.assertEquals(bat.Manpad.AudioCueRangeM, 6000)
end

function TestManpadAlertnessDecay:test_activeCrew_doesNotDecay()
	local bat = makeManpadBattery({
		Manpad = {
			SleepWakeState = "ALERT",
			AlertCycleCount = 2,
			LastAlertedTime = 100,
			AudioCueRangeM = 6000,
		},
	})
	evaluateSingle(bat, makeTrackStore(), makeGeoGrid({}), 200, "NORMAL", 100)
	lu.assertEquals(bat.Manpad.AlertCycleCount, 2)
	lu.assertEquals(bat.Manpad.LastAlertedTime, 100)
end

function TestManpadAlertnessDecay:test_updatedDoctrineValue_appliesOnNextEvaluation()
	local bat = makeManpadBattery({
		Manpad = {
			SleepWakeState = "ASLEEP",
			AlertCycleCount = 1,
			LastAlertedTime = 0,
			AudioCueRangeM = 6000,
		},
	})
	evaluateSingle(bat, makeTrackStore(), makeGeoGrid({}), 100, "NORMAL", 200)
	lu.assertEquals(bat.Manpad.AlertCycleCount, 1)
	evaluateSingle(bat, makeTrackStore(), makeGeoGrid({}), 100, "NORMAL", 100)
	lu.assertEquals(bat.Manpad.AlertCycleCount, 0)
end

-- ============================================================
-- 4. Wake scheduling via cueFromIADS
-- (formerly _scheduleWake direct tests; now routed through public API)
-- ============================================================

TestManpadScheduleWake = {}

function TestManpadScheduleWake:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()

	self.store = newManpadView()
	local store = self.store
	self.geoGrid = {
		queryRadius = function(self_, pos, radius, kinds)
			local ids = {}
			for _, bat in ipairs(store:getAll()) do
				ids[bat.BatteryId] = true
			end
			return { ManpadIds = ids }
		end,
	}
	self.network = makeNetwork("test-network", self.store, self.geoGrid)
end

function TestManpadScheduleWake:tearDown()
	Medusa.Services.ManpadService.cancelPendingWakes(self.store)
	restoreMocks()
end

-- Duplicate-wake guard: battery with WakeTimerId already set → cueFromIADS is a no-op.
-- Verified by: pre-set WakeTimerId, call cueFromIADS — must produce no additional timer.
function TestManpadScheduleWake:test_scheduleWake_duplicateGuard()
	local bat = makeManpadBattery({ NetworkId = "test-network" })
	self.store:add(bat)
	-- Manually set WakeTimerId to simulate an already-scheduled wake
	bat.Manpad.WakeTimerId = "already-scheduled"

	Medusa.Services.ManpadService.cueFromIADS(self.network._ctx, bat.Position)

	lu.assertEquals(
		#timerHarness.scheduledCallbacks,
		0,
		"cueFromIADS must not schedule when WakeTimerId is already set"
	)
	lu.assertEquals(bat.Manpad.WakeTimerId, "already-scheduled", "WakeTimerId must remain unchanged on duplicate guard")
end

function TestManpadScheduleWake:test_scheduleWake_emptyContextStore_isNoOp()
	local bat = makeManpadBattery({ NetworkId = "unregistered-network-xyz" })
	local emptyStore = newManpadView()

	Medusa.Services.ManpadService.cueFromIADS({ manpadStore = emptyStore, geoGrid = makeGeoGrid({}) }, bat.Position)

	lu.assertEquals(
		#timerHarness.scheduledCallbacks,
		0,
		"cueFromIADS must not schedule when its explicit store is empty"
	)
	lu.assertIsNil(bat.Manpad.WakeTimerId)
end

-- Successful schedule: cueFromIADS sets ALERTING state and assigns WakeTimerId
function TestManpadScheduleWake:test_scheduleWake_setsStateAndTimerId()
	local bat = makeManpadBattery({ NetworkId = "test-network" })
	self.store:add(bat)

	Medusa.Services.ManpadService.cueFromIADS(self.network._ctx, bat.Position)

	lu.assertEquals(bat.Manpad.SleepWakeState, "ALERTING", "cueFromIADS must set SleepWakeState to ALERTING")
	lu.assertEquals(bat.Manpad.WakeReason, "IADS", "cueFromIADS must retain the IADS wake reason")
	lu.assertNotNil(bat.Manpad.WakeTimerId, "cueFromIADS must set WakeTimerId")
	lu.assertEquals(bat.Manpad.AlertCycleCount, 0)
	lu.assertIsNil(bat.Manpad.LastAlertedTime)
end

function TestManpadScheduleWake:test_scheduleFailure_restoresSleepingState()
	local bat = makeManpadBattery({ NetworkId = "test-network" })
	self.store:add(bat)
	ScheduleOnce = function()
		return nil
	end

	Medusa.Services.ManpadService.cueFromIADS(self.network._ctx, bat.Position)

	lu.assertEquals(bat.Manpad.SleepWakeState, "ASLEEP")
	lu.assertEquals(bat.Manpad.WakeReason, "NONE")
	lu.assertIsNil(bat.Manpad.WakeTimerId)
end

function TestManpadScheduleWake:test_wakeDelay_usesAlertCycleCount()
	local fresh = makeManpadBattery({ NetworkId = "test-network" })
	local experienced = makeManpadBattery({
		NetworkId = "test-network",
		Manpad = { AlertCycleCount = 1, LastAlertedTime = 10 },
	})
	self.store:add(fresh)
	self.store:add(experienced)
	Medusa.Services.ManpadService.cueFromIADS(self.network._ctx, fresh.Position)
	lu.assertEquals(#timerHarness.scheduledCallbacks, 2)
	for i = 1, #timerHarness.scheduledCallbacks do
		local delay = timerHarness.scheduledCallbacks[i].delay
		if timerHarness.scheduledCallbacks[i].id == fresh.Manpad.WakeTimerId then
			lu.assertTrue(delay >= Medusa.Constants.Manpad.FIRST_WAKE_MIN_SEC)
			lu.assertTrue(delay <= Medusa.Constants.Manpad.FIRST_WAKE_MAX_SEC)
		else
			lu.assertTrue(delay >= Medusa.Constants.Manpad.WAKE_MIN_SEC)
			lu.assertTrue(delay <= Medusa.Constants.Manpad.WAKE_MAX_SEC)
		end
	end
end

-- ============================================================
-- 5. Wake callback behaviour
-- ============================================================

TestManpadWakeCallback = {}

function TestManpadWakeCallback:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()

	self.store = newManpadView()
	local store = self.store
	self.geoGrid = {
		queryRadius = function(self_, pos, radius, kinds)
			local ids = {}
			for _, bat in ipairs(store:getAll()) do
				ids[bat.BatteryId] = true
			end
			return { ManpadIds = ids }
		end,
	}
	self.network = makeNetwork("test-network", self.store, self.geoGrid)
end

function TestManpadWakeCallback:tearDown()
	Medusa.Services.ManpadService.cancelPendingWakes(self.store)
	restoreMocks()
end

-- Schedule a wake via cueFromIADS and capture the resulting ScheduleOnce callback.
local function captureWakeCallback(network, store, bat)
	store:add(bat)
	Medusa.Services.ManpadService.cueFromIADS(network._ctx, bat.Position)
	local entry = timerHarness.scheduledCallbacks[#timerHarness.scheduledCallbacks]
	return entry.fn, entry.args
end

-- Callback fires while ALERTING → transitions to ALERT, sets AlertStartTime
function TestManpadWakeCallback:test_callback_setsAlertState_whenAlerting()
	timerHarness.time = 500
	local bat = makeManpadBattery({ NetworkId = "test-network" })
	local cb, args = captureWakeCallback(self.network, self.store, bat)

	cb(args)

	lu.assertEquals(bat.Manpad.SleepWakeState, "ALERT", "wake callback must set state to ALERT when still in ALERTING")
	lu.assertEquals(bat.Manpad.AlertStartTime, 500, "wake callback must set AlertStartTime to GetTime()")
	lu.assertEquals(bat.Manpad.AlertCycleCount, 1)
	lu.assertEquals(bat.Manpad.LastAlertedTime, 500)

	cb(args)
	lu.assertEquals(bat.Manpad.AlertCycleCount, 1)
	lu.assertEquals(bat.Manpad.LastAlertedTime, 500)
end

function TestManpadWakeCallback:test_rearm_doesNotCreateAnotherAlertCycle()
	local bat = makeManpadBattery({
		Manpad = { AlertCycleCount = 2, LastAlertedTime = 250 },
	})
	Medusa.Services.ManpadService.onRearmed(bat, 500)
	lu.assertEquals(bat.Manpad.AlertCycleCount, 2)
	lu.assertEquals(bat.Manpad.LastAlertedTime, 250)
end

-- Callback on destroyed battery (removed from store) is a no-op — no crash
function TestManpadWakeCallback:test_callback_noOp_whenBatteryDestroyed()
	local bat = makeManpadBattery({ NetworkId = "test-network" })
	local cb, args = captureWakeCallback(self.network, self.store, bat)

	self.store:remove(bat.BatteryId)

	local ok, err = pcall(cb, args)
	lu.assertTrue(ok, string.format("wake callback must not raise when battery is gone: %s", tostring(err)))
end

-- ============================================================
-- 6. Wake timer lifecycle
-- ============================================================

TestManpadNetworkLifecycle = {}

function TestManpadNetworkLifecycle:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
end

function TestManpadNetworkLifecycle:tearDown()
	restoreMocks()
end

function TestManpadNetworkLifecycle:test_cancelPendingWakes_cancelsEveryTimer()
	local store = newManpadView()
	local first = makeManpadBattery()
	local second = makeManpadBattery()
	first.Manpad.WakeTimerId = "timer-A"
	second.Manpad.WakeTimerId = "timer-B"
	store:add(first)
	store:add(second)

	Medusa.Services.ManpadService.cancelPendingWakes(store)

	local cancelled = {}
	for i = 1, #timerHarness.cancelledIds do
		cancelled[timerHarness.cancelledIds[i]] = true
	end
	lu.assertTrue(cancelled["timer-A"])
	lu.assertTrue(cancelled["timer-B"])
	lu.assertIsNil(first.Manpad.WakeTimerId)
	lu.assertIsNil(second.Manpad.WakeTimerId)
end

function TestManpadNetworkLifecycle:test_cancelPendingWakes_isIdempotent()
	local store = newManpadView()
	local bat = makeManpadBattery()
	bat.Manpad.WakeTimerId = "timer-A"
	store:add(bat)

	Medusa.Services.ManpadService.cancelPendingWakes(store)
	local cancelCountAfterFirst = #timerHarness.cancelledIds

	local ok, err = pcall(function()
		Medusa.Services.ManpadService.cancelPendingWakes(store)
	end)

	lu.assertTrue(ok, tostring(err))
	lu.assertEquals(#timerHarness.cancelledIds, cancelCountAfterFirst)
end

function TestManpadNetworkLifecycle:test_cancelPendingWake_allowsFutureCue()
	local store = newManpadView()
	local bat = makeManpadBattery()
	store:add(bat)
	local ctx = {
		manpadStore = store,
		geoGrid = makeGeoGrid({ ManpadIds = { [bat.BatteryId] = true } }),
	}

	Medusa.Services.ManpadService.cueFromIADS(ctx, bat.Position)
	lu.assertEquals(bat.Manpad.SleepWakeState, "ALERTING")
	lu.assertNotNil(bat.Manpad.WakeTimerId)

	Medusa.Services.ManpadService.cancelPendingWake(bat)
	lu.assertEquals(bat.Manpad.SleepWakeState, "ASLEEP")
	lu.assertEquals(bat.Manpad.WakeReason, "NONE")
	lu.assertIsNil(bat.Manpad.WakeTimerId)

	Medusa.Services.ManpadService.cueFromIADS(ctx, bat.Position)

	lu.assertEquals(bat.Manpad.SleepWakeState, "ALERTING")
	lu.assertNotNil(bat.Manpad.WakeTimerId)
	lu.assertEquals(#timerHarness.scheduledCallbacks, 2)
end

function TestManpadNetworkLifecycle:test_lateCancelledCallback_doesNotOwnReplacementWake()
	local store = newManpadView()
	local bat = makeManpadBattery()
	store:add(bat)
	local ctx = {
		manpadStore = store,
		geoGrid = makeGeoGrid({ ManpadIds = { [bat.BatteryId] = true } }),
	}

	Medusa.Services.ManpadService.cueFromIADS(ctx, bat.Position)
	local first = timerHarness.scheduledCallbacks[1]
	CancelSchedule = function()
		return false
	end
	Medusa.Services.ManpadService.cancelPendingWake(bat)
	Medusa.Services.ManpadService.cueFromIADS(ctx, bat.Position)
	local second = timerHarness.scheduledCallbacks[2]

	first.fn(first.args)

	lu.assertEquals(bat.Manpad.SleepWakeState, "ALERTING")
	lu.assertEquals(bat.Manpad.WakeReason, "IADS")
	lu.assertEquals(bat.Manpad.WakeTimerId, second.id)
end
