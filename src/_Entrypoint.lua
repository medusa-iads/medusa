require("_header")
require("core.Core")
require("core.Config")
require("core.Logger")
require("core.IadsNetwork")
require("services.ApiService")
require("services.BlackBoxService")
require("services.stores.MissionUnitSkillIndex")
require("services.stores.BlackBoxWeaponStore")

--[[
            ███████╗███╗   ██╗████████╗██████╗ ██╗   ██╗██████╗  ██████╗ ██╗███╗   ██╗████████╗
            ██╔════╝████╗  ██║╚══██╔══╝██╔══██╗╚██╗ ██╔╝██╔══██╗██╔═══██╗██║████╗  ██║╚══██╔══╝
            █████╗  ██╔██╗ ██║   ██║   ██████╔╝ ╚████╔╝ ██████╔╝██║   ██║██║██╔██╗ ██║   ██║
            ██╔══╝  ██║╚██╗██║   ██║   ██╔══██╗  ╚██╔╝  ██╔═══╝ ██║   ██║██║██║╚██╗██║   ██║
            ███████╗██║ ╚████║   ██║   ██║  ██║   ██║   ██║     ╚██████╔╝██║██║ ╚████║   ██║
            ╚══════╝╚═╝  ╚═══╝   ╚═╝   ╚═╝  ╚═╝   ╚═╝   ╚═╝      ╚═════╝ ╚═╝╚═╝  ╚═══╝   ╚═╝

--]]

-- Initialize logging immediately so something appears in dcs.log even if scheduling fails
Medusa.Config:initialize()
Medusa.Logger:initialize(Medusa.Config)
local _entryLog = Medusa.Logger:ns("Entrypoint")
_entryLog:info(string.format("Medusa IADS v%s by %s", tostring(Medusa.version), Medusa.Author))
if #Medusa.Contributors > 0 then
	_entryLog:info("Contributors: " .. table.concat(Medusa.Contributors, ", "))
end

-- Spawn independent IADS instances from config
Medusa.Core.IadsById = {}
local nets = Medusa.Config:getNetworks()
local aaaBarrageState = Medusa.Services.AaaService.newBarrageState()
local blackBoxWeaponStore =
	Medusa.Services.BlackBoxWeaponStore:new(Medusa.Constants.CrewSuppression.WEAPON_TRACK_CAPACITY)
local crewSkillIndex = Medusa.Services.MissionUnitSkillIndex.new(env and env.mission)
local suppressionEnabled = false
local function publishTerminalEvent(terminalEvent)
	for i = 1, #nets do
		local iads = Medusa.Core.IadsById[nets[i].id]
		if iads then
			local ok, err = pcall(iads.enqueueTerminalEvent, iads, terminalEvent)
			if not ok then
				_entryLog:error(
					string.format("terminal-event delivery failed for IADS %s: %s", tostring(nets[i].id), tostring(err))
				)
			end
		end
	end
end
for i = 1, #nets do
	local n = nets[i]
	local iads = Medusa.Core.IadsNetwork:new({
		id = n.id,
		coalitionId = n.coalitionId,
		prefix = n.prefix,
		doctrine = n.doctrine,
		borderZones = n.borderZones,
		aaaBarrageState = aaaBarrageState,
		blackBoxWeaponStore = blackBoxWeaponStore,
		blackBoxTerminalSink = publishTerminalEvent,
		crewSkillIndex = crewSkillIndex,
	})
	Medusa.Core.IadsById[n.id] = iads
	iads:initialize()
	suppressionEnabled = suppressionEnabled or iads:getDoctrine().CrewSuppression.Enabled
end
if suppressionEnabled and not Medusa.Services.BlackBoxService.start(blackBoxWeaponStore, HarnessWorldEventBus) then
	_entryLog:error("crew suppression weapon tracker failed to start")
end
for i = 1, #nets do
	local n = nets[i]
	local iads = Medusa.Core.IadsById[n.id]
	iads:start()
end

Medusa.Services.MetricsSnapshotService.installSnapshot()

-- Public API for runtime control by other mission scripts
Medusa.API = {
	setROE = Medusa.Services.ApiService.setROE,
	getROE = Medusa.Services.ApiService.getROE,
	setPosture = Medusa.Services.ApiService.setPosture,
	getPosture = Medusa.Services.ApiService.getPosture,
	setEMCON = Medusa.Services.ApiService.setEMCON,
	getEMCON = Medusa.Services.ApiService.getEMCON,
	setScanTiming = Medusa.Services.ApiService.setScanTiming,
	getScanTiming = Medusa.Services.ApiService.getScanTiming,
	setRotationGroups = Medusa.Services.ApiService.setRotationGroups,
	getRotationGroups = Medusa.Services.ApiService.getRotationGroups,
}

-- Prometheus metrics file export (requires io desanitization + PrometheusEnabled config)
if Medusa.Config:get().PrometheusEnabled and io and io.open then
	local _promLogger = Medusa.Logger:ns("Prometheus")
	local _promPath = (lfs and lfs.writedir and lfs.writedir() or "") .. "Logs/medusa_metrics.prom"
	local _promInterval = Medusa.Config:get().PrometheusExtendEnabled and 2 or 10
	_promLogger:info(string.format("enabled, writing to %s (interval=%ds)", _promPath, _promInterval))
	timer.scheduleFunction(function()
		local ok, err = pcall(function()
			local data = Medusa.Services.MetricsService.serialize()
			if data and #data > 0 then
				local f = io.open(_promPath, "w")
				if f then
					f:write(data)
					f:write("\n")
					f:close()
				end
			end
		end)
		if not ok then
			_promLogger:error("serialize failed: " .. tostring(err))
		end
		return GetTime() + _promInterval
	end, nil, GetTime() + _promInterval)
else
	if Medusa.Config:get().PrometheusEnabled then
		Medusa.Logger:ns("Prometheus"):info("enabled but io is sanitized; desanitize io in MissionScripting.lua")
	end
end
