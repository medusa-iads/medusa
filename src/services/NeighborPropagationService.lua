require("_header")
require("services.Services")
require("core.Logger")

Medusa.Services.NeighborPropagationService = {}

local recipientBuffer = {}
local logger = Medusa.Logger:ns("NeighborPropagationService")

local function clear(values)
	for i = #values, 1, -1 do
		values[i] = nil
	end
end

function Medusa.Services.NeighborPropagationService.findRecipients(geoGrid, repository, center, rangeM, gridType, excludeId)
	clear(recipientBuffer)
	local results = geoGrid:queryRadius(center, rangeM, { gridType })
	local ids = results[gridType .. "Ids"]
	if not ids then
		return recipientBuffer
	end
	for id in pairs(ids) do
		if id ~= excludeId then
			local recipient = repository:get(id)
			if recipient then
				recipientBuffer[#recipientBuffer + 1] = recipient
			end
		end
	end
	return recipientBuffer
end

--- Registers one recipient-owned delayed delivery and reports whether a timer handle was returned.
function Medusa.Services.NeighborPropagationService.scheduleDelivery(delivery)
	local state = delivery.recipient[delivery.recipientStateField]
	if state[delivery.pendingTimerField] then
		return false
	end
	local delay = delivery.delayMinSec
	if delivery.delayMaxSec > delivery.delayMinSec then
		delay = delivery.delayMinSec + math.random() * (delivery.delayMaxSec - delivery.delayMinSec)
	end
	local recipientId = delivery.recipient.BatteryId
	local timerId
	local registered, result = pcall(ScheduleOnce, function()
		local ok, err = pcall(function()
			local recipient = delivery.recipientStore:get(recipientId)
			local currentState = recipient and recipient[delivery.recipientStateField]
			if not currentState or currentState[delivery.pendingTimerField] ~= timerId then
				return
			end
			currentState[delivery.pendingTimerField] = nil
			delivery.onDelivery(recipient, delivery.message, GetTime())
		end)
		if not ok then
			local originalState = delivery.recipient[delivery.recipientStateField]
			if originalState and originalState[delivery.pendingTimerField] == timerId then
				originalState[delivery.pendingTimerField] = nil
			end
			logger:error(string.format("delivery callback failed for %s: %s", tostring(recipientId), tostring(err)))
		end
	end, nil, delay)
	timerId = registered and result or nil
	if not timerId then
		return false
	end
	state[delivery.pendingTimerField] = timerId
	return true
end

--- Cancels one owned neighbor-delivery handle and reports whether one existed.
function Medusa.Services.NeighborPropagationService.cancelDelivery(recipient, recipientStateField, pendingTimerField)
	local state = recipient[recipientStateField]
	local timerId = state and state[pendingTimerField]
	if not timerId then
		return false
	end
	state[pendingTimerField] = nil
	pcall(CancelSchedule, timerId)
	return true
end
