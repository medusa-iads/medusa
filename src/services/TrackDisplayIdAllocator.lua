require("_header")
require("services.Services")
require("core.Constants")

Medusa.Services.TrackDisplayIdAllocator = {}
Medusa.Services.TrackDisplayIdAllocator.MAX_NUMBER = 4095
Medusa.Services.TrackDisplayIdAllocator._shared = nil

local function newSourceState()
	return {
		nextNumber = 1,
		activeNumbers = {},
		releasedNumbers = {},
		releasedHead = 1,
		releasedTail = 0,
		releasedCount = 0,
	}
end

local function sourcePrefix(sourceType)
	local prefix = Medusa.Constants.TrackSourcePrefix[sourceType]
	if not prefix then
		error(string.format("invalid track source: %s", tostring(sourceType)))
	end
	return prefix
end

local function parseDisplayId(displayId)
	if type(displayId) ~= "string" then
		error(string.format("invalid track display ID: %s", tostring(displayId)))
	end
	local prefix, digits = string.match(displayId, "^([A-Z][A-Z])([0-7][0-7][0-7][0-7])$")
	local number = digits and tonumber(digits, 8) or nil
	if not prefix or not number or number < 1 or number > Medusa.Services.TrackDisplayIdAllocator.MAX_NUMBER then
		error(string.format("invalid track display ID: %s", displayId))
	end
	for sourceType, candidatePrefix in pairs(Medusa.Constants.TrackSourcePrefix) do
		if candidatePrefix == prefix then
			return sourceType, number
		end
	end
	error(string.format("invalid track display ID prefix: %s", prefix))
end

function Medusa.Services.TrackDisplayIdAllocator:new()
	local o = { _statesBySource = {} }
	setmetatable(o, { __index = self })
	return o
end

function Medusa.Services.TrackDisplayIdAllocator.shared()
	local allocator = Medusa.Services.TrackDisplayIdAllocator._shared
	if not allocator then
		allocator = Medusa.Services.TrackDisplayIdAllocator:new()
		Medusa.Services.TrackDisplayIdAllocator._shared = allocator
	end
	return allocator
end

function Medusa.Services.TrackDisplayIdAllocator:_state(sourceType)
	local state = self._statesBySource[sourceType]
	if not state then
		state = newSourceState()
		self._statesBySource[sourceType] = state
	end
	return state
end

function Medusa.Services.TrackDisplayIdAllocator:allocate(sourceType)
	local prefix = sourcePrefix(sourceType)
	local state = self:_state(sourceType)
	local number

	if state.nextNumber <= Medusa.Services.TrackDisplayIdAllocator.MAX_NUMBER then
		number = state.nextNumber
		state.nextNumber = number + 1
	elseif state.releasedCount > 0 then
		number = state.releasedNumbers[state.releasedHead]
		state.releasedNumbers[state.releasedHead] = nil
		state.releasedHead = (state.releasedHead % Medusa.Services.TrackDisplayIdAllocator.MAX_NUMBER) + 1
		state.releasedCount = state.releasedCount - 1
	else
		error(string.format("track display ID pool exhausted for source: %s", sourceType))
	end

	state.activeNumbers[number] = true
	return string.format("%s%04o", prefix, number)
end

function Medusa.Services.TrackDisplayIdAllocator:release(displayId)
	local sourceType, number = parseDisplayId(displayId)
	local state = self:_state(sourceType)
	if not state.activeNumbers[number] then
		return false
	end

	state.activeNumbers[number] = nil
	state.releasedTail = (state.releasedTail % Medusa.Services.TrackDisplayIdAllocator.MAX_NUMBER) + 1
	state.releasedNumbers[state.releasedTail] = number
	state.releasedCount = state.releasedCount + 1
	return true
end
