require("_header")
require("services.Services")
require("core.Config")
require("core.Constants")

--[[
             ██████╗ ██████╗  ██████╗ ██╗   ██╗██████╗     ███╗   ██╗ █████╗ ███╗   ███╗███████╗    ██████╗  █████╗ ██████╗ ███████╗███████╗██████╗ 
            ██╔════╝ ██╔══██╗██╔═══██╗██║   ██║██╔══██╗    ████╗  ██║██╔══██╗████╗ ████║██╔════╝    ██╔══██╗██╔══██╗██╔══██╗██╔════╝██╔════╝██╔══██╗
            ██║  ███╗██████╔╝██║   ██║██║   ██║██████╔╝    ██╔██╗ ██║███████║██╔████╔██║█████╗      ██████╔╝███████║██████╔╝███████╗█████╗  ██████╔╝
            ██║   ██║██╔══██╗██║   ██║██║   ██║██╔═══╝     ██║╚██╗██║██╔══██║██║╚██╔╝██║██╔══╝      ██╔═══╝ ██╔══██║██╔══██╗╚════██║██╔══╝  ██╔══██╗
            ╚██████╔╝██║  ██║╚██████╔╝╚██████╔╝██║         ██║ ╚████║██║  ██║██║ ╚═╝ ██║███████╗    ██║     ██║  ██║██║  ██║███████║███████╗██║  ██║
             ╚═════╝ ╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═╝         ╚═╝  ╚═══╝╚═╝  ╚═╝╚═╝     ╚═╝╚══════╝    ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚══════╝╚═╝  ╚═╝
                                                                                                                                                    
    What this service does
    - Parses a DCS group name that follows the dot-echelon naming convention into structured data.
    - Extracts the managed prefix, roles (GCI, EWR, HQ), hierarchy path, and a human label.
    - Supports both exact and prefix-style role matching for backward compatibility.

    How others use it
    - DiscoveryService calls parse() on every group name to decide if a group is managed and what it is.
    - EntityFactory relies on the parsed roles and echelon path to classify groups as batteries, sensors, or HQs.
]]

---@class Medusa.Services.GroupNameParser
---@field parse fun(self: Medusa.Services.GroupNameParser, groupName: string, managedPrefix?: string): {
---@field   isManaged: boolean,
---@field   unitLabel: string|nil,
---@field   roles: string[],
---@field   isHQ: boolean,
---@field   sensorType: string|nil,
---@field   echelonPath: string[],
---@field   roleAnchorEchelon: string|nil,
---@field   originalName: string,
---@field   nameWithoutPrefix: string|nil,
---@field }
Medusa.Services.GroupNameParser = {}

local EWR_ALIASES = { ewr = true, radar = true, sensor = true }

--- Check if a segment matches a role token.
--- Supports both exact match ("ewr") and prefix match ("ewr north", "ewr-1")
--- for backward compatibility with Skynet-style group naming.
local function segmentMatchesToken(seg, token)
	if seg == token then
		return true
	end
	if #seg > #token and string.sub(seg, 1, #token) == token then
		local next_char = string.sub(seg, #token + 1, #token + 1)
		if not string.match(next_char, "%w") then
			return true
		end
	end
	return false
end

local function isEwrToken(seg, configToken)
	for alias in pairs(EWR_ALIASES) do
		if segmentMatchesToken(seg, alias) then
			return true
		end
	end
	return configToken and segmentMatchesToken(seg, configToken)
end

function Medusa.Services.GroupNameParser:_findRoleIndexes(segments, tokens)
	local roleIndexes = {}
	for i = 1, #segments do
		local seg = string.lower(segments[i])
		if
			tokens
			and (
				segmentMatchesToken(seg, tokens.GCI)
				or isEwrToken(seg, tokens.EWR)
				or segmentMatchesToken(seg, tokens.HQ)
				or segmentMatchesToken(seg, tokens.AWACS or "awacs")
			)
		then
			roleIndexes[#roleIndexes + 1] = i
		end
	end
	return roleIndexes
end

function Medusa.Services.GroupNameParser:_rolesFromSegments(segments, tokens)
	local roles = {}
	local sensorType
	local isHq = false
	for i = 1, #segments do
		local seg = string.lower(segments[i])
		if tokens and segmentMatchesToken(seg, tokens.GCI) then
			roles[#roles + 1] = Medusa.Constants.Role.GCI
			if not sensorType then
				sensorType = Medusa.Constants.Role.GCI
			end
		elseif isEwrToken(seg, tokens and tokens.EWR) then
			roles[#roles + 1] = Medusa.Constants.Role.EWR
			if not sensorType then
				sensorType = Medusa.Constants.Role.EWR
			end
		elseif tokens and segmentMatchesToken(seg, tokens.AWACS or "awacs") then
			roles[#roles + 1] = Medusa.Constants.Role.AWACS
			if not sensorType then
				sensorType = Medusa.Constants.Role.AWACS
			end
		elseif tokens and segmentMatchesToken(seg, tokens.HQ) then
			roles[#roles + 1] = Medusa.Constants.Role.HQ
			isHq = true
		end
	end
	return roles, sensorType, isHq
end

function Medusa.Services.GroupNameParser:parse(groupName, managedPrefix)
	local result = {
		isManaged = false,
		unitLabel = nil,
		roles = {},
		isHQ = false,
		sensorType = nil,
		echelonPath = {},
		roleAnchorEchelon = nil,
		originalName = groupName,
		nameWithoutPrefix = nil,
	}

	if type(groupName) ~= "string" or #groupName == 0 then
		return result
	end

	local nameAfterPrefix = groupName
	local effectivePrefix = managedPrefix
	if type(effectivePrefix) == "string" and #effectivePrefix > 0 then
		local p = effectivePrefix
		-- accept either exact prefix or prefix followed by a dot
		if StartsWith(groupName, p .. ".") then
			result.isManaged = true
			nameAfterPrefix = string.sub(groupName, #p + 2)
		elseif groupName == p then
			result.isManaged = true
			nameAfterPrefix = ""
		elseif
			StartsWith(groupName, p)
			and not StartsWith(groupName, p .. "_")
			and not StartsWith(groupName, p .. "-")
		then
			-- bare prefix match without trailing dot
			result.isManaged = true
			nameAfterPrefix = string.sub(groupName, #p + 1)
			local first = string.sub(nameAfterPrefix, 1, 1)
			if first == "." or first == " " then
				nameAfterPrefix = string.sub(nameAfterPrefix, 2)
			end
		else
			result.isManaged = false
		end
	end

	result.nameWithoutPrefix = nameAfterPrefix

	local segments = SplitString(nameAfterPrefix, ".") or {}
	if #segments == 0 then
		return result
	end

	local tokens = Medusa.Config and Medusa.Config.getRoleTokens and Medusa.Config:getRoleTokens() or nil
	local roles, sensorType, isHq = self:_rolesFromSegments(segments, tokens)
	result.roles = roles
	result.sensorType = sensorType
	result.isHQ = isHq

	-- Dot-Echelon: read left-to-right, top-down. Highest echelon first, unit label last.
	-- With roles: echelon = segments before first role, label = segments after last role.
	-- Without roles: echelon = all segments except last, label = last segment.
	local roleIndexes = self:_findRoleIndexes(segments, tokens)
	local firstRoleIndex = roleIndexes[1]
	local lastRoleIndex = (#roleIndexes > 0) and roleIndexes[#roleIndexes] or nil

	if lastRoleIndex then
		-- Echelon path = everything before the first role
		if firstRoleIndex > 1 then
			for i = 1, firstRoleIndex - 1 do
				result.echelonPath[#result.echelonPath + 1] = segments[i]
			end
		end
		-- Label = everything after the last role
		if lastRoleIndex < #segments then
			local labelParts = {}
			for i = lastRoleIndex + 1, #segments do
				labelParts[#labelParts + 1] = segments[i]
			end
			result.unitLabel = table.concat(labelParts, ".")
		else
			-- Role is last segment (flat Skynet-style name like "EWR North")
			result.unitLabel = segments[lastRoleIndex]
		end
		if #result.echelonPath > 0 then
			result.roleAnchorEchelon = result.echelonPath[1]
		end
	else
		-- No roles: label is the last segment, echelon is everything before it
		result.unitLabel = segments[#segments]
		if #segments > 1 then
			for i = 1, #segments - 1 do
				result.echelonPath[#result.echelonPath + 1] = segments[i]
			end
		end
	end

	return result
end
