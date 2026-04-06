local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Track")
require("services.Services")
require("services.stores.TrackStore")

-- == Track Entity Tests ==

TestTrack = {}

local function makeTrackData(overrides)
	local base = {
		Position = { x = 1000, y = 500, z = 2000 },
		Velocity = { x = 100, y = 0, z = 50 },
		NetworkId = "net-1",
	}
	if overrides then
		for k, v in pairs(overrides) do
			base[k] = v
		end
	end
	return base
end

function TestTrack:test_track_creation_fails_without_position()
	lu.assertErrorMsgContains("missing required field: Position", function()
		Medusa.Entities.Track.new({ Velocity = { x = 0, y = 0, z = 0 }, NetworkId = "n" })
	end)
end

function TestTrack:test_track_creation_fails_without_velocity()
	lu.assertErrorMsgContains("missing required field: Velocity", function()
		Medusa.Entities.Track.new({ Position = { x = 0, y = 0, z = 0 }, NetworkId = "n" })
	end)
end

function TestTrack:test_track_creation_fails_without_network_id()
	lu.assertErrorMsgContains("missing required field: NetworkId", function()
		Medusa.Entities.Track.new({ Position = { x = 0, y = 0, z = 0 }, Velocity = { x = 0, y = 0, z = 0 } })
	end)
end

function TestTrack:test_track_creation_preserves_provided_track_id()
	local track = Medusa.Entities.Track.new(makeTrackData({ TrackId = "my-track-123" }))
	lu.assertEquals(track.TrackId, "my-track-123")
end

-- == TrackStore Tests ==

TestTrackStore = {}

local function makeTrack(overrides)
	return Medusa.Entities.Track.new(makeTrackData(overrides))
end

function TestTrackStore:test_store_add_and_get()
	local store = Medusa.Services.TrackStore:new()
	local track = makeTrack({ TrackId = "t1" })
	store:add(track)

	local got = store:get("t1")
	lu.assertNotNil(got)
	lu.assertEquals(got.TrackId, "t1")
end

function TestTrackStore:test_store_get_returns_nil_for_unknown()
	local store = Medusa.Services.TrackStore:new()
	lu.assertNil(store:get("nonexistent"))
end

function TestTrackStore:test_store_remove()
	local store = Medusa.Services.TrackStore:new()
	local track = makeTrack({ TrackId = "t2" })
	store:add(track)
	local removed = store:remove("t2")

	lu.assertNotNil(removed)
	lu.assertEquals(removed.TrackId, "t2")
	lu.assertNil(store:get("t2"))
	lu.assertEquals(store:count(), 0)
end

function TestTrackStore:test_store_remove_returns_nil_for_unknown()
	local store = Medusa.Services.TrackStore:new()
	lu.assertNil(store:remove("nonexistent"))
end

function TestTrackStore:test_store_get_all()
	local store = Medusa.Services.TrackStore:new()
	store:add(makeTrack({ TrackId = "a1" }))
	store:add(makeTrack({ TrackId = "a2" }))
	store:add(makeTrack({ TrackId = "a3" }))

	local all = store:getAll()
	lu.assertEquals(#all, 3)
end

function TestTrackStore:test_store_get_by_identification()
	local store = Medusa.Services.TrackStore:new()
	store:add(makeTrack({ TrackId = "c1", TrackIdentification = "HOSTILE" }))
	store:add(makeTrack({ TrackId = "c2", TrackIdentification = "HOSTILE" }))
	store:add(makeTrack({ TrackId = "c3", TrackIdentification = "BANDIT" }))

	local hostiles = store:getByIdentification("HOSTILE")
	lu.assertEquals(#hostiles, 2)

	local bandits = store:getByIdentification("BANDIT")
	lu.assertEquals(#bandits, 1)
end

function TestTrackStore:test_store_get_by_identification_empty()
	local store = Medusa.Services.TrackStore:new()
	local result = store:getByIdentification("NONEXISTENT")
	lu.assertEquals(#result, 0)
end

function TestTrackStore:test_store_count()
	local store = Medusa.Services.TrackStore:new()
	lu.assertEquals(store:count(), 0)

	store:add(makeTrack({ TrackId = "n1" }))
	lu.assertEquals(store:count(), 1)

	store:add(makeTrack({ TrackId = "n2" }))
	lu.assertEquals(store:count(), 2)

	store:remove("n1")
	lu.assertEquals(store:count(), 1)
end

function TestTrackStore:test_store_update_identification()
	local store = Medusa.Services.TrackStore:new()
	store:add(makeTrack({ TrackId = "u1", TrackIdentification = "UNKNOWN" }))

	store:updateIdentification("u1", "HOSTILE")

	local track = store:get("u1")
	lu.assertEquals(track.TrackIdentification, "HOSTILE")

	local unknown = store:getByIdentification("UNKNOWN")
	lu.assertEquals(#unknown, 0)

	local hostiles = store:getByIdentification("HOSTILE")
	lu.assertEquals(#hostiles, 1)
	lu.assertEquals(hostiles[1].TrackId, "u1")
end

function TestTrackStore:test_store_add_duplicate_errors()
	local store = Medusa.Services.TrackStore:new()
	store:add(makeTrack({ TrackId = "dup1" }))

	lu.assertErrorMsgContains("duplicate TrackId: dup1", function()
		store:add(makeTrack({ TrackId = "dup1" }))
	end)
end

function TestTrackStore:test_store_get_stale_ids()
	local store = Medusa.Services.TrackStore:new()
	store:add(Medusa.Entities.Track.new(makeTrackData({ TrackId = "s1", LastDetectionTime = 100 })))
	store:add(Medusa.Entities.Track.new(makeTrackData({ TrackId = "s2", LastDetectionTime = 200 })))
	store:add(Medusa.Entities.Track.new(makeTrackData({ TrackId = "s3", LastDetectionTime = 300 })))

	local stale = store:getStaleIds(250)
	lu.assertEquals(#stale, 2)
end

function TestTrackStore:test_store_get_all_reuses_output_table()
	local store = Medusa.Services.TrackStore:new()
	store:add(makeTrack({ TrackId = "r1" }))
	store:add(makeTrack({ TrackId = "r2" }))

	local buf = {}
	local result = store:getAll(buf)
	lu.assertEquals(result, buf)
	lu.assertEquals(#buf, 2)
end

-- == Track Update Tests ==

TestTrackUpdate = {}

function TestTrackUpdate:test_update_sets_position_velocity_timestamp()
	local track = makeTrack()
	local newPos = { x = 2000, y = 600, z = 3000 }
	local newVel = { x = 200, y = 10, z = 100 }

	Medusa.Entities.Track.update(track, newPos, newVel, 5000)

	lu.assertEquals(track.Position, newPos)
	lu.assertEquals(track.Velocity, newVel)
	lu.assertEquals(track.LastDetectionTime, 5000)
end

function TestTrackUpdate:test_update_appends_to_position_history()
	local track = makeTrack()
	lu.assertEquals(track.PositionHistory:size(), 0)

	Medusa.Entities.Track.update(track, { x = 1, y = 2, z = 3 }, { x = 10, y = 0, z = 5 }, 100)
	lu.assertEquals(track.PositionHistory:size(), 1)
	local arr = track.PositionHistory:toArray()
	lu.assertEquals(arr[1].timestamp, 100)
	lu.assertEquals(arr[1].position.x, 1)
	lu.assertEquals(arr[1].velocity.x, 10)

	Medusa.Entities.Track.update(track, { x = 2, y = 3, z = 4 }, { x = 20, y = 0, z = 10 }, 200)
	lu.assertEquals(track.PositionHistory:size(), 2)
end

function TestTrackUpdate:test_update_bounds_position_history()
	local track = makeTrack()
	local max = Medusa.Entities.Track.MAX_POSITION_HISTORY

	for i = 1, max + 5 do
		Medusa.Entities.Track.update(track, { x = i, y = 0, z = 0 }, { x = 1, y = 0, z = 0 }, i)
	end

	lu.assertEquals(track.PositionHistory:size(), max)
	-- Oldest entries should have been removed; first entry should be timestamp 6
	local arr = track.PositionHistory:toArray()
	lu.assertEquals(arr[1].timestamp, 6)
end

function TestTrackUpdate:test_update_resets_stale_to_active()
	local track = makeTrack({ LifecycleState = "STALE" })
	lu.assertEquals(track.LifecycleState, "STALE")

	Medusa.Entities.Track.update(track, { x = 1, y = 2, z = 3 }, { x = 10, y = 0, z = 5 }, 100)
	lu.assertEquals(track.LifecycleState, "ACTIVE")
end

-- == Smoothed Velocity Tests ==

TestSmoothedVelocity = {}

function TestSmoothedVelocity:test_single_entry_uses_current_velocity()
	local track = makeTrack()
	Medusa.Entities.Track.update(track, { x = 1, y = 0, z = 0 }, { x = 50, y = 5, z = 25 }, 100)

	Medusa.Entities.Track.computeSmoothedVelocity(track, 60)

	lu.assertAlmostEquals(track.SmoothedVelocity.x, 50, 0.001)
	lu.assertAlmostEquals(track.SmoothedVelocity.y, 5, 0.001)
	lu.assertAlmostEquals(track.SmoothedVelocity.z, 25, 0.001)
end

function TestSmoothedVelocity:test_averages_over_window()
	local track = makeTrack()

	Medusa.Entities.Track.update(track, { x = 1, y = 0, z = 0 }, { x = 100, y = 0, z = 0 }, 10)
	Medusa.Entities.Track.update(track, { x = 2, y = 0, z = 0 }, { x = 200, y = 0, z = 0 }, 20)
	Medusa.Entities.Track.update(track, { x = 3, y = 0, z = 0 }, { x = 300, y = 0, z = 0 }, 30)

	Medusa.Entities.Track.computeSmoothedVelocity(track, 60)

	-- Average of 100, 200, 300 = 200
	lu.assertAlmostEquals(track.SmoothedVelocity.x, 200, 0.001)
end

function TestSmoothedVelocity:test_window_excludes_old_entries()
	local track = makeTrack()

	Medusa.Entities.Track.update(track, { x = 1, y = 0, z = 0 }, { x = 100, y = 0, z = 0 }, 10)
	Medusa.Entities.Track.update(track, { x = 2, y = 0, z = 0 }, { x = 200, y = 0, z = 0 }, 50)
	Medusa.Entities.Track.update(track, { x = 3, y = 0, z = 0 }, { x = 300, y = 0, z = 0 }, 80)

	-- Window of 40 sec from latest (80): cutoff at 40, so entry at t=10 excluded
	Medusa.Entities.Track.computeSmoothedVelocity(track, 40)

	-- Average of 200, 300 = 250
	lu.assertAlmostEquals(track.SmoothedVelocity.x, 250, 0.001)
end

-- == Maneuver State Tests ==

TestManeuverState = {}

function TestManeuverState:test_straight_for_same_heading()
	local track = makeTrack()
	track.Velocity = { x = 100, y = 0, z = 0 }
	track.SmoothedVelocity = { x = 100, y = 0, z = 0 }

	Medusa.Entities.Track.deriveManeuverState(track)

	lu.assertEquals(track.ManeuverState, "STRAIGHT")
end

function TestManeuverState:test_turning_right_for_positive_heading_change()
	-- Current heading: 45 deg (vx=100, vz=100) -> atan2(100,100) = pi/4
	-- Smoothed heading: 0 deg (vx=100, vz=0) -> atan2(0,100) = 0
	-- Delta = pi/4 - 0 = pi/4 ~ 0.785 > 0.15 -> TURNING_RIGHT
	local track = makeTrack()
	track.Velocity = { x = 100, y = 0, z = 100 }
	track.SmoothedVelocity = { x = 100, y = 0, z = 0 }

	Medusa.Entities.Track.deriveManeuverState(track)

	lu.assertEquals(track.ManeuverState, "TURNING_RIGHT")
end

function TestManeuverState:test_turning_left_for_negative_heading_change()
	-- Current heading: 0 deg (vx=100, vz=0) -> atan2(0,100) = 0
	-- Smoothed heading: 45 deg (vx=100, vz=100) -> atan2(100,100) = pi/4
	-- Delta = 0 - pi/4 = -pi/4 ~ -0.785 < -0.15 -> TURNING_LEFT
	local track = makeTrack()
	track.Velocity = { x = 100, y = 0, z = 0 }
	track.SmoothedVelocity = { x = 100, y = 0, z = 100 }

	Medusa.Entities.Track.deriveManeuverState(track)

	lu.assertEquals(track.ManeuverState, "TURNING_LEFT")
end

function TestManeuverState:test_unknown_when_no_smoothed_velocity()
	local track = makeTrack()
	track.SmoothedVelocity = nil

	Medusa.Entities.Track.deriveManeuverState(track)

	lu.assertEquals(track.ManeuverState, "UNKNOWN")
end

function TestManeuverState:test_unknown_when_stationary()
	local track = makeTrack()
	track.Velocity = { x = 0.1, y = 0, z = 0.1 }
	track.SmoothedVelocity = { x = 0.1, y = 0, z = 0.1 }

	Medusa.Entities.Track.deriveManeuverState(track)

	lu.assertEquals(track.ManeuverState, "UNKNOWN")
end

function TestManeuverState:test_maneuvering_for_large_speed_change()
	-- Same heading but very different speeds (>30% change)
	local track = makeTrack()
	track.Velocity = { x = 200, y = 0, z = 0 }
	track.SmoothedVelocity = { x = 100, y = 0, z = 0 }

	Medusa.Entities.Track.deriveManeuverState(track)

	lu.assertEquals(track.ManeuverState, "MANEUVERING")
end

function TestManeuverState:test_orbiting_for_reversed_heading()
	-- Current heading ~= pi, smoothed heading ~= 0 -> delta ~= pi > 2.5
	local track = makeTrack()
	track.Velocity = { x = -100, y = 0, z = 0 }
	track.SmoothedVelocity = { x = 100, y = 0, z = 0 }

	Medusa.Entities.Track.deriveManeuverState(track)

	lu.assertEquals(track.ManeuverState, "ORBITING")
end
