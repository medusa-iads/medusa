local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("core.Logger")
require("entities.Entities")
require("entities.Battery")
require("services.Services")
require("services.BatteryActivationService")

local AS = Medusa.Constants.ActivationState

local MOCK_GLOBALS = {
	"GetGroupController",
	"GetGroup",
	"EnableGroupEmissions",
	"SetControllerOnOff",
	"ControllerSetROE",
	"ControllerSetAlarmState",
	"ControllerSetDisperseOnAttack",
	"SetControllerOption",
	"AI",
}

local function setupMocks(testCase)
	testCase.originalGlobals = {}
	for i = 1, #MOCK_GLOBALS do
		local name = MOCK_GLOBALS[i]
		testCase.originalGlobals[name] = _G[name]
	end
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
end

local function restoreMocks(testCase)
	for name, value in pairs(testCase.originalGlobals) do
		_G[name] = value
	end
end

local function makeBattery(groupName)
	return {
		GroupName = groupName,
		ActivationState = AS.INITIALIZING,
		CurrentTargetTrackId = "track-42",
		LastStateChangeTime = nil,
		StateChangeHoldDownSec = nil,
	}
end

TestGoAutonomous = {}

function TestGoAutonomous:setUp()
	setupMocks(self)
	GetGroupController = function()
		return {}
	end
	SetControllerOnOff = function()
		return true
	end
	ControllerSetROE = function()
		return true
	end
	ControllerSetAlarmState = function()
		return false
	end
	ControllerSetDisperseOnAttack = function()
		return true
	end
end

function TestGoAutonomous:tearDown()
	restoreMocks(self)
end

function TestGoAutonomous:test_partial_erect_failure_clears_assignment_and_retains_medusa_ownership()
	local battery = makeBattery("sa6-1")
	battery.BatteryId = "battery"
	local assigned = Set()
	assigned:add(battery.BatteryId)
	local track = { TrackId = battery.CurrentTargetTrackId, AssignedBatteryIds = assigned }
	local trackStore = {
		get = function(_, trackId)
			return trackId == track.TrackId and track or nil
		end,
	}
	local repositoryRemoved = false
	local gridRemoved = false
	local repository = {
		remove = function()
			repositoryRemoved = true
		end,
	}
	local grid = {
		remove = function()
			gridRemoved = true
		end,
	}

	local result = Medusa.Services.BatteryActivationService.goAutonomous(battery, repository, grid, trackStore)

	lu.assertFalse(result)
	lu.assertEquals(battery.ActivationState, AS.INITIALIZING)
	lu.assertNil(battery.CurrentTargetTrackId)
	lu.assertFalse(track.AssignedBatteryIds:contains(battery.BatteryId))
	lu.assertFalse(repositoryRemoved)
	lu.assertFalse(gridRemoved)
end

-- == TestGoHot ==

TestGoHot = {}

function TestGoHot:setUp()
	setupMocks(self)
	self.controllerOnOffCalls = {}
	self.roeCalls = {}
	self.alarmCalls = {}

	GetGroupController = function(name)
		return { name = name }
	end
	GetGroup = function()
		return {}
	end
	EnableGroupEmissions = function()
		return true
	end
	SetControllerOnOff = function(controller, onOff)
		table.insert(self.controllerOnOffCalls, { controller = controller, onOff = onOff })
		return true
	end
	ControllerSetROE = function(controller, roe)
		table.insert(self.roeCalls, { controller = controller, roe = roe })
		return true
	end
	ControllerSetAlarmState = function(controller, value)
		table.insert(self.alarmCalls, { controller = controller, value = value })
		return true
	end
end

function TestGoHot:tearDown()
	restoreMocks(self)
end

function TestGoHot:test_returnsTrueOnSuccess()
	local battery = makeBattery("sa6-1")
	local result = Medusa.Services.BatteryActivationService.goHot(battery, 100)
	lu.assertTrue(result)
end

function TestGoHot:test_setsActivationStateHot()
	local battery = makeBattery("sa6-1")
	Medusa.Services.BatteryActivationService.goHot(battery, 100)
	lu.assertEquals(battery.ActivationState, AS.STATE_HOT)
end

function TestGoHot:test_turnsControllerOn()
	local battery = makeBattery("sa6-1")
	Medusa.Services.BatteryActivationService.goHot(battery, 100)
	lu.assertEquals(#self.controllerOnOffCalls, 1)
	lu.assertTrue(self.controllerOnOffCalls[1].onOff)
end

function TestGoHot:test_setsRoeOpenFire()
	local battery = makeBattery("sa6-1")
	Medusa.Services.BatteryActivationService.goHot(battery, 100)
	lu.assertEquals(#self.roeCalls, 1)
	lu.assertEquals(self.roeCalls[1].roe, "OPEN_FIRE")
end

function TestGoHot:test_setsAlarmStateRed()
	local battery = makeBattery("sa6-1")
	Medusa.Services.BatteryActivationService.goHot(battery, 100)
	lu.assertEquals(#self.alarmCalls, 1)
	lu.assertEquals(self.alarmCalls[1].value, "RED")
end

function TestGoHot:test_returnsFalseWhenNoController()
	GetGroupController = function(_)
		return nil
	end
	local battery = makeBattery("dead-group")
	local result = Medusa.Services.BatteryActivationService.goHot(battery, 100)
	lu.assertFalse(result)
end

function TestGoHot:test_doesNotMutateStateWhenNoController()
	GetGroupController = function(_)
		return nil
	end
	local battery = makeBattery("dead-group")
	Medusa.Services.BatteryActivationService.goHot(battery, 100)
	lu.assertEquals(battery.ActivationState, AS.INITIALIZING)
end

function TestGoHot:test_required_command_failure_does_not_commit_hot_state()
	ControllerSetROE = function()
		return nil
	end
	local battery = makeBattery("sa6-1")

	local result = Medusa.Services.BatteryActivationService.goHot(battery, 100)

	lu.assertFalse(result)
	lu.assertEquals(battery.ActivationState, AS.INITIALIZING)
	lu.assertNil(battery.LastStateChangeTime)
end

function TestGoHot:test_partial_command_failure_marks_previous_readiness_unknown()
	ControllerSetROE = function()
		return false
	end
	local battery = makeBattery("sa6-1")
	battery.ActivationState = AS.STATE_COLD
	battery.LastStateChangeTime = 50

	local result = Medusa.Services.BatteryActivationService.goHot(battery, 100)

	lu.assertFalse(result)
	lu.assertEquals(battery.ActivationState, AS.INITIALIZING)
	lu.assertNil(battery.LastStateChangeTime)
end

function TestGoHot:test_blockedByHoldDown()
	local battery = makeBattery("sa6-1")
	battery.StateChangeHoldDownSec = 10
	battery.ActivationState = AS.STATE_COLD
	battery.LastStateChangeTime = 95
	local result = Medusa.Services.BatteryActivationService.goHot(battery, 100)
	lu.assertFalse(result)
	lu.assertEquals(battery.ActivationState, AS.STATE_COLD)
end

function TestGoHot:test_allowedAfterHoldDown()
	local battery = makeBattery("sa6-1")
	battery.StateChangeHoldDownSec = 10
	battery.ActivationState = AS.STATE_COLD
	battery.LastStateChangeTime = 85
	local result = Medusa.Services.BatteryActivationService.goHot(battery, 100)
	lu.assertTrue(result)
	lu.assertEquals(battery.ActivationState, AS.STATE_HOT)
end

function TestGoHot:test_alreadyHotReturnsFalse()
	local battery = makeBattery("sa6-1")
	battery.ActivationState = AS.STATE_HOT
	local result = Medusa.Services.BatteryActivationService.goHot(battery, 100)
	lu.assertFalse(result)
end

function TestGoHot:test_setsLastStateChangeTime()
	local battery = makeBattery("sa6-1")
	Medusa.Services.BatteryActivationService.goHot(battery, 100)
	lu.assertEquals(battery.LastStateChangeTime, 100)
end

function TestGoHot:test_crew_suppression_blocks_normal_and_emergency_activation()
	local battery = makeBattery("sa6-1")
	battery.CrewSuppressionState = Medusa.Constants.CrewSuppressionState.SUPPRESSED
	battery.CrewSuppressionUntil = 200

	lu.assertFalse(Medusa.Services.BatteryActivationService.goHot(battery, 100))
	lu.assertFalse(Medusa.Services.BatteryActivationService.forceGoHot(battery, 100))
	lu.assertEquals(battery.ActivationState, AS.INITIALIZING)
	lu.assertEquals(#self.roeCalls, 0)
end

-- == TestGoCold ==

TestGoCold = {}

function TestGoCold:setUp()
	setupMocks(self)
	self.controllerOnOffCalls = {}
	self.roeCalls = {}

	GetGroupController = function(name)
		return { name = name }
	end
	GetGroup = function()
		return {}
	end
	EnableGroupEmissions = function()
		return true
	end
	SetControllerOnOff = function(controller, onOff)
		table.insert(self.controllerOnOffCalls, { controller = controller, onOff = onOff })
		return true
	end
	ControllerSetROE = function(controller, roe)
		table.insert(self.roeCalls, { controller = controller, roe = roe })
		return true
	end
	ControllerSetAlarmState = function()
		return true
	end
end

function TestGoCold:tearDown()
	restoreMocks(self)
end

function TestGoCold:test_returnsTrueOnSuccess()
	local battery = makeBattery("sa6-1")
	local result = Medusa.Services.BatteryActivationService.goCold(battery, 100)
	lu.assertTrue(result)
end

function TestGoCold:test_setsActivationStateCold()
	local battery = makeBattery("sa6-1")
	Medusa.Services.BatteryActivationService.goCold(battery, 100)
	lu.assertEquals(battery.ActivationState, AS.STATE_COLD)
end

function TestGoCold:test_disablesEmissionsInsteadOfControllerOff()
	local battery = makeBattery("sa6-1")
	Medusa.Services.BatteryActivationService.goCold(battery, 100)
	lu.assertEquals(#self.controllerOnOffCalls, 0)
end

function TestGoCold:test_setsRoeWeaponHold()
	local battery = makeBattery("sa6-1")
	Medusa.Services.BatteryActivationService.goCold(battery, 100)
	lu.assertEquals(#self.roeCalls, 1)
	lu.assertEquals(self.roeCalls[1].roe, "WEAPON_HOLD")
end

function TestGoCold:test_clearsCurrentTargetTrackId()
	local battery = makeBattery("sa6-1")
	lu.assertNotNil(battery.CurrentTargetTrackId)
	Medusa.Services.BatteryActivationService.goCold(battery, 100)
	lu.assertNil(battery.CurrentTargetTrackId)
end

function TestGoCold:test_returnsFalseWhenNoController()
	GetGroupController = function(_)
		return nil
	end
	local battery = makeBattery("dead-group")
	local result = Medusa.Services.BatteryActivationService.goCold(battery, 100)
	lu.assertFalse(result)
end

function TestGoCold:test_no_controller_releases_assignment_and_keeps_readiness_unknown()
	GetGroupController = function(_)
		return nil
	end
	local battery = makeBattery("dead-group")
	battery.BatteryId = "battery"
	local assigned = Set()
	assigned:add(battery.BatteryId)
	local track = { TrackId = battery.CurrentTargetTrackId, AssignedBatteryIds = assigned }
	local trackStore = {
		get = function(_, trackId)
			return trackId == track.TrackId and track or nil
		end,
	}
	Medusa.Services.BatteryActivationService.goCold(battery, 100, trackStore)
	lu.assertEquals(battery.ActivationState, AS.INITIALIZING)
	lu.assertNil(battery.CurrentTargetTrackId)
	lu.assertFalse(track.AssignedBatteryIds:contains(battery.BatteryId))
end

function TestGoCold:test_alreadyColdReturnsFalse()
	local battery = makeBattery("sa6-1")
	battery.ActivationState = AS.STATE_COLD
	local result = Medusa.Services.BatteryActivationService.goCold(battery, 100)
	lu.assertFalse(result)
end

-- == TestGoWarm ==

TestGoWarm = {}

function TestGoWarm:setUp()
	setupMocks(self)
	self.controllerOnOffCalls = {}
	self.roeCalls = {}
	self.alarmCalls = {}

	GetGroupController = function(name)
		return { name = name }
	end
	GetGroup = function()
		return {}
	end
	EnableGroupEmissions = function()
		return true
	end
	SetControllerOnOff = function(controller, onOff)
		table.insert(self.controllerOnOffCalls, { controller = controller, onOff = onOff })
		return true
	end
	ControllerSetROE = function(controller, roe)
		table.insert(self.roeCalls, { controller = controller, roe = roe })
		return true
	end
	ControllerSetAlarmState = function(controller, value)
		table.insert(self.alarmCalls, { controller = controller, value = value })
		return true
	end
end

function TestGoWarm:tearDown()
	restoreMocks(self)
end

function TestGoWarm:test_returnsTrueOnSuccess()
	local battery = makeBattery("sa10-1")
	local result = Medusa.Services.BatteryActivationService.goWarm(battery, 100)
	lu.assertTrue(result)
end

function TestGoWarm:test_setsActivationStateWarm()
	local battery = makeBattery("sa10-1")
	Medusa.Services.BatteryActivationService.goWarm(battery, 100)
	lu.assertEquals(battery.ActivationState, AS.STATE_WARM)
end

function TestGoWarm:test_turnsControllerOn()
	local battery = makeBattery("sa10-1")
	Medusa.Services.BatteryActivationService.goWarm(battery, 100)
	lu.assertEquals(#self.controllerOnOffCalls, 1)
	lu.assertTrue(self.controllerOnOffCalls[1].onOff)
end

function TestGoWarm:test_setsRoeWeaponHold()
	local battery = makeBattery("sa10-1")
	Medusa.Services.BatteryActivationService.goWarm(battery, 100)
	lu.assertEquals(#self.roeCalls, 1)
	lu.assertEquals(self.roeCalls[1].roe, "WEAPON_HOLD")
end

function TestGoWarm:test_setsAlarmStateRed()
	local battery = makeBattery("sa10-1")
	Medusa.Services.BatteryActivationService.goWarm(battery, 100)
	lu.assertEquals(#self.alarmCalls, 1)
	lu.assertEquals(self.alarmCalls[1].value, "RED")
end

function TestGoWarm:test_returnsFalseWhenNoController()
	GetGroupController = function(_)
		return nil
	end
	local battery = makeBattery("dead-group")
	local result = Medusa.Services.BatteryActivationService.goWarm(battery, 100)
	lu.assertFalse(result)
end

function TestGoWarm:test_alreadyWarmReturnsFalse()
	local battery = makeBattery("sa10-1")
	battery.ActivationState = AS.STATE_WARM
	local result = Medusa.Services.BatteryActivationService.goWarm(battery, 100)
	lu.assertFalse(result)
end

function TestGoWarm:test_setsLastStateChangeTime()
	local battery = makeBattery("sa10-1")
	Medusa.Services.BatteryActivationService.goWarm(battery, 100)
	lu.assertEquals(battery.LastStateChangeTime, 100)
end

function TestGoWarm:test_crew_suppression_blocks_warm_state()
	local battery = makeBattery("sa10-1")
	battery.CrewSuppressionState = Medusa.Constants.CrewSuppressionState.SUPPRESSED
	battery.CrewSuppressionUntil = 200

	lu.assertFalse(Medusa.Services.BatteryActivationService.goWarm(battery, 100))
	lu.assertEquals(battery.ActivationState, AS.INITIALIZING)
	lu.assertEquals(#self.roeCalls, 0)
end

TestBatteryActivationCommandOrder = {}

function TestBatteryActivationCommandOrder:setUp()
	setupMocks(self)
	self.calls = {}
	AI = nil
	GetGroupController = function()
		return {}
	end
	GetGroup = function()
		return {}
	end
	SetControllerOnOff = function(_, enabled)
		self.calls[#self.calls + 1] = enabled and "ON" or "OFF"
		return true
	end
	ControllerSetROE = function(_, value)
		self.calls[#self.calls + 1] = "ROE:" .. value
		return true
	end
	ControllerSetAlarmState = function(_, value)
		self.calls[#self.calls + 1] = "ALARM:" .. value
		return true
	end
	ControllerSetDisperseOnAttack = function()
		self.calls[#self.calls + 1] = "DISPERSE"
		return true
	end
	EnableGroupEmissions = function(_, enabled)
		self.calls[#self.calls + 1] = enabled and "EMIT:ON" or "EMIT:OFF"
		return true
	end
end

function TestBatteryActivationCommandOrder:tearDown()
	restoreMocks(self)
end

function TestBatteryActivationCommandOrder:test_each_transition_issues_its_required_commands_in_order()
	local BAS = Medusa.Services.BatteryActivationService
	local cases = {
		{
			invoke = function()
				return BAS.erectGroup("group")
			end,
			expected = { "ON", "ROE:OPEN_FIRE", "ALARM:RED", "DISPERSE" },
		},
		{
			invoke = function()
				return BAS.goHot(makeBattery("group"), 100)
			end,
			expected = { "ON", "ROE:OPEN_FIRE", "ALARM:RED", "EMIT:ON" },
		},
		{
			invoke = function()
				return BAS.goCold(makeBattery("group"), 100)
			end,
			expected = { "ROE:WEAPON_HOLD", "ALARM:RED", "EMIT:OFF" },
		},
		{
			invoke = function()
				return BAS.goHarmShutdown(makeBattery("group"), 100)
			end,
			expected = { "OFF", "ROE:WEAPON_HOLD", "ALARM:RED", "EMIT:OFF" },
		},
		{
			invoke = function()
				return BAS.goGreen(makeBattery("group"), 100)
			end,
			expected = { "ROE:WEAPON_HOLD", "ALARM:GREEN", "EMIT:OFF" },
		},
		{
			invoke = function()
				return BAS.goWarm(makeBattery("group"), 100)
			end,
			expected = { "ON", "ROE:WEAPON_HOLD", "ALARM:RED", "EMIT:ON" },
		},
		{
			invoke = function()
				return BAS.setSensorState("group", AS.STATE_COLD)
			end,
			expected = { "ROE:WEAPON_HOLD", "ALARM:GREEN", "OFF", "EMIT:OFF" },
		},
	}
	for i = 1, #cases do
		self.calls = {}
		lu.assertTrue(cases[i].invoke())
		lu.assertEquals(self.calls, cases[i].expected)
	end
end

function TestBatteryActivationCommandOrder:test_later_safety_commands_still_run_after_an_earlier_failure()
	SetControllerOnOff = function(_, enabled)
		self.calls[#self.calls + 1] = enabled and "ON" or "OFF"
		return false
	end

	lu.assertFalse(Medusa.Services.BatteryActivationService.goWarm(makeBattery("group"), 100))
	lu.assertEquals(self.calls, { "ON", "ROE:WEAPON_HOLD", "ALARM:RED", "EMIT:ON" })
end
