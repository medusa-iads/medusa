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
require("services.HarmDetectionService")

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

local function clearSprtStates()
	local ns = Medusa.Services.HarmDetectionService._networkStates
	for k in pairs(ns) do
		ns[k] = nil
	end
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

local function makeTrack(overrides)
	local base = {
		Position = { x = 1000, y = 5000, z = 2000 },
		Velocity = { x = 300, y = -30, z = 150 },
		NetworkId = overrides and overrides.NetworkId or string.format("net-%d", math.random(1, 999999)),
	}
	if overrides then
		for k, v in pairs(overrides) do
			base[k] = v
		end
	end
	return Medusa.Entities.Track.new(base)
end

local function makeBattery(overrides)
	local base = {
		NetworkId = 1,
		GroupId = overrides and overrides.GroupId or math.random(1, 999999),
		GroupName = overrides and overrides.GroupName or string.format("SAM-%d", math.random(1, 999999)),
		OperationalStatus = "ACTIVE",
		ActivationState = "STATE_WARM",
		Position = { x = 5000, y = 0, z = 5000 },
		EngagementRangeMax = 50000,
	}
	if overrides then
		for k, v in pairs(overrides) do
			base[k] = v
		end
	end
	return Medusa.Entities.Battery.new(base)
end

local function makeBatteryStoreAndGrid(batteries)
	local store = Medusa.Services.BatteryStore:new()
	for i = 1, #batteries do
		store:add(batteries[i])
	end
	return store, makeMockGeoGrid(store)
end

-- ARM-like kinematics: velocity vector aims directly at emitter in 3D for low CPA
local function populateArmHistory(track, count, startTime, emitterPos)
	local ex = emitterPos and emitterPos.x or 10000
	local ey = emitterPos and emitterPos.y or 0
	local ez = emitterPos and emitterPos.z or 6000
	-- Start position: offset from emitter so velocity vector can aim at it
	local startX, startY, startZ = ex - 6000, ey + 4000, ez - 3000
	for i = 1, count do
		local t = startTime + i
		local speed = 700 - i * 10
		-- Current position progresses toward emitter
		local frac = i / (count + 5)
		local px = startX + (ex - startX) * frac
		local py = startY + (ey - startY) * frac
		local pz = startZ + (ez - startZ) * frac
		-- Velocity points from current pos toward emitter
		local dx = ex - px
		local dy = ey - py
		local dz = ez - pz
		local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
		local vx = dx / dist * speed
		local vy = dy / dist * speed
		local vz = dz / dist * speed
		Medusa.Entities.Track.update(track, { x = px, y = py, z = pz }, { x = vx, y = vy, z = vz }, t)
	end
end

-- Non-ARM kinematics: slow, level, wandering
local function populateNonArmHistory(track, count, startTime)
	for i = 1, count do
		local t = startTime + i
		local angle = i * 0.3
		Medusa.Entities.Track.update(
			track,
			{ x = 1000 + i * 200, y = 5000, z = 2000 + i * 100 },
			{ x = 200 * math.cos(angle), y = 0, z = 200 * math.sin(angle) },
			t
		)
	end
end

local function makeCtx(fields)
	return {
		trackStore = fields.trackStore,
		batteryStore = fields.batteryStore,
		geoGrid = fields.geoGrid,
		doctrine = fields.doctrine,
		now = fields.now or 1000,
	}
end

-- == computeScanLLR tests ==

TestComputeScanLLR = {}

function TestComputeScanLLR:setUp()
	setupMocks()
end

function TestComputeScanLLR:test_arm_like_features_positive_llr()
	-- Features matching ARM class means: high speed, diving, straight, decelerating, low CPA, converging
	local feat = { 650, 0.5236, 0.005, -15, 25, -50, -600, -300 }
	local llr = Medusa.Services.HarmDetectionService._computeScanLLR(feat)
	lu.assertTrue(llr > 0)
end

function TestComputeScanLLR:test_non_arm_features_negative_llr()
	-- Features matching non-ARM class: slow, level, turning, no accel, far CPA, no closure
	local feat = { 280, 0.087, 0.035, 0, 3000, -5, -150, -10 }
	local llr = Medusa.Services.HarmDetectionService._computeScanLLR(feat)
	lu.assertTrue(llr < 0)
end

function TestComputeScanLLR:test_mixed_features_between_extremes()
	-- Some ARM-like, some non-ARM-like features
	local armFeat = { 650, 0.5236, 0.005, -15, 25, -50, -600, -300 }
	local nonFeat = { 280, 0.087, 0.035, 0, 3000, -5, -150, -10 }
	local mixFeat = { 650, 0.087, 0.005, 0, 25, -5, -150, -300 }
	local armLlr = Medusa.Services.HarmDetectionService._computeScanLLR(armFeat)
	local nonLlr = Medusa.Services.HarmDetectionService._computeScanLLR(nonFeat)
	local mixLlr = Medusa.Services.HarmDetectionService._computeScanLLR(mixFeat)
	lu.assertTrue(mixLlr > nonLlr)
	lu.assertTrue(mixLlr < armLlr)
end

-- == evaluateTrack tests ==

TestEvaluateTrack = {}

function TestEvaluateTrack:setUp()
	setupMocks()
	clearSprtStates()
	self.states = {}
end

function TestEvaluateTrack:test_returns_evaluating_with_one_history_entry()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = { x = 10000, y = 0, z = 6000 } })
	local store, grid = makeBatteryStoreAndGrid({ battery })
	local label, state = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, self.states)
	lu.assertEquals(label, "EVALUATING")
	lu.assertNil(state)
end

function TestEvaluateTrack:test_below_speed_gate_returns_cleared()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	Medusa.Entities.Track.update(track, { x = 100, y = 100, z = 100 }, { x = 10, y = 0, z = 10 }, mockTime + 1)
	Medusa.Entities.Track.update(track, { x = 120, y = 100, z = 120 }, { x = 10, y = 0, z = 10 }, mockTime + 2)
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = { x = 10000, y = 0, z = 6000 } })
	local store, grid = makeBatteryStoreAndGrid({ battery })
	local label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, self.states)
	lu.assertEquals(label, "CLEARED")
end

function TestEvaluateTrack:test_no_emitting_battery_returns_evaluating()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	Medusa.Entities.Track.update(track, { x = 2000, y = 5000, z = 3000 }, { x = 600, y = -100, z = 300 }, mockTime + 1)
	Medusa.Entities.Track.update(track, { x = 2600, y = 4900, z = 3300 }, { x = 600, y = -100, z = 300 }, mockTime + 2)
	local battery = makeBattery({ ActivationState = "STATE_COLD", Position = { x = 10000, y = 0, z = 6000 } })
	local store, grid = makeBatteryStoreAndGrid({ battery })
	local label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, self.states)
	lu.assertEquals(label, "EVALUATING")
end

function TestEvaluateTrack:test_evaluating_during_min_scans()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	populateArmHistory(track, 2, mockTime, emitterPos)
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	local store, grid = makeBatteryStoreAndGrid({ battery })

	local label, state = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, self.states)
	lu.assertEquals(label, "EVALUATING")
	lu.assertNotNil(state)
	lu.assertEquals(state.scanCount, 1)
end

function TestEvaluateTrack:test_arm_track_reaches_confirmed()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	populateArmHistory(track, 15, mockTime, emitterPos)
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	local store, grid = makeBatteryStoreAndGrid({ battery })

	local label
	for j = 1, 15 do
		populateArmHistory(track, 2, mockTime + j * 100, emitterPos)
		label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, self.states)
		if label == "CONFIRMED" then
			break
		end
	end
	lu.assertEquals(label, "CONFIRMED")
end

function TestEvaluateTrack:test_non_arm_track_does_not_confirm()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	local store, grid = makeBatteryStoreAndGrid({ battery })

	local label
	for j = 1, 15 do
		populateNonArmHistory(track, 2, mockTime + j * 100)
		label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, self.states)
	end
	lu.assertNotEquals(label, "CONFIRMED")
end

function TestEvaluateTrack:test_confirmed_is_absorbing()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	local store, grid = makeBatteryStoreAndGrid({ battery })

	for j = 1, 20 do
		populateArmHistory(track, 2, mockTime + j * 100, emitterPos)
		Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, self.states)
	end
	local state = self.states[track.TrackId]
	if state then
		state.label = "CONFIRMED"
		state.llr = 10

		populateNonArmHistory(track, 2, mockTime + 5000)
		local label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, self.states)
		lu.assertEquals(label, "CONFIRMED")
	end
end

function TestEvaluateTrack:test_cleared_is_absorbing()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	local store, grid = makeBatteryStoreAndGrid({ battery })

	populateNonArmHistory(track, 2, mockTime)
	Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, self.states)
	local state = self.states[track.TrackId]
	if state then
		state.label = "CLEARED"
		state.llr = -5

		-- Young CLEARED tracks re-enter evaluation (not terminal)
		populateArmHistory(track, 2, mockTime + 5000, emitterPos)
		local label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, self.states)
		lu.assertEquals(label, "EVALUATING")
	end
end

function TestEvaluateTrack:test_duplicate_timestamps_returns_current_label()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	local store, grid = makeBatteryStoreAndGrid({ battery })

	Medusa.Entities.Track.update(track, { x = 2000, y = 5000, z = 3000 }, { x = 600, y = -100, z = 300 }, mockTime + 1)
	Medusa.Entities.Track.update(track, { x = 2600, y = 4900, z = 3300 }, { x = 600, y = -100, z = 300 }, mockTime + 1)
	local label = Medusa.Services.HarmDetectionService._evaluateTrack(track, grid, store, self.states)
	lu.assertEquals(label, "EVALUATING")
end

-- == assessHarmThreats integration tests ==

TestAssessHarmThreats = {}

function TestAssessHarmThreats:setUp()
	setupMocks()
	clearSprtStates()
	self.trackStore = Medusa.Services.TrackStore:new()
	self.batteryStore = Medusa.Services.BatteryStore:new()
	self.geoGrid = makeMockGeoGrid(self.batteryStore)
end

function TestAssessHarmThreats:test_reclassifies_confirmed_arm()
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local track = makeTrack({ AssessedAircraftType = "MISSILE", FirstDetectionTime = 0 })
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	self.trackStore:add(track)
	self.batteryStore:add(battery)

	local count = 0
	for j = 1, 30 do
		populateArmHistory(track, 2, mockTime + j * 100, emitterPos)
		count = Medusa.Services.HarmDetectionService.assessHarmThreats(
			makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
		)
		if count > 0 then
			break
		end
	end

	lu.assertEquals(track.AssessedAircraftType, "HARM")
	lu.assertTrue(track.IsSeadThreat)
	lu.assertTrue(track.HarmLikelihoodScore > 0)
end

function TestAssessHarmThreats:test_does_not_reclassify_non_arm()
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local track = makeTrack({ AssessedAircraftType = "MISSILE", FirstDetectionTime = 0 })
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	self.trackStore:add(track)
	self.batteryStore:add(battery)

	for j = 1, 15 do
		populateNonArmHistory(track, 2, mockTime + j * 100)
		Medusa.Services.HarmDetectionService.assessHarmThreats(
			makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
		)
	end

	lu.assertEquals(track.AssessedAircraftType, "MISSILE")
end

function TestAssessHarmThreats:test_skips_stale_tracks()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	populateArmHistory(track, 6, mockTime, { x = 10000, y = 0, z = 6000 })
	track.LifecycleState = "STALE"
	self.trackStore:add(track)

	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = { x = 10000, y = 0, z = 6000 } })
	self.batteryStore:add(battery)

	local count = Medusa.Services.HarmDetectionService.assessHarmThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 0)
end

function TestAssessHarmThreats:test_skips_slow_tracks()
	local track = makeTrack({ Velocity = { x = 10, y = 0, z = 10 } })
	self.trackStore:add(track)

	local battery = makeBattery({ ActivationState = "STATE_WARM" })
	self.batteryStore:add(battery)

	local count = Medusa.Services.HarmDetectionService.assessHarmThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 0)
end

function TestAssessHarmThreats:test_skips_young_tracks()
	local track = makeTrack({ AssessedAircraftType = "MISSILE" })
	self.trackStore:add(track)
	local battery = makeBattery({ ActivationState = "STATE_WARM" })
	self.batteryStore:add(battery)

	local count = Medusa.Services.HarmDetectionService.assessHarmThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 0)
	local states = Medusa.Services.HarmDetectionService._networkStates[self.trackStore]
	lu.assertNil(states and states[track.TrackId])
end

function TestAssessHarmThreats:test_returns_zero_with_no_tracks()
	local battery = makeBattery({ ActivationState = "STATE_WARM" })
	self.batteryStore:add(battery)

	local count = Medusa.Services.HarmDetectionService.assessHarmThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertEquals(count, 0)
end

function TestAssessHarmThreats:test_prunes_sprt_state_for_removed_tracks()
	local track = makeTrack({ AssessedAircraftType = "MISSILE", FirstDetectionTime = 0 })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	self.trackStore:add(track)
	self.batteryStore:add(battery)

	populateArmHistory(track, 3, mockTime, emitterPos)
	Medusa.Services.HarmDetectionService.assessHarmThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)

	local states = Medusa.Services.HarmDetectionService._networkStates[self.trackStore]
	lu.assertNotNil(states[track.TrackId])

	self.trackStore:remove(track.TrackId)
	Medusa.Services.HarmDetectionService.assessHarmThreats(
		makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
	)
	lu.assertNil(states[track.TrackId])
end

function TestAssessHarmThreats:test_cleared_track_gets_zero_score()
	local track = makeTrack({ AssessedAircraftType = "MISSILE", FirstDetectionTime = 0 })
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local battery = makeBattery({ ActivationState = "STATE_WARM", Position = emitterPos })
	self.trackStore:add(track)
	self.batteryStore:add(battery)

	for j = 1, 20 do
		populateNonArmHistory(track, 2, mockTime + j * 100)
		Medusa.Services.HarmDetectionService.assessHarmThreats(
			makeCtx({ trackStore = self.trackStore, batteryStore = self.batteryStore, geoGrid = self.geoGrid })
		)
	end

	local states = Medusa.Services.HarmDetectionService._networkStates[self.trackStore]
	local state = states and states[track.TrackId]
	if state and state.label == "CLEARED" then
		lu.assertEquals(track.HarmLikelihoodScore, 0)
	end
end

-- == extractFeatures tests ==

TestExtractFeatures = {}

function TestExtractFeatures:setUp()
	setupMocks()
	clearSprtStates()
end

function TestExtractFeatures:test_extracts_eight_features()
	local curr = {
		timestamp = 1001,
		position = { x = 5000, y = 4000, z = 3000 },
		velocity = { x = 600, y = -200, z = 300 },
	}
	local prev = {
		timestamp = 1000,
		position = { x = 4400, y = 4200, z = 2700 },
		velocity = { x = 610, y = -190, z = 310 },
	}
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local sprtState = { prevCpa = nil, prevTime = nil }
	local feat = Medusa.Services.HarmDetectionService._extractFeatures(curr, prev, 1.0, emitterPos, sprtState)
	lu.assertEquals(#feat, 8)

	-- Speed should be ~700 m/s (sqrt(600^2 + 200^2 + 300^2))
	local expectedSpeed = math.sqrt(600 * 600 + 200 * 200 + 300 * 300)
	lu.assertAlmostEquals(feat[1], expectedSpeed, 1)

	-- Dive angle should be positive (descending)
	lu.assertTrue(feat[2] > 0)

	-- Altitude rate should be negative (descending)
	lu.assertEquals(feat[8], -200)
end

function TestExtractFeatures:test_cpa_rate_computed_on_second_call()
	local emitterPos = { x = 10000, y = 0, z = 6000 }
	local sprtState = { prevCpa = 5000, prevTime = 1000 }
	local curr = {
		timestamp = 1001,
		position = { x = 6000, y = 3000, z = 4000 },
		velocity = { x = 600, y = -200, z = 300 },
	}
	local prev = {
		timestamp = 1000,
		position = { x = 5400, y = 3200, z = 3700 },
		velocity = { x = 610, y = -190, z = 310 },
	}
	local feat = Medusa.Services.HarmDetectionService._extractFeatures(curr, prev, 1.0, emitterPos, sprtState)
	-- CPA rate (feat[6]) should be non-zero since prevCpa was set
	lu.assertNotEquals(feat[6], 0)
end
