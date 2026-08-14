local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("core.Logger")
require("entities.Entities")
require("entities.Battery")
require("services.Services")
require("services.BatteryActivationService")
require("services.stores.BatteryStore")
require("services.AaaService")

local C = Medusa.Constants
local original = {}

local function battery(overrides)
	local value = Medusa.Entities.Battery.new({
		BatteryId = "aaa-1",
		NetworkId = "net",
		GroupId = 1,
		GroupName = "red.aaa",
		Role = C.BatteryRole.AAA,
		Position = { x = 0, y = 100, z = 0 },
		ActivationState = C.ActivationState.STATE_COLD,
		OperationalStatus = C.BatteryOperationalStatus.ACTIVE,
		WeaponRangeMax = 6000,
		EngagementRangeMax = 6000,
		EngagementAltitudeMin = 0,
		EngagementAltitudeMax = 4000,
		TotalAmmoStatus = 100,
	})
	value.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 1,
			UnitName = "gun-1",
			Roles = { C.BatteryUnitRole.AAA },
			AmmoCount = 100,
		}),
	}
	value.Aaa.UnitHeadings = { { hx = 1, hz = 0 } }
	value.Aaa.UnitHeadingCount = 1
	if overrides then
		for key, item in pairs(overrides) do
			value[key] = item
		end
	end
	return value
end

local function firingBattery(overrides)
	local value = battery(overrides)
	value.Aaa.ResponseState = C.Aaa.ResponseState.AREA_FIRE
	value.Aaa.FireTaskActive = true
	value.Aaa.LastFirePoint = { x = 4000, y = 1000, z = 0 }
	return value
end

local function target(name, x, y, z)
	return {
		UnitName = name,
		Position = { x = x, y = y, z = z },
		Velocity = { x = 100, y = 0, z = 0 },
	}
end

local function scanner(targets)
	local values = RingBuffer(math.max(1, #targets), false)
	for i = 1, #targets do
		values:push(targets[i])
	end
	return {
		setSearchRadius = function() end,
		refresh = function() end,
		getTargets = function()
			return values
		end,
		resolve = function(_, snapshot)
			return { name = snapshot.UnitName }, snapshot
		end,
		isHostileAircraft = function()
			return true
		end,
	}
end

local function context(site, targets, overrides)
	local repository = Medusa.Services.BatteryStore:new()
	repository:batteries():add(site)
	local ctx = {
		networkId = "net",
		barrageState = Medusa.Services.AaaService.newBarrageState(),
		batteryStore = repository:batteries(),
		trackStore = {},
		localSearch = scanner(targets),
		now = 0,
		coalitionId = 1,
		posture = C.Posture.HOT_WAR,
		doctrine = {
			ROE = C.ROEState.TIGHT,
			AAA = { AudioRangeM = 6000, AreaFireChance = 0.20, BarrageChance = 0.25, MaxBarrageGroups = 15 },
		},
	}
	if overrides then
		for key, value in pairs(overrides) do
			ctx[key] = value
		end
	end
	return ctx
end

local function propagationContext(sites, options)
	local repository = Medusa.Services.BatteryStore:new()
	local store = repository:batteries()
	local aaaIds = {}
	for i = 1, #sites do
		store:add(sites[i])
		aaaIds[sites[i].BatteryId] = true
	end
	return {
		networkId = options.networkId,
		barrageState = options.barrageState or Medusa.Services.AaaService.newBarrageState(),
		batteryStore = store,
		trackStore = {},
		localGeoGrid = {
			queryRadius = function()
				return { AaaIds = aaaIds }
			end,
		},
		doctrine = { ROE = C.ROEState.TIGHT, AAA = { MaxBarrageGroups = options.maxBarrageGroups } },
	}
end

TestAaaService = {}

function TestAaaService:setUp()
	for _, name in ipairs({
		"GetGroupController",
		"GetGroup",
		"PushControllerTask",
		"PopControllerTask",
		"GetTerrainHeight",
		"IsNightTime",
		"GetUnitPosition",
		"GetUnitHeading",
		"GetTime",
		"ScheduleOnce",
		"CancelSchedule",
	}) do
		original[name] = _G[name]
	end
	original.metricsInc = Medusa.Services.MetricsService.inc
	self.metricCounts = {}
	self.metricNetworks = {}
	Medusa.Services.MetricsService.inc = function(name, delta, labels)
		self.metricCounts[name] = (self.metricCounts[name] or 0) + (delta or 1)
		self.metricNetworks[name] = labels and labels.network or nil
	end
	self.pushedTask = nil
	self.pushedTasks = {}
	self.popCount = 0
	self.now = 0
	self.scheduledCallbacks = {}
	self.cancelledSchedules = {}
	local controller = setmetatable({}, { __index = Controller })
	GetGroupController = function()
		return controller
	end
	GetGroup = function()
		return { enableEmission = function() end }
	end
	PushControllerTask = function(_, task)
		self.pushedTask = task
		self.pushedTasks[#self.pushedTasks + 1] = task
		return true
	end
	PopControllerTask = function()
		self.popCount = self.popCount + 1
		return true
	end
	GetTerrainHeight = function()
		return 100
	end
	IsNightTime = function()
		return false
	end
	GetTime = function()
		return self.now
	end
	ScheduleOnce = function(callback, _, delay)
		local id = "aaa-timer-" .. tostring(#self.scheduledCallbacks + 1)
		self.scheduledCallbacks[#self.scheduledCallbacks + 1] = { id = id, callback = callback, delay = delay }
		return id
	end
	CancelSchedule = function(id)
		self.cancelledSchedules[#self.cancelledSchedules + 1] = id
		return true
	end
	self.random = math.random
end

function TestAaaService:tearDown()
	for name, value in pairs(original) do
		_G[name] = value
	end
	Medusa.Services.MetricsService.inc = original.metricsInc
	math.random = self.random
end

function TestAaaService:test_records_visual_detection_and_local_acquisition()
	math.random = function()
		return 0.9
	end
	local site = battery()
	local ctx = context(site, { target("aircraft", 5000, 500, 0) })
	ctx.doctrine.AAA.AudioRangeM = 0

	Medusa.Services.AaaService.evaluate(ctx)
	ctx.now = 15
	Medusa.Services.AaaService.evaluate(ctx)

	lu.assertEquals(self.metricCounts.medusa_aaa_visual_detections_total, 1)
	lu.assertEquals(self.metricCounts.medusa_aaa_local_acquisition_responses_total, 1)
	lu.assertIsNil(self.metricCounts.medusa_aaa_audio_detections_total)
	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.LOCAL_ACQUISITION)
	lu.assertEquals(site.ActivationState, C.ActivationState.STATE_HOT)
	lu.assertIsNil(site.CurrentTargetTrackId)
end

function TestAaaService:test_records_audio_attempts_detection_and_area_fire()
	math.random = function()
		return 0
	end
	local site = battery()
	local ctx = context(site, { target("aircraft", -1000, 100, 0) })
	ctx.doctrine.AAA.AreaFireChance = 1

	Medusa.Services.AaaService.evaluate(ctx)
	ctx.now = 15
	Medusa.Services.AaaService.evaluate(ctx)

	lu.assertEquals(self.metricCounts.medusa_aaa_audio_attempts_total, 1)
	lu.assertEquals(self.metricCounts.medusa_aaa_audio_detections_total, 1)
	lu.assertEquals(self.metricCounts.medusa_aaa_area_fire_responses_total, 1)
end

function TestAaaService:test_position_refresh_updates_grid_and_metric()
	local site = battery()
	site.Aaa.Mode = C.Aaa.Mode.INDEPENDENT
	local ctx = context(site, {})
	local updatedBattery
	ctx.localGeoGrid = {
		updatePosition = function(_, batteryId)
			if batteryId == site.BatteryId then
				updatedBattery = site
			end
		end,
	}
	GetUnitPosition = function()
		return { x = 200, y = 100, z = 300 }
	end
	GetUnitHeading = function()
		return 90
	end

	Medusa.Services.AaaService.refreshOnePosition(ctx)

	lu.assertEquals(updatedBattery, site)
	lu.assertEquals(site.Position, { x = 200, y = 100, z = 300 })
	lu.assertEquals(site.Aaa.UnitHeadingCount, 1)
	lu.assertEquals(self.metricCounts.medusa_aaa_position_refreshes_total, 1)
end

function TestAaaService:test_scan_radius_covers_visual_altitude_ceiling()
	local radius
	local localScanner = scanner({})
	localScanner.setSearchRadius = function(_, value)
		radius = value
	end
	local ctx = context(battery(), {}, { localSearch = localScanner })

	Medusa.Services.AaaService.evaluate(ctx)

	local detection = C.LocalAircraftDetection
	local requiredSquared = detection.PRIMARY_RANGE_M ^ 2 + detection.RELATIVE_ALTITUDE_CEILING_M ^ 2
	lu.assertAlmostEquals(radius, math.sqrt(requiredSquared), 0.001)
end

function TestAaaService:test_night_area_fire_uses_inverse_day_probability()
	IsNightTime = function()
		return true
	end
	local rolls = { 0.5, 0, 0, 0 }
	math.random = function()
		return table.remove(rolls, 1)
	end
	local site = battery()
	local ctx = context(site, { target("aircraft", 3000, 500, 0) })
	Medusa.Services.AaaService.evaluate(ctx)
	ctx.now = 15
	Medusa.Services.AaaService.evaluate(ctx)
	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.AREA_FIRE)
	lu.assertEquals(self.pushedTask.id, "FireAtPoint")
	lu.assertEquals(self.pushedTask.params.point, { x = 3500, y = 0 })
	lu.assertEquals(self.pushedTask.params.altitude, 500)
	lu.assertEquals(self.pushedTask.params.alt_type, 0)
end

function TestAaaService:test_area_fire_is_capped_to_maximum_slant_range()
	GetTerrainHeight = function()
		return 1000
	end
	local rolls = { 0, 1, 0, 0 }
	math.random = function()
		return table.remove(rolls, 1)
	end
	local site = battery()
	local ctx = context(site, { target("aircraft", 5900, 500, 0) })
	ctx.doctrine.AAA.AreaFireChance = 1
	Medusa.Services.AaaService.evaluate(ctx)
	ctx.now = 15

	Medusa.Services.AaaService.evaluate(ctx)

	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.AREA_FIRE)
	local point = self.pushedTask.params.point
	local dx = point.x - site.Position.x
	local dy = self.pushedTask.params.altitude - site.Position.y
	local dz = point.y - site.Position.z
	lu.assertAlmostEquals(math.sqrt(dx * dx + dy * dy + dz * dz), site.WeaponRangeMax, 0.001)
	lu.assertAlmostEquals(point.x, math.sqrt(site.WeaponRangeMax ^ 2 - 1000 ^ 2), 0.001)
	lu.assertEquals(self.pushedTask.params.altitude, 1100)
end

function TestAaaService:test_area_fire_can_escalate_into_alternating_barrage_bursts()
	math.random = function()
		return 0
	end
	local site = battery()
	local ctx = context(site, { target("aircraft", 3000, 500, 0) })
	ctx.doctrine.AAA.AreaFireChance = 1
	ctx.doctrine.AAA.BarrageChance = 1

	Medusa.Services.AaaService.evaluate(ctx)
	ctx.now = 15
	Medusa.Services.AaaService.evaluate(ctx)
	ctx.now = 45
	Medusa.Services.AaaService.evaluate(ctx)

	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.BARRAGE_PAUSE)
	lu.assertEquals(site.Aaa.BarrageUntil, 645)
	lu.assertEquals(site.Aaa.ResponseUntil, 55)
	lu.assertEquals(self.popCount, 1)
	ctx.localSearch = scanner({})

	ctx.now = 55
	Medusa.Services.AaaService.evaluate(ctx)
	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.BARRAGE_FIRE)
	lu.assertEquals(site.Aaa.ResponseUntil, 65)
	lu.assertEquals(#self.pushedTasks, 2)

	ctx.now = 65
	Medusa.Services.AaaService.evaluate(ctx)
	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.BARRAGE_PAUSE)
	lu.assertEquals(site.Aaa.ResponseUntil, 75)
	lu.assertEquals(self.popCount, 2)

	ctx.now = 75
	Medusa.Services.AaaService.evaluate(ctx)
	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.BARRAGE_FIRE)
	lu.assertEquals(#self.pushedTasks, 3)
	lu.assertEquals(self.metricCounts.medusa_aaa_barrage_responses_total, 1)
	lu.assertEquals(self.metricCounts.medusa_aaa_barrage_bursts_total, 2)
end

function TestAaaService:test_barrage_chance_zero_finishes_after_area_fire()
	math.random = function()
		return 0
	end
	local site = battery()
	local ctx = context(site, { target("aircraft", 3000, 500, 0) })
	ctx.doctrine.AAA.AreaFireChance = 1
	ctx.doctrine.AAA.BarrageChance = 0

	Medusa.Services.AaaService.evaluate(ctx)
	ctx.now = 15
	Medusa.Services.AaaService.evaluate(ctx)
	ctx.now = 45
	Medusa.Services.AaaService.evaluate(ctx)

	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.IDLE)
	lu.assertEquals(site.ActivationState, C.ActivationState.STATE_COLD)
	lu.assertIsNil(self.metricCounts.medusa_aaa_barrage_responses_total)
end

function TestAaaService:test_barrage_pause_durations_diverge()
	local first = battery({ BatteryId = "first", ActivationState = C.ActivationState.STATE_HOT })
	first.Aaa.Mode = C.Aaa.Mode.INDEPENDENT
	first.Aaa.ResponseState = C.Aaa.ResponseState.BARRAGE_FIRE
	first.Aaa.ResponseUntil = 100
	first.Aaa.BarrageUntil = 600
	first.Aaa.FireTaskActive = true
	local second = battery({ BatteryId = "second", ActivationState = C.ActivationState.STATE_HOT })
	second.Aaa.Mode = C.Aaa.Mode.INDEPENDENT
	second.Aaa.ResponseState = C.Aaa.ResponseState.BARRAGE_FIRE
	second.Aaa.ResponseUntil = 100
	second.Aaa.BarrageUntil = 600
	second.Aaa.FireTaskActive = true
	local rolls = { 0.2, 0.8 }
	math.random = function()
		return table.remove(rolls, 1)
	end

	local firstCtx = context(first, {})
	firstCtx.now = 100
	Medusa.Services.AaaService.evaluate(firstCtx)
	local secondCtx = context(second, {})
	secondCtx.now = 100
	Medusa.Services.AaaService.evaluate(secondCtx)

	lu.assertEquals(first.Aaa.ResponseState, C.Aaa.ResponseState.BARRAGE_PAUSE)
	lu.assertEquals(second.Aaa.ResponseState, C.Aaa.ResponseState.BARRAGE_PAUSE)
	lu.assertAlmostEquals(first.Aaa.ResponseUntil, 111, 0.001)
	lu.assertAlmostEquals(second.Aaa.ResponseUntil, 114, 0.001)
end

function TestAaaService:test_zero_barrage_limit_prevents_escalation()
	math.random = function()
		return 0
	end
	local site = battery()
	local ctx = context(site, { target("aircraft", 3000, 500, 0) })
	ctx.doctrine.AAA.AreaFireChance = 1
	ctx.doctrine.AAA.MaxBarrageGroups = 0

	Medusa.Services.AaaService.evaluate(ctx)
	ctx.now = 15
	Medusa.Services.AaaService.evaluate(ctx)
	ctx.now = 45
	Medusa.Services.AaaService.evaluate(ctx)

	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.IDLE)
	lu.assertEquals(site.ActivationState, C.ActivationState.STATE_COLD)
	lu.assertIsNil(self.metricCounts.medusa_aaa_barrage_responses_total)
end

function TestAaaService:test_barrage_detection_uses_normal_response_then_resumes_until_deadline()
	math.random = function()
		return 0.9
	end
	local site = battery({ ActivationState = C.ActivationState.STATE_HOT })
	site.Aaa.Mode = C.Aaa.Mode.INDEPENDENT
	site.Aaa.ResponseState = C.Aaa.ResponseState.BARRAGE_FIRE
	site.Aaa.ResponseUntil = 10
	site.Aaa.BarrageUntil = 600
	site.Aaa.FireTaskActive = true
	local ctx = context(site, { target("new-contact", 3000, 500, 0) })
	ctx.now = 1

	Medusa.Services.AaaService.evaluate(ctx)

	lu.assertEquals(self.popCount, 1)
	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.LOCAL_ACQUISITION)
	lu.assertEquals(site.Aaa.PendingTarget.UnitName, "new-contact")
	lu.assertEquals(site.Aaa.BarrageUntil, 600)

	ctx.localSearch = scanner({})
	ctx.now = 181
	Medusa.Services.AaaService.evaluate(ctx)
	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.BARRAGE_PAUSE)
	lu.assertAlmostEquals(site.Aaa.ResponseUntil, 195.5, 0.001)
	lu.assertEquals(site.ActivationState, C.ActivationState.STATE_HOT)

	ctx.now = 600
	Medusa.Services.AaaService.evaluate(ctx)
	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.IDLE)
	lu.assertEquals(site.ActivationState, C.ActivationState.STATE_COLD)
end

function TestAaaService:test_aaa_fire_infects_idle_and_alert_neighbors_after_ten_seconds()
	math.random = function()
		return 0
	end
	local source = firingBattery({
		BatteryId = "source",
		NetworkId = "infection-net",
		GroupId = 1,
		GroupName = "source",
		ActivationState = C.ActivationState.STATE_HOT,
	})
	local idle = battery({ BatteryId = "idle", NetworkId = "infection-net", GroupId = 2, GroupName = "idle" })
	idle.Units[1].UnitId = 2
	idle.Aaa.Mode = C.Aaa.Mode.INDEPENDENT
	local alertSite = battery({ BatteryId = "alert", NetworkId = "infection-net", GroupId = 3, GroupName = "alert" })
	alertSite.Units[1].UnitId = 3
	alertSite.Aaa.Mode = C.Aaa.Mode.INDEPENDENT
	alertSite.Aaa.ResponseState = C.Aaa.ResponseState.ALERT
	alertSite.Aaa.ResponseAt = 15
	local active = battery({ BatteryId = "active", NetworkId = "infection-net", GroupId = 4, GroupName = "active" })
	active.Units[1].UnitId = 4
	active.Aaa.ResponseState = C.Aaa.ResponseState.LOCAL_ACQUISITION
	active.Aaa.ResponseUntil = 180
	local changed = battery({ BatteryId = "changed", NetworkId = "infection-net", GroupId = 5, GroupName = "changed" })
	changed.Units[1].UnitId = 5

	local queriedRadius
	local queryCount = 0
	local ctx = propagationContext({ source, idle, alertSite, active, changed }, {
		networkId = "infection-net",
		maxBarrageGroups = 15,
	})
	ctx.localGeoGrid.queryRadius = function(_, _, radius)
		queryCount = queryCount + 1
		queriedRadius = radius
		return { AaaIds = { source = true, idle = true, alert = true, active = true, changed = true } }
	end

	Medusa.Services.AaaService.onShot(ctx, source, source.Units[1], 100)

	lu.assertEquals(queriedRadius, 5 * 1852)
	lu.assertEquals(#self.scheduledCallbacks, 3)
	lu.assertEquals(idle.Aaa.ResponseState, C.Aaa.ResponseState.IDLE)
	lu.assertEquals(alertSite.Aaa.ResponseState, C.Aaa.ResponseState.ALERT)
	lu.assertEquals(active.Aaa.ResponseState, C.Aaa.ResponseState.LOCAL_ACQUISITION)
	Medusa.Services.AaaService.onShot(ctx, source, source.Units[1], 119)
	lu.assertEquals(queryCount, 1)
	changed.Aaa.ResponseState = C.Aaa.ResponseState.LOCAL_ACQUISITION
	changed.Aaa.ResponseUntil = 300

	self.now = 110
	for i = 1, #self.scheduledCallbacks do
		self.scheduledCallbacks[i].callback()
	end

	lu.assertEquals(idle.Aaa.ResponseState, C.Aaa.ResponseState.BARRAGE_FIRE)
	lu.assertEquals(alertSite.Aaa.ResponseState, C.Aaa.ResponseState.BARRAGE_FIRE)
	lu.assertEquals(idle.Aaa.BarrageUntil, 700)
	lu.assertEquals(alertSite.Aaa.BarrageUntil, 700)
	lu.assertEquals(idle.Aaa.ResponseUntil, 120)
	lu.assertEquals(alertSite.Aaa.ResponseUntil, 120)
	lu.assertEquals(active.Aaa.ResponseState, C.Aaa.ResponseState.LOCAL_ACQUISITION)
	lu.assertEquals(changed.Aaa.ResponseState, C.Aaa.ResponseState.LOCAL_ACQUISITION)
	for i = 1, #self.pushedTasks do
		lu.assertEquals(self.pushedTasks[i].params.point, { x = 4000, y = 0 })
		lu.assertEquals(self.pushedTasks[i].params.altitude, 1000)
	end

	local rolls = { 0, 0.5, 0, 0.5, 0, 0, 0.5, 0.5, 0.5, 0 }
	local rollIndex = 0
	math.random = function()
		rollIndex = rollIndex + 1
		return rolls[rollIndex]
	end
	local idleCtx = context(idle, {}, { networkId = ctx.networkId, barrageState = ctx.barrageState })
	idleCtx.now = 120
	Medusa.Services.AaaService.evaluate(idleCtx)
	idleCtx.now = 130
	Medusa.Services.AaaService.evaluate(idleCtx)
	local alertCtx = context(alertSite, {}, { networkId = ctx.networkId, barrageState = ctx.barrageState })
	alertCtx.now = 120
	Medusa.Services.AaaService.evaluate(alertCtx)
	alertCtx.now = 130
	Medusa.Services.AaaService.evaluate(alertCtx)

	lu.assertAlmostEquals(self.pushedTasks[3].params.point.x, 5500, 0.001)
	lu.assertAlmostEquals(self.pushedTasks[4].params.point.x, 2500, 0.001)

	math.random = function()
		return 0
	end
	active.Aaa.ResponseState = C.Aaa.ResponseState.IDLE
	active.Aaa.ResponseUntil = nil
	Medusa.Services.AaaService.onShot(ctx, idle, idle.Units[1], 130)
	lu.assertEquals(#self.scheduledCallbacks, 4)
	self.now = 140
	self.scheduledCallbacks[4].callback()
	lu.assertAlmostEquals(self.pushedTasks[5].params.point.x, 5500, 0.001)
	lu.assertEquals(self.metricCounts.medusa_aaa_barrage_responses_total, 3)
	lu.assertEquals(self.metricCounts.medusa_aaa_barrage_infections_total, 3)
	lu.assertEquals(self.metricCounts.medusa_aaa_barrage_bursts_total, 5)
	lu.assertEquals(self.metricNetworks.medusa_aaa_barrage_responses_total, "infection-net")
	lu.assertEquals(self.metricNetworks.medusa_aaa_barrage_infections_total, "infection-net")
	lu.assertEquals(self.metricNetworks.medusa_aaa_barrage_bursts_total, "infection-net")

	changed.Aaa.ResponseState = C.Aaa.ResponseState.IDLE
	changed.Aaa.ResponseUntil = nil
	lu.assertEquals(Medusa.Services.AaaService.onShot(ctx, active, active.Units[1], 700), 0)
	lu.assertEquals(#self.scheduledCallbacks, 4)
end

function TestAaaService:test_barrage_infection_delays_vary_without_dropping_below_ten_seconds()
	local source = firingBattery({ BatteryId = "source", GroupId = 1, GroupName = "source" })
	local first = battery({ BatteryId = "first", GroupId = 2, GroupName = "first" })
	first.Units[1].UnitId = 2
	local second = battery({ BatteryId = "second", GroupId = 3, GroupName = "second" })
	second.Units[1].UnitId = 3
	local rolls = { 0, 1, 0.2, 0.8 }
	math.random = function()
		return table.remove(rolls, 1)
	end
	local ctx = propagationContext({ source, first, second }, {
		networkId = "delay-net",
		maxBarrageGroups = 15,
	})

	Medusa.Services.AaaService.onShot(ctx, source, source.Units[1], 100)

	local delays = { self.scheduledCallbacks[1].delay, self.scheduledCallbacks[2].delay }
	table.sort(delays)
	lu.assertEquals(delays, { 10, 20 })
	for i = 1, #self.scheduledCallbacks do
		self.now = 100 + self.scheduledCallbacks[i].delay
		self.scheduledCallbacks[i].callback()
	end
	local responseDeadlines = { first.Aaa.ResponseUntil, second.Aaa.ResponseUntil }
	table.sort(responseDeadlines)
	lu.assertEquals(responseDeadlines, { 121, 134 })
end

function TestAaaService:test_barrage_participant_cap_is_shared_across_networks()
	local barrageState = Medusa.Services.AaaService.newBarrageState()
	Medusa.Services.AaaService.setBarrageLimit(barrageState, "first-network", 1)
	Medusa.Services.AaaService.setBarrageLimit(barrageState, "second-network", 2)
	local sourceA =
		firingBattery({ BatteryId = "source-a", NetworkId = "first-network", GroupId = 1, GroupName = "source-a" })
	local recipientA =
		battery({ BatteryId = "recipient-a", NetworkId = "first-network", GroupId = 2, GroupName = "recipient-a" })
	recipientA.Units[1].UnitId = 2
	local sourceB =
		firingBattery({ BatteryId = "source-b", NetworkId = "second-network", GroupId = 3, GroupName = "source-b" })
	local recipientB =
		battery({ BatteryId = "recipient-b", NetworkId = "second-network", GroupId = 4, GroupName = "recipient-b" })
	recipientB.Units[1].UnitId = 4
	math.random = function()
		return 0
	end

	Medusa.Services.AaaService.onShot(
		propagationContext({ sourceB, recipientB }, {
			networkId = "second-network",
			barrageState = barrageState,
			maxBarrageGroups = 2,
		}),
		sourceB,
		sourceB.Units[1],
		100
	)
	self.now = 110
	self.scheduledCallbacks[1].callback()
	Medusa.Services.AaaService.onShot(
		propagationContext({ sourceA, recipientA }, {
			networkId = "first-network",
			barrageState = barrageState,
			maxBarrageGroups = 1,
		}),
		sourceA,
		sourceA.Units[1],
		100
	)
	self.scheduledCallbacks[2].callback()

	lu.assertEquals(recipientB.Aaa.ResponseState, C.Aaa.ResponseState.BARRAGE_FIRE)
	lu.assertEquals(recipientA.Aaa.ResponseState, C.Aaa.ResponseState.IDLE)
	lu.assertEquals(recipientA.ActivationState, C.ActivationState.STATE_COLD)
	lu.assertEquals(self.metricNetworks.medusa_aaa_barrage_infections_total, "second-network")
end

function TestAaaService:test_audio_detection_rolls_for_each_aircraft()
	local rolls = 0
	math.random = function()
		rolls = rolls + 1
		return rolls == 1 and 0.9 or 0.1
	end
	local site = battery()
	local ctx = context(site, {
		target("second", -3000, 100, 0),
		target("first", -2000, 100, 0),
	})
	Medusa.Services.AaaService.evaluate(ctx)
	lu.assertEquals(rolls, 2)
	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.ALERT)
	lu.assertEquals(site.Aaa.PendingTarget.UnitName, "second")
end

function TestAaaService:test_hold_roe_suppresses_local_response()
	local site = battery()
	local ctx = context(site, { target("aircraft", 1000, 100, 0) })
	ctx.doctrine.ROE = C.ROEState.HOLD
	Medusa.Services.AaaService.evaluate(ctx)
	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.IDLE)
end

function TestAaaService:test_hold_roe_cancels_pending_response()
	local site = battery()
	local ctx = context(site, { target("aircraft", 1000, 100, 0) })
	Medusa.Services.AaaService.evaluate(ctx)
	ctx.doctrine.ROE = C.ROEState.HOLD
	ctx.now = 1

	Medusa.Services.AaaService.evaluate(ctx)

	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.IDLE)
	lu.assertEquals(site.ActivationState, C.ActivationState.STATE_COLD)
end

function TestAaaService:test_local_acquisition_returns_to_cold_after_timeout()
	math.random = function()
		return 0.9
	end
	local site = battery()
	local ctx = context(site, { target("aircraft", 1000, 100, 0) })
	Medusa.Services.AaaService.evaluate(ctx)
	ctx.now = 15
	Medusa.Services.AaaService.evaluate(ctx)
	ctx.now = 195

	Medusa.Services.AaaService.evaluate(ctx)

	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.IDLE)
	lu.assertEquals(site.ActivationState, C.ActivationState.STATE_COLD)
end

function TestAaaService:test_alert_response_continues_when_site_is_already_hot()
	math.random = function()
		return 0.9
	end
	local site = battery({ ActivationState = C.ActivationState.STATE_HOT })
	site.Aaa.Mode = C.Aaa.Mode.INDEPENDENT
	local ctx = context(site, { target("aircraft", 1000, 100, 0) })

	Medusa.Services.AaaService.evaluate(ctx)
	ctx.now = 15
	Medusa.Services.AaaService.evaluate(ctx)

	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.LOCAL_ACQUISITION)
end

function TestAaaService:test_radar_directed_aaa_is_not_locally_activated()
	local site = battery({ DetectionRangeMax = 20000 })
	site.Units[#site.Units + 1] = Medusa.Entities.Battery.newUnit({
		UnitId = 2,
		UnitName = "search-radar",
		Roles = { C.BatteryUnitRole.SEARCH_RADAR },
	})
	local ctx = context(site, { target("aircraft", 1000, 100, 0) })
	Medusa.Services.AaaService.evaluate(ctx)
	lu.assertEquals(site.Aaa.ResponseState, C.Aaa.ResponseState.IDLE)
	lu.assertEquals(site.ActivationState, C.ActivationState.STATE_COLD)
end

function TestAaaService:test_radar_loss_returns_site_to_independent_cold_state()
	local site = battery({
		ActivationState = C.ActivationState.STATE_HOT,
		DetectionRangeMax = 10000,
	})
	site.Aaa.Mode = C.Aaa.Mode.RADAR_DIRECTED
	local ctx = context(site, {})
	local withdrawnId
	local syncedBattery
	ctx.spatialIndex = {
		withdrawBattery = function(_, batteryId)
			withdrawnId = batteryId
		end,
		syncBattery = function(_, value)
			syncedBattery = value
		end,
	}

	Medusa.Services.AaaService.evaluate(ctx)

	lu.assertEquals(site.Aaa.Mode, C.Aaa.Mode.INDEPENDENT)
	lu.assertEquals(site.ActivationState, C.ActivationState.STATE_COLD)
	lu.assertEquals(withdrawnId, site.BatteryId)
	lu.assertEquals(syncedBattery, site)
end
