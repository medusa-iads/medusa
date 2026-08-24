local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("services.Services")
require("services.NeighborPropagationService")

TestNeighborPropagationService = {}

function TestNeighborPropagationService:setUp()
	self.originalScheduleOnce = ScheduleOnce
	self.callback = nil
	ScheduleOnce = function(callback)
		self.callback = callback
		return "delivery-1"
	end
end

function TestNeighborPropagationService:tearDown()
	ScheduleOnce = self.originalScheduleOnce
end

function TestNeighborPropagationService:test_delivery_error_is_contained_and_pending_claim_is_cleared()
	local recipient = {
		BatteryId = "recipient-1",
		State = {},
	}
	local store = {
		get = function()
			return recipient
		end,
	}
	lu.assertTrue(Medusa.Services.NeighborPropagationService.scheduleDelivery({
		recipient = recipient,
		recipientStore = store,
		recipientStateField = "State",
		pendingTimerField = "TimerId",
		delayMinSec = 1,
		delayMaxSec = 1,
		message = "message",
		onDelivery = function()
			error("delivery failed")
		end,
	}))

	local ok = pcall(self.callback)

	lu.assertTrue(ok)
	lu.assertNil(recipient.State.TimerId)
end

function TestNeighborPropagationService:test_registration_error_is_contained_without_a_pending_claim()
	local recipient = { BatteryId = "recipient-1", State = {} }
	ScheduleOnce = function()
		error("injected timer registration failure")
	end

	local contained, scheduled = pcall(Medusa.Services.NeighborPropagationService.scheduleDelivery, {
		recipient = recipient,
		recipientStore = {
			get = function()
				return recipient
			end,
		},
		recipientStateField = "State",
		pendingTimerField = "TimerId",
		delayMinSec = 1,
		delayMaxSec = 1,
		message = "message",
		onDelivery = function() end,
	})

	lu.assertTrue(contained)
	lu.assertFalse(scheduled)
	lu.assertIsNil(recipient.State.TimerId)
end
