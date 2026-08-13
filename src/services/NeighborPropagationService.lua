require("_header")
require("services.Services")

Medusa.Services.NeighborPropagationService = {}

local recipientBuffer = {}

local function clear(values)
	for i = #values, 1, -1 do
		values[i] = nil
	end
end

function Medusa.Services.NeighborPropagationService.findRecipients(
	geoGrid,
	repository,
	center,
	rangeM,
	gridType,
	excludeId
)
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

function Medusa.Services.NeighborPropagationService.schedule(spec)
	local state = spec.recipient[spec.stateField]
	if state[spec.timerField] then
		return false
	end
	local delay = spec.minDelaySec
	if spec.maxDelaySec > spec.minDelaySec then
		delay = spec.minDelaySec + math.random() * (spec.maxDelaySec - spec.minDelaySec)
	end
	local recipientId = spec.recipient.BatteryId
	local timerId
	timerId = ScheduleOnce(function()
		local recipient = spec.repository:get(recipientId)
		local currentState = recipient and recipient[spec.stateField]
		if not currentState or currentState[spec.timerField] ~= timerId then
			return
		end
		currentState[spec.timerField] = nil
		spec.receive(recipient, spec.payload, GetTime())
	end, nil, delay)
	if not timerId then
		return false
	end
	state[spec.timerField] = timerId
	return true
end

function Medusa.Services.NeighborPropagationService.cancel(recipient, stateField, timerField)
	local state = recipient[stateField]
	local timerId = state and state[timerField]
	if not timerId then
		return false
	end
	CancelSchedule(timerId)
	state[timerField] = nil
	return true
end
