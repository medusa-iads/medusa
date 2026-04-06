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
