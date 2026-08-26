require("_header")
require("core.Core")
require("core.Config")
require("core.Logger")
require("core.IadsNetwork")
require("services.ApiService")
require("services.BlackBoxService")
require("observability.MetricsService")
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

--- Replaces the mission-wide raw-event observer and reports whether TRACE diagnostics are configured.
local function configureRawWorldEventTrace()
	local previousHandler = Medusa.Core.RawWorldEventTraceHandler
	if previousHandler then
		if not RemoveWorldEventHandler(previousHandler) then
			_entryLog:error("raw DCS event TRACE handler replacement failed")
			return false
		end
		Medusa.Core.RawWorldEventTraceHandler = nil
	end
	if Medusa.Logger:getLevel() ~= Medusa.Constants.LogLevel.TRACE then
		return true
	end

	local eventNameById = {}
	local eventTypes = GetWorldEventTypes()
	if type(eventTypes) == "table" then
		for eventName, eventId in pairs(eventTypes) do
			if
				type(eventName) == "string"
				and string.sub(eventName, 1, 8) == "S_EVENT_"
				and eventName ~= "S_EVENT_MAX"
				and type(eventId) == "number"
				and (not eventNameById[eventId] or eventName < eventNameById[eventId])
			then
				eventNameById[eventId] = eventName
			end
		end
	end

	local handler = {}
	--- Logs one bounded raw DCS event with its known name or unmatched numeric identifier.
	function handler:onEvent(event)
		local eventId = type(event) == "table" and event.id or nil
		local eventName = eventNameById[eventId] or ("UNKNOWN_ID_" .. tostring(eventId))
		local contained, traceError = pcall(_entryLog.traceDcsEvent, _entryLog, eventName, event)
		if not contained then
			_entryLog:error("raw DCS event TRACE callback failed: " .. tostring(traceError))
		end
	end
	if not AddWorldEventHandler(handler) then
		_entryLog:error("raw DCS event TRACE handler registration failed")
		return false
	end
	Medusa.Core.RawWorldEventTraceHandler = handler
	_entryLog:info("raw DCS event TRACE observer active")
	return true
end
configureRawWorldEventTrace()

-- Spawn independent IADS instances from config
Medusa.Core.IadsById = {}
local nets = Medusa.Config:getNetworks()
local aaaBarrageState = Medusa.Services.AaaService.newBarrageState()
local blackBoxWeaponStore = Medusa.Services.BlackBoxWeaponStore:new(Medusa.Constants.CrewSuppression.WEAPON_TRACK_CAPACITY)
local crewSkillIndex = Medusa.Services.MissionUnitSkillIndex.new(env and env.mission)
local suppressionEnabled = false
local function publishTerminalEvent(terminalEvent)
	for i = 1, #nets do
		local iads = Medusa.Core.IadsById[nets[i].id]
		if iads then
			local ok, err = pcall(iads.enqueueTerminalEvent, iads, terminalEvent)
			if not ok then
				_entryLog:error(string.format("terminal-event delivery failed for IADS %s: %s", tostring(nets[i].id), tostring(err)))
			end
		end
	end
end
for i = 1, #nets do
	local n = nets[i]
	local iads
	local initialized, result = pcall(function()
		iads = Medusa.Core.IadsNetwork:new({
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
		return iads:initialize()
	end)
	if initialized and result then
		Medusa.Core.IadsById[n.id] = iads
		suppressionEnabled = suppressionEnabled or iads:getDoctrine().CrewSuppression.Enabled
	else
		if iads then
			pcall(iads.stop, iads)
		end
		_entryLog:error(string.format("IADS %s construction or initialization failed; other networks will continue: %s", tostring(n.id), tostring(result)))
	end
end
if suppressionEnabled then
	local contained, started = pcall(Medusa.Services.BlackBoxService.start, blackBoxWeaponStore, HarnessWorldEventBus)
	if not contained or not started then
		_entryLog:error("crew suppression weapon tracker failed to start: " .. tostring(started))
	end
end
for i = 1, #nets do
	local n = nets[i]
	local iads = Medusa.Core.IadsById[n.id]
	if iads then
		local started, result = pcall(iads.start, iads)
		if not started or not result then
			pcall(iads.stop, iads)
			Medusa.Core.IadsById[n.id] = nil
			_entryLog:error(string.format("IADS %s start failed; other networks will continue: %s", tostring(n.id), tostring(result)))
		end
	end
end

local snapshotInstalled, snapshotError = pcall(Medusa.Observability.MetricsSnapshot.installSnapshot)
if not snapshotInstalled then
	_entryLog:error("metrics snapshot installation failed: " .. tostring(snapshotError))
end

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

-- Prometheus metrics file export (requires file-system access + PrometheusEnabled config)
if Medusa.Config:get().PrometheusEnabled and io and io.open and os and os.rename and os.remove and lfs and lfs.writedir and lfs.attributes then
	local _promLogger = Medusa.Logger:ns("Prometheus")
	local _promPath = (lfs and lfs.writedir and lfs.writedir() or "") .. "Logs/medusa_metrics.prom"
	local _promTempPath = _promPath .. ".tmp"
	local _promPreviousPath = _promPath .. ".previous"
	local _promInterval = Medusa.Config:get().PrometheusExtendEnabled and 2 or 10
	_promLogger:info(string.format("enabled, writing to %s (interval=%ds)", _promPath, _promInterval))
	local exportMetrics
	--- Publishes one complete Prometheus snapshot after its temporary file is closed.
	local function publishMetrics(data)
		local payload = data .. "\n"
		local opened, file, openError = pcall(io.open, _promTempPath, "w")
		if not opened or not file then
			return false, "temporary file open failed: " .. tostring(openError or file)
		end
		local written, writeError = pcall(file.write, file, payload)
		local closed, closeError = pcall(file.close, file)
		if not written or not closed then
			os.remove(_promTempPath)
			return false, "temporary file write failed: " .. tostring(not written and writeError or closeError)
		end
		local measured, size = pcall(lfs.attributes, _promTempPath, "size")
		if not measured or size ~= #payload then
			os.remove(_promTempPath)
			return false, "temporary file size mismatch: expected=" .. tostring(#payload) .. " actual=" .. tostring(size)
		end

		local published, publishError = os.rename(_promTempPath, _promPath)
		if published then
			os.remove(_promPreviousPath)
			return true
		end

		os.remove(_promPreviousPath)
		local preserved, preserveError = os.rename(_promPath, _promPreviousPath)
		if not preserved then
			os.remove(_promTempPath)
			return false, "existing metrics file could not be preserved: " .. tostring(preserveError or publishError)
		end
		published, publishError = os.rename(_promTempPath, _promPath)
		if not published then
			local restored, restoreError = os.rename(_promPreviousPath, _promPath)
			os.remove(_promTempPath)
			return false, "metrics file publish failed: " .. tostring(publishError) .. "; previous file restored=" .. tostring(restored == true) .. ": " .. tostring(restoreError)
		end
		os.remove(_promPreviousPath)
		return true
	end
	--- Registers one contained metrics export and reports whether a timer handle was returned.
	local function scheduleMetricsExport()
		local registered, timerId = pcall(ScheduleOnce, exportMetrics, nil, _promInterval)
		if not registered or not timerId then
			_promLogger:error("metrics export scheduling failed: " .. tostring(timerId))
			return false
		end
		return true
	end
	--- Exports one metrics snapshot with contained file errors, then schedules the next export.
	exportMetrics = function()
		local ok, err = pcall(function()
			local data = Medusa.Observability.MetricsService.serialize()
			if data and #data > 0 then
				local published, publishError = publishMetrics(data)
				if not published then
					_promLogger:error("metrics publish failed: " .. tostring(publishError))
				end
			end
		end)
		if not ok then
			_promLogger:error("serialize failed: " .. tostring(err))
		end
		scheduleMetricsExport()
	end
	scheduleMetricsExport()
else
	if Medusa.Config:get().PrometheusEnabled then
		Medusa.Logger:ns("Prometheus"):info("enabled but io, os, or lfs is sanitized; desanitize them in MissionScripting.lua")
	end
end
