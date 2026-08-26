require("_header")

--[[
            ██╗      ██████╗  ██████╗  ██████╗ ███████╗██████╗
            ██║     ██╔═══██╗██╔════╝ ██╔════╝ ██╔════╝██╔══██╗
            ██║     ██║   ██║██║  ███╗██║  ███╗█████╗  ██████╔╝
            ██║     ██║   ██║██║   ██║██║   ██║██╔══╝  ██╔══██╗
            ███████╗╚██████╔╝╚██████╔╝╚██████╔╝███████╗██║  ██║
            ╚══════╝ ╚═════╝  ╚═════╝  ╚═════╝ ╚══════╝╚═╝  ╚═╝

    What this module does
    - Filters log messages by severity level (TRACE, DEBUG, INFO, ERROR).
    - Writes output to the DCS log via env.info/env.error and optionally to the screen.
    - Creates namespaced child loggers so each module's output is labeled.

    How others use it
    - Every module calls Logger:ns("Name") at load time to get a prefixed logger instance.
    - Config sets the active log level and screen output flag during initialization.
--]]

Medusa.Logger = {}

Medusa.Logger._level = "INFO"
Medusa.Logger._initialized = false

function Medusa.Logger:initialize(config)
	if self._initialized then
		return
	end
	local desired = "INFO"
	if config and config.getLogLevel then
		desired = tostring(config:getLogLevel()):upper()
	end
	self:setLevel(desired)
	self._initialized = true
end

local LEVEL_RANK = {
	NONE = 0,
	ERROR = 1,
	INFO = 2,
	DEBUG = 3,
	TRACE = 4,
}

local DCS_EVENT_FIELD_LIMIT = 32
local DCS_EVENT_VALUE_LIMIT = 160

--- Formats at most 32 top-level DCS event fields without traversing object handles.
local function formatDcsEvent(event)
	if type(event) ~= "table" then
		return tostring(event)
	end
	local fields = {}
	local truncated = false
	for key, value in pairs(event) do
		if #fields >= DCS_EVENT_FIELD_LIMIT then
			truncated = true
			break
		end
		local keyOk, keyText = pcall(tostring, key)
		keyText = keyOk and keyText or "<unprintable-key>"
		local valueOk, valueText = pcall(tostring, value)
		valueText = valueOk and valueText or "<unprintable-value>"
		valueText = string.gsub(valueText, "[\r\n]", " ")
		if #valueText > DCS_EVENT_VALUE_LIMIT then
			valueText = string.sub(valueText, 1, DCS_EVENT_VALUE_LIMIT) .. "..."
		end
		if type(value) == "string" then
			valueText = string.format("%q", valueText)
		end
		fields[#fields + 1] = string.format("%s=%s<%s>", keyText, valueText, type(value))
	end
	table.sort(fields)
	if truncated then
		fields[#fields + 1] = "..."
	end
	return "{" .. table.concat(fields, ", ") .. "}"
end

--- Returns the event type and bounded raw fields for one DCS diagnostic.
local function dcsEventMessage(eventName, event)
	return string.format("raw DCS event %s: %s", tostring(eventName), formatDcsEvent(event))
end

function Medusa.Logger:setLevel(levelName)
	local name = tostring(levelName):upper()
	if LEVEL_RANK[name] then
		self._level = name
	end
end

function Medusa.Logger:getLevel()
	return self._level
end

--- Sends one diagnostic to the DCS logger without allowing sink failure to escape.
local function emit(level, msg)
	local sink = level == "ERROR" and env and env.error or env and env.info
	if type(sink) == "function" then
		pcall(sink, msg)
	end
end

local function is_enabled(current, level)
	local currentRank = LEVEL_RANK[current] or 0
	local levelRank = LEVEL_RANK[level] or 0
	return levelRank <= currentRank
end

function Medusa.Logger:trace(msg)
	if is_enabled(self._level, "TRACE") then
		emit("TRACE", msg)
	end
end

--- Emits eventName and the bounded raw event fields only when TRACE logging is active.
function Medusa.Logger:traceDcsEvent(eventName, event)
	if is_enabled(self._level, "TRACE") then
		emit("TRACE", dcsEventMessage(eventName, event))
	end
end

function Medusa.Logger:debug(msg)
	if is_enabled(self._level, "DEBUG") then
		emit("DEBUG", msg)
	end
end

function Medusa.Logger:info(msg)
	if is_enabled(self._level, "INFO") then
		emit("INFO", msg)
	end
end

function Medusa.Logger:error(msg)
	if is_enabled(self._level, "ERROR") then
		emit("ERROR", msg)
	end
end

local function prefixed(namespace, level, msg)
	return string.format("[ Medusa | %s | %s ] %s", level, tostring(namespace), msg)
end

function Medusa.Logger:ns(namespace)
	local base = self
	return {
		trace = function(_, msg)
			if is_enabled(base._level, "TRACE") then
				emit("TRACE", prefixed(namespace, "TRACE", msg))
			end
		end,
		traceDcsEvent = function(_, eventName, event)
			if is_enabled(base._level, "TRACE") then
				emit("TRACE", prefixed(namespace, "TRACE", dcsEventMessage(eventName, event)))
			end
		end,
		debug = function(_, msg)
			if is_enabled(base._level, "DEBUG") then
				emit("DEBUG", prefixed(namespace, "DEBUG", msg))
			end
		end,
		info = function(_, msg)
			if is_enabled(base._level, "INFO") then
				emit("INFO", prefixed(namespace, "INFO", msg))
			end
		end,
		error = function(_, msg)
			if is_enabled(base._level, "ERROR") then
				emit("ERROR", prefixed(namespace, "ERROR", msg))
			end
		end,
	}
end
