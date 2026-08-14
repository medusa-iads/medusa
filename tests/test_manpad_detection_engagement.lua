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
-- Commit 1.5 — Directional visual detection, engagement, audio
-- cueing, IADS cue, and neighbor-HOT wake tests.
--
-- Harness contract reminder:
--   geoGrid:queryRadius returns a KINDED table: { TrackIds={id=true,...}, ... }
--   Callers MUST guard on results.TrackIds ~= nil.
-- ============================================================

-- ============================================================
-- Module-level mock management
-- ============================================================

local _origForceGoHot
local _origGoCold
local timerHarness = ManpadTest.newTimerHarness()

local function installMocks()
	timerHarness:install()
end

local function restoreMocks()
	timerHarness:restore()
end

local function saveActivation()
	_origForceGoHot = Medusa.Services.BatteryActivationService.forceGoHot
	_origGoCold = Medusa.Services.BatteryActivationService.goCold
end

local function restoreActivation()
	Medusa.Services.BatteryActivationService.forceGoHot = _origForceGoHot
	Medusa.Services.BatteryActivationService.goCold = _origGoCold
end

-- ============================================================
-- Shared builders
-- ============================================================

local _batSeq = 0

local newManpadView = ManpadTest.newManpadView

local function makeHeadingVec(deg)
	local rad = math.rad(deg)
	return { hx = math.cos(rad), hz = math.sin(rad) }
end

local function makeManpadBattery(overrides)
	_batSeq = _batSeq + 1
	local bat = {
		BatteryId = string.format("bat-%d", _batSeq),
		GroupId = _batSeq * 100,
		GroupName = string.format("manpad-grp-%d", _batSeq),
		NetworkId = "test-network",
		Role = Medusa.Constants.BatteryRole.MANPAD,
		Position = { x = 0, y = 0, z = 0 },
		TotalAmmoStatus = 10,
		EngagementRangeMax = 5000,
		MissileInFlightUntil = nil,
		Manpad = {
			SleepWakeState = "ALERT",
			WakeReason = "NONE",
			WakeTimerId = nil,
			AlertCycleCount = 1,
			LastAlertedTime = 0,
			AudioCueRangeM = 3000,
			HotUntil = nil,
			CooldownUntil = nil,
			AlertStartTime = nil,
			UnitHeadings = { makeHeadingVec(0) },
			UnitHeadingCount = 1,
		},
	}
	return ManpadTest.applyManpadOverrides(bat, overrides)
end

local function makeTrack(overrides)
	local C = Medusa.Constants
	local t = {
		TrackId = "track-default",
		AssessedAircraftType = C.AssessedAircraftType.FIXED_WING,
		Position = { x = 1000, y = 0, z = 0 },
		Velocity = { x = 0, y = 0, z = 0 },
		LifecycleState = C.TrackLifecycleState.ACTIVE,
	}
	if overrides then
		for k, v in pairs(overrides) do
			if k == "Position" or k == "Velocity" then
				for pk, pv in pairs(v) do
					t[k] = t[k] or {}
					t[k][pk] = pv
				end
			else
				t[k] = v
			end
		end
	end
	return t
end

local function makeTrackStore(trackById)
	return {
		get = function(self, id)
			return trackById and trackById[id] or nil
		end,
	}
end

local makeGeoGrid = ManpadTest.makeQueryGeoGrid

local evaluateSingle = ManpadTest.evaluateSingle

-- Helper: call ManpadService.evaluate with positional args (test ergonomics)
local function evalPositional(store, trackStore, geoGrid, now, posture, coalitionId, decaySec, radioRangeM)
	Medusa.Services.ManpadService.evaluate({
		manpadStore = store,
		trackStore = trackStore,
		geoGrid = geoGrid,
		now = now,
		posture = posture,
		coalitionId = coalitionId,
		doctrine = {
			MANPADAlertnessDecaySec = decaySec == nil and 14400 or decaySec,
			MANPADFieldRadioRangeM = radioRangeM == nil and 5000 or radioRangeM,
		},
	})
end

-- ============================================================
-- 1. Visual cone geometry (8 tests)
-- ============================================================

TestVisualConeGeometry = {}

function TestVisualConeGeometry:setUp()
	installMocks()
	self.originalGetUnitHeading = GetUnitHeading
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
end

function TestVisualConeGeometry:tearDown()
	GetUnitHeading = self.originalGetUnitHeading
	restoreMocks()
end

function TestVisualConeGeometry:test_rebuildHeadings_usesDcsHeadingContract()
	local bat = makeManpadBattery({
		Units = {
			{ UnitName = "manpad-east", Roles = { Medusa.Constants.BatteryUnitRole.MANPAD } },
		},
		Manpad = { UnitHeadings = {}, UnitHeadingCount = 0 },
	})
	GetUnitHeading = function(unitName)
		lu.assertEquals(unitName, "manpad-east")
		return 0
	end

	Medusa.Services.ManpadService.rebuildHeadings(bat)

	lu.assertAlmostEquals(bat.Manpad.UnitHeadings[1].hx, 1, 0.0001)
	lu.assertAlmostEquals(bat.Manpad.UnitHeadings[1].hz, 0, 0.0001)
	lu.assertAlmostEquals(Medusa.Services.ManpadService.headingBearingDegrees(bat.Manpad.UnitHeadings[1]), 90, 0.0001)
	lu.assertTrue(Medusa.Services.ManpadService.canDetectVisually(bat, makeTrack(), "NORMAL"))
end

-- Narrow cone head-on at 5000m → detected
function TestVisualConeGeometry:test_narrowCone_headOn_5000m_detected()
	local MS = Medusa.Services.ManpadService
	local bat = makeManpadBattery({
		Manpad = { UnitHeadings = { makeHeadingVec(0) }, UnitHeadingCount = 1 },
	})
	local track = makeTrack({ Position = { x = 5000, y = 0, z = 0 } })
	lu.assertTrue(MS.canDetectVisually(bat, track, "NORMAL"), "narrow-cone head-on at 5000m must be detected")
end

-- Narrow cone 45° off (dot=0.707) → NOT detected (below narrow threshold 0.866)
function TestVisualConeGeometry:test_narrowCone_45degOff_notDetected()
	local MS = Medusa.Services.ManpadService
	-- heading=90; target at (2828, 0, 2828): dist=4000, dot=2828/4000=0.707 < 0.866
	-- Wide range = 4000m, dot=0.707 > 0 so wide cone... but we want NARROW-only test.
	-- Use long range: (5657, 0, 5657): dist=8000, dot=5657/8000=0.707 < 0.866, dist > 4000 (wide range)
	local bat = makeManpadBattery({
		Manpad = { UnitHeadings = { makeHeadingVec(0) }, UnitHeadingCount = 1 },
	})
	local track = makeTrack({ Position = { x = 5657, y = 0, z = 5657 } }) -- dist≈8000, dot≈0.707
	lu.assertFalse(MS.canDetectVisually(bat, track, "NORMAL"), "45° off-axis beyond wide range must not be detected")
end

-- Wide cone 45° off at 3000m (within 4000m wide range) → detected
function TestVisualConeGeometry:test_wideCone_45degOff_3000m_detected()
	local MS = Medusa.Services.ManpadService
	-- heading=90; 45° off-axis at 4000m: dot=0.707 > 0 (wide), dist=4000 ≤ 4000
	local bat = makeManpadBattery({
		Manpad = { UnitHeadings = { makeHeadingVec(0) }, UnitHeadingCount = 1 },
	})
	local track = makeTrack({ Position = { x = 2828, y = 0, z = 2828 } }) -- dist≈4000, dot≈0.707
	lu.assertTrue(
		MS.canDetectVisually(bat, track, "NORMAL"),
		"wide-cone target at 45° off-axis within 4000m must be detected"
	)
end

-- Wide cone 45° off at 6000m (beyond 4000m wide range) → NOT detected
function TestVisualConeGeometry:test_wideCone_45degOff_6000m_notDetected()
	local MS = Medusa.Services.ManpadService
	local C = Medusa.Constants
	-- heading=90; target: x=100, z=6000: dist≈6001, dot≈0.017 (wide cone angle but > wide range)
	local bat = makeManpadBattery({
		Manpad = { UnitHeadings = { makeHeadingVec(0) }, UnitHeadingCount = 1 },
	})
	local track = makeTrack({ Position = { x = 100, y = 0, z = 6000 } })
	lu.assertFalse(MS.canDetectVisually(bat, track, "NORMAL"), "wide-cone target beyond 4000m must not be detected")
end

-- Rear hemisphere (dot < 0) → NOT detected
function TestVisualConeGeometry:test_rearHemisphere_notDetected()
	local MS = Medusa.Services.ManpadService
	-- heading=90 (east); track due west: dot=-1.0
	local bat = makeManpadBattery({
		Manpad = { UnitHeadings = { makeHeadingVec(0) }, UnitHeadingCount = 1 },
	})
	local track = makeTrack({ Position = { x = -1000, y = 0, z = 0 } })
	lu.assertFalse(MS.canDetectVisually(bat, track, "NORMAL"), "rear-hemisphere target must not be detected")
end

-- Altitude ceiling (target 3049m above) → NOT detected
function TestVisualConeGeometry:test_altitudeCeiling_aboveCeiling_notDetected()
	local MS = Medusa.Services.ManpadService
	local C = Medusa.Constants
	local bat = makeManpadBattery({ Position = { x = 0, y = 100, z = 0 } })
	local track = makeTrack({ Position = { x = 0, y = 100 + C.Manpad.REL_ALT_CEIL_M + 1, z = 0 } })
	lu.assertFalse(
		MS.canDetectVisually(bat, track, "NORMAL"),
		string.format("altRel %d above ceiling must be rejected", C.Manpad.REL_ALT_CEIL_M + 1)
	)
end

-- Look-down (target 1500m below, mountain placement) → detected
function TestVisualConeGeometry:test_lookDown_negativAltRel_detected()
	local MS = Medusa.Services.ManpadService
	-- Battery on mountain at y=2000, track in valley at y=500: altRel=-1500 (no ceiling block)
	local bat = makeManpadBattery({ Position = { x = 0, y = 2000, z = 0 } })
	local track = makeTrack({ Position = { x = 0, y = 500, z = 0 } }) -- coincident 2D
	lu.assertTrue(
		MS.canDetectVisually(bat, track, "NORMAL"),
		"look-down (negative altRel) must not be blocked by altitude gate"
	)
end

-- Coincident track (dist² < 1) → detected unconditionally
function TestVisualConeGeometry:test_coincident_alwaysDetected()
	local MS = Medusa.Services.ManpadService
	local bat = makeManpadBattery({ Manpad = { UnitHeadings = {}, UnitHeadingCount = 0 } })
	local track = makeTrack({ Position = { x = 0, y = 0, z = 0 } })
	lu.assertTrue(MS.canDetectVisually(bat, track, "NORMAL"), "coincident position must always return true")
end

-- ============================================================
-- 2. State/posture gates (3 tests)
-- ============================================================

TestStatePostureGates = {}

function TestStatePostureGates:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
end

function TestStatePostureGates:tearDown()
	restoreMocks()
end

-- ASLEEP in HOT_WAR, narrow cone → detected (sentry mode)
function TestStatePostureGates:test_asleep_hotWar_narrowCone_detected()
	local MS = Medusa.Services.ManpadService
	local bat = makeManpadBattery({
		Manpad = {
			SleepWakeState = "ASLEEP",
			AlertCycleCount = 0,
			UnitHeadings = { makeHeadingVec(0) },
			UnitHeadingCount = 1,
		},
	})
	-- Head-on 1000m east → dot=1.0 > 0.866, dist=1000 ≤ 8000
	local track = makeTrack({ Position = { x = 1000, y = 0, z = 0 } })
	lu.assertTrue(MS.canDetectVisually(bat, track, "HOT_WAR"), "ASLEEP in HOT_WAR must detect target in narrow cone")
end

-- ASLEEP in HOT_WAR, wide cone (dot=0.5) → NOT detected (narrow-only in ASLEEP)
function TestStatePostureGates:test_asleep_hotWar_wideConeOnly_notDetected()
	local MS = Medusa.Services.ManpadService
	-- heading=90; 60° off-axis: x=1000, z=1732 → dist≈2000, dot=1000/2000=0.5 < 0.866 (wide only)
	local bat = makeManpadBattery({
		Manpad = {
			SleepWakeState = "ASLEEP",
			AlertCycleCount = 0,
			UnitHeadings = { makeHeadingVec(0) },
			UnitHeadingCount = 1,
		},
	})
	local track = makeTrack({ Position = { x = 1000, y = 0, z = 1732 } })
	lu.assertFalse(
		MS.canDetectVisually(bat, track, "HOT_WAR"),
		"ASLEEP must disable wide cone — 60° off-axis must not be detected"
	)
end

function TestStatePostureGates:test_previouslyAlerted_asleep_hotWar_usesFullDetection()
	local MS = Medusa.Services.ManpadService
	local bat = makeManpadBattery({
		Manpad = {
			SleepWakeState = "ASLEEP",
			AlertCycleCount = 1,
			UnitHeadings = { makeHeadingVec(0) },
			UnitHeadingCount = 1,
		},
	})
	local track = makeTrack({ Position = { x = 1000, y = 0, z = 1732 } })
	lu.assertTrue(MS.canDetectVisually(bat, track, "HOT_WAR"))
end

-- ASLEEP in COLD_WAR, any cone → NOT detected (wrong posture)
function TestStatePostureGates:test_asleep_coldWar_notDetected()
	local MS = Medusa.Services.ManpadService
	local bat = makeManpadBattery({ Manpad = { SleepWakeState = "ASLEEP" } })
	local track = makeTrack({ Position = { x = 0, y = 0, z = 0 } }) -- coincident
	lu.assertFalse(
		MS.canDetectVisually(bat, track, "COLD_WAR"),
		"ASLEEP in COLD_WAR must return false regardless of geometry"
	)
	lu.assertFalse(MS.canDetectVisually(bat, track, "NORMAL"), "ASLEEP in NORMAL posture must return false")
end

-- ============================================================
-- 3. Audio hearing
-- Formerly tested via MS._hearsAudio directly; now routed through
-- evaluate: an ASLEEP battery wakes when a track is within audio range.
-- ============================================================

TestAudioHearing = {}

function TestAudioHearing:setUp()
	installMocks()
	self.originalRandom = math.random
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	saveActivation()
	Medusa.Services.BatteryActivationService.goCold = function()
		return true
	end
	Medusa.Services.BatteryActivationService.forceGoHot = function()
		return false
	end
end

function TestAudioHearing:tearDown()
	math.random = self.originalRandom
	restoreActivation()
	restoreMocks()
end

local function makeAudioBattery(headingDeg)
	_batSeq = _batSeq + 1
	return {
		BatteryId = string.format("bat-audio-%d", _batSeq),
		GroupId = _batSeq * 100,
		NetworkId = "test-net-audio",
		Role = Medusa.Constants.BatteryRole.MANPAD,
		Position = { x = 0, y = 0, z = 0 },
		TotalAmmoStatus = 10,
		EngagementRangeMax = 5000,
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
			UnitHeadings = { makeHeadingVec(headingDeg) },
			UnitHeadingCount = 1,
		},
	}
end

-- Audio wake is a direct wake (no timer delay): battery transitions ASLEEP → ALERT immediately.
function TestAudioHearing:test_frontHemisphere_withinRange_wakeScheduled()
	local bat = makeAudioBattery(0)

	local store = newManpadView()
	store:add(bat)
	local trackId = "track-audio-front"
	local track = makeTrack({ TrackId = trackId, Position = { x = 2500, y = 0, z = 0 } })
	local trackStore = makeTrackStore({ [trackId] = track })
	local geoGrid = makeGeoGrid({ TrackIds = { [trackId] = true } })
	evalPositional(store, trackStore, geoGrid, 0, "NORMAL")

	lu.assertNotEquals(
		bat.Manpad.SleepWakeState,
		"ASLEEP",
		"ASLEEP battery must NOT remain ASLEEP after hearing forward-hemisphere track at 2500m"
	)
	lu.assertEquals(bat.Manpad.WakeReason, "AUDIO")
	lu.assertEquals(bat.Manpad.AlertCycleCount, 1)
	lu.assertEquals(bat.Manpad.LastAlertedTime, 0)
end

function TestAudioHearing:test_audioWake_cancelsPendingWakeAndTakesPrecedenceOverVisualWake()
	local MC = Medusa.Constants.Manpad
	local bat = makeAudioBattery(0)
	bat.Manpad.SleepWakeState = MC.SleepWakeState.ALERTING
	bat.Manpad.WakeReason = MC.WakeReason.IADS
	bat.Manpad.WakeTimerId = "timer-pending"

	local store = newManpadView()
	store:add(bat)
	local trackId = "track-audio-visual"
	local track = makeTrack({ TrackId = trackId, Position = { x = 1000, y = 0, z = 0 } })
	local geoGrid = makeGeoGrid({ TrackIds = { [trackId] = true } })

	evalPositional(store, makeTrackStore({ [trackId] = track }), geoGrid, 100, "NORMAL")

	lu.assertEquals(bat.Manpad.SleepWakeState, MC.SleepWakeState.ALERT)
	lu.assertEquals(bat.Manpad.WakeReason, MC.WakeReason.AUDIO)
	lu.assertNil(bat.Manpad.WakeTimerId)
	lu.assertEquals(bat.Manpad.AlertCycleCount, 1)
	lu.assertEquals(timerHarness.cancelledIds, { "timer-pending" })
end

function TestAudioHearing:test_rearHemisphere_withinRange_wakes()
	local bat = makeAudioBattery(0)

	local store = newManpadView()
	store:add(bat)
	local trackId = "track-audio-rear"
	local track = makeTrack({ TrackId = trackId, Position = { x = -2500, y = 0, z = 0 } })
	local trackStore = makeTrackStore({ [trackId] = track })
	local geoGrid = makeGeoGrid({ TrackIds = { [trackId] = true } })
	bat.NetworkId = "test-net-audio-b"

	evalPositional(store, trackStore, geoGrid, 0, "NORMAL")

	lu.assertNotEquals(bat.Manpad.SleepWakeState, "ASLEEP", "hearing must be omnidirectional")
end

function TestAudioHearing:test_target_outsideAudioRange_doesNotWake()
	local bat = makeAudioBattery(0)

	local store = newManpadView()
	store:add(bat)
	local trackId = "track-audio-outside"
	local track = makeTrack({ TrackId = trackId, Position = { x = -3500, y = 0, z = 0 } })
	local trackStore = makeTrackStore({ [trackId] = track })
	local geoGrid = makeGeoGrid({ TrackIds = { [trackId] = true } })
	bat.NetworkId = "test-net-audio-c"

	evalPositional(store, trackStore, geoGrid, 0, "NORMAL")

	lu.assertEquals(bat.Manpad.SleepWakeState, "ASLEEP", "targets beyond AudioCueRangeM must not wake the crew")
end

function TestAudioHearing:test_slantDistance_includesAltitude()
	local bat = makeAudioBattery(0)
	local store = newManpadView()
	store:add(bat)
	local trackId = "track-audio-slant"
	local track = makeTrack({ TrackId = trackId, Position = { x = 1000, y = 2900, z = 0 } })
	local geoGrid = makeGeoGrid({ TrackIds = { [trackId] = true } })
	evalPositional(store, makeTrackStore({ [trackId] = track }), geoGrid, 0, "NORMAL")
	lu.assertEquals(bat.Manpad.SleepWakeState, "ASLEEP")
end

function TestAudioHearing:test_audioIgnoresEngagementAltitudeCeiling()
	local bat = makeAudioBattery(0)
	bat.Manpad.AudioCueRangeM = 6000
	local store = newManpadView()
	store:add(bat)
	local trackId = "track-audio-high"
	local track = makeTrack({ TrackId = trackId, Position = { x = 1000, y = 4000, z = 0 } })
	local geoGrid = makeGeoGrid({ TrackIds = { [trackId] = true } })
	evalPositional(store, makeTrackStore({ [trackId] = track }), geoGrid, 125, "NORMAL")
	lu.assertEquals(bat.Manpad.SleepWakeState, "ALERT")
	lu.assertEquals(bat.Manpad.AlertCycleCount, 1)
	lu.assertEquals(bat.Manpad.LastAlertedTime, 125)
end

function TestAudioHearing:test_decayRunsBeforeTargetEvaluation()
	math.random = function()
		return 0
	end
	local bat = makeAudioBattery(0)
	bat.Manpad.AlertCycleCount = 1
	bat.Manpad.LastAlertedTime = 0
	bat.Manpad.AudioCueRangeM = 6000
	local store = newManpadView()
	store:add(bat)
	local trackId = "track-audio-decay-order"
	local track = makeTrack({ TrackId = trackId, Position = { x = 2500, y = 0, z = 0 } })
	local geoGrid = makeGeoGrid({ TrackIds = { [trackId] = true } })
	evalPositional(store, makeTrackStore({ [trackId] = track }), geoGrid, 100, "NORMAL", nil, 100)
	lu.assertEquals(bat.Manpad.SleepWakeState, "ASLEEP")
	lu.assertEquals(bat.Manpad.AlertCycleCount, 0)
	lu.assertEquals(bat.Manpad.AudioCueRangeM, Medusa.Constants.Manpad.AUDIO_RANGE_MIN_M)
end

TestAutonomousAcquisition = {}

function TestAutonomousAcquisition:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	saveActivation()
	self.origSearchWorldObjects = SearchWorldObjects
	self.origGetUnit = GetUnit
	self.origGetGroupController = GetGroupController
	self.origKnowControllerTarget = KnowControllerTarget
	Medusa.Services.BatteryActivationService.goCold = function()
		return true
	end
end

function TestAutonomousAcquisition:tearDown()
	SearchWorldObjects = self.origSearchWorldObjects
	GetUnit = self.origGetUnit
	GetGroupController = self.origGetGroupController
	KnowControllerTarget = self.origKnowControllerTarget
	restoreActivation()
	restoreMocks()
end

local function makeWorldTarget(coalitionId, category, active, position, unitName)
	return {
		getName = function()
			return unitName
		end,
		getCoalition = function()
			return coalitionId
		end,
		getCategoryEx = function()
			return category
		end,
		isActive = function()
			return active
		end,
		getPosition = function()
			return {
				p = position,
				x = { x = 1, y = 0, z = 0 },
				y = { x = 0, y = 1, z = 0 },
				z = { x = 0, y = 0, z = 1 },
			}
		end,
	}
end

function TestAutonomousAcquisition:test_hostileAircraftInVisualEnvelope_engagesWithoutTrack()
	local bat = makeManpadBattery({
		Manpad = {
			SleepWakeState = "ASLEEP",
			UnitHeadings = { makeHeadingVec(0) },
			UnitHeadingCount = 1,
		},
	})
	local store = newManpadView()
	store:add(bat)
	local hostileAircraft =
		makeWorldTarget(2, Unit.Category.AIRPLANE, true, { x = 4000, y = 0, z = 0 }, "hostile-aircraft")
	SearchWorldObjects = function(category, volume, handler)
		lu.assertEquals(category, Object.Category.UNIT)
		lu.assertEquals(volume.params.radius, Medusa.Constants.Manpad.GEOGRID_QUERY_RADIUS_M)
		handler(hostileAircraft)
	end
	Medusa.Services.BatteryActivationService.forceGoHot = function()
		return true
	end
	GetUnit = function(unitName)
		lu.assertEquals(unitName, "hostile-aircraft")
		return hostileAircraft
	end
	local controller = {}
	local knownTarget = nil
	GetGroupController = function(groupName)
		lu.assertEquals(groupName, bat.GroupName)
		return controller
	end
	KnowControllerTarget = function(actualController, target, typeKnown, distanceKnown)
		lu.assertIs(actualController, controller)
		lu.assertFalse(typeKnown)
		lu.assertTrue(distanceKnown)
		knownTarget = target
		return true
	end

	evalPositional(store, makeTrackStore({}), makeGeoGrid({}), 100, "HOT_WAR", 1)

	lu.assertEquals(bat.Manpad.SleepWakeState, "HOT")
	lu.assertEquals(bat.Manpad.WakeReason, "VISUAL")
	lu.assertEquals(bat.Manpad.AlertCycleCount, 2)
	lu.assertEquals(bat.Manpad.LastAlertedTime, 100)
	lu.assertIs(knownTarget, hostileAircraft)
end

function TestAutonomousAcquisition:test_nonHostileOrNonAircraftObjects_areRejected()
	local bat = makeManpadBattery({
		Manpad = {
			SleepWakeState = "ASLEEP",
			UnitHeadings = { makeHeadingVec(0) },
			UnitHeadingCount = 1,
		},
	})
	local store = newManpadView()
	store:add(bat)
	local candidates = {
		makeWorldTarget(1, Unit.Category.AIRPLANE, true, { x = 4000, y = 0, z = 0 }),
		makeWorldTarget(0, Unit.Category.AIRPLANE, true, { x = 4000, y = 0, z = 0 }),
		makeWorldTarget(2, Unit.Category.AIRPLANE, false, { x = 4000, y = 0, z = 0 }),
		makeWorldTarget(2, Unit.Category.GROUND_UNIT, true, { x = 4000, y = 0, z = 0 }),
	}
	SearchWorldObjects = function(_, _, handler)
		for i = 1, #candidates do
			handler(candidates[i])
		end
	end
	local forceGoHotCalled = false
	Medusa.Services.BatteryActivationService.forceGoHot = function()
		forceGoHotCalled = true
		return true
	end

	evalPositional(store, makeTrackStore({}), makeGeoGrid({}), 100, "HOT_WAR", 1)

	lu.assertFalse(forceGoHotCalled)
	lu.assertEquals(bat.Manpad.SleepWakeState, "ASLEEP")
end

local function makeAutonomousContext(store, now)
	return {
		manpadStore = store,
		trackStore = makeTrackStore({}),
		geoGrid = makeGeoGrid({}),
		now = now,
		posture = "HOT_WAR",
		coalitionId = 1,
		doctrine = { MANPADAlertnessDecaySec = 14400, MANPADFieldRadioRangeM = 5000 },
	}
end

local function countSet(values)
	local count = 0
	for _ in pairs(values) do
		count = count + 1
	end
	return count
end

function TestAutonomousAcquisition:test_scanQuota_advancesRoundRobinWithoutScanningEveryGroup()
	local store = newManpadView()
	for i = 1, 3 do
		store:add(makeManpadBattery({
			Position = { x = i * 1000, y = 0, z = 0 },
			Manpad = { SleepWakeState = "ASLEEP" },
		}))
	end
	local scannedPositions = {}
	local searches = 0
	SearchWorldObjects = function(_, volume)
		searches = searches + 1
		scannedPositions[volume.params.point.x] = true
	end
	local ctx = makeAutonomousContext(store, 0)

	Medusa.Services.ManpadService.evaluate(ctx)
	lu.assertEquals(searches, 2)
	lu.assertEquals(countSet(scannedPositions), 2)

	ctx.now = 0.25
	Medusa.Services.ManpadService.evaluate(ctx)
	lu.assertEquals(searches, 2)
	lu.assertEquals(countSet(scannedPositions), 2)

	store:add(makeManpadBattery({
		Position = { x = 4000, y = 0, z = 0 },
		Manpad = { SleepWakeState = "ASLEEP" },
	}))

	ctx.now = 0.5
	Medusa.Services.ManpadService.evaluate(ctx)
	lu.assertEquals(searches, 3)
	lu.assertEquals(countSet(scannedPositions), 3)
	lu.assertNil(scannedPositions[4000])

	ctx.now = 1
	Medusa.Services.ManpadService.evaluate(ctx)
	lu.assertEquals(searches, 4)
	lu.assertEquals(countSet(scannedPositions), 4)
	lu.assertTrue(scannedPositions[4000])
end

function TestAutonomousAcquisition:test_emptyScanResult_isReusedUntilCacheExpires()
	local store = newManpadView()
	store:add(makeManpadBattery({ Manpad = { SleepWakeState = "ASLEEP" } }))
	local searches = 0
	SearchWorldObjects = function()
		searches = searches + 1
	end
	local ctx = makeAutonomousContext(store, 0)

	Medusa.Services.ManpadService.evaluate(ctx)
	lu.assertEquals(searches, 1)
	ctx.now = 1
	Medusa.Services.ManpadService.evaluate(ctx)
	lu.assertEquals(searches, 1)
	ctx.now = 2.99
	Medusa.Services.ManpadService.evaluate(ctx)
	lu.assertEquals(searches, 1)
	ctx.now = 3
	Medusa.Services.ManpadService.evaluate(ctx)
	lu.assertEquals(searches, 2)
end

function TestAutonomousAcquisition:test_cachedCandidates_areBoundedAndContainNoDcsHandles()
	local store = newManpadView()
	local bat = makeManpadBattery({ Manpad = { SleepWakeState = "ASLEEP" } })
	store:add(bat)
	local candidates = {}
	for i = 1, 12 do
		local name = string.format("hostile-%d", i)
		candidates[name] = makeWorldTarget(2, Unit.Category.AIRPLANE, true, { x = 9000, y = 0, z = 0 }, name)
	end
	local visited = 0
	SearchWorldObjects = function(_, _, handler)
		for _, candidate in pairs(candidates) do
			visited = visited + 1
			if handler(candidate) == false then
				break
			end
		end
	end
	GetUnit = function(unitName)
		return candidates[unitName]
	end
	local ctx = makeAutonomousContext(store, 0)

	Medusa.Services.ManpadService.evaluate(ctx)

	lu.assertEquals(visited, Medusa.Constants.Manpad.AUTONOMOUS_TARGET_CACHE_CAPACITY)
	local cache = ctx.localSearch.cacheByBatteryId[bat.BatteryId]
	lu.assertEquals(cache.Targets:size(), Medusa.Constants.Manpad.AUTONOMOUS_TARGET_CACHE_CAPACITY)
	for i = 1, cache.Targets:size() do
		local snapshot = cache.Targets:get(i)
		lu.assertNotNil(snapshot.UnitName)
		lu.assertNotNil(snapshot.Position)
		lu.assertNil(snapshot.Unit)
	end
end

function TestAutonomousAcquisition:test_removedGroup_isRemovedFromQueueAndCache()
	local store = newManpadView()
	local bat = makeManpadBattery({ Manpad = { SleepWakeState = "ASLEEP" } })
	store:add(bat)
	SearchWorldObjects = function() end
	local ctx = makeAutonomousContext(store, 0)

	Medusa.Services.ManpadService.evaluate(ctx)
	lu.assertNotNil(ctx.localSearch.cacheByBatteryId[bat.BatteryId])
	store:remove(bat.BatteryId)
	ctx.now = 1
	Medusa.Services.ManpadService.evaluate(ctx)

	lu.assertEquals(ctx.localSearch.queue:size(), 0)
	lu.assertNil(ctx.localSearch.cacheByBatteryId[bat.BatteryId])
end

-- ============================================================
-- 4. Engagement gate (3 tests)
-- Formerly tested via MS._processCandidateTracks; now routed through evaluate.
-- ============================================================

TestEngagementGate = {}

function TestEngagementGate:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	saveActivation()
	Medusa.Services.BatteryActivationService.goCold = function()
		return true
	end
end

function TestEngagementGate:tearDown()
	restoreActivation()
	restoreMocks()
end

local function buildProcessSetup(networkId, batOverrides)
	local store = newManpadView()
	local bat = makeManpadBattery(batOverrides)
	bat.NetworkId = networkId
	store:add(bat)
	return bat, store
end

-- ALERT + track in envelope + visible → goes HOT
function TestEngagementGate:test_alert_trackInEnvelope_goesHOT()
	local BAS = Medusa.Services.BatteryActivationService

	local bat, store = buildProcessSetup("net-engage-a", {
		TotalAmmoStatus = 5,
		EngagementRangeMax = 5000,
		Manpad = {
			SleepWakeState = "ALERT",
			AlertStartTime = 0,
			UnitHeadings = { makeHeadingVec(0) },
			UnitHeadingCount = 1,
		},
	})

	BAS.forceGoHot = function(battery, now)
		battery.Manpad.SleepWakeState = "HOT"
		return true
	end

	local track = makeTrack({ Position = { x = 2000, y = 0, z = 0 } })
	local trackStore = makeTrackStore({ ["track-1"] = track })
	local geoGrid = makeGeoGrid({ TrackIds = { ["track-1"] = true } })

	evalPositional(store, trackStore, geoGrid, 100, "NORMAL")

	lu.assertEquals(bat.Manpad.SleepWakeState, "HOT", "ALERT + in-envelope track must produce HOT state")
end

function TestEngagementGate:test_inferredAircraftTypes_areEligible()
	local aircraftTypes = {
		"FIXED_WING",
		"ROTARY_WING",
		"FIGHTER",
		"SEAD_AIRCRAFT",
	}
	Medusa.Services.BatteryActivationService.forceGoHot = function()
		return true
	end
	for i = 1, #aircraftTypes do
		local bat, store = buildProcessSetup("net-inferred-" .. i, {
			Manpad = { SleepWakeState = "ALERT", AlertStartTime = 0 },
		})
		local track = makeTrack({ TrackId = "track-" .. i, AssessedAircraftType = aircraftTypes[i] })
		evalPositional(
			store,
			makeTrackStore({ [track.TrackId] = track }),
			makeGeoGrid({ TrackIds = { [track.TrackId] = true } }),
			100,
			"NORMAL"
		)
		lu.assertEquals(bat.Manpad.SleepWakeState, "HOT")
	end
end

function TestEngagementGate:test_aircraftTrackPreventsAlertTimeout()
	local bat, store = buildProcessSetup("net-idle-track", {
		Manpad = {
			SleepWakeState = "ALERT",
			AlertStartTime = 0,
			UnitHeadings = {},
			UnitHeadingCount = 0,
		},
	})
	local track = makeTrack({ TrackId = "track-nearby", Position = { x = 5000, y = 0, z = 0 } })

	evalPositional(
		store,
		makeTrackStore({ [track.TrackId] = track }),
		makeGeoGrid({ TrackIds = { [track.TrackId] = true } }),
		901,
		"NORMAL"
	)

	lu.assertEquals(bat.Manpad.SleepWakeState, "ALERT")
end

function TestEngagementGate:test_nonAircraftTracksDoNotWakeOrPreventSleep()
	local aircraftTypes = { "UNKNOWN", "MISSILE", "HARM" }
	for i = 1, #aircraftTypes do
		local trackId = "non-aircraft-" .. i
		local track = makeTrack({ TrackId = trackId, AssessedAircraftType = aircraftTypes[i] })
		local trackStore = makeTrackStore({ [trackId] = track })
		local geoGrid = makeGeoGrid({ TrackIds = { [trackId] = true } })

		local asleep = makeManpadBattery({ Manpad = { SleepWakeState = "ASLEEP", AudioCueRangeM = 6000 } })
		evaluateSingle(asleep, trackStore, geoGrid, 901, "HOT_WAR")
		lu.assertEquals(asleep.Manpad.SleepWakeState, "ASLEEP")

		local alert = makeManpadBattery({ Manpad = { SleepWakeState = "ALERT", AlertStartTime = 0 } })
		evaluateSingle(alert, trackStore, geoGrid, 901, "NORMAL")
		lu.assertEquals(alert.Manpad.SleepWakeState, "ASLEEP")
	end
end

-- ALERT + ammo=0 → stays ALERT (zero-ammo battery must not engage)
function TestEngagementGate:test_alert_ammoZero_staysAlert()
	local BAS = Medusa.Services.BatteryActivationService

	local bat, store = buildProcessSetup("net-engage-b", {
		TotalAmmoStatus = 0,
		EngagementRangeMax = 5000,
		Manpad = {
			SleepWakeState = "ALERT",
			AlertStartTime = 0,
			UnitHeadings = { makeHeadingVec(0) },
			UnitHeadingCount = 1,
		},
	})

	local forceGoHotCalled = false
	BAS.forceGoHot = function(battery, now)
		forceGoHotCalled = true
		return true
	end

	local track = makeTrack({ Position = { x = 2000, y = 0, z = 0 } })
	local trackStore = makeTrackStore({ ["track-1"] = track })
	local geoGrid = makeGeoGrid({ TrackIds = { ["track-1"] = true } })

	evalPositional(store, trackStore, geoGrid, 100, "NORMAL")

	lu.assertFalse(forceGoHotCalled, "forceGoHot must not be called when ammo=0")
	lu.assertEquals(bat.Manpad.SleepWakeState, "ALERT", "state must stay ALERT when ammo is empty")
end

-- ALERT + forceGoHot returns false → stays ALERT (bug protection)
function TestEngagementGate:test_alert_forceGoHotFalse_staysAlert()
	local BAS = Medusa.Services.BatteryActivationService

	local bat, store = buildProcessSetup("net-engage-c", {
		TotalAmmoStatus = 5,
		EngagementRangeMax = 5000,
		Manpad = {
			SleepWakeState = "ALERT",
			AlertStartTime = 0,
			UnitHeadings = { makeHeadingVec(0) },
			UnitHeadingCount = 1,
		},
	})

	BAS.forceGoHot = function(battery, now)
		return false
	end

	local track = makeTrack({ Position = { x = 2000, y = 0, z = 0 } })
	local trackStore = makeTrackStore({ ["track-1"] = track })
	local geoGrid = makeGeoGrid({ TrackIds = { ["track-1"] = true } })

	evalPositional(store, trackStore, geoGrid, 100, "NORMAL")

	lu.assertEquals(bat.Manpad.SleepWakeState, "ALERT", "forceGoHot=false must leave state as ALERT")
end

-- ============================================================
-- 5. Wake triggers (2 tests)
-- ============================================================

TestWakeTriggers = {}

function TestWakeTriggers:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	saveActivation()
	Medusa.Services.BatteryActivationService.goCold = function()
		return true
	end
end

function TestWakeTriggers:tearDown()
	restoreActivation()
	restoreMocks()
end

-- cueFromIADS wakes ASLEEP MANPADs within 10km of track position
function TestWakeTriggers:test_cueFromIADS_wakesAsleepManpadsInRange()
	local MS = Medusa.Services.ManpadService
	local store = newManpadView()
	local asleep_bat = makeManpadBattery({
		BatteryId = "bat-cue-asleep",
		GroupId = 10,
		NetworkId = "net-cue-a",
		Manpad = { SleepWakeState = "ASLEEP", UnitHeadings = {}, UnitHeadingCount = 0 },
	})
	store:add(asleep_bat)

	local geoGrid = makeGeoGrid({ ManpadIds = { ["bat-cue-asleep"] = true } })

	MS.cueFromIADS({ manpadStore = store, localGeoGrid = geoGrid }, { x = 0, y = 0, z = 0 })

	lu.assertEquals(
		asleep_bat.Manpad.SleepWakeState,
		"ALERTING",
		"cueFromIADS must schedule a wake for ASLEEP MANPAD in range"
	)
end

function TestWakeTriggers:test_onManpadGoHot_usesDoctrineRadioRangeAndSkipsIneligibleGroups()
	local BAS = Medusa.Services.BatteryActivationService
	local store = newManpadView()

	local self_bat = makeManpadBattery({
		BatteryId = "bat-self",
		GroupId = 1,
		NetworkId = "net-gohot",
		TotalAmmoStatus = 5,
		Manpad = {
			SleepWakeState = "ALERT",
			AlertStartTime = 0,
			UnitHeadings = { makeHeadingVec(0) },
			UnitHeadingCount = 1,
		},
	})
	local neighbor_alert = makeManpadBattery({
		BatteryId = "bat-alert-nbr",
		GroupId = 2,
		NetworkId = "net-gohot",
		Role = Medusa.Constants.BatteryRole.MANPAD,
		Position = { x = 100, y = 0, z = 0 },
		Manpad = { SleepWakeState = "ALERT", UnitHeadings = {}, UnitHeadingCount = 0 },
	})
	local neighbor_asleep = makeManpadBattery({
		BatteryId = "bat-asleep-nbr",
		GroupId = 3,
		NetworkId = "net-gohot",
		Position = { x = 200, y = 0, z = 0 },
		Manpad = { SleepWakeState = "ASLEEP", UnitHeadings = {}, UnitHeadingCount = 0 },
	})
	store:add(self_bat)
	store:add(neighbor_alert)
	store:add(neighbor_asleep)

	local trackId = "track-hot"
	local radioQueryRangeM
	local geoGrid = {
		queryRadius = function(self, pos, radiusM, kinds)
			if kinds[1] == "Manpad" then
				radioQueryRangeM = radiusM
				return {
					ManpadIds = {
						["bat-self"] = true,
						["bat-alert-nbr"] = true,
						["bat-asleep-nbr"] = true,
					},
				}
			end
			return { TrackIds = { [trackId] = true } }
		end,
	}
	BAS.forceGoHot = function(battery, now)
		battery.Manpad.SleepWakeState = "HOT"
		return true
	end
	BAS.goCold = function()
		return true
	end

	local track = makeTrack({ TrackId = trackId, Position = { x = 4000, y = 0, z = 0 } })
	local trackStore = makeTrackStore({ [trackId] = track })

	evalPositional(store, trackStore, geoGrid, 100, "NORMAL", nil, nil, 7500)

	lu.assertEquals(radioQueryRangeM, 7500)
	lu.assertEquals(self_bat.Manpad.SleepWakeState, "HOT", "self must be HOT after engagement")
	lu.assertEquals(neighbor_alert.Manpad.SleepWakeState, "ALERT", "non-ASLEEP neighbor must not be rescheduled")
	lu.assertEquals(neighbor_asleep.Manpad.SleepWakeState, "ALERTING", "ASLEEP neighbor must be scheduled to wake")
	lu.assertEquals(neighbor_asleep.Manpad.WakeReason, "NEIGHBOR")
	timerHarness.time = 150
	for i = 1, #timerHarness.scheduledCallbacks do
		if timerHarness.scheduledCallbacks[i].id == neighbor_asleep.Manpad.WakeTimerId then
			timerHarness.scheduledCallbacks[i].fn(timerHarness.scheduledCallbacks[i].args)
			break
		end
	end
	lu.assertEquals(neighbor_asleep.Manpad.AlertCycleCount, 2)
	lu.assertEquals(neighbor_asleep.Manpad.LastAlertedTime, 150)
end

function TestWakeTriggers:test_onManpadGoHot_zeroRadioRangeDisablesNeighborWake()
	local store = newManpadView()
	local battery = makeManpadBattery({ Manpad = { SleepWakeState = "ALERT" } })
	local neighbor = makeManpadBattery({
		Position = { x = 20000, y = 0, z = 0 },
		Manpad = { SleepWakeState = "ASLEEP" },
	})
	store:add(battery)
	store:add(neighbor)
	local trackId = "track-radio-disabled"
	local manpadQueries = 0
	local geoGrid = {
		queryRadius = function(self, position, radiusM, kinds)
			if kinds[1] == "Manpad" then
				manpadQueries = manpadQueries + 1
				return { ManpadIds = { [neighbor.BatteryId] = true } }
			end
			if position.x == 0 then
				return { TrackIds = { [trackId] = true } }
			end
			return {}
		end,
	}
	Medusa.Services.BatteryActivationService.forceGoHot = function()
		return true
	end

	evalPositional(
		store,
		makeTrackStore({ [trackId] = makeTrack({ TrackId = trackId, Position = { x = 1000, y = 0, z = 0 } }) }),
		geoGrid,
		100,
		"NORMAL",
		nil,
		nil,
		0
	)

	lu.assertEquals(manpadQueries, 0)
	lu.assertEquals(neighbor.Manpad.SleepWakeState, "ASLEEP")
end

-- ============================================================
-- 6. Full state cycle integration (1 test)
--
-- ASLEEP → ALERTING (cueFromIADS) → ALERT (wake callback fires)
--        → HOT (engagement via evaluate) → COOLDOWN (goCold)
--        → ALERT (cooldown expires, evaluate) → ASLEEP (idle, evaluate)
-- ============================================================

TestFullStateCycle = {}

function TestFullStateCycle:setUp()
	installMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	saveActivation()
end

function TestFullStateCycle:tearDown()
	restoreActivation()
	restoreMocks()
end

function TestFullStateCycle:test_fullCycle_asleepToAlertToHotToCooldownToAlertToAsleep()
	local MS = Medusa.Services.ManpadService
	local BAS = Medusa.Services.BatteryActivationService
	local C = Medusa.Constants

	local store = newManpadView()
	local bat = makeManpadBattery({
		NetworkId = "net-cycle",
		TotalAmmoStatus = 5,
		EngagementRangeMax = 5000,
		Manpad = {
			SleepWakeState = "ASLEEP",
			AlertStartTime = nil,
			UnitHeadings = { makeHeadingVec(0) },
			UnitHeadingCount = 1,
			WakeTimerId = nil,
			AlertCycleCount = 1,
			LastAlertedTime = 0,
			AudioCueRangeM = 3000,
		},
	})
	store:add(bat)

	-- Dynamic geoGrid: returns ManpadIds for cueFromIADS queries, and can be overridden
	-- for track-based evaluate queries using the _override field.
	local _geoOverride = nil
	local idleGeoGrid = {
		queryRadius = function(self_, pos, radius, kinds)
			if _geoOverride then
				return _geoOverride
			end
			-- Default: return all batteries as ManpadIds (for cueFromIADS)
			local ids = {}
			for _, b in ipairs(store:getAll()) do
				ids[b.BatteryId] = true
			end
			return { ManpadIds = ids }
		end,
	}
	-- Step 1: cueFromIADS → ALERTING (dynamic grid returns bat's ManpadId)
	MS.cueFromIADS({ manpadStore = store, geoGrid = idleGeoGrid }, bat.Position)
	lu.assertEquals(bat.Manpad.SleepWakeState, "ALERTING", "Step 1: cueFromIADS must set ALERTING")

	-- Step 2: fire wake callback → ALERT
	timerHarness.time = 30
	local cb = timerHarness.scheduledCallbacks[1]
	cb.fn(cb.args)
	lu.assertEquals(bat.Manpad.SleepWakeState, "ALERT", "Step 2: wake callback must transition to ALERT")

	-- Step 3: evaluate with in-envelope track → HOT
	BAS.forceGoHot = function(battery, now)
		battery.Manpad.SleepWakeState = "HOT"
		battery.Manpad.HotUntil = now + 300
		return true
	end
	local track = makeTrack({ TrackId = "t1", Position = { x = 2000, y = 0, z = 0 } })
	local trackStore = makeTrackStore({ t1 = track })
	local engageGeoGrid = makeGeoGrid({ TrackIds = { t1 = true } })
	evalPositional(store, trackStore, engageGeoGrid, 30, "NORMAL")
	lu.assertEquals(bat.Manpad.SleepWakeState, "HOT", "Step 3: in-envelope track must produce HOT")

	-- Step 4: HOT → COOLDOWN via evaluate (HotUntil=330, now=400 → expired)
	bat.Manpad.HotUntil = 330
	BAS.goCold = function(battery, now, ts)
		battery.Manpad.SleepWakeState = "COOLDOWN"
		battery.Manpad.CooldownUntil = now + C.Manpad.COOLDOWN_SEC
		return true
	end
	evalPositional(store, makeTrackStore({}), idleGeoGrid, 400, "NORMAL")
	lu.assertEquals(bat.Manpad.SleepWakeState, "COOLDOWN", "Step 4: HOT must transition to COOLDOWN after HotUntil")

	-- Step 5: COOLDOWN → ALERT via evaluate (CooldownUntil=500, now=600 → expired)
	bat.Manpad.CooldownUntil = 500
	evalPositional(store, makeTrackStore({}), idleGeoGrid, 600, "NORMAL")
	lu.assertEquals(bat.Manpad.SleepWakeState, "ALERT", "Step 5: COOLDOWN must transition to ALERT after CooldownUntil")

	-- Step 6: ALERT → ASLEEP (idle timeout, no tracks)
	bat.Manpad.AlertStartTime = 0
	evalPositional(store, makeTrackStore({}), idleGeoGrid, 600 + C.Manpad.ALERT_TIMEOUT_SEC, "NORMAL")
	lu.assertEquals(bat.Manpad.SleepWakeState, "ASLEEP", "Step 6: ALERT must timeout to ASLEEP when no nearby tracks")
end
