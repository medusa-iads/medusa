local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Track")
require("entities.Battery")
require("services.Services")
require("services.stores.TrackStore")
require("services.stores.BatteryStore")
require("services.SpatialQuery")
require("services.TrackClassifier")

-- == Helpers ==

local mockTime = 1000

local function setupMocks()
	mockTime = 1000
	GetTime = function()
		return mockTime
	end
	NewULID = function()
		return string.format("ULID-%d", math.random(1, 999999))
	end
end

local function makeTrack(overrides)
	local base = {
		Position = { x = 1000, y = 500, z = 2000 },
		Velocity = { x = 100, y = 0, z = 50 },
		NetworkId = overrides and overrides.NetworkId or string.format("net-%d", math.random(1, 999999)),
	}
	if overrides then
		for k, v in pairs(overrides) do
			base[k] = v
		end
	end
	return Medusa.Entities.Track.new(base)
end

local function makeMockGeoGrid(batteryStore)
	return {
		queryRadius = function(_, _, _, _)
			local ids = {}
			local all = batteryStore:getAll()
			for i = 1, #all do
				ids[all[i].BatteryId] = true
			end
			return { BatteryIds = ids }
		end,
	}
end

local function makeBattery(overrides)
	local base = {
		NetworkId = 1,
		GroupId = 1,
		GroupName = "SAM-1",
		OperationalStatus = "ACTIVE",
		Position = { x = 1000, y = 0, z = 2000 },
		EngagementRangeMax = 50000,
	}
	if overrides then
		for k, v in pairs(overrides) do
			base[k] = v
		end
	end
	return Medusa.Entities.Battery.new(base)
end

-- == TestUpdateIdentifications ==

TestUpdateIdentifications = {}

function TestUpdateIdentifications:setUp()
	setupMocks()
	self.trackStore = Medusa.Services.TrackStore:new()
	self.batteryStore = Medusa.Services.BatteryStore:new()
	self.geoGrid = makeMockGeoGrid(self.batteryStore)
end

function TestUpdateIdentifications:test_unknown_promoted_to_bogey_at_min_updates()
	local track = makeTrack({ TrackIdentification = "UNKNOWN", UpdateCount = 3 })
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.updateIdentifications(
		self.trackStore,
		self.batteryStore,
		nil,
		1000,
		50000,
		self.geoGrid
	)

	lu.assertEquals(track.TrackIdentification, "BOGEY")
	lu.assertEquals(track.LastIdentificationTime, 1000)
end

function TestUpdateIdentifications:test_unknown_not_promoted_below_min_updates()
	local track = makeTrack({ TrackIdentification = "UNKNOWN", UpdateCount = 2 })
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.updateIdentifications(
		self.trackStore,
		self.batteryStore,
		nil,
		1000,
		50000,
		self.geoGrid
	)

	lu.assertEquals(track.TrackIdentification, "UNKNOWN")
end

function TestUpdateIdentifications:test_bogey_promoted_to_bandit_in_envelope()
	local track = makeTrack({
		TrackIdentification = "BOGEY",
		Position = { x = 1000, y = 500, z = 2000 },
	})
	self.trackStore:add(track)

	local battery = makeBattery({
		Position = { x = 1500, y = 0, z = 2500 },
		EngagementRangeMax = 50000,
	})
	self.batteryStore:add(battery)

	Medusa.Services.TrackClassifier.updateIdentifications(
		self.trackStore,
		self.batteryStore,
		nil,
		1000,
		50000,
		self.geoGrid
	)

	lu.assertEquals(track.TrackIdentification, "BANDIT")
	lu.assertEquals(track.LastIdentificationTime, 1000)
end

function TestUpdateIdentifications:test_bogey_not_promoted_outside_envelope()
	local track = makeTrack({
		TrackIdentification = "BOGEY",
		Position = { x = 100000, y = 500, z = 200000 },
	})
	self.trackStore:add(track)

	local battery = makeBattery({
		Position = { x = 0, y = 0, z = 0 },
		EngagementRangeMax = 1000,
	})
	self.batteryStore:add(battery)

	Medusa.Services.TrackClassifier.updateIdentifications(
		self.trackStore,
		self.batteryStore,
		nil,
		1000,
		1000,
		self.geoGrid
	)

	lu.assertEquals(track.TrackIdentification, "BOGEY")
end

function TestUpdateIdentifications:test_bogey_uses_default_range_when_battery_has_none()
	local track = makeTrack({
		TrackIdentification = "BOGEY",
		Position = { x = 1000, y = 500, z = 2000 },
	})
	self.trackStore:add(track)

	local battery = makeBattery({
		Position = { x = 1500, y = 0, z = 2500 },
		EngagementRangeMax = nil,
	})
	self.batteryStore:add(battery)

	Medusa.Services.TrackClassifier.updateIdentifications(
		self.trackStore,
		self.batteryStore,
		nil,
		1000,
		50000,
		self.geoGrid
	)

	lu.assertEquals(track.TrackIdentification, "BANDIT")
end

function TestUpdateIdentifications:test_bandit_promoted_to_hostile_after_dwell()
	local track = makeTrack({
		TrackIdentification = "BANDIT",
		LastIdentificationTime = 950,
	})
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.updateIdentifications(
		self.trackStore,
		self.batteryStore,
		nil,
		1000,
		50000,
		self.geoGrid
	)

	lu.assertEquals(track.TrackIdentification, "HOSTILE")
	lu.assertEquals(track.LastIdentificationTime, 1000)
end

function TestUpdateIdentifications:test_bandit_not_promoted_before_dwell()
	local track = makeTrack({
		TrackIdentification = "BANDIT",
		LastIdentificationTime = 990,
	})
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.updateIdentifications(
		self.trackStore,
		self.batteryStore,
		nil,
		1000,
		50000,
		self.geoGrid
	)

	lu.assertEquals(track.TrackIdentification, "BANDIT")
end

function TestUpdateIdentifications:test_hostile_not_demoted()
	local track = makeTrack({ TrackIdentification = "HOSTILE", UpdateCount = 0 })
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.updateIdentifications(
		self.trackStore,
		self.batteryStore,
		nil,
		1000,
		50000,
		self.geoGrid
	)

	lu.assertEquals(track.TrackIdentification, "HOSTILE")
end

function TestUpdateIdentifications:test_bogey_skips_inactive_batteries()
	local track = makeTrack({
		TrackIdentification = "BOGEY",
		Position = { x = 1000, y = 500, z = 2000 },
	})
	self.trackStore:add(track)

	local battery = makeBattery({
		OperationalStatus = "DESTROYED",
		Position = { x = 1000, y = 0, z = 2000 },
		EngagementRangeMax = 50000,
	})
	self.batteryStore:add(battery)

	Medusa.Services.TrackClassifier.updateIdentifications(
		self.trackStore,
		self.batteryStore,
		nil,
		1000,
		50000,
		self.geoGrid
	)

	lu.assertEquals(track.TrackIdentification, "BOGEY")
end

function TestUpdateIdentifications:test_no_double_promotion_in_one_tick()
	-- UNKNOWN with enough updates should go to BOGEY, not further
	local track = makeTrack({ TrackIdentification = "UNKNOWN", UpdateCount = 5 })
	self.trackStore:add(track)

	local battery = makeBattery({
		Position = { x = 1000, y = 0, z = 2000 },
		EngagementRangeMax = 50000,
	})
	self.batteryStore:add(battery)

	Medusa.Services.TrackClassifier.updateIdentifications(
		self.trackStore,
		self.batteryStore,
		nil,
		1000,
		50000,
		self.geoGrid
	)

	lu.assertEquals(track.TrackIdentification, "BOGEY")
end

function TestUpdateIdentifications:test_bandit_without_identification_time_not_promoted()
	local track = makeTrack({
		TrackIdentification = "BANDIT",
		LastIdentificationTime = nil,
	})
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.updateIdentifications(
		self.trackStore,
		self.batteryStore,
		nil,
		1000,
		50000,
		self.geoGrid
	)

	lu.assertEquals(track.TrackIdentification, "BANDIT")
end

-- Track closing on a battery in WARM_WAR should promote BANDIT->HOSTILE after 60s
function TestUpdateIdentifications:test_bandit_promoted_to_hostile_via_hostile_intent()
	local battery = makeBattery({ Position = { x = 50000, y = 0, z = 0 } })
	self.batteryStore:add(battery)

	-- Track at origin, flying east toward battery at 200 m/s
	local track = makeTrack({
		TrackIdentification = "BANDIT",
		LastIdentificationTime = 900,
		Position = { x = 0, y = 5000, z = 0 },
		Velocity = { x = 200, y = 0, z = 0 },
	})
	self.trackStore:add(track)

	local doctrine = { Posture = "WARM_WAR" }

	-- First call: starts the clock, stays BANDIT
	Medusa.Services.TrackClassifier.updateIdentifications(
		self.trackStore,
		self.batteryStore,
		doctrine,
		1000,
		200000,
		self.geoGrid
	)
	lu.assertEquals(track.TrackIdentification, "BANDIT")
	lu.assertNotNil(track.HostileIntentStart)

	-- Second call at +61s: sustained intent met, promotes to HOSTILE
	Medusa.Services.TrackClassifier.updateIdentifications(
		self.trackStore,
		self.batteryStore,
		doctrine,
		1061,
		200000,
		self.geoGrid
	)
	lu.assertEquals(track.TrackIdentification, "HOSTILE")
end

-- Track diverging from battery should NOT trigger hostile intent
function TestUpdateIdentifications:test_bandit_not_promoted_when_diverging()
	local battery = makeBattery({ Position = { x = 50000, y = 0, z = 0 } })
	self.batteryStore:add(battery)

	-- Track flying AWAY from battery (west, battery is east)
	local track = makeTrack({
		TrackIdentification = "BANDIT",
		LastIdentificationTime = 900,
		Position = { x = 40000, y = 5000, z = 0 },
		Velocity = { x = -200, y = 0, z = 0 },
	})
	self.trackStore:add(track)

	local doctrine = { Posture = "WARM_WAR" }

	Medusa.Services.TrackClassifier.updateIdentifications(
		self.trackStore,
		self.batteryStore,
		doctrine,
		1000,
		200000,
		self.geoGrid
	)
	lu.assertEquals(track.TrackIdentification, "BANDIT")
	lu.assertNil(track.HostileIntentStart)

	Medusa.Services.TrackClassifier.updateIdentifications(
		self.trackStore,
		self.batteryStore,
		doctrine,
		1061,
		200000,
		self.geoGrid
	)
	lu.assertEquals(track.TrackIdentification, "BANDIT")
end

-- == TestAssessAircraftTypes ==

TestAssessAircraftTypes = {}

function TestAssessAircraftTypes:setUp()
	setupMocks()
	self.trackStore = Medusa.Services.TrackStore:new()
end

function TestAssessAircraftTypes:test_slow_track_classified_as_rotary_wing()
	local track = makeTrack({ Velocity = { x = 50, y = 0, z = 30 } })
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.assessAircraftTypes(self.trackStore)

	lu.assertEquals(track.AssessedAircraftType, "ROTARY_WING")
end

function TestAssessAircraftTypes:test_medium_speed_classified_as_fixed_wing()
	local track = makeTrack({ Velocity = { x = 150, y = 0, z = 100 } })
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.assessAircraftTypes(self.trackStore)

	lu.assertEquals(track.AssessedAircraftType, "FIXED_WING")
end

function TestAssessAircraftTypes:test_supersonic_track_classified_as_missile()
	local track = makeTrack({ Velocity = { x = 1000, y = 0, z = 200 } })
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.assessAircraftTypes(self.trackStore)

	lu.assertEquals(track.AssessedAircraftType, "MISSILE")
end

function TestAssessAircraftTypes:test_fast_subsonic_track_classified_as_fixed_wing()
	local track = makeTrack({ Velocity = { x = 350, y = 0, z = 100 } })
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.assessAircraftTypes(self.trackStore)

	lu.assertEquals(track.AssessedAircraftType, "FIXED_WING")
end

function TestAssessAircraftTypes:test_maneuvering_fast_track_classified_as_fighter()
	local track = makeTrack({
		Velocity = { x = 250, y = 0, z = 100 },
		ManeuverState = "MANEUVERING",
	})
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.assessAircraftTypes(self.trackStore)

	lu.assertEquals(track.AssessedAircraftType, "FIGHTER")
end

function TestAssessAircraftTypes:test_turning_fast_track_classified_as_fighter()
	local track = makeTrack({
		Velocity = { x = 250, y = 0, z = 100 },
		ManeuverState = "TURNING_LEFT",
	})
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.assessAircraftTypes(self.trackStore)

	lu.assertEquals(track.AssessedAircraftType, "FIGHTER")
end

function TestAssessAircraftTypes:test_short_dwell_straight_stays_fixed_wing()
	local track = makeTrack({
		Velocity = { x = 200, y = 0, z = 100 },
		ManeuverState = "STRAIGHT",
		FirstDetectionTime = 900,
		LastDetectionTime = 1000,
	})
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.assessAircraftTypes(self.trackStore)

	lu.assertEquals(track.AssessedAircraftType, "FIXED_WING")
end

function TestAssessAircraftTypes:test_stale_track_skipped()
	local track = makeTrack({
		LifecycleState = "STALE",
		Velocity = { x = 50, y = 0, z = 30 },
	})
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.assessAircraftTypes(self.trackStore)

	lu.assertEquals(track.AssessedAircraftType, "UNKNOWN")
end

function TestAssessAircraftTypes:test_no_velocity_skipped()
	local track = makeTrack()
	track.Velocity = nil
	track.SmoothedVelocity = nil
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.assessAircraftTypes(self.trackStore)

	lu.assertEquals(track.AssessedAircraftType, "UNKNOWN")
end

function TestAssessAircraftTypes:test_prefers_smoothed_velocity()
	local track = makeTrack({
		Velocity = { x = 50, y = 0, z = 30 },
		SmoothedVelocity = { x = 200, y = 0, z = 100 },
		ManeuverState = "STRAIGHT",
	})
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.assessAircraftTypes(self.trackStore)

	-- SmoothedVelocity speed ~= 224 m/s -> FIXED_WING (not ROTARY_WING from raw velocity)
	lu.assertEquals(track.AssessedAircraftType, "FIXED_WING")
end

function TestAssessAircraftTypes:test_same_type_not_overwritten()
	local track = makeTrack({
		Velocity = { x = 50, y = 0, z = 30 },
		AssessedAircraftType = "ROTARY_WING",
	})
	self.trackStore:add(track)
	local originalType = track.AssessedAircraftType

	Medusa.Services.TrackClassifier.assessAircraftTypes(self.trackStore)

	lu.assertEquals(track.AssessedAircraftType, originalType)
end

function TestAssessAircraftTypes:test_turning_right_fast_classified_as_fighter()
	local track = makeTrack({
		Velocity = { x = 250, y = 0, z = 100 },
		ManeuverState = "TURNING_RIGHT",
	})
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.assessAircraftTypes(self.trackStore)

	lu.assertEquals(track.AssessedAircraftType, "FIGHTER")
end

function TestAssessAircraftTypes:test_maneuvering_slow_not_fighter()
	local track = makeTrack({
		Velocity = { x = 120, y = 0, z = 80 },
		ManeuverState = "MANEUVERING",
	})
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.assessAircraftTypes(self.trackStore)

	lu.assertEquals(track.AssessedAircraftType, "FIXED_WING")
end

function TestAssessAircraftTypes:test_fighter_not_demoted_to_fixed_wing()
	local track = makeTrack({
		Velocity = { x = 250, y = 0, z = 100 },
		ManeuverState = "STRAIGHT",
		AssessedAircraftType = "FIGHTER",
	})
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.assessAircraftTypes(self.trackStore)

	lu.assertEquals(track.AssessedAircraftType, "FIGHTER")
end

function TestAssessAircraftTypes:test_harm_track_not_overwritten()
	local track = makeTrack({
		Velocity = { x = 250, y = 0, z = 100 },
		ManeuverState = "STRAIGHT",
		AssessedAircraftType = "HARM",
	})
	self.trackStore:add(track)

	Medusa.Services.TrackClassifier.assessAircraftTypes(self.trackStore)

	lu.assertEquals(track.AssessedAircraftType, "HARM")
end
