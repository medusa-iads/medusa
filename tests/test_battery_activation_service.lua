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

local function setupMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
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

-- == TestGoHot ==

TestGoHot = {}

function TestGoHot:setUp()
	setupMocks()
	self.controllerOnOffCalls = {}
	self.roeCalls = {}
	self.alarmCalls = {}

	GetGroupController = function(name)
		return { name = name }
	end
	SetControllerOnOff = function(controller, onOff)
		table.insert(self.controllerOnOffCalls, { controller = controller, onOff = onOff })
	end
	ControllerSetROE = function(controller, roe)
		table.insert(self.roeCalls, { controller = controller, roe = roe })
	end
	ControllerSetAlarmState = function(controller, value)
		table.insert(self.alarmCalls, { controller = controller, value = value })
	end
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

-- == TestGoCold ==

TestGoCold = {}

function TestGoCold:setUp()
	setupMocks()
	self.controllerOnOffCalls = {}
	self.roeCalls = {}

	GetGroupController = function(name)
		return { name = name }
	end
	SetControllerOnOff = function(controller, onOff)
		table.insert(self.controllerOnOffCalls, { controller = controller, onOff = onOff })
	end
	ControllerSetROE = function(controller, roe)
		table.insert(self.roeCalls, { controller = controller, roe = roe })
	end
	ControllerSetAlarmState = function() end
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

function TestGoCold:test_doesNotMutateStateWhenNoController()
	GetGroupController = function(_)
		return nil
	end
	local battery = makeBattery("dead-group")
	Medusa.Services.BatteryActivationService.goCold(battery, 100)
	lu.assertEquals(battery.ActivationState, AS.INITIALIZING)
	lu.assertEquals(battery.CurrentTargetTrackId, "track-42")
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
	setupMocks()
	self.controllerOnOffCalls = {}
	self.roeCalls = {}
	self.alarmCalls = {}

	GetGroupController = function(name)
		return { name = name }
	end
	SetControllerOnOff = function(controller, onOff)
		table.insert(self.controllerOnOffCalls, { controller = controller, onOff = onOff })
	end
	ControllerSetROE = function(controller, roe)
		table.insert(self.roeCalls, { controller = controller, roe = roe })
	end
	ControllerSetAlarmState = function(controller, value)
		table.insert(self.alarmCalls, { controller = controller, value = value })
	end
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
