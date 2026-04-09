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

-- == Helpers ==

local ulidCounter = 0

local function setupMocks()
	ulidCounter = 0
	GetTime = function()
		return 1000
	end
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
end

local function makeTrack(overrides)
	local data = {
		NetworkId = "net-1",
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

local function makeBattery(overrides)
	local data = {
		NetworkId = "bat-net-1",
		GroupId = 100,
		GroupName = "SAM-1",
		ActivationState = Medusa.Constants.ActivationState.STATE_COLD,
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
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
	return Medusa.Entities.Battery.new(data)
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

local function makeFreeDoctrine(overrides)
	local d = { ROE = "FREE", HoldDownSec = 0 }
	if overrides then
		for k, v in pairs(overrides) do
			d[k] = v
		end
	end
	return d
end

local function makeCtx(fields)
	return {
		trackStore = fields.trackStore,
		batteryStore = fields.batteryStore,
		geoGrid = fields.geoGrid,
		doctrine = fields.doctrine,
		now = fields.now or 1000,
		maxRange = fields.maxRange or 50000,
	}
end

-- == TestComputeThreatValue ==

TestComputeThreatValue = {}

function TestComputeThreatValue:setUp()
	setupMocks()
end

function TestComputeThreatValue:test_returns_number()
	local track = makeTrack({
		AssessedAircraftType = "FIGHTER",
	})
	local score = Medusa.Services.TargetAssigner.computeThreatValue(track)
	lu.assertIsNumber(score)
	lu.assertTrue(score > 0)
end

function TestComputeThreatValue:test_sead_scores_higher_than_rotary()
	local sead = makeTrack({
		AssessedAircraftType = "SEAD_AIRCRAFT",
		Velocity = { x = 250, y = 0, z = 0 },
	})
	local rotary = makeTrack({
		AssessedAircraftType = "ROTARY_WING",
		Velocity = { x = 60, y = 0, z = 0 },
	})
	local seadScore = Medusa.Services.TargetAssigner.computeThreatValue(sead)
	local rotaryScore = Medusa.Services.TargetAssigner.computeThreatValue(rotary)
	lu.assertTrue(seadScore > rotaryScore)
end

function TestComputeThreatValue:test_uses_smoothed_velocity_when_available()
	local track = makeTrack({
		AssessedAircraftType = "FIXED_WING",
		Velocity = { x = 100, y = 0, z = 0 },
	})
	track.SmoothedVelocity = { x = 300, y = 0, z = 0 }
	local score = Medusa.Services.TargetAssigner.computeThreatValue(track)
	-- With smoothed velocity at 300 m/s, speed score should be high
	lu.assertTrue(score > 40)
end

function TestComputeThreatValue:test_unknown_types_get_default_scores()
	local track = makeTrack({
		AssessedAircraftType = "UNKNOWN",
		Velocity = { x = 0, y = 0, z = 0 },
	})
	local score = Medusa.Services.TargetAssigner.computeThreatValue(track)
	lu.assertIsNumber(score)
end

-- == TestAssignTargets ==

TestAssignTargets = {}

function TestAssignTargets:setUp()
	setupMocks()
	self.trackStore = Medusa.Services.TrackStore:new()
	self.batteryStore = Medusa.Services.BatteryStore:new()
	self.geoGrid = makeMockGeoGrid(self.batteryStore)
end

function TestAssignTargets:test_assigns_best_pk_battery_first()
	local track = makeTrack({ TrackId = "T1" })
	self.trackStore:add(track)

	-- B1 at origin: dist to track = 22500m = PkRangeOptimal (best Pk)
	local nearBat = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		Position = { x = 0, y = 0, z = 0 },
	})
	-- B2 far away: dist to track = 37500m, well off PkRangeOptimal (worse Pk)
	local farBat = makeBattery({
		BatteryId = "B2",
		GroupId = 2,
		GroupName = "SAM-2",
		Position = { x = -15000, y = 0, z = 0 },
	})
	self.batteryStore:add(nearBat)
	self.batteryStore:add(farBat)

	local doctrine = makeFreeDoctrine()
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	-- WTA may assign multiple batteries; first assignment should be best Pk (B1)
	lu.assertTrue(#assignments >= 1)
	lu.assertEquals(assignments[1].batteryId, "B1")
	lu.assertEquals(assignments[1].trackId, "T1")
end

function TestAssignTargets:test_sets_battery_target_and_track_assignment()
	local track = makeTrack({ TrackId = "T1" })
	self.trackStore:add(track)

	local battery = makeBattery({ BatteryId = "B1", GroupId = 1, GroupName = "SAM-1" })
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine()
	Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(battery.CurrentTargetTrackId, "T1")
	lu.assertTrue(track.AssignedBatteryIds:contains("B1"))
end

function TestAssignTargets:test_sets_assignment_time()
	local track = makeTrack({ TrackId = "T1" })
	self.trackStore:add(track)

	local battery = makeBattery({ BatteryId = "B1", GroupId = 1, GroupName = "SAM-1" })
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine()
	Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(track.AssignmentTime, 1000)
end

function TestAssignTargets:test_skips_track_with_existing_assignment()
	local track = makeTrack({ TrackId = "T1" })
	track.AssignedBatteryIds:add("B-existing")
	self.trackStore:add(track)

	local battery = makeBattery({ BatteryId = "B1", GroupId = 1, GroupName = "SAM-1" })
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine()
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 0)
end

function TestAssignTargets:test_skips_stale_tracks()
	local track = makeTrack({
		TrackId = "T1",
		LifecycleState = Medusa.Constants.TrackLifecycleState.STALE,
	})
	self.trackStore:add(track)

	local battery = makeBattery({ BatteryId = "B1", GroupId = 1, GroupName = "SAM-1" })
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine()
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 0)
end

function TestAssignTargets:test_skips_hot_batteries()
	local track = makeTrack({ TrackId = "T1" })
	self.trackStore:add(track)

	local battery = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
	})
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine()
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 0)
end

function TestAssignTargets:test_skips_destroyed_batteries()
	local track = makeTrack({ TrackId = "T1" })
	self.trackStore:add(track)

	local battery = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.DESTROYED,
	})
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine()
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 0)
end

function TestAssignTargets:test_skips_battery_without_position()
	local track = makeTrack({ TrackId = "T1" })
	self.trackStore:add(track)

	local battery = Medusa.Entities.Battery.new({
		BatteryId = "B1",
		NetworkId = "bat-net-1",
		GroupId = 1,
		GroupName = "SAM-1",
		ActivationState = Medusa.Constants.ActivationState.STATE_COLD,
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
	})
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine()
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 0)
end

function TestAssignTargets:test_respects_battery_engagement_range()
	local track = makeTrack({ TrackId = "T1", Position = { x = 500, y = 5000, z = 0 } })
	self.trackStore:add(track)

	-- Track at 500m from origin, battery range only 100m -> out of range
	local battery = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		Position = { x = 0, y = 0, z = 0 },
		EngagementRangeMax = 100,
	})
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine()
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 0)
end

function TestAssignTargets:test_skips_battery_with_nil_engagement_range()
	local track = makeTrack({ TrackId = "T1", Position = { x = 0, y = 500, z = 0 } })
	self.trackStore:add(track)

	local battery = Medusa.Entities.Battery.new({
		BatteryId = "B1",
		NetworkId = "bat-net-1",
		GroupId = 1,
		GroupName = "SAM-1",
		ActivationState = Medusa.Constants.ActivationState.STATE_COLD,
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
		Position = { x = 10, y = 0, z = 10 },
	})
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine()
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 0)
end

function TestAssignTargets:test_returns_empty_with_no_tracks()
	local battery = makeBattery({ BatteryId = "B1", GroupId = 1, GroupName = "SAM-1" })
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine()
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 0)
end

function TestAssignTargets:test_returns_empty_with_no_batteries()
	local track = makeTrack({ TrackId = "T1" })
	self.trackStore:add(track)

	local doctrine = makeFreeDoctrine()
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 0)
end

-- == TestPkFloor ==

TestPkFloor = {}

function TestPkFloor:setUp()
	setupMocks()
	self.trackStore = Medusa.Services.TrackStore:new()
	self.batteryStore = Medusa.Services.BatteryStore:new()
	self.geoGrid = makeMockGeoGrid(self.batteryStore)
end

function TestPkFloor:test_high_pkfloor_rejects_marginal_track()
	-- Track at 900m with velocity toward battery. After 8s projection, projected dist ~700m.
	-- Pk at 700m with optimal=450, sigma=250: gaussian=exp(-0.5*1.0)=0.607, pk~0.42
	-- PkFloor=0.50 -> should NOT assign.
	local track = makeTrack({
		TrackId = "T1",
		Position = { x = 900, y = 500, z = 0 },
		Velocity = { x = -25, y = 0, z = 0 },
	})
	self.trackStore:add(track)

	local battery = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		Position = { x = 0, y = 0, z = 0 },
		EngagementRangeMax = 1000,
		PkRangeOptimal = 450,
		PkRangeSigma = 250,
	})
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine({ PkFloor = 0.50 })
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 0)
end

function TestPkFloor:test_low_pkfloor_accepts_marginal_track()
	-- Same geometry but PkFloor=0.10 (default) -> Pk~0.42 exceeds floor -> should assign.
	local track = makeTrack({
		TrackId = "T1",
		Position = { x = 900, y = 500, z = 0 },
		Velocity = { x = -25, y = 0, z = 0 },
	})
	self.trackStore:add(track)

	local battery = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		Position = { x = 0, y = 0, z = 0 },
		EngagementRangeMax = 1000,
		PkRangeOptimal = 450,
		PkRangeSigma = 250,
	})
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine({ PkFloor = 0.10 })
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 1)
end

function TestPkFloor:test_default_pkfloor_used_when_not_specified()
	-- No PkFloor in doctrine. Track near optimal -> should assign with default 0.10.
	local track = makeTrack({
		TrackId = "T1",
		Position = { x = 500, y = 500, z = 0 },
		Velocity = { x = -5, y = 0, z = 0 },
	})
	self.trackStore:add(track)

	local battery = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		Position = { x = 0, y = 0, z = 0 },
		EngagementRangeMax = 1000,
		PkRangeOptimal = 450,
		PkRangeSigma = 250,
	})
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine()
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 1)
end

function TestPkFloor:test_projected_beyond_hardware_range_rejected()
	-- Track at 950m heading away from battery at 20m/s. After 8s, projected dist = 1110m.
	-- Hardware max is 1000m -> rejected before Pk computation.
	local track = makeTrack({
		TrackId = "T1",
		Position = { x = 950, y = 500, z = 0 },
		Velocity = { x = 20, y = 0, z = 0 },
	})
	self.trackStore:add(track)

	local battery = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		Position = { x = 0, y = 0, z = 0 },
		EngagementRangeMax = 1000,
		PkRangeOptimal = 450,
		PkRangeSigma = 250,
	})
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine()
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 0)
end

-- == TestROE ==

TestROE = {}

function TestROE:setUp()
	setupMocks()
	self.trackStore = Medusa.Services.TrackStore:new()
	self.batteryStore = Medusa.Services.BatteryStore:new()
	self.geoGrid = makeMockGeoGrid(self.batteryStore)
end

function TestROE:test_hold_returns_empty()
	local track = makeTrack({ TrackId = "T1", TrackIdentification = "HOSTILE" })
	self.trackStore:add(track)

	local battery = makeBattery({ BatteryId = "B1", GroupId = 1, GroupName = "SAM-1" })
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine({ ROE = "HOLD" })
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 0)
end

function TestROE:test_tight_rejects_bandit()
	local track = makeTrack({ TrackId = "T1", TrackIdentification = "BANDIT" })
	self.trackStore:add(track)

	local battery = makeBattery({ BatteryId = "B1", GroupId = 1, GroupName = "SAM-1" })
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine({ ROE = "TIGHT" })
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 0)
end

function TestROE:test_tight_accepts_hostile()
	local track = makeTrack({ TrackId = "T1", TrackIdentification = "HOSTILE" })
	self.trackStore:add(track)

	local battery = makeBattery({ BatteryId = "B1", GroupId = 1, GroupName = "SAM-1" })
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine({ ROE = "TIGHT" })
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 1)
end

function TestROE:test_free_accepts_bandit()
	local track = makeTrack({ TrackId = "T1", TrackIdentification = "BANDIT" })
	self.trackStore:add(track)

	local battery = makeBattery({ BatteryId = "B1", GroupId = 1, GroupName = "SAM-1" })
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine({ ROE = "FREE" })
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 1)
end

function TestROE:test_free_rejects_bogey()
	local track = makeTrack({ TrackId = "T1", TrackIdentification = "BOGEY" })
	self.trackStore:add(track)

	local battery = makeBattery({ BatteryId = "B1", GroupId = 1, GroupName = "SAM-1" })
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine({ ROE = "FREE" })
	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = doctrine,
	}))

	lu.assertEquals(#assignments, 0)
end

function TestROE:test_nil_doctrine_defaults_to_free()
	local track = makeTrack({ TrackId = "T1", TrackIdentification = "BANDIT" })
	self.trackStore:add(track)

	local battery = makeBattery({ BatteryId = "B1", GroupId = 1, GroupName = "SAM-1" })
	self.batteryStore:add(battery)

	local assignments = Medusa.Services.TargetAssigner.assignTargets(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		geoGrid = self.geoGrid,
		doctrine = {},
	}))

	lu.assertEquals(#assignments, 1)
end

-- == TestCheckDeactivations ==

TestCheckDeactivations = {}

function TestCheckDeactivations:setUp()
	setupMocks()
	self.trackStore = Medusa.Services.TrackStore:new()
	self.batteryStore = Medusa.Services.BatteryStore:new()
end

function TestCheckDeactivations:test_returns_hot_battery_with_nil_target()
	local battery = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		CurrentTargetTrackId = nil,
	})
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine()
	local result = Medusa.Services.TargetAssigner.checkDeactivations(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		doctrine = doctrine,
	}))

	lu.assertEquals(#result, 1)
	lu.assertIs(result[1], battery)
end

function TestCheckDeactivations:test_returns_hot_battery_when_track_removed()
	local battery = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		CurrentTargetTrackId = "T-gone",
	})
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine()
	local result = Medusa.Services.TargetAssigner.checkDeactivations(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		doctrine = doctrine,
	}))

	lu.assertEquals(#result, 1)
	lu.assertIs(result[1], battery)
end

function TestCheckDeactivations:test_returns_hot_battery_when_track_stale_no_holddown()
	local track = makeTrack({
		TrackId = "T1",
		LifecycleState = Medusa.Constants.TrackLifecycleState.STALE,
	})
	self.trackStore:add(track)

	local battery = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		CurrentTargetTrackId = "T1",
	})
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine({ HoldDownSec = 0 })
	local result = Medusa.Services.TargetAssigner.checkDeactivations(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		doctrine = doctrine,
	}))

	lu.assertEquals(#result, 1)
	lu.assertIs(result[1], battery)
end

function TestCheckDeactivations:test_holddown_protects_stale_track()
	local track = makeTrack({
		TrackId = "T1",
		LifecycleState = Medusa.Constants.TrackLifecycleState.STALE,
		AssignmentTime = 995,
	})
	self.trackStore:add(track)

	local battery = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		CurrentTargetTrackId = "T1",
	})
	self.batteryStore:add(battery)

	-- Hold-down is 10s, assignment was 5s ago -> protected
	local doctrine = makeFreeDoctrine({ HoldDownSec = 10 })
	local result = Medusa.Services.TargetAssigner.checkDeactivations(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		doctrine = doctrine,
	}))

	lu.assertEquals(#result, 0)
end

function TestCheckDeactivations:test_holddown_expired_allows_deactivation()
	local track = makeTrack({
		TrackId = "T1",
		LifecycleState = Medusa.Constants.TrackLifecycleState.STALE,
		AssignmentTime = 980,
	})
	self.trackStore:add(track)

	local battery = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		CurrentTargetTrackId = "T1",
	})
	self.batteryStore:add(battery)

	-- Hold-down is 10s, assignment was 20s ago -> expired
	local doctrine = makeFreeDoctrine({ HoldDownSec = 10 })
	local result = Medusa.Services.TargetAssigner.checkDeactivations(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		doctrine = doctrine,
	}))

	lu.assertEquals(#result, 1)
end

function TestCheckDeactivations:test_expired_track_always_deactivates()
	local track = makeTrack({
		TrackId = "T1",
		LifecycleState = Medusa.Constants.TrackLifecycleState.EXPIRED,
		AssignmentTime = 999,
	})
	self.trackStore:add(track)

	local battery = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		CurrentTargetTrackId = "T1",
	})
	self.batteryStore:add(battery)

	-- Even with long hold-down, EXPIRED always deactivates
	local doctrine = makeFreeDoctrine({ HoldDownSec = 9999 })
	local result = Medusa.Services.TargetAssigner.checkDeactivations(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		doctrine = doctrine,
	}))

	lu.assertEquals(#result, 1)
end

function TestCheckDeactivations:test_keeps_hot_battery_with_active_track()
	local track = makeTrack({
		TrackId = "T1",
		LifecycleState = Medusa.Constants.TrackLifecycleState.ACTIVE,
	})
	self.trackStore:add(track)

	local battery = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		CurrentTargetTrackId = "T1",
	})
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine()
	local result = Medusa.Services.TargetAssigner.checkDeactivations(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		doctrine = doctrine,
	}))

	lu.assertEquals(#result, 0)
end

function TestCheckDeactivations:test_ignores_cold_batteries()
	local battery = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		ActivationState = Medusa.Constants.ActivationState.STATE_COLD,
		CurrentTargetTrackId = nil,
	})
	self.batteryStore:add(battery)

	local doctrine = makeFreeDoctrine()
	local result = Medusa.Services.TargetAssigner.checkDeactivations(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		doctrine = doctrine,
	}))

	lu.assertEquals(#result, 0)
end

function TestCheckDeactivations:test_returns_empty_with_no_batteries()
	local doctrine = makeFreeDoctrine()
	local result = Medusa.Services.TargetAssigner.checkDeactivations(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		doctrine = doctrine,
	}))

	lu.assertEquals(#result, 0)
end

function TestCheckDeactivations:test_nil_doctrine_defaults_holddown_zero()
	local track = makeTrack({
		TrackId = "T1",
		LifecycleState = Medusa.Constants.TrackLifecycleState.STALE,
		AssignmentTime = 999,
	})
	self.trackStore:add(track)

	local battery = makeBattery({
		BatteryId = "B1",
		GroupId = 1,
		GroupName = "SAM-1",
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		CurrentTargetTrackId = "T1",
	})
	self.batteryStore:add(battery)

	local result = Medusa.Services.TargetAssigner.checkDeactivations(makeCtx({
		trackStore = self.trackStore,
		batteryStore = self.batteryStore,
		doctrine = {},
	}))

	lu.assertEquals(#result, 1)
end
