local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("core.Logger")
require("entities.Entities")
require("entities.Battery")
require("services.Services")
require("services.stores.BatteryStore")
require("services.BatteryActivationService")
require("services.AaaService")
require("services.ManpadService")
require("services.CrewSuppressionService")

local C = Medusa.Constants
local Battery = Medusa.Entities.Battery
local CrewSuppressionService = Medusa.Services.CrewSuppressionService
local MetricsService = Medusa.Services.MetricsService

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
		battery.Aaa.FireTaskActive = true
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
				DamageDurationSec = C.CrewSuppression.DEFAULT_DAMAGE_DURATION_SEC,
				MaxGroupDiameterM = C.CrewSuppression.DEFAULT_MAX_GROUP_DIAMETER_M,
			},
		},
		now = test.now,
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
		"ControllerSetROE",
		"ControllerSetAlarmState",
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
	ControllerSetROE = function(_, value)
		self.roe[#self.roe + 1] = value
	end
	ControllerSetAlarmState = function() end
	GetGroup = function()
		return {}
	end
	EnableGroupEmissions = function() end
	PopControllerTask = function()
		self.popCount = self.popCount + 1
	end
end

function TestCrewSuppressionService:tearDown()
	MetricsService.inc = self.metricsInc
	for name, value in pairs(original) do
		_G[name] = value
	end
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
	lu.assertFalse(battery.Aaa.FireTaskActive)
	lu.assertEquals(self.popCount, 1)
	lu.assertEquals(self.roe[#self.roe], "WEAPON_HOLD")
	lu.assertEquals(self.scheduled[1].delay, 120)
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
