local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("core.Logger")
require("services.Services")
require("services.ManpadService")
require("services.AaaService")

local C = Medusa.Constants

TestStateTransitionLogging = {}

function TestStateTransitionLogging:setUp()
	self.originalInfo = env.info
	self.originalLevel = Medusa.Logger:getLevel()
	self.messages = {}
	env.info = function(message)
		self.messages[#self.messages + 1] = message
	end
	Medusa.Logger:setLevel("INFO")
end

function TestStateTransitionLogging:tearDown()
	env.info = self.originalInfo
	Medusa.Logger:setLevel(self.originalLevel)
end

function TestStateTransitionLogging:test_actual_aaa_and_manpad_transitions_log_once_at_info()
	local manpad = {
		GroupName = "red.manpad",
		Manpad = {
			SleepWakeState = C.Manpad.SleepWakeState.HOT,
			WakeReason = C.Manpad.WakeReason.NONE,
		},
	}
	local aaa = {
		BatteryId = "aaa-1",
		GroupName = "red.aaa",
		Role = C.BatteryRole.AAA,
		Aaa = { ResponseState = C.Aaa.ResponseState.ALERT },
	}
	local aaaContext = { barrageState = { participants = {} } }

	lu.assertTrue(Medusa.Services.ManpadService.suppressBattery(manpad))
	lu.assertTrue(Medusa.Services.ManpadService.suppressBattery(manpad))
	lu.assertTrue(Medusa.Services.AaaService.suppressBattery(aaaContext, aaa))
	lu.assertTrue(Medusa.Services.AaaService.suppressBattery(aaaContext, aaa))

	lu.assertEquals(#self.messages, 2)
	lu.assertStrContains(self.messages[1], "[ Medusa | INFO | ManpadService ] MANPAD red.manpad state HOT -> ALERT reason=crew suppression")
	lu.assertStrContains(self.messages[2], "[ Medusa | INFO | AaaService ] AAA red.aaa state ALERT -> IDLE reason=crew suppression")
end
