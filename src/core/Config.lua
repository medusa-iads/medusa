require("_header")
require("entities.Entities")
require("entities.Doctrine")

--[[
             ██████╗ ██████╗ ███╗   ██╗███████╗██╗ ██████╗
            ██╔════╝██╔═══██╗████╗  ██║██╔════╝██║██╔════╝
            ██║     ██║   ██║██╔██╗ ██║█████╗  ██║██║  ███╗
            ██║     ██║   ██║██║╚██╗██║██╔══╝  ██║██║   ██║
            ╚██████╗╚██████╔╝██║ ╚████║██║     ██║╚██████╔╝
             ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝     ╚═╝ ╚═════╝

    What this module does
    - Reads the MEDUSA_CONFIG global set by mission makers and merges it with built-in defaults.
    - Resolves coalition names to numeric IDs and builds the list of network definitions.
    - Provides typed accessors for logging, doctrine, track memory, and other settings.

    How others use it
    - IadsNetwork reads network definitions and doctrine during initialization.
    - Logger reads the configured log level and screen output flag at startup.
--]]

Medusa.Config = {}

local CONFIG_SCHEMA = {
	{ name = "LogLevel", type = "enum", default = "INFO", enum = "LogLevel" },
	{ name = "TrackMemorySec", type = "number", default = 30, min = 0, max = 86400 },
	{ name = "VelocityWindowSec", type = "number", default = 60, min = 1, max = 600 },
	{ name = "ChunkBudgetTracks", type = "number", default = 20, min = 1, max = 200 },
	{ name = "ChunkBudgetHarm", type = "number", default = 15, min = 1, max = 200 },
	{ name = "ChunkBudgetBatteries", type = "number", default = 20, min = 1, max = 200 },
	{ name = "PrometheusEnabled", type = "boolean", default = false },
	{ name = "PrometheusExtendEnabled", type = "boolean", default = false },
	{ name = "AllowDynamicProbing", type = "boolean", default = false },
}

local function validateConfigField(s, raw, logger)
	if s.type == "enum" then
		local enumTable = Medusa.Constants[s.enum]
		if raw ~= nil and (not enumTable or not enumTable[raw]) then
			local valid = {}
			if enumTable then
				for k in pairs(enumTable) do
					valid[#valid + 1] = k
				end
			end
			logger:error(
				string.format(
					"invalid config '%s' value '%s' (valid: %s), using '%s'",
					s.name,
					tostring(raw),
					table.concat(valid, ", "),
					tostring(s.default)
				)
			)
			raw = nil
		end
		return raw or s.default
	elseif s.type == "number" then
		local v = tonumber(raw) or s.default
		if v and s.min and v < s.min then
			v = s.min
		end
		if v and s.max and v > s.max then
			v = s.max
		end
		return v
	elseif s.type == "boolean" then
		if raw ~= nil then
			return raw
		end
		return s.default
	else
		return raw or s.default
	end
end

function Medusa.Config:initialize()
	if self.Current then
		return self.Current
	end

	self._logger = Medusa.Logger:ns("Config")

	-- selene: allow(undefined_variable)
	local overrides = (type(MEDUSA_CONFIG) == "table") and MEDUSA_CONFIG or {}

	local DEFAULT_ROLES = { HQ = "hq", GCI = "gci", EWR = "ewr", AWACS = "awacs" }
	local DEFAULT_NETWORKS = {
		{
			name = "DEFAULT",
			coalition = (coalition and coalition.side and coalition.side.RED) or 1,
			prefix = "iads",
		},
	}

	local runningConfig = {
		Roles = {
			HQ = (overrides.Roles and overrides.Roles.HQ) or DEFAULT_ROLES.HQ,
			GCI = (overrides.Roles and overrides.Roles.GCI) or DEFAULT_ROLES.GCI,
			EWR = (overrides.Roles and overrides.Roles.EWR) or DEFAULT_ROLES.EWR,
			AWACS = (overrides.Roles and overrides.Roles.AWACS) or DEFAULT_ROLES.AWACS,
		},
		Networks = (overrides.Networks and type(overrides.Networks) == "table" and overrides.Networks)
			or DEFAULT_NETWORKS,
	}

	for i = 1, #CONFIG_SCHEMA do
		local s = CONFIG_SCHEMA[i]
		runningConfig[s.name] = validateConfigField(s, overrides[s.name], self._logger)
	end

	self.Current = runningConfig
	return self.Current
end

function Medusa.Config:get()
	return self.Current or self:initialize()
end

function Medusa.Config:getRoleTokens()
	local cfg = self:get()
	local tokens = cfg and cfg.Roles
	if type(tokens) ~= "table" then
		return nil
	end
	if type(tokens.HQ) ~= "string" or type(tokens.GCI) ~= "string" or type(tokens.EWR) ~= "string" then
		self._logger:error("invalid Roles; role detection disabled")
		return nil
	end
	return {
		HQ = string.lower(tokens.HQ),
		GCI = string.lower(tokens.GCI),
		EWR = string.lower(tokens.EWR),
		AWACS = string.lower(tokens.AWACS or "awacs"),
	}
end

function Medusa.Config:_resolveCoalition(value)
	if type(value) == "number" then
		return value
	end
	if type(value) == "string" then
		local lower = string.lower(value)
		if lower == "red" then
			return (coalition and coalition.side and coalition.side.RED) or 1
		elseif lower == "blue" then
			return (coalition and coalition.side and coalition.side.BLUE) or 2
		elseif lower == "neutral" or lower == "neutrals" then
			return (coalition and coalition.side and coalition.side.NEUTRAL) or 0
		end
	end
	return nil
end

function Medusa.Config:getNetworks()
	local cfg = self:get()
	local nets = cfg and cfg.Networks or {}
	local out = {}
	for i = 1, #nets do
		local n = nets[i]
		if n and n.name and n.coalition and n.prefix then
			local coalitionId = self:_resolveCoalition(n.coalition)
			out[#out + 1] = {
				id = tostring(n.name),
				coalitionId = coalitionId,
				prefix = tostring(n.prefix),
				doctrine = n.doctrine,
				borderZones = n.borderZones,
			}
		end
	end
	return out
end

function Medusa.Config:getLogLevel()
	local cfg = self:get()
	return (cfg and cfg.LogLevel) or "INFO"
end

function Medusa.Config:getTrackMemoryDurationSec()
	local cfg = self:get()
	return (cfg and cfg.TrackMemorySec) or 30
end

function Medusa.Config:getSmoothedVelocityWindowSec()
	local cfg = self:get()
	return (cfg and cfg.VelocityWindowSec) or 60
end

function Medusa.Config:getDoctrine(doctrineInput)
	-- selene: allow(undefined_variable)
	local base = (type(Medusa_MM_Doctrine) == "table") and Medusa_MM_Doctrine or {}
	local network
	if type(doctrineInput) == "table" then
		network = doctrineInput
	elseif type(doctrineInput) == "string" then
		-- selene: allow(global_usage)
		network = _G[doctrineInput]
	end
	if type(network) ~= "table" then
		return Medusa.Entities.Doctrine.new(base)
	end
	local merged = {}
	for k, v in pairs(base) do
		merged[k] = v
	end
	for k, v in pairs(network) do
		if type(v) == "table" and type(merged[k]) == "table" then
			local nested = {}
			for nk, nv in pairs(merged[k]) do
				nested[nk] = nv
			end
			for nk, nv in pairs(v) do
				nested[nk] = nv
			end
			merged[k] = nested
		else
			merged[k] = v
		end
	end
	return Medusa.Entities.Doctrine.new(merged)
end
