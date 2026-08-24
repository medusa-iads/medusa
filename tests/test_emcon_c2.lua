local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("entities.Battery")
require("entities.SensorUnit")
require("services.EmconService")
require("services.stores.BatteryStore")
require("services.stores.SensorUnitStore")

TestEmconC2 = {}

local READINESS_GLOBALS = {
	"GetGroupController",
	"GetGroup",
	"EnableGroupEmissions",
	"SetControllerOnOff",
	"ControllerSetROE",
	"ControllerSetAlarmState",
}

function TestEmconC2:setUp()
	self.originalGlobals = {}
	for i = 1, #READINESS_GLOBALS do
		local name = READINESS_GLOBALS[i]
		self.originalGlobals[name] = _G[name]
	end
	self.originalGoWarm = Medusa.Services.BatteryActivationService.goWarm
	self.originalGoCold = Medusa.Services.BatteryActivationService.goCold
	self.originalSetSensorState = Medusa.Services.BatteryActivationService.setSensorState
	Medusa.Services.BatteryActivationService.goWarm = function(battery)
		battery.ActivationState = Medusa.Constants.ActivationState.STATE_WARM
		return true
	end
	Medusa.Services.BatteryActivationService.goCold = function(battery)
		battery.ActivationState = Medusa.Constants.ActivationState.STATE_COLD
		return true
	end
end

function TestEmconC2:tearDown()
	Medusa.Services.BatteryActivationService.goWarm = self.originalGoWarm
	Medusa.Services.BatteryActivationService.goCold = self.originalGoCold
	Medusa.Services.BatteryActivationService.setSensorState = self.originalSetSensorState
	for name, value in pairs(self.originalGlobals) do
		_G[name] = value
	end
end

local function eligibleSam()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "N",
		GroupId = 1,
		GroupName = "sam",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
		Position = { x = 0, y = 0, z = 0 },
		DetectionRangeMax = 10000,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 10,
			UnitName = "sam-radar",
			Roles = { Medusa.Constants.BatteryUnitRole.SEARCH_RADAR },
		}),
	}
	return battery
end

local function ewrSensor()
	return Medusa.Entities.SensorUnit.new({
		NetworkId = "N",
		UnitId = 3,
		UnitName = "sensor-ewr",
		GroupId = 2,
		GroupName = "ewr",
		SensorType = Medusa.Constants.SensorType.EWR,
		Position = { x = 0, y = 0, z = 0 },
	})
end

local function context(sensor)
	local repository = Medusa.Services.BatteryStore:new()
	local battery = eligibleSam()
	repository:batteries():add(battery)
	local sensorStore = Medusa.Services.SensorUnitStore:new()
	if sensor then
		sensorStore:add(sensor)
	end
	return {
		battery = battery,
		ctx = {
			batteryStore = repository:batteries(),
			sensorStore = sensorStore,
			doctrine = { SAMAsEWR = "WHEN_NO_EWR" },
		},
	}
end

function TestEmconC2:test_coordinated_battery_accepts_only_same_partition_tracks()
	local fixture = context(nil)
	fixture.battery.PartitionKey = "partition-a"
	fixture.battery.CoordinationState = Medusa.Constants.CoordinationState.COORDINATED

	lu.assertTrue(Medusa.Entities.Battery.canAcceptTrack(fixture.battery, { PartitionKey = "partition-a" }, {}))
	lu.assertFalse(Medusa.Entities.Battery.canAcceptTrack(fixture.battery, { PartitionKey = "partition-b" }, {}))
end

function TestEmconC2:test_autonomous_degraded_battery_accepts_same_partition_tracks()
	local fixture = context(nil)
	fixture.battery.PartitionKey = "partition-a"
	fixture.battery.CoordinationState = Medusa.Constants.CoordinationState.DEGRADED
	local doctrine = { DegradedMode = Medusa.Constants.NetworkDegradationPolicy.REVERT_TO_AUTONOMOUS }

	lu.assertTrue(Medusa.Entities.Battery.canAcceptTrack(fixture.battery, { PartitionKey = "partition-a" }, doctrine))
end

function TestEmconC2:test_self_defense_degraded_battery_accepts_only_defensive_tracks()
	local fixture = context(nil)
	fixture.battery.PartitionKey = "partition-a"
	fixture.battery.CoordinationState = Medusa.Constants.CoordinationState.DEGRADED
	local doctrine = { DegradedMode = Medusa.Constants.NetworkDegradationPolicy.REVERT_TO_SELF_DEFENSE }
	local track = { PartitionKey = "partition-a" }

	lu.assertFalse(Medusa.Entities.Battery.canAcceptTrack(fixture.battery, track, doctrine))
	track.AssessedAircraftType = Medusa.Constants.AssessedAircraftType.HARM
	lu.assertTrue(Medusa.Entities.Battery.canAcceptTrack(fixture.battery, track, doctrine))
end

function TestEmconC2:test_go_dark_degraded_battery_accepts_no_tracks()
	local fixture = context(nil)
	fixture.battery.PartitionKey = "partition-a"
	fixture.battery.CoordinationState = Medusa.Constants.CoordinationState.DEGRADED
	local doctrine = { DegradedMode = Medusa.Constants.NetworkDegradationPolicy.GO_DARK }
	local track = { PartitionKey = "partition-a" }

	lu.assertFalse(Medusa.Entities.Battery.canAcceptTrack(fixture.battery, track, doctrine))
end

local function applyDegradedPolicy(policy, initialState)
	local fixture = context(nil)
	fixture.battery.CoordinationState = Medusa.Constants.CoordinationState.DEGRADED
	fixture.battery.ActivationState = initialState
	fixture.ctx.doctrine = {
		DegradedMode = policy,
		EMCON = { LR_SAM = Medusa.Constants.EmissionControlPolicy.MINIMIZE },
		SAMAsEWR = "DISABLED",
	}
	fixture.ctx.now = 10
	Medusa.Services.EmconService.applyPolicy(fixture.ctx)
	return fixture.battery.ActivationState
end

function TestEmconC2:test_autonomous_degraded_battery_stays_warm_under_minimize()
	lu.assertEquals(
		applyDegradedPolicy(
			Medusa.Constants.NetworkDegradationPolicy.REVERT_TO_AUTONOMOUS,
			Medusa.Constants.ActivationState.STATE_COLD
		),
		Medusa.Constants.ActivationState.STATE_WARM
	)
end

function TestEmconC2:test_self_defense_degraded_battery_stays_warm_under_minimize()
	lu.assertEquals(
		applyDegradedPolicy(
			Medusa.Constants.NetworkDegradationPolicy.REVERT_TO_SELF_DEFENSE,
			Medusa.Constants.ActivationState.STATE_COLD
		),
		Medusa.Constants.ActivationState.STATE_WARM
	)
end

function TestEmconC2:test_go_dark_degraded_battery_becomes_cold()
	lu.assertEquals(
		applyDegradedPolicy(
			Medusa.Constants.NetworkDegradationPolicy.GO_DARK,
			Medusa.Constants.ActivationState.STATE_WARM
		),
		Medusa.Constants.ActivationState.STATE_COLD
	)
end

function TestEmconC2:test_recent_assignment_release_blocks_minimize_until_hold_down_expires()
	local fixture = context(nil)
	fixture.battery.CoordinationState = Medusa.Constants.CoordinationState.COORDINATED
	fixture.battery.ActivationState = Medusa.Constants.ActivationState.STATE_HOT
	fixture.battery.LastAssignmentChangeTime = 10
	fixture.ctx.doctrine = {
		HoldDownSec = 15,
		EMCON = { LR_SAM = Medusa.Constants.EmissionControlPolicy.MINIMIZE },
		SAMAsEWR = Medusa.Constants.SAMAsEWRPolicy.DISABLED,
	}
	fixture.ctx.now = 10.4

	Medusa.Services.EmconService.applyPolicy(fixture.ctx)
	lu.assertEquals(fixture.battery.ActivationState, Medusa.Constants.ActivationState.STATE_HOT)

	fixture.ctx.now = 25
	Medusa.Services.EmconService.applyPolicy(fixture.ctx)
	lu.assertEquals(fixture.battery.ActivationState, Medusa.Constants.ActivationState.STATE_COLD)
end

function TestEmconC2:test_degraded_readiness_policy_is_independent_of_minimize()
	local battery = eligibleSam()
	battery.CoordinationState = Medusa.Constants.CoordinationState.DEGRADED
	local doctrine = {
		DegradedMode = Medusa.Constants.NetworkDegradationPolicy.REVERT_TO_AUTONOMOUS,
		EMCON = { LR_SAM = Medusa.Constants.EmissionControlPolicy.MINIMIZE },
	}

	lu.assertEquals(
		Medusa.Services.EmconService.getDesiredBatteryState(battery, 1, 1, doctrine, 10),
		Medusa.Constants.ActivationState.STATE_WARM
	)
	doctrine.DegradedMode = Medusa.Constants.NetworkDegradationPolicy.GO_DARK
	lu.assertEquals(
		Medusa.Services.EmconService.getDesiredBatteryState(battery, 1, 1, doctrine, 10),
		Medusa.Constants.ActivationState.STATE_COLD
	)
end

function TestEmconC2:test_failed_readiness_is_retried_on_the_next_policy_pass()
	local fixture = context(nil)
	fixture.battery.CoordinationState = Medusa.Constants.CoordinationState.DEGRADED
	fixture.battery.ActivationState = Medusa.Constants.ActivationState.STATE_COLD
	fixture.ctx.doctrine = {
		DegradedMode = Medusa.Constants.NetworkDegradationPolicy.REVERT_TO_AUTONOMOUS,
		EMCON = { LR_SAM = Medusa.Constants.EmissionControlPolicy.MINIMIZE },
		SAMAsEWR = "DISABLED",
	}
	fixture.ctx.now = 10
	Medusa.Services.BatteryActivationService.goWarm = self.originalGoWarm
	GetGroupController = function()
		return {}
	end
	GetGroup = function()
		return {}
	end
	EnableGroupEmissions = function()
		return true
	end
	SetControllerOnOff = function()
		return true
	end
	local attempts = 0
	ControllerSetROE = function()
		attempts = attempts + 1
		return attempts > 1
	end
	ControllerSetAlarmState = function()
		return true
	end

	Medusa.Services.EmconService.applyPolicy(fixture.ctx)
	lu.assertEquals(fixture.battery.ActivationState, Medusa.Constants.ActivationState.INITIALIZING)
	lu.assertNil(fixture.battery.CurrentTargetTrackId)
	Medusa.Services.EmconService.applyPolicy(fixture.ctx)

	lu.assertEquals(attempts, 2)
	lu.assertEquals(fixture.battery.ActivationState, Medusa.Constants.ActivationState.STATE_WARM)
end

function TestEmconC2:test_replacement_sensor_group_does_not_inherit_prior_emcon_state()
	local sensorStore = Medusa.Services.SensorUnitStore:new()
	local oldSensor = ewrSensor()
	sensorStore:add(oldSensor)
	local attempts = 0
	Medusa.Services.BatteryActivationService.setSensorState = function()
		attempts = attempts + 1
		return attempts ~= 2
	end
	local ctx = {
		batteryStore = Medusa.Services.BatteryStore:new():batteries(),
		sensorStore = sensorStore,
		doctrine = {
			EMCON = { EWR = Medusa.Constants.EmissionControlPolicy.ALWAYS_ON },
			SAMAsEWR = Medusa.Constants.SAMAsEWRPolicy.DISABLED,
		},
		now = 10,
	}

	Medusa.Services.EmconService.applyPolicy(ctx)
	lu.assertEquals(oldSensor.EmconState, Medusa.Constants.ActivationState.STATE_WARM)
	sensorStore:remove(oldSensor.SensorUnitId)
	local replacement = Medusa.Entities.SensorUnit.new({
		NetworkId = "N",
		UnitId = 4,
		UnitName = "sensor-ewr-replacement",
		GroupId = 4,
		GroupName = "ewr",
		SensorType = Medusa.Constants.SensorType.EWR,
	})
	sensorStore:add(replacement)

	Medusa.Services.EmconService.applyPolicy(ctx)
	lu.assertEquals(attempts, 2)
	lu.assertEquals(replacement.EmconState, Medusa.Constants.ActivationState.INITIALIZING)
	lu.assertEquals(replacement.RadarStatus, Medusa.Constants.RadarStatus.DARK)
	Medusa.Services.EmconService.applyPolicy(ctx)

	lu.assertEquals(attempts, 3)
	lu.assertEquals(replacement.EmconState, Medusa.Constants.ActivationState.STATE_WARM)
	lu.assertEquals(replacement.RadarStatus, Medusa.Constants.RadarStatus.ACTIVE)
end
