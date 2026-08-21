require("_header")
require("entities.Entities")
require("core.Constants")

--[[
            ██████╗  ██████╗  ██████╗████████╗██████╗ ██╗███╗   ██╗███████╗
            ██╔══██╗██╔═══██╗██╔════╝╚══██╔══╝██╔══██╗██║████╗  ██║██╔════╝
            ██║  ██║██║   ██║██║        ██║   ██████╔╝██║██╔██╗ ██║█████╗
            ██║  ██║██║   ██║██║        ██║   ██╔══██╗██║██║╚██╗██║██╔══╝
            ██████╔╝╚██████╔╝╚██████╗   ██║   ██║  ██║██║██║ ╚████║███████╗
            ╚═════╝  ╚═════╝  ╚═════╝   ╚═╝   ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝╚══════╝

    What this entity does
    - Defines a doctrine configuration table with defaults for every tactical setting.
    - Validates enum fields against Constants, clamps numeric fields, fills missing values from defaults.

    How others use it
    - Config:getDoctrine merges mission-maker overrides with this template to produce the active doctrine.
    - IadsNetwork, TargetAssigner, EmconService, and HarmResponseService read doctrine fields each tick.
--]]

Medusa.Entities.Doctrine = {}

local DOCTRINE_SCHEMA = {
	-- Enum fields
	{ name = "ROE", type = "enum", default = "TIGHT", enum = "ROEState" },
	{ name = "HARMResponse", type = "enum", default = "AUTO_DEFENSE", enum = "HarmResponseStrategy" },
	{
		name = "EngageTactics",
		type = "enum",
		default = "SHOOT_IN_DEPTH",
		enum = "CoordinatedEngagementTactics",
	},
	{ name = "Posture", type = "enum", default = "HOT_WAR", enum = "Posture" },
	{ name = "ShootScoot", type = "enum", default = "NONE", enum = "ShootAndScootPolicy" },
	{ name = "SAMAsEWR", type = "enum", default = "WHEN_NO_EWR", enum = "SAMAsEWRPolicy" },
	{
		name = "DegradedMode",
		type = "enum",
		default = "REVERT_TO_AUTONOMOUS",
		enum = "NetworkDegradationPolicy",
	},
	{
		name = "LaunchAuthority",
		type = "enum",
		default = "LOCAL_AUTONOMY",
		enum = "InterceptorLaunchAuthorityPolicy",
	},
	{ name = "GCIPolicy", type = "enum", default = "CLOSEST_AIRBASE", enum = "GciServicePolicy" },
	-- Clamped numbers
	{ name = "PkFloor", type = "number", default = 0.25, min = 0, max = 1 },
	{ name = "DefendPk", type = "number", default = 0.30, min = 0, max = 1 },
	{ name = "TargetKillRate", type = "number", default = 0.50, min = 0, max = 1 },
	{ name = "HoldDownSec", type = "number", default = 15, min = 0, max = 300 },
	{ name = "EngageTimeoutSec", type = "number", default = 45, min = 0, max = 300 },
	{ name = "LookaheadSec", type = "number", default = 8, min = 0, max = 30 },
	{ name = "ADIZBufferNm", type = "number", default = 12, min = 0, max = 200 },
	{ name = "C2DelaySec", type = "number", default = 2, min = 0, max = 60 },
	{ name = "ThreatSpeedScaling", type = "number", default = 30, min = 0, max = 100 },
	{ name = "PerTrackScanUpdateRate", type = "number", default = 5, min = 1, max = 60 },
	{ name = "SensorCleanupSec", type = "number", default = 30, min = 5, max = 300 },
	{ name = "BallisticSimStepSec", type = "number", default = 1.0, min = 0.1, max = 5 },
	{ name = "BallisticSimMaxSec", type = "number", default = 120, min = 10, max = 600 },
	-- Optional clamped numbers (nil if not set)
	{ name = "ScanSec", type = "number_opt", min = 0, max = 86400 },
	{ name = "QuietPeriodSec", type = "number_opt", min = 0, max = 86400 },
	{ name = "HARMShutdownM", type = "number_opt", min = 0, max = 300000 },
	{ name = "PoolDefensePointsRadius", type = "number_opt", min = 1000, max = 100000 },
	-- Unclamped numbers with defaults
	{ name = "EmconRotateGroups", type = "number", default = 2 },
	{ name = "FlightSize", type = "number", default = 1 },
	{ name = "MaxTargets", type = "number", default = 1 },
	{ name = "StickyRangePct", type = "number", default = 15 },
	{ name = "SkillFactor", type = "number", default = 0.1 },
	-- Optional unclamped numbers (nil if not set)
	{ name = "GCIRangeKm", type = "number_opt" },
	{ name = "RelocateMinM", type = "number_opt" },
	{ name = "RelocateMaxM", type = "number_opt" },
	-- Booleans (default true)
	{ name = "GuiltByAssociation", type = "boolean", default = true },
	{ name = "ADIZEnabled", type = "boolean", default = true },
	{ name = "AutoDiscoverEwrs", type = "boolean", default = true },
	{ name = "BatteryTargetDatalink", type = "boolean", default = true },
	{ name = "RollingPkEnabled", type = "boolean", default = true },
	{ name = "HARMSaturateOnAmmo", type = "boolean", default = false },
	{ name = "PoolDefensePoints", type = "boolean", default = false },
	-- Tables (pass through)
	{ name = "EMCON", type = "table" },
	{ name = "MaxEngageRangePct", type = "table" },
	{ name = "FlightSizeOverrides", type = "table" },
	{ name = "LaunchCriteria", type = "table" },
	{ name = "AllowedAirbases", type = "table" },
	-- Strings
	{ name = "Name", type = "string", default = "Passive Defense" },
}

local MANPAD_SCHEMA = {
	{
		name = "AlertnessDecaySec",
		legacyName = "MANPADAlertnessDecaySec",
		default = 14400,
		min = 0,
	},
	{
		name = "FieldRadioRangeM",
		legacyName = "MANPADFieldRadioRangeM",
		default = Medusa.Constants.Manpad.DEFAULT_FIELD_RADIO_RANGE_M,
		min = 0,
		max = Medusa.Constants.Manpad.MAX_FIELD_RADIO_RANGE_M,
	},
	{
		name = "AudioRangeM",
		default = Medusa.Constants.Manpad.AUDIO_RANGE_MAX_M,
		min = Medusa.Constants.Manpad.AUDIO_RANGE_MIN_M,
		max = Medusa.Constants.Manpad.AUDIO_RANGE_MAX_M,
	},
}

local AAA_SCHEMA = {
	{
		name = "AudioRangeM",
		default = Medusa.Constants.Aaa.DEFAULT_AUDIO_RANGE_M,
		min = 0,
		max = Medusa.Constants.Aaa.MAX_AUDIO_RANGE_M,
	},
	{
		name = "AreaFireChance",
		default = Medusa.Constants.Aaa.DEFAULT_AREA_FIRE_CHANCE,
		min = 0,
		max = 0.5,
	},
	{
		name = "BarrageChance",
		default = Medusa.Constants.Aaa.DEFAULT_BARRAGE_CHANCE,
		min = 0,
		max = 1,
	},
	{
		name = "MaxBarrageGroups",
		default = Medusa.Constants.Aaa.DEFAULT_MAX_BARRAGE_GROUPS,
		min = 0,
		max = Medusa.Constants.Aaa.MAX_BARRAGE_GROUPS,
		integer = true,
	},
}

local CREW_SUPPRESSION_SCHEMA = {
	{
		name = "DamageDurationSec",
		default = Medusa.Constants.CrewSuppression.DEFAULT_DAMAGE_DURATION_SEC,
		min = 1,
		max = Medusa.Constants.CrewSuppression.MAX_DAMAGE_DURATION_SEC,
	},
	{
		name = "MaxGroupDiameterM",
		default = Medusa.Constants.CrewSuppression.DEFAULT_MAX_GROUP_DIAMETER_M,
		min = 1,
		max = Medusa.Constants.CrewSuppression.MAX_GROUP_DIAMETER_M,
	},
}

local _logger

local function resolveNumericSubtable(schema, overrides, legacyOverrides)
	local source = type(overrides) == "table" and overrides or {}
	local resolved = {}
	for i = 1, #schema do
		local setting = schema[i]
		local raw = source[setting.name]
		if raw == nil and setting.legacyName and legacyOverrides then
			raw = legacyOverrides[setting.legacyName]
		end
		local value = tonumber(raw) or setting.default
		if setting.min and value < setting.min then
			value = setting.min
		elseif setting.max and value > setting.max then
			value = setting.max
		end
		if setting.integer then
			value = math.floor(value)
		end
		resolved[setting.name] = value
	end
	return resolved
end

function Medusa.Entities.Doctrine.new(overrides)
	local d = overrides or {}
	local doctrine = { DoctrineId = d.DoctrineId or NewULID() }
	if not _logger then
		_logger = Medusa.Logger:ns("Doctrine")
	end

	for i = 1, #DOCTRINE_SCHEMA do
		local s = DOCTRINE_SCHEMA[i]
		local raw = d[s.name]

		if s.type == "enum" then
			local enumTable = Medusa.Constants[s.enum]
			if raw ~= nil and (not enumTable or not enumTable[raw]) then
				local valid = {}
				if enumTable then
					for k in pairs(enumTable) do
						valid[#valid + 1] = k
					end
				end
				_logger:error(
					string.format(
						"invalid '%s' value '%s' (valid: %s), using '%s'",
						s.name,
						tostring(raw),
						table.concat(valid, ", "),
						tostring(s.default)
					)
				)
				raw = nil
			end
			doctrine[s.name] = raw or s.default
		elseif s.type == "number" then
			local v = tonumber(raw) or s.default
			if v and s.min and v < s.min then
				v = s.min
			end
			if v and s.max and v > s.max then
				v = s.max
			end
			doctrine[s.name] = v
		elseif s.type == "number_opt" then
			if raw ~= nil then
				local v = tonumber(raw)
				if v then
					if s.min and v < s.min then
						v = s.min
					end
					if s.max and v > s.max then
						v = s.max
					end
					doctrine[s.name] = v
				end
			end
		elseif s.type == "boolean" then
			if raw ~= nil then
				doctrine[s.name] = raw
			else
				doctrine[s.name] = s.default
			end
		elseif s.type == "table" then
			doctrine[s.name] = raw
		else
			doctrine[s.name] = raw or s.default
		end
	end

	doctrine.MANPAD = resolveNumericSubtable(MANPAD_SCHEMA, d.MANPAD, d)
	doctrine.AAA = resolveNumericSubtable(AAA_SCHEMA, d.AAA)
	local crewSuppressionOverrides = type(d.CrewSuppression) == "table" and d.CrewSuppression or {}
	doctrine.CrewSuppression = resolveNumericSubtable(CREW_SUPPRESSION_SCHEMA, crewSuppressionOverrides)
	local enabled = crewSuppressionOverrides.Enabled
	if enabled ~= nil and type(enabled) ~= "boolean" then
		_logger:error(
			string.format(
				"invalid CrewSuppression.Enabled value '%s', using '%s'",
				tostring(enabled),
				tostring(Medusa.Constants.CrewSuppression.DEFAULT_ENABLED)
			)
		)
		enabled = nil
	end
	if enabled == nil then
		enabled = Medusa.Constants.CrewSuppression.DEFAULT_ENABLED
	end
	doctrine.CrewSuppression.Enabled = enabled

	return doctrine
end
