local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Battery")
require("entities.Track")
require("entities.Doctrine")
require("services.Services")
require("services.stores.TrackStore")
require("services.stores.BatteryStore")
require("services.SpatialQuery")
require("services.TargetAssigner")
require("services.EmconService")

local AS = Medusa.Constants.ActivationState
local BOS = Medusa.Constants.BatteryOperationalStatus
local TA = Medusa.Services.TargetAssigner
local ES = Medusa.Services.EmconService

-- == Helpers ==

local function setupMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()

	GetGroupController = function(name)
		return { name = name }
	end
	GetControllerDetectedTargets = function(_controller)
		return {}
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

-- Fields that Battery.new() does NOT copy from data (lazy-initialized at runtime).
local LAZY_FIELDS = {
	"LastChanceTrackId",
	"LastChanceExpiresAt",
	"LastChanceShotsRemaining",
	"LastChanceExtended",
	"MissileInFlightUntil",
	"LastAssignmentChangeTime",
	"LastShotTime",
	"CurrentTargetTrackId",
	"HarmShutdownUntil",
}

local function makeBattery(overrides)
	local data = {
		NetworkId = "bat-net-1",
		GroupId = 100,
		GroupName = "SAM-1",
		ActivationState = AS.STATE_HOT,
		OperationalStatus = BOS.ACTIVE,
		Position = { x = 0, y = 0, z = 0 },
		EngagementRangeMax = 50000,
		PkRangeOptimal = 22500,
		PkRangeSigma = 12500,
		TotalAmmoStatus = 10,
		EngagementAltitudeMin = 0,
		EngagementAltitudeMax = 30000,
	}
	if overrides then
		for k, v in pairs(overrides) do
			data[k] = v
		end
	end
	local battery = Medusa.Entities.Battery.new(data)
	-- Apply lazy-init fields that Battery.new() silently drops.
	if overrides then
		for _, field in ipairs(LAZY_FIELDS) do
			if overrides[field] ~= nil then
				battery[field] = overrides[field]
			end
		end
	end
	return battery
end

local function makeTrack(overrides)
	local data = {
		NetworkId = "net-track-1",
		Position = { x = 22500, y = 5000, z = 0 },
		Velocity = { x = -200, y = 0, z = 0 },
		LifecycleState = Medusa.Constants.TrackLifecycleState.ACTIVE,
		TrackIdentification = "BANDIT",
	}
	if overrides then
		for k, v in pairs(overrides) do
			data[k] = v
		end
	end
	return Medusa.Entities.Track.new(data)
end

local function makeFreeDoctrine(overrides)
	local d = { ROE = "FREE", HoldDownSec = 15 }
	if overrides then
		for k, v in pairs(overrides) do
			d[k] = v
		end
	end
	return d
end

-- Minimal mock store factories so we can drive checkDeactivations directly
-- without relying on the full store implementations for these lower-level tests.

local function makeBatteryStoreMock(batteries)
	return {
		getAll = function(self, buf)
			buf = buf or {}
			for i = 1, #batteries do
				buf[i] = batteries[i]
			end
			-- zero out any stale tail entries that might persist across calls
			for i = #batteries + 1, #buf do
				buf[i] = nil
			end
			return buf
		end,
	}
end

local function makeTrackStoreMock(tracks)
	-- index by TrackId for :get()
	local byId = {}
	for i = 1, #tracks do
		local t = tracks[i]
		if t.TrackId then
			byId[t.TrackId] = t
		end
	end
	return {
		get = function(self, trackId)
			return byId[trackId]
		end,
		getAll = function(self, buf)
			buf = buf or {}
			local idx = 1
			for _, t in pairs(byId) do
				buf[idx] = t
				idx = idx + 1
			end
			for i = idx, #buf do
				buf[i] = nil
			end
			return buf
		end,
	}
end

-- ============================================================
-- Contract 1: batteryDetectsTrack
-- Accessed via checkDeactivations (hold-down-expired-detected branch).
-- We verify detection by observing whether checkDeactivations extends
-- LastChanceExpiresAt (detected) vs deactivates (not detected).
-- ============================================================

TestBatteryDetectsTrack = {}

function TestBatteryDetectsTrack:setUp()
	setupMocks()
end

-- Happy path: controller returns a detection entry whose id_ matches track.NetworkId.
-- Detection is confirmed when checkDeactivations extends LastChanceExpiresAt.
function TestBatteryDetectsTrack:test_detectsTrack_whenIdMatches()
	local now = 1000
	local expiresAt = now -- expired right now
	local trackNetId = 42

	GetGroupController = function(_name)
		return { name = "SAM-1" }
	end
	GetControllerDetectedTargets = function(_controller)
		return { { object = { id_ = trackNetId } } }
	end

	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = expiresAt,
		LastChanceShotsRemaining = 2,
	})

	local track = makeTrack({
		TrackId = "LC-1",
		NetworkId = tostring(trackNetId),
	})
	-- NetworkId stored as number in the detection lookup
	track.NetworkId = trackNetId

	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine({ HoldDownSec = 15 })

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	-- Battery detected the track: hold-down should extend, not deactivate
	lu.assertEquals(#result, 0, "detected track: battery must NOT be deactivated")
	lu.assertTrue(battery.LastChanceExpiresAt > expiresAt, "detected track: LastChanceExpiresAt must be extended")
end

-- Nil track: if track cannot be retrieved, detection returns false -> deactivate.
function TestBatteryDetectsTrack:test_detectsTrack_nilTrack_deactivates()
	local now = 1000
	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "GONE-TRACK",
		LastChanceExpiresAt = now, -- expired
		LastChanceShotsRemaining = 1,
	})

	-- trackStore returns nil for the last-chance track ID
	local trackStore = makeTrackStoreMock({})
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine()

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 1, "nil track: battery must be deactivated")
end

-- Nil controller: GetGroupController returns nil -> detection false -> deactivate.
function TestBatteryDetectsTrack:test_detectsTrack_nilController_deactivates()
	local now = 1000
	GetGroupController = function(_name)
		return nil
	end

	local track = makeTrack({ TrackId = "LC-1", NetworkId = 77 })
	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now,
		LastChanceShotsRemaining = 1,
	})

	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine()

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 1, "nil controller: battery must be deactivated")
end

-- Nil detections list: GetControllerDetectedTargets returns nil -> detection false.
function TestBatteryDetectsTrack:test_detectsTrack_nilDetections_deactivates()
	local now = 1000
	GetGroupController = function(_name)
		return { name = "SAM-1" }
	end
	GetControllerDetectedTargets = function(_controller)
		return nil
	end

	local track = makeTrack({ TrackId = "LC-1", NetworkId = 77 })
	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now,
		LastChanceShotsRemaining = 1,
	})

	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine()

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 1, "nil detections: battery must be deactivated")
end

-- Empty detections list: no entries -> no match -> deactivate.
function TestBatteryDetectsTrack:test_detectsTrack_emptyDetections_deactivates()
	local now = 1000
	GetGroupController = function(_name)
		return { name = "SAM-1" }
	end
	GetControllerDetectedTargets = function(_controller)
		return {}
	end

	local track = makeTrack({ TrackId = "LC-1", NetworkId = 77 })
	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now,
		LastChanceShotsRemaining = 1,
	})

	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine()

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 1, "empty detections: battery must be deactivated")
end

-- Detection list contains one entry that does NOT match: still no detection.
function TestBatteryDetectsTrack:test_detectsTrack_wrongId_deactivates()
	local now = 1000
	GetGroupController = function(_name)
		return { name = "SAM-1" }
	end
	GetControllerDetectedTargets = function(_controller)
		return { { object = { id_ = 999 } } }
	end

	local track = makeTrack({ TrackId = "LC-1", NetworkId = 77 })
	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now,
		LastChanceShotsRemaining = 1,
	})

	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine()

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 1, "wrong id_: battery must be deactivated")
end

-- Track.NetworkId is nil: no possible match -> deactivate.
function TestBatteryDetectsTrack:test_detectsTrack_nilNetworkId_deactivates()
	local now = 1000
	GetGroupController = function(_name)
		return { name = "SAM-1" }
	end
	GetControllerDetectedTargets = function(_controller)
		return { { object = { id_ = 77 } } }
	end

	-- NetworkId explicitly nil
	local track = makeTrack({ TrackId = "LC-1" })
	track.NetworkId = nil

	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now,
		LastChanceShotsRemaining = 1,
	})

	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine()

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 1, "nil NetworkId: battery must be deactivated")
end

-- Multiple detections: match is in the middle of the list.
function TestBatteryDetectsTrack:test_detectsTrack_matchInMiddleOfList()
	local now = 1000
	local expiresAt = now
	local trackNetId = 55

	GetGroupController = function(_name)
		return { name = "SAM-1" }
	end
	GetControllerDetectedTargets = function(_controller)
		return {
			{ object = { id_ = 11 } },
			{ object = { id_ = trackNetId } },
			{ object = { id_ = 99 } },
		}
	end

	local track = makeTrack({ TrackId = "LC-1", NetworkId = trackNetId })
	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = expiresAt,
		LastChanceShotsRemaining = 2,
	})

	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine({ HoldDownSec = 15 })

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 0, "match in middle of list: must NOT deactivate")
	lu.assertTrue(battery.LastChanceExpiresAt > expiresAt, "must extend expiry on match")
end

-- ============================================================
-- Contract 2: checkDeactivations — last-chance branches
-- ============================================================

TestCheckDeactivationsLastChance = {}

function TestCheckDeactivationsLastChance:setUp()
	setupMocks()
end

-- Branch: shots exhausted AND no missile in flight -> clear fields, deactivate.
function TestCheckDeactivationsLastChance:test_shotsExhausted_noMissile_deactivates()
	local now = 1000
	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now + 30, -- still within hold-down, but shots exhausted
		LastChanceShotsRemaining = 0,
		MissileInFlightUntil = nil,
	})

	local track = makeTrack({ TrackId = "LC-1", NetworkId = 42 })
	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine()

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 1, "shots exhausted, no missile: must deactivate")
	lu.assertNil(battery.LastChanceTrackId, "LastChanceTrackId must be cleared")
	lu.assertNil(battery.LastChanceShotsRemaining, "LastChanceShotsRemaining must be cleared")
end

-- Branch: shots exhausted AND missile still flying -> stay HOT.
function TestCheckDeactivationsLastChance:test_shotsExhausted_missileFlying_staysHot()
	local now = 1000
	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now + 30,
		LastChanceShotsRemaining = 0,
		MissileInFlightUntil = now + 10, -- missile still flying
	})

	local track = makeTrack({ TrackId = "LC-1", NetworkId = 42 })
	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine()

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 0, "shots exhausted but missile flying: must stay HOT")
end

-- Boundary: missile expiry exactly equals now (expired, not flying) -> deactivate.
function TestCheckDeactivationsLastChance:test_shotsExhausted_missileExpiredAtNow_deactivates()
	local now = 1000
	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now + 30,
		LastChanceShotsRemaining = 0,
		MissileInFlightUntil = now, -- exactly now: not strictly < now, treat as expired
	})

	local track = makeTrack({ TrackId = "LC-1", NetworkId = 42 })
	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine()

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	-- now < MissileInFlightUntil is false when equal, so missile is NOT flying
	lu.assertEquals(#result, 1, "missile expired exactly at now: must deactivate")
end

-- Branch: hold-down still active (now < LastChanceExpiresAt) -> stay HOT.
function TestCheckDeactivationsLastChance:test_holdDownActive_staysHot()
	local now = 1000
	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now + 5, -- expires in the future
		LastChanceShotsRemaining = 2,
		MissileInFlightUntil = nil,
	})

	local track = makeTrack({ TrackId = "LC-1", NetworkId = 42 })
	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine()

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 0, "hold-down active: must stay HOT")
end

-- Boundary: hold-down expires exactly at now -> should check detection.
function TestCheckDeactivationsLastChance:test_holdDownExpiredExactlyAtNow_checkDetection()
	local now = 1000
	GetGroupController = function(_name)
		return { name = "SAM-1" }
	end
	GetControllerDetectedTargets = function(_controller)
		-- no detections
		return {}
	end

	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now, -- exactly now: expired
		LastChanceShotsRemaining = 2,
		MissileInFlightUntil = nil,
	})

	local track = makeTrack({ TrackId = "LC-1", NetworkId = 42 })
	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine()

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	-- Hold-down expired, no detection -> deactivate
	lu.assertEquals(#result, 1, "hold-down exactly expired, no detection: must deactivate")
end

-- Branch: hold-down expired, battery detects track -> extend LastChanceExpiresAt.
function TestCheckDeactivationsLastChance:test_holdDownExpired_detected_extendsExpiry()
	local now = 1000
	local holdDownSec = 15
	local trackNetId = 42

	GetGroupController = function(_name)
		return { name = "SAM-1" }
	end
	GetControllerDetectedTargets = function(_controller)
		return { { object = { id_ = trackNetId } } }
	end

	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now - 1, -- expired one second ago
		LastChanceShotsRemaining = 3,
		MissileInFlightUntil = nil,
	})

	local track = makeTrack({ TrackId = "LC-1", NetworkId = trackNetId })
	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine({ HoldDownSec = holdDownSec })

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 0, "detected: must stay HOT")
	lu.assertEquals(battery.LastChanceExpiresAt, now + holdDownSec, "must extend LastChanceExpiresAt by HoldDownSec")
end

-- Branch: hold-down expired, no detection -> clear fields, deactivate.
function TestCheckDeactivationsLastChance:test_holdDownExpired_notDetected_deactivates()
	local now = 1000
	GetGroupController = function(_name)
		return { name = "SAM-1" }
	end
	GetControllerDetectedTargets = function(_controller)
		return {}
	end

	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now - 1, -- expired
		LastChanceShotsRemaining = 3,
		MissileInFlightUntil = nil,
	})

	local track = makeTrack({ TrackId = "LC-1", NetworkId = 42 })
	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine()

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 1, "expired hold-down, no detection: must deactivate")
	lu.assertNil(battery.LastChanceTrackId, "LastChanceTrackId must be cleared on deactivation")
	lu.assertNil(battery.LastChanceShotsRemaining, "LastChanceShotsRemaining must be cleared on deactivation")
end

-- Fallback branch: no LastChanceTrackId -> uses standard POST_HANDOFF_HOT_SEC logic.
-- A HOT battery with nil CurrentTargetTrackId and nil LastChanceTrackId should
-- fall through to existing deactivation logic and be deactivated.
function TestCheckDeactivationsLastChance:test_noLastChance_fallsBackToStandardLogic()
	local now = 1000
	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		ActivationState = AS.STATE_HOT,
		CurrentTargetTrackId = nil,
		LastChanceTrackId = nil,
		LastChanceShotsRemaining = nil,
		MissileInFlightUntil = nil,
	})

	local trackStore = makeTrackStoreMock({})
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine({ HoldDownSec = 0 })

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 1, "no last-chance fields: standard logic must deactivate")
end

-- State must be STATE_HOT to enter any last-chance branch at all.
-- A COLD battery with last-chance fields set must be ignored.
function TestCheckDeactivationsLastChance:test_coldBattery_ignoredEvenWithLastChanceFields()
	local now = 1000
	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		ActivationState = AS.STATE_COLD,
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now + 30,
		LastChanceShotsRemaining = 2,
	})

	local track = makeTrack({ TrackId = "LC-1", NetworkId = 42 })
	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine()

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 0, "COLD battery: must be ignored entirely")
end

-- Multiple batteries: last-chance deactivation is per-battery, not global.
function TestCheckDeactivationsLastChance:test_mixedBatteries_onlyExhaustedOneDeactivates()
	local now = 1000
	local trackNetId = 42

	GetGroupController = function(_name)
		return { name = "SAM-1" }
	end
	GetControllerDetectedTargets = function(_controller)
		return { { object = { id_ = trackNetId } } }
	end

	-- B1: exhausted and no missile -> deactivate
	local b1 = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		GroupId = 101,
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now + 30,
		LastChanceShotsRemaining = 0,
		MissileInFlightUntil = nil,
	})

	-- B2: hold-down still active -> stay HOT
	local b2 = makeBattery({
		BatteryId = "B2",
		GroupName = "SAM-2",
		GroupId = 102,
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now + 10,
		LastChanceShotsRemaining = 1,
		MissileInFlightUntil = nil,
	})

	local track = makeTrack({ TrackId = "LC-1", NetworkId = trackNetId })
	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ b1, b2 })
	local doctrine = makeFreeDoctrine()

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 1, "only exhausted battery must be deactivated")
	lu.assertIs(result[1].battery, b1, "the deactivated battery must be B1")
end

-- Nil doctrine: must not error; HoldDownSec should default gracefully.
function TestCheckDeactivationsLastChance:test_nilDoctrine_doesNotError()
	local now = 1000
	GetGroupController = function(_name)
		return { name = "SAM-1" }
	end
	GetControllerDetectedTargets = function(_controller)
		return {}
	end

	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now - 1,
		LastChanceShotsRemaining = 1,
		MissileInFlightUntil = nil,
	})

	local track = makeTrack({ TrackId = "LC-1", NetworkId = 42 })
	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })

	local ok, err = pcall(function()
		TA.checkDeactivations(trackStore, batteryStore, nil, now)
	end)

	lu.assertTrue(ok, string.format("nil doctrine must not raise an error: %s", tostring(err)))
end

-- Empty battery store: must return empty result.
function TestCheckDeactivationsLastChance:test_emptyBatteryStore_returnsEmpty()
	local now = 1000
	local trackStore = makeTrackStoreMock({})
	local batteryStore = makeBatteryStoreMock({})
	local doctrine = makeFreeDoctrine()

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 0, "empty store: must return empty result")
end

-- Branch: second hold-down expiry with detection -> unconditional deactivation.
-- Even though the battery radar still sees the target, LastChanceExtended = true
-- means no further extension is allowed; battery must be deactivated and all
-- last-chance fields cleared.
function TestCheckDeactivationsLastChance:test_secondHoldDownExpired_deactivatesRegardless()
	local now = 1000
	local trackNetId = 42

	-- Radar confirms target is still detected (would normally extend hold-down).
	GetGroupController = function(_name)
		return { name = "SAM-1" }
	end
	GetControllerDetectedTargets = function(_controller)
		return { { object = { id_ = trackNetId } } }
	end

	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now - 1, -- hold-down expired
		LastChanceShotsRemaining = 2,
		LastChanceExtended = true, -- already extended once
		MissileInFlightUntil = nil,
	})

	local track = makeTrack({ TrackId = "LC-1", NetworkId = trackNetId })
	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine({ HoldDownSec = 15 })

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 1, "second expiry with detection: battery must be deactivated unconditionally")
	lu.assertNil(battery.LastChanceTrackId, "LastChanceTrackId must be cleared")
	lu.assertNil(battery.LastChanceExpiresAt, "LastChanceExpiresAt must be cleared")
	lu.assertNil(battery.LastChanceShotsRemaining, "LastChanceShotsRemaining must be cleared")
	lu.assertNil(battery.LastChanceExtended, "LastChanceExtended must be cleared")
end

-- Branch: second hold-down expiry without detection -> unconditional deactivation.
-- Mirrors the above test to confirm the short-circuit fires regardless of radar state.
function TestCheckDeactivationsLastChance:test_secondHoldDownExpired_noDetection_deactivates()
	local now = 1000

	GetGroupController = function(_name)
		return { name = "SAM-1" }
	end
	GetControllerDetectedTargets = function(_controller)
		return {} -- nothing detected
	end

	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now - 1, -- hold-down expired
		LastChanceShotsRemaining = 3,
		LastChanceExtended = true, -- already extended once
		MissileInFlightUntil = nil,
	})

	local track = makeTrack({ TrackId = "LC-1", NetworkId = 42 })
	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine({ HoldDownSec = 15 })

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 1, "second expiry, no detection: battery must be deactivated")
	lu.assertNil(battery.LastChanceTrackId, "LastChanceTrackId must be cleared")
	lu.assertNil(battery.LastChanceExpiresAt, "LastChanceExpiresAt must be cleared")
	lu.assertNil(battery.LastChanceShotsRemaining, "LastChanceShotsRemaining must be cleared")
	lu.assertNil(battery.LastChanceExtended, "LastChanceExtended must be cleared")
end

-- Branch: first hold-down expiry with detection -> sets LastChanceExtended = true.
-- After a successful detection check that extends the hold-down, the battery must
-- record that one extension has been consumed.
function TestCheckDeactivationsLastChance:test_firstExtension_setsExtendedFlag()
	local now = 1000
	local trackNetId = 55

	GetGroupController = function(_name)
		return { name = "SAM-1" }
	end
	GetControllerDetectedTargets = function(_controller)
		return { { object = { id_ = trackNetId } } }
	end

	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now - 1, -- expired
		LastChanceShotsRemaining = 2,
		-- LastChanceExtended intentionally absent (nil = not yet extended)
		MissileInFlightUntil = nil,
	})

	local track = makeTrack({ TrackId = "LC-1", NetworkId = trackNetId })
	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine({ HoldDownSec = 15 })

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 0, "first extension: battery must stay HOT")
	lu.assertEquals(battery.LastChanceExtended, true, "first extension: LastChanceExtended must be set to true")
end

-- Branch: extended flag set but hold-down is still active (timer running) -> stays HOT.
-- LastChanceExtended = true does NOT mean deactivate; the timer must also be expired.
function TestCheckDeactivationsLastChance:test_holdDownActive_afterExtension_staysHot()
	local now = 1000

	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-1",
		LastChanceExpiresAt = now + 10, -- hold-down still running
		LastChanceShotsRemaining = 2,
		LastChanceExtended = true, -- extended once, but timer not yet expired
		MissileInFlightUntil = nil,
	})

	local track = makeTrack({ TrackId = "LC-1", NetworkId = 42 })
	local trackStore = makeTrackStoreMock({ track })
	local batteryStore = makeBatteryStoreMock({ battery })
	local doctrine = makeFreeDoctrine({ HoldDownSec = 15 })

	local result = TA.checkDeactivations(trackStore, batteryStore, doctrine, now)

	lu.assertEquals(#result, 0, "extended flag set but timer active: battery must stay HOT")
	lu.assertEquals(battery.LastChanceExtended, true, "LastChanceExtended must remain true while timer runs")
end

-- ============================================================
-- Contract 2 (real stores): smoke test through real BatteryStore / TrackStore
-- ============================================================

TestCheckDeactivationsRealStores = {}

function TestCheckDeactivationsRealStores:setUp()
	setupMocks()
	self.trackStore = Medusa.Services.TrackStore:new()
	self.batteryStore = Medusa.Services.BatteryStore:new()
end

-- Shots exhausted, no missile, real stores -> deactivates.
function TestCheckDeactivationsRealStores:test_realStores_shotsExhausted_deactivates()
	local now = 1000
	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-REAL",
		LastChanceExpiresAt = now + 30,
		LastChanceShotsRemaining = 0,
		MissileInFlightUntil = nil,
	})
	self.batteryStore:add(battery)

	local track = makeTrack({ TrackId = "LC-REAL", NetworkId = 99 })
	self.trackStore:add(track)

	local doctrine = makeFreeDoctrine()
	local result = TA.checkDeactivations(self.trackStore, self.batteryStore, doctrine, now)

	lu.assertEquals(#result, 1, "real stores: exhausted battery must be deactivated")
end

-- Hold-down active, real stores -> stays HOT.
function TestCheckDeactivationsRealStores:test_realStores_holdDownActive_staysHot()
	local now = 1000
	local battery = makeBattery({
		BatteryId = "B1",
		GroupName = "SAM-1",
		CurrentTargetTrackId = nil,
		LastChanceTrackId = "LC-REAL",
		LastChanceExpiresAt = now + 20,
		LastChanceShotsRemaining = 2,
		MissileInFlightUntil = nil,
	})
	self.batteryStore:add(battery)

	local track = makeTrack({ TrackId = "LC-REAL", NetworkId = 99 })
	self.trackStore:add(track)

	local doctrine = makeFreeDoctrine()
	local result = TA.checkDeactivations(self.trackStore, self.batteryStore, doctrine, now)

	lu.assertEquals(#result, 0, "real stores: active hold-down must keep battery HOT")
end
