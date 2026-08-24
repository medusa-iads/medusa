local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("core.Logger")
require("entities.Entities")
require("entities.Battery")
require("services.Services")
require("services.stores.BatteryStore")
require("services.stores.UnitGeoGrid")
require("services.BatteryActivationService")
require("services.AaaService")
require("services.ManpadService")
require("services.PointDefenseService")
require("services.CrewSuppressionService")

local C = Medusa.Constants
local Battery = Medusa.Entities.Battery
local CrewSuppressionService = Medusa.Services.CrewSuppressionService
local MetricsService = Medusa.Observability.MetricsService

local original = {}

local function manpadState()
	return {
		SleepWakeState = C.Manpad.SleepWakeState.ALERTING,
		WakeReason = C.Manpad.WakeReason.IADS,
		AlertCycleCount = 0,
		LastAlertedTime = nil,
		AudioCueRangeM = C.Manpad.AUDIO_RANGE_MAX_M,
		WakeTimerId = "wake-timer",
		UnitHeadings = {},
		UnitHeadingCount = 0,
	}
end

local function makeBattery(role)
	local battery = Battery.new({
		BatteryId = "battery-1",
		NetworkId = "network-1",
		GroupId = 10,
		GroupName = "red.local-defense",
		Role = role,
		ActivationState = C.ActivationState.STATE_HOT,
		OperationalStatus = C.BatteryOperationalStatus.ACTIVE,
		TotalAmmoStatus = 20,
		GroupDiameterM = 0,
		Manpad = role == C.BatteryRole.MANPAD and manpadState() or nil,
	})
	battery.Units = {
		Battery.newUnit({
			UnitId = 101,
			UnitName = "gunner-1",
			Roles = {
				role == C.BatteryRole.MANPAD and C.BatteryUnitRole.MANPAD or C.BatteryUnitRole.AAA,
			},
			LastKnownLife = 100,
			InitialLife = 100,
		}),
	}
	if battery.Aaa then
		battery.Aaa.ResponseState = C.Aaa.ResponseState.AREA_FIRE
		battery.Aaa.ResponseAt = 110
		battery.Aaa.ResponseUntil = 140
		battery.Aaa.PendingTarget = { UnitName = "target" }
		battery.Aaa.LastFirePoint = { x = 1000, y = 100, z = 0 }
	end
	return battery
end

local function makeContext(test, battery)
	local repository = Medusa.Services.BatteryStore:new()
	repository:add(battery)
	local assigned = Set()
	assigned:add(battery.BatteryId)
	local track = { AssignedBatteryIds = assigned }
	return {
		networkId = "network-1",
		batteryRepository = repository,
		trackStore = {
			get = function(_, trackId)
				return trackId == "track-1" and track or nil
			end,
		},
		barrageState = Medusa.Services.AaaService.newBarrageState(),
		doctrine = {
			CrewSuppression = {
				Enabled = C.CrewSuppression.DEFAULT_ENABLED,
				DurationMinSec = C.CrewSuppression.DEFAULT_DURATION_MIN_SEC,
				DurationMaxSec = C.CrewSuppression.DEFAULT_DURATION_MAX_SEC,
				MaxGroupDiameterM = C.CrewSuppression.DEFAULT_MAX_GROUP_DIAMETER_M,
				ExplosiveRadiusScaleM = C.CrewSuppression.DEFAULT_EXPLOSIVE_RADIUS_SCALE_M,
				ExplosiveRadiusMaxM = C.CrewSuppression.EXPLOSIVE_RADIUS_MAX_M,
				ExplosiveEffectiveness = C.CrewSuppression.DEFAULT_EXPLOSIVE_EFFECTIVENESS,
				DefaultCrewSkill = C.CrewSuppression.DEFAULT_CREW_SKILL,
				SkillResistancePerLevel = C.CrewSuppression.DEFAULT_SKILL_RESISTANCE_PER_LEVEL,
				CannonRadiusM = C.CrewSuppression.DEFAULT_CANNON_RADIUS_M,
				CannonEffectiveness = C.CrewSuppression.DEFAULT_CANNON_EFFECTIVENESS,
			},
		},
		now = test.now,
		random = function()
			return 1
		end,
	}
end

TestCrewSuppressionService = {}

function TestCrewSuppressionService:setUp()
	for _, name in ipairs({
		"GetTime",
		"GetUnitHealth",
		"ScheduleOnce",
		"CancelSchedule",
		"GetGroupController",
		"SetControllerOnOff",
		"ControllerSetROE",
		"ControllerSetAlarmState",
		"SetControllerOption",
		"GetGroup",
		"EnableGroupEmissions",
		"PopControllerTask",
	}) do
		original[name] = _G[name]
	end
	self.now = 100
	self.life = 80
	self.scheduled = {}
	self.cancelled = {}
	self.roe = {}
	self.popCount = 0
	self.droppedReasons = {}
	self.originalInfo = env.info
	self.originalLogLevel = Medusa.Logger:getLevel()
	self.infoMessages = {}
	env.info = function(message)
		self.infoMessages[#self.infoMessages + 1] = message
	end
	Medusa.Logger:setLevel(C.LogLevel.INFO)
	self.metricsInc = MetricsService.inc
	MetricsService.inc = function(name, _, labels)
		if name == "medusa_crew_suppression_dropped_events_total" then
			self.droppedReasons[#self.droppedReasons + 1] = labels.reason
		end
	end
	GetTime = function()
		return self.now
	end
	GetUnitHealth = function()
		if self.life == nil then
			return nil
		end
		return {
			CurrentLife = self.life,
			InitialLife = 100,
			IsAlive = self.life > 0,
			IsDamaged = self.life > 0 and self.life < 100,
		}
	end
	ScheduleOnce = function(callback, _, delay)
		local id = "timer-" .. tostring(#self.scheduled + 1)
		self.scheduled[#self.scheduled + 1] = { id = id, callback = callback, delay = delay }
		return id
	end
	CancelSchedule = function(timerId)
		self.cancelled[#self.cancelled + 1] = timerId
		return true
	end
	GetGroupController = function()
		return {}
	end
	SetControllerOnOff = function()
		return true
	end
	ControllerSetROE = function(_, value)
		self.roe[#self.roe + 1] = value
		return true
	end
	ControllerSetAlarmState = function()
		return true
	end
	SetControllerOption = function()
		return true
	end
	GetGroup = function()
		return {}
	end
	EnableGroupEmissions = function()
		return true
	end
	PopControllerTask = function()
		self.popCount = self.popCount + 1
		return true
	end
end

function TestCrewSuppressionService:tearDown()
	MetricsService.inc = self.metricsInc
	env.info = self.originalInfo
	Medusa.Logger:setLevel(self.originalLogLevel)
	for name, value in pairs(original) do
		_G[name] = value
	end
end

function TestCrewSuppressionService:test_successful_suppression_logs_group_cause_and_duration()
	local battery = makeBattery(C.BatteryRole.AAA)
	local ctx = makeContext(self, battery)

	lu.assertTrue(CrewSuppressionService.processDamage(ctx, 101))

	lu.assertEquals(#self.infoMessages, 1)
	lu.assertStrContains(self.infoMessages[1], "[ Medusa | INFO | CrewSuppressionService ]")
	lu.assertStrContains(self.infoMessages[1], "red.local-defense")
	lu.assertStrContains(self.infoMessages[1], "cause=DAMAGE")
	lu.assertStrContains(self.infoMessages[1], "duration=120s")
end

function TestCrewSuppressionService:test_missing_health_logs_damage_evaluation_at_debug()
	local battery = makeBattery(C.BatteryRole.AAA)
	local ctx = makeContext(self, battery)
	self.life = nil
	Medusa.Logger:setLevel(C.LogLevel.DEBUG)

	lu.assertFalse(CrewSuppressionService.processDamage(ctx, 101))

	local message = self.infoMessages[#self.infoMessages]
	lu.assertStrContains(message, "[ Medusa | DEBUG | CrewSuppressionService ]")
	lu.assertStrContains(message, "red.local-defense")
	lu.assertStrContains(message, "unitId=101")
	lu.assertStrContains(message, "health unavailable")
end

function TestCrewSuppressionService:test_extension_and_recovery_decisions_are_logged_at_info()
	local battery = makeBattery(C.BatteryRole.AAA)
	local ctx = makeContext(self, battery)

	CrewSuppressionService.apply(ctx, battery, C.CrewSuppressionCause.DAMAGE, 120)
	self.now = 150
	ctx.now = self.now
	CrewSuppressionService.apply(ctx, battery, C.CrewSuppressionCause.DAMAGE, 120)
	lu.assertStrContains(self.infoMessages[#self.infoMessages], "crew suppression extended")
	lu.assertStrContains(self.infoMessages[#self.infoMessages], "duration=120s")

	self.now = 160
	ctx.now = self.now
	CrewSuppressionService.apply(ctx, battery, C.CrewSuppressionCause.DAMAGE, 30)
	lu.assertStrContains(self.infoMessages[#self.infoMessages], "crew suppression reapplied")

	self.now = 220
	self.scheduled[1].callback()
	self.now = 270
	self.scheduled[2].callback()
	lu.assertStrContains(self.infoMessages[#self.infoMessages], "crew suppression recovered")
	lu.assertStrContains(self.infoMessages[#self.infoMessages], "cause=DAMAGE")
end

function TestCrewSuppressionService:test_new_damage_suppresses_complete_aaa_group()
	local battery = makeBattery(C.BatteryRole.AAA)
	battery.CurrentTargetTrackId = "track-1"
	battery.LastChanceTrackId = "stale-track"
	battery.LastChanceExpiresAt = 140
	battery.LastChanceShotsRemaining = 1
	local ctx = makeContext(self, battery)

	local applied = CrewSuppressionService.processDamage(ctx, 101)

	lu.assertTrue(applied)
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.SUPPRESSED)
	lu.assertEquals(battery.CrewSuppressionCause, C.CrewSuppressionCause.DAMAGE)
	lu.assertEquals(battery.CrewSuppressionUntil, 220)
	lu.assertEquals(battery.Units[1].LastKnownLife, 80)
	lu.assertEquals(battery.Units[1].OperationalStatus, C.UnitOperationalStatus.DAMAGED)
	lu.assertEquals(battery.ActivationState, C.ActivationState.STATE_COLD)
	lu.assertNil(battery.CurrentTargetTrackId)
	lu.assertNil(battery.LastChanceTrackId)
	lu.assertEquals(battery.Aaa.ResponseState, C.Aaa.ResponseState.IDLE)
	lu.assertNil(battery.Aaa.LastFirePoint)
	lu.assertEquals(self.popCount, 1)
	lu.assertEquals(self.roe[#self.roe], "WEAPON_HOLD")
	lu.assertEquals(self.scheduled[1].delay, 120)
end

function TestCrewSuppressionService:test_damage_duration_is_sampled_from_doctrine_range()
	local cases = {
		{ sample = 0, duration = C.CrewSuppression.DEFAULT_DURATION_MIN_SEC },
		{ sample = 0.5, duration = 75 },
		{ sample = 1, duration = C.CrewSuppression.DEFAULT_DURATION_MAX_SEC },
	}

	for i = 1, #cases do
		local battery = makeBattery(C.BatteryRole.AAA)
		local ctx = makeContext(self, battery)
		ctx.random = function()
			return cases[i].sample
		end

		lu.assertTrue(CrewSuppressionService.processDamage(ctx, 101))
		lu.assertEquals(battery.CrewSuppressionUntil, self.now + cases[i].duration)
	end
end

function TestCrewSuppressionService:test_hit_without_new_live_damage_does_not_suppress()
	local battery = makeBattery(C.BatteryRole.AAA)
	local ctx = makeContext(self, battery)
	self.life = 100
	lu.assertFalse(CrewSuppressionService.processDamage(ctx, 101))
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.CLEAR)

	self.life = 0
	lu.assertFalse(CrewSuppressionService.processDamage(ctx, 101))
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.CLEAR)

	self.life = nil
	lu.assertFalse(CrewSuppressionService.processDamage(ctx, 101))
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.CLEAR)
end

function TestCrewSuppressionService:test_disabled_doctrine_does_not_suppress()
	local battery = makeBattery(C.BatteryRole.AAA)
	local ctx = makeContext(self, battery)
	ctx.doctrine.CrewSuppression.Enabled = false

	lu.assertFalse(CrewSuppressionService.processDamage(ctx, 101))
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.CLEAR)
	lu.assertEquals(#self.scheduled, 0)
end

function TestCrewSuppressionService:test_group_below_diameter_limit_can_be_suppressed()
	local battery = makeBattery(C.BatteryRole.AAA)
	battery.GroupDiameterM = 609.5
	local ctx = makeContext(self, battery)

	lu.assertTrue(CrewSuppressionService.processDamage(ctx, 101))
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.SUPPRESSED)
end

function TestCrewSuppressionService:test_group_at_diameter_limit_cannot_be_suppressed()
	local battery = makeBattery(C.BatteryRole.AAA)
	battery.GroupDiameterM = 609.6
	local ctx = makeContext(self, battery)

	lu.assertFalse(CrewSuppressionService.processDamage(ctx, 101))
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.CLEAR)
	lu.assertEquals(#self.scheduled, 0)
end

function TestCrewSuppressionService:test_group_without_diameter_cannot_be_suppressed()
	local battery = makeBattery(C.BatteryRole.AAA)
	battery.GroupDiameterM = nil
	local ctx = makeContext(self, battery)

	lu.assertFalse(CrewSuppressionService.processDamage(ctx, 101))
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.CLEAR)
	lu.assertEquals(#self.scheduled, 0)
end

function TestCrewSuppressionService:test_damage_to_non_suppressible_group_member_is_ignored()
	local battery = makeBattery(C.BatteryRole.AAA)
	battery.Units[1].Roles = { C.BatteryUnitRole.OTHER }
	local ctx = makeContext(self, battery)

	lu.assertFalse(CrewSuppressionService.processDamage(ctx, 101))
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.CLEAR)
	lu.assertEquals(#self.scheduled, 0)
end

function TestCrewSuppressionService:test_damage_suppresses_only_the_affected_group()
	local affected = makeBattery(C.BatteryRole.AAA)
	local unrelated = makeBattery(C.BatteryRole.AAA)
	unrelated.BatteryId = "battery-2"
	unrelated.GroupId = 20
	unrelated.GroupName = "red.unrelated-defense"
	unrelated.Units[1].UnitId = 201
	unrelated.Units[1].UnitName = "gunner-2"
	local ctx = makeContext(self, affected)
	ctx.batteryRepository:add(unrelated)

	lu.assertTrue(CrewSuppressionService.processDamage(ctx, 101))
	lu.assertEquals(affected.CrewSuppressionState, C.CrewSuppressionState.SUPPRESSED)
	lu.assertEquals(unrelated.CrewSuppressionState, C.CrewSuppressionState.CLEAR)
end

function TestCrewSuppressionService:test_initial_damage_is_consumed_once()
	local battery = makeBattery(C.BatteryRole.AAA)
	battery.Units[1].LastKnownLife = 60
	battery.Units[1].InitialDamagePending = true
	local ctx = makeContext(self, battery)

	lu.assertTrue(CrewSuppressionService.applyInitialDamage(ctx, battery))
	lu.assertFalse(CrewSuppressionService.applyInitialDamage(ctx, battery))
	lu.assertFalse(battery.Units[1].InitialDamagePending)
	lu.assertEquals(#self.scheduled, 1)
end

function TestCrewSuppressionService:test_initial_damage_without_pending_marker_does_not_record_drop()
	local battery = makeBattery(C.BatteryRole.AAA)
	battery.GroupDiameterM = nil
	local ctx = makeContext(self, battery)

	lu.assertFalse(CrewSuppressionService.applyInitialDamage(ctx, battery))
	lu.assertEquals(self.droppedReasons, {})
end

function TestCrewSuppressionService:test_ineligible_initial_damage_is_dropped_once()
	local battery = makeBattery(C.BatteryRole.AAA)
	battery.GroupDiameterM = nil
	battery.Units[1].InitialDamagePending = true
	local ctx = makeContext(self, battery)

	lu.assertFalse(CrewSuppressionService.applyInitialDamage(ctx, battery))
	lu.assertFalse(CrewSuppressionService.applyInitialDamage(ctx, battery))
	lu.assertFalse(battery.Units[1].InitialDamagePending)
	lu.assertEquals(self.droppedReasons, { C.CrewSuppressionDropReason.GROUP_DIAMETER_UNAVAILABLE })
end

function TestCrewSuppressionService:test_repeated_suppression_never_shortens_deadline()
	local battery = makeBattery(C.BatteryRole.AAA)
	local ctx = makeContext(self, battery)

	CrewSuppressionService.apply(ctx, battery, C.CrewSuppressionCause.DAMAGE, 120)
	local firstTimerId = battery.CrewSuppressionTimerId
	self.now = 150
	ctx.now = self.now
	CrewSuppressionService.apply(ctx, battery, C.CrewSuppressionCause.DAMAGE, 30)
	lu.assertEquals(battery.CrewSuppressionUntil, 220)
	lu.assertEquals(battery.CrewSuppressionTimerId, firstTimerId)

	CrewSuppressionService.apply(ctx, battery, C.CrewSuppressionCause.DAMAGE, 120)
	lu.assertEquals(battery.CrewSuppressionUntil, 270)
	lu.assertEquals(battery.CrewSuppressionTimerId, firstTimerId)
	lu.assertEquals(#self.cancelled, 0)

	self.now = 220
	self.scheduled[1].callback()
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.SUPPRESSED)
	lu.assertEquals(battery.CrewSuppressionUntil, 270)
	lu.assertEquals(self.scheduled[#self.scheduled].delay, 50)

	self.now = 270
	self.scheduled[#self.scheduled].callback()
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.CLEAR)
end

function TestCrewSuppressionService:test_recovery_stays_cold_without_restoring_aaa_response()
	local battery = makeBattery(C.BatteryRole.AAA)
	battery.CurrentTargetTrackId = "track-1"
	local ctx = makeContext(self, battery)
	CrewSuppressionService.apply(ctx, battery, C.CrewSuppressionCause.DAMAGE, 120)

	self.now = 220
	self.scheduled[1].callback()

	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.CLEAR)
	lu.assertNil(battery.CrewSuppressionUntil)
	lu.assertNil(battery.CrewSuppressionTimerId)
	lu.assertEquals(battery.ActivationState, C.ActivationState.STATE_COLD)
	lu.assertNil(battery.CurrentTargetTrackId)
	lu.assertEquals(battery.Aaa.ResponseState, C.Aaa.ResponseState.IDLE)
end

function TestCrewSuppressionService:test_manpad_pending_wake_is_cancelled_and_recovers_alert()
	local battery = makeBattery(C.BatteryRole.MANPAD)
	local ctx = makeContext(self, battery)

	CrewSuppressionService.apply(ctx, battery, C.CrewSuppressionCause.DAMAGE, 120)

	lu.assertEquals(self.cancelled[1], "wake-timer")
	lu.assertNil(battery.Manpad.WakeTimerId)
	lu.assertEquals(battery.Manpad.SleepWakeState, C.Manpad.SleepWakeState.ALERT)
	lu.assertEquals(battery.ActivationState, C.ActivationState.STATE_COLD)

	self.now = 220
	self.scheduled[1].callback()
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.CLEAR)
	lu.assertEquals(battery.Manpad.SleepWakeState, C.Manpad.SleepWakeState.ALERT)
	lu.assertEquals(battery.Manpad.WakeReason, C.Manpad.WakeReason.RECOVERY)
end

function TestCrewSuppressionService:test_manpad_recoversFromMissingControllerAndReentersHotLifecycle()
	local battery = makeBattery(C.BatteryRole.MANPAD)
	battery.Position = { x = 0, y = 0, z = 0 }
	battery.EngagementRangeMax = 5000
	battery.Manpad.UnitHeadings = { { hx = 1, hz = 0 } }
	battery.Manpad.UnitHeadingCount = 1
	local ctx = makeContext(self, battery)
	GetGroupController = function()
		return nil
	end

	CrewSuppressionService.apply(ctx, battery, C.CrewSuppressionCause.DAMAGE, 120)

	lu.assertEquals(battery.ActivationState, C.ActivationState.INITIALIZING)
	self.now = 220
	self.scheduled[1].callback()
	lu.assertEquals(battery.Manpad.SleepWakeState, C.Manpad.SleepWakeState.ALERT)
	GetGroupController = function()
		return {}
	end
	local track = {
		TrackId = "recovery-track",
		AssessedAircraftType = C.AssessedAircraftType.FIXED_WING,
		LifecycleState = C.TrackLifecycleState.ACTIVE,
		Position = { x = 1000, y = 0, z = 0 },
	}

	Medusa.Services.ManpadService.evaluate({
		manpadStore = ctx.batteryRepository:manpads(),
		trackStore = {
			get = function(_, trackId)
				return trackId == track.TrackId and track or nil
			end,
		},
		geoGrid = {
			queryRadius = function()
				return { TrackIds = { [track.TrackId] = true } }
			end,
		},
		now = self.now,
		posture = C.Posture.NORMAL,
		doctrine = {
			MANPAD = {
				AlertnessDecaySec = 14400,
				FieldRadioRangeM = 0,
				AudioRangeM = C.Manpad.AUDIO_RANGE_MAX_M,
			},
		},
	})

	lu.assertEquals(battery.ActivationState, C.ActivationState.STATE_HOT)
	lu.assertEquals(battery.Manpad.SleepWakeState, C.Manpad.SleepWakeState.HOT)
end

function TestCrewSuppressionService:test_stop_cancels_owned_timer_and_resume_replaces_it()
	local battery = makeBattery(C.BatteryRole.AAA)
	local ctx = makeContext(self, battery)
	CrewSuppressionService.apply(ctx, battery, C.CrewSuppressionCause.DAMAGE, 120)
	local stoppedTimerId = battery.CrewSuppressionTimerId
	local stoppedCallback = self.scheduled[#self.scheduled].callback

	CrewSuppressionService.stop(ctx)
	lu.assertEquals(self.cancelled[#self.cancelled], stoppedTimerId)
	lu.assertNil(battery.CrewSuppressionTimerId)
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.SUPPRESSED)

	self.now = 150
	CrewSuppressionService.resume(ctx)
	local resumedTimerId = battery.CrewSuppressionTimerId
	lu.assertNotNil(resumedTimerId)
	lu.assertEquals(self.scheduled[#self.scheduled].delay, 70)
	stoppedCallback()
	lu.assertEquals(battery.CrewSuppressionTimerId, resumedTimerId)
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.SUPPRESSED)

	self.now = 220
	self.scheduled[#self.scheduled].callback()
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.CLEAR)
end

function TestCrewSuppressionService:test_recovery_timer_failure_does_not_leave_permanent_suppression()
	local battery = makeBattery(C.BatteryRole.AAA)
	local ctx = makeContext(self, battery)
	ScheduleOnce = function()
		return nil
	end

	lu.assertFalse(CrewSuppressionService.apply(ctx, battery, C.CrewSuppressionCause.DAMAGE, 120))
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.CLEAR)
	lu.assertNil(battery.CrewSuppressionUntil)
end

function TestCrewSuppressionService:test_recovery_reschedule_failure_does_not_leave_permanent_suppression()
	local battery = makeBattery(C.BatteryRole.AAA)
	local ctx = makeContext(self, battery)
	CrewSuppressionService.apply(ctx, battery, C.CrewSuppressionCause.DAMAGE, 120)
	self.now = 150
	ctx.now = self.now
	CrewSuppressionService.apply(ctx, battery, C.CrewSuppressionCause.DAMAGE, 120)
	ScheduleOnce = function()
		return nil
	end

	self.now = 220
	self.scheduled[1].callback()

	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.CLEAR)
	lu.assertNil(battery.CrewSuppressionUntil)
end

function TestCrewSuppressionService:test_recovery_callback_contains_repository_failure_and_clears_suppression()
	local battery = makeBattery(C.BatteryRole.AAA)
	local ctx = makeContext(self, battery)
	CrewSuppressionService.apply(ctx, battery, C.CrewSuppressionCause.DAMAGE, 120)
	ctx.batteryRepository.get = function()
		error("repository unavailable")
	end
	self.now = 220

	local ok = pcall(self.scheduled[1].callback)

	lu.assertTrue(ok)
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.CLEAR)
	lu.assertNil(battery.CrewSuppressionTimerId)
end

function TestCrewSuppressionService:test_explosive_radius_uses_cube_root_mass_scaling_and_maximum()
	local policy = {
		ExplosiveRadiusScaleM = 10,
		ExplosiveRadiusMaxM = 50,
		ExplosiveEffectiveness = 1,
	}

	lu.assertAlmostEquals(CrewSuppressionService.explosiveRadius(policy, 1), 10, 0.0001)
	lu.assertAlmostEquals(CrewSuppressionService.explosiveRadius(policy, 8), 20, 0.0001)
	lu.assertAlmostEquals(CrewSuppressionService.explosiveRadius(policy, 1000), 50, 0.0001)
	lu.assertNil(CrewSuppressionService.explosiveRadius(policy, 0))
end

function TestCrewSuppressionService:test_explosive_probability_never_increases_with_distance()
	local policy = { ExplosiveEffectiveness = 0.8 }

	local near = CrewSuppressionService.explosiveProbability(policy, 20, 2)
	local middle = CrewSuppressionService.explosiveProbability(policy, 20, 10)
	local far = CrewSuppressionService.explosiveProbability(policy, 20, 19)

	lu.assertTrue(near >= middle)
	lu.assertTrue(middle >= far)
	lu.assertEquals(CrewSuppressionService.explosiveProbability(policy, 20, 20), 0)
end

function TestCrewSuppressionService:test_defender_skill_levels_reduce_multiplier_and_damage_duration()
	local policy = {
		DefaultCrewSkill = C.CrewSkill.AVERAGE,
		SkillResistancePerLevel = 0.1,
	}
	lu.assertEquals(CrewSuppressionService.crewSkillMultiplier(policy, { CrewSkill = C.CrewSkill.AVERAGE }), 1)
	lu.assertEquals(CrewSuppressionService.crewSkillMultiplier(policy, { CrewSkill = C.CrewSkill.GOOD }), 0.9)
	lu.assertEquals(CrewSuppressionService.crewSkillMultiplier(policy, { CrewSkill = C.CrewSkill.HIGH }), 0.8)
	lu.assertEquals(CrewSuppressionService.crewSkillMultiplier(policy, { CrewSkill = C.CrewSkill.EXCELLENT }), 0.7)

	local battery = makeBattery(C.BatteryRole.AAA)
	battery.Units[1].CrewSkill = C.CrewSkill.EXCELLENT
	local ctx = makeContext(self, battery)
	local randomCalls = 0
	ctx.random = function()
		randomCalls = randomCalls + 1
		return 1
	end

	lu.assertTrue(CrewSuppressionService.processDamage(ctx, 101))
	lu.assertEquals(randomCalls, 1)
	lu.assertEquals(battery.CrewSuppressionUntil, 184)
end

function TestCrewSuppressionService:test_cannon_terminal_event_uses_defender_skill_and_group_suppression()
	local battery = makeBattery(C.BatteryRole.AAA)
	battery.Units[1].CrewSkill = C.CrewSkill.GOOD
	battery.Units[1].Position = { x = 0, y = 0, z = 0 }
	local ctx = makeContext(self, battery)
	local samples = { 0.44, 1 }
	ctx.random = function()
		return table.remove(samples, 1)
	end
	ctx.suppressibleUnitGeoGrid = Medusa.Services.UnitGeoGrid:new(500)
	ctx.suppressibleUnitGeoGrid:add(101, battery.Units[1].Position)
	local terminalEvent = {
		TerminalEventId = 9,
		Kind = C.CrewSuppressionTerminalKind.CANNON,
		Position = { x = 0, y = 0, z = 0 },
		ObservedAt = self.now,
		Source = C.CrewSuppressionTerminalSource.FORWARD_VECTOR,
	}

	local work = CrewSuppressionService.beginTerminalEvent(ctx, terminalEvent)
	local _, complete, candidates, applications = CrewSuppressionService.continueTerminalEvent(ctx, work, 32, {})

	lu.assertTrue(complete)
	lu.assertEquals(candidates, 1)
	lu.assertEquals(applications, 1)
	lu.assertEquals(battery.CrewSuppressionCause, C.CrewSuppressionCause.CANNON)
	lu.assertEquals(battery.CrewSuppressionUntil, 208)
	lu.assertStrContains(self.infoMessages[1], "cause=CANNON")
end

function TestCrewSuppressionService:test_cannon_debug_reports_estimate_distance_to_nearest_indexed_defender()
	local battery = makeBattery(C.BatteryRole.AAA)
	battery.Units[1].Position = { x = 200, y = 0, z = 0 }
	local ctx = makeContext(self, battery)
	Medusa.Logger:setLevel(C.LogLevel.DEBUG)
	ctx.suppressibleUnitGeoGrid = Medusa.Services.UnitGeoGrid:new(500)
	ctx.suppressibleUnitGeoGrid:add(101, battery.Units[1].Position)
	local terminalEvent = {
		TerminalEventId = 10,
		Kind = C.CrewSuppressionTerminalKind.CANNON,
		Position = { x = 0, y = 0, z = 0 },
		ObservedAt = self.now,
		Source = C.CrewSuppressionTerminalSource.FORWARD_VECTOR,
	}

	local work = CrewSuppressionService.beginTerminalEvent(ctx, terminalEvent)
	local _, complete, candidates, applications = CrewSuppressionService.continueTerminalEvent(ctx, work, 32, {})

	lu.assertTrue(complete)
	lu.assertEquals(candidates, 0)
	lu.assertEquals(applications, 0)
	lu.assertStrContains(self.infoMessages[#self.infoMessages], "nearestIndexedUnitDistance=200.0m")
end

function TestCrewSuppressionService:test_initial_damage_uses_longest_member_adjusted_duration_once()
	local battery = makeBattery(C.BatteryRole.AAA)
	battery.Units[1].CrewSkill = C.CrewSkill.EXCELLENT
	battery.Units[1].InitialDamagePending = true
	battery.Units[2] = Battery.newUnit({
		UnitId = 102,
		UnitName = "gunner-2",
		Roles = { C.BatteryUnitRole.AAA },
		CrewSkill = C.CrewSkill.AVERAGE,
		InitialDamagePending = true,
	})
	local ctx = makeContext(self, battery)
	ctx.random = function()
		return 1
	end

	lu.assertTrue(CrewSuppressionService.applyInitialDamage(ctx, battery))
	lu.assertEquals(battery.CrewSuppressionUntil, 220)
	lu.assertFalse(battery.Units[1].InitialDamagePending)
	lu.assertFalse(battery.Units[2].InitialDamagePending)
end

function TestCrewSuppressionService:test_explosive_impact_uses_exact_member_distance_and_suppresses_group()
	local battery = makeBattery(C.BatteryRole.AAA)
	battery.Units[1].Position = { x = 3, y = 0, z = 0 }
	local ctx = makeContext(self, battery)
	ctx.random = function()
		return 0.5
	end
	ctx.suppressibleUnitGeoGrid = Medusa.Services.UnitGeoGrid:new(500)
	ctx.suppressibleUnitGeoGrid:add(101, battery.Units[1].Position)
	local impact = {
		TerminalEventId = 7,
		Kind = C.CrewSuppressionTerminalKind.EXPLOSIVE,
		Position = { x = 0, y = 0, z = 0 },
		EffectiveExplosiveMassKg = 1,
		ObservedAt = self.now,
		Source = C.CrewSuppressionTerminalSource.HIT,
	}

	local work = CrewSuppressionService.beginTerminalEvent(ctx, impact)
	local visited, complete, candidates, applications = CrewSuppressionService.continueTerminalEvent(ctx, work, 32, {})

	lu.assertEquals(visited, 1)
	lu.assertTrue(complete)
	lu.assertEquals(candidates, 1)
	lu.assertEquals(applications, 1)
	lu.assertEquals(battery.CrewSuppressionCause, C.CrewSuppressionCause.EXPLOSIVE)
	lu.assertEquals(battery.CrewSuppressionUntil, 175)
	lu.assertEquals(battery.LastTerminalEventId, 7)
	lu.assertEquals(battery.Units[1].LastTerminalEventId, 7)
end

function TestCrewSuppressionService:test_explosive_impact_rejects_member_outside_exact_three_dimensional_radius()
	local battery = makeBattery(C.BatteryRole.MANPAD)
	battery.Units[1].Position = { x = 0, y = 11, z = 0 }
	local ctx = makeContext(self, battery)
	ctx.random = function()
		return 0
	end
	ctx.suppressibleUnitGeoGrid = Medusa.Services.UnitGeoGrid:new(500)
	ctx.suppressibleUnitGeoGrid:add(101, battery.Units[1].Position)
	local impact = {
		TerminalEventId = 8,
		Kind = C.CrewSuppressionTerminalKind.EXPLOSIVE,
		Position = { x = 0, y = 0, z = 0 },
		EffectiveExplosiveMassKg = 1,
		ObservedAt = self.now,
		Source = C.CrewSuppressionTerminalSource.TERRAIN,
	}

	local work = CrewSuppressionService.beginTerminalEvent(ctx, impact)
	local _, complete, candidates, applications = CrewSuppressionService.continueTerminalEvent(ctx, work, 32, {})

	lu.assertTrue(complete)
	lu.assertEquals(candidates, 1)
	lu.assertEquals(applications, 0)
	lu.assertEquals(battery.CrewSuppressionState, C.CrewSuppressionState.CLEAR)
end
