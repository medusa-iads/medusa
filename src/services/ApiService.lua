require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")

--[[
             █████╗ ██████╗ ██╗    ███████╗███████╗██████╗ ██╗   ██╗██╗ ██████╗███████╗
            ██╔══██╗██╔══██╗██║    ██╔════╝██╔════╝██╔══██╗██║   ██║██║██╔════╝██╔════╝
            ███████║██████╔╝██║    ███████╗█████╗  ██████╔╝██║   ██║██║██║     █████╗
            ██╔══██║██╔═══╝ ██║    ╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██║██║     ██╔══╝
            ██║  ██║██║     ██║    ███████║███████╗██║  ██║ ╚████╔╝ ██║╚██████╗███████╗
            ╚═╝  ╚═╝╚═╝     ╚═╝    ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚═╝ ╚═════╝╚══════╝

    What this service does
    - Exposes runtime API functions for changing network doctrine fields mid-mission.
    - Validates values against Constants enums and looks up the target network by name.

    How others use it
    - The Entrypoint wires these functions into Medusa.API so external mission scripts can call them.
--]]

Medusa.Services.ApiService = {}

local _logger = Medusa.Logger:ns("ApiService")

local function isValidROE(value)
	for _, v in pairs(Medusa.Constants.ROEState) do
		if v == value then
			return true
		end
	end
	return false
end

function Medusa.Services.ApiService.setROE(networkName, roeValue)
	if not isValidROE(roeValue) then
		_logger:error(string.format("invalid ROE value: %s", tostring(roeValue)))
		return false
	end
	local iads = Medusa.Core.IadsById[tostring(networkName)]
	if not iads then
		_logger:error(string.format("network not found: %s", tostring(networkName)))
		return false
	end
	local prev = iads:getDoctrine().ROE
	iads:getDoctrine().ROE = roeValue
	_logger:info(string.format("network %s ROE changed: %s -> %s", networkName, prev, roeValue))
	Medusa.Services.MetricsService.inc("medusa_roe_changes_total")
	return true
end

function Medusa.Services.ApiService.getROE(networkName)
	local iads = Medusa.Core.IadsById[tostring(networkName)]
	if not iads then
		return nil
	end
	return iads:getDoctrine().ROE
end

local function isValidPosture(value)
	for _, v in pairs(Medusa.Constants.Posture) do
		if v == value then
			return true
		end
	end
	return false
end

function Medusa.Services.ApiService.setPosture(networkName, postureValue)
	if not isValidPosture(postureValue) then
		_logger:error(string.format("invalid Posture value: %s", tostring(postureValue)))
		return false
	end
	local iads = Medusa.Core.IadsById[tostring(networkName)]
	if not iads then
		_logger:error(string.format("network not found: %s", tostring(networkName)))
		return false
	end
	local prev = iads:getDoctrine().Posture
	iads:getDoctrine().Posture = postureValue
	_logger:info(string.format("network %s Posture changed: %s -> %s", networkName, prev, postureValue))
	return true
end

function Medusa.Services.ApiService.getPosture(networkName)
	local iads = Medusa.Core.IadsById[tostring(networkName)]
	if not iads then
		return nil
	end
	return iads:getDoctrine().Posture
end

local function isValidEmconPolicy(value)
	for _, v in pairs(Medusa.Constants.EmissionControlPolicy) do
		if v == value then
			return true
		end
	end
	return false
end

local function isValidEmconRole(role)
	return Medusa.Constants.EMCON_DEFAULT_POLICY_BY_ROLE[role] ~= nil
end

local _roleGroups = {
	SAM = { "VLR_SAM", "LR_SAM", "MR_SAM", "SR_SAM", "AAA", "GENERIC_SAM" },
	RADAR = { "EWR", "GCI" },
}

local function resolveRoles(role)
	if role == nil then
		local roles = {}
		for r, _ in pairs(Medusa.Constants.EMCON_DEFAULT_POLICY_BY_ROLE) do
			roles[#roles + 1] = r
		end
		return roles
	end
	if _roleGroups[role] then
		return _roleGroups[role]
	end
	if isValidEmconRole(role) then
		return { role }
	end
	return nil
end

function Medusa.Services.ApiService.setEMCON(networkName, policyValue, role)
	if not isValidEmconPolicy(policyValue) then
		_logger:error(string.format("invalid EMCON policy value: %s", tostring(policyValue)))
		return false
	end
	local iads = Medusa.Core.IadsById[tostring(networkName)]
	if not iads then
		_logger:error(string.format("network not found: %s", tostring(networkName)))
		return false
	end
	local roles = resolveRoles(role)
	if not roles then
		_logger:error(string.format("invalid EMCON role: %s", tostring(role)))
		return false
	end
	local doctrine = iads:getDoctrine()
	if not doctrine.EMCON then
		doctrine.EMCON = {}
	end
	for i = 1, #roles do
		doctrine.EMCON[roles[i]] = policyValue
	end
	local label = role or "all"
	_logger:info(string.format("network %s EMCON[%s] set to %s", networkName, label, policyValue))
	Medusa.Services.MetricsService.inc("medusa_emcon_changes_total")
	return true
end

function Medusa.Services.ApiService.getEMCON(networkName, role)
	local iads = Medusa.Core.IadsById[tostring(networkName)]
	if not iads then
		return nil
	end
	if not role or not isValidEmconRole(role) then
		_logger:error(string.format("invalid EMCON role for getEMCON: %s", tostring(role)))
		return nil
	end
	local doctrine = iads:getDoctrine()
	if doctrine.EMCON and doctrine.EMCON[role] ~= nil then
		return doctrine.EMCON[role]
	end
	return Medusa.Constants.EMCON_DEFAULT_POLICY_BY_ROLE[role]
end

function Medusa.Services.ApiService.setScanTiming(networkName, scanSec, quietSec)
	if type(scanSec) ~= "number" or scanSec <= 0 then
		_logger:error(string.format("invalid scanSec: %s", tostring(scanSec)))
		return false
	end
	if type(quietSec) ~= "number" or quietSec < 0 then
		_logger:error(string.format("invalid quietSec: %s", tostring(quietSec)))
		return false
	end
	local iads = Medusa.Core.IadsById[tostring(networkName)]
	if not iads then
		_logger:error(string.format("network not found: %s", tostring(networkName)))
		return false
	end
	local doctrine = iads:getDoctrine()
	local prevScan = doctrine.ScanSec or Medusa.Constants.EMCON_DEFAULT_SCAN_DURATION_SEC
	local prevQuiet = doctrine.QuietPeriodSec or Medusa.Constants.EMCON_DEFAULT_QUIET_PERIOD_SEC
	doctrine.ScanSec = scanSec
	doctrine.QuietPeriodSec = quietSec
	_logger:info(
		string.format(
			"network %s ScanTiming changed: scan %s->%s quiet %s->%s",
			networkName,
			prevScan,
			scanSec,
			prevQuiet,
			quietSec
		)
	)
	Medusa.Services.MetricsService.inc("medusa_emcon_changes_total")
	return true
end

function Medusa.Services.ApiService.getScanTiming(networkName)
	local iads = Medusa.Core.IadsById[tostring(networkName)]
	if not iads then
		return nil, nil
	end
	local doctrine = iads:getDoctrine()
	local scan = doctrine.ScanSec
	local quiet = doctrine.QuietPeriodSec
	if scan == nil then
		scan = Medusa.Constants.EMCON_DEFAULT_SCAN_DURATION_SEC
	end
	if quiet == nil then
		quiet = Medusa.Constants.EMCON_DEFAULT_QUIET_PERIOD_SEC
	end
	return scan, quiet
end

function Medusa.Services.ApiService.setRotationGroups(networkName, count)
	if type(count) ~= "number" or count < 1 or count ~= math.floor(count) then
		_logger:error(string.format("invalid rotation group count: %s", tostring(count)))
		return false
	end
	local iads = Medusa.Core.IadsById[tostring(networkName)]
	if not iads then
		_logger:error(string.format("network not found: %s", tostring(networkName)))
		return false
	end
	local doctrine = iads:getDoctrine()
	local prev = doctrine.EmconRotateGroups or Medusa.Constants.EMCON_DEFAULT_ROTATION_GROUPS
	doctrine.EmconRotateGroups = count
	_logger:info(string.format("network %s RotationGroups changed: %s -> %s", networkName, prev, count))
	Medusa.Services.MetricsService.inc("medusa_emcon_changes_total")
	return true
end

function Medusa.Services.ApiService.getRotationGroups(networkName)
	local iads = Medusa.Core.IadsById[tostring(networkName)]
	if not iads then
		return nil
	end
	local doctrine = iads:getDoctrine()
	local groups = doctrine.EmconRotateGroups
	if groups == nil then
		groups = Medusa.Constants.EMCON_DEFAULT_ROTATION_GROUPS
	end
	return groups
end
