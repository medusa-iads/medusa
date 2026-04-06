require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")
require("entities.Battery")

--[[
            ██████╗  █████╗ ████████╗████████╗███████╗██████╗ ██╗   ██╗     █████╗  ██████╗████████╗██╗██╗   ██╗ █████╗ ████████╗██╗ ██████╗ ███╗   ██╗
            ██╔══██╗██╔══██╗╚══██╔══╝╚══██╔══╝██╔════╝██╔══██╗╚██╗ ██╔╝    ██╔══██╗██╔════╝╚══██╔══╝██║██║   ██║██╔══██╗╚══██╔══╝██║██╔═══██╗████╗  ██║
            ██████╔╝███████║   ██║      ██║   █████╗  ██████╔╝ ╚████╔╝     ███████║██║        ██║   ██║╚██╗ ██╔╝███████║   ██║   ██║██║   ██║██╔██╗ ██║
            ██╔══██╗██╔══██║   ██║      ██║   ██╔══╝  ██╔══██╗  ╚██╔╝      ██╔══██║██║        ██║   ██║ ╚████╔╝ ██╔══██║   ██║   ██║██║   ██║██║╚██╗██║
            ██████╔╝██║  ██║   ██║      ██║   ███████╗██║  ██║   ██║       ██║  ██║╚██████╗   ██║   ██║  ╚██╔╝  ██║  ██║   ██║   ██║╚██████╔╝██║ ╚████║
            ╚═════╝ ╚═╝  ╚═╝   ╚═╝      ╚═╝   ╚══════╝╚═╝  ╚═╝   ╚═╝       ╚═╝  ╚═╝ ╚═════╝   ╚═╝   ╚═╝   ╚═╝   ╚═╝  ╚═╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝

    What this service does
    - Issues DCS controller commands to set battery radar on/off, ROE, alarm state, and emission control.
    - Provides goHot, goCold, goWarm, goGreen, and goHarmShutdown transitions with hold-down enforcement.
    - This is the only code path that sends controller commands to SAM groups.

    How others use it
    - TargetAssigner calls goHot when assigning a battery to a track.
    - EmconService calls goWarm/goCold to enforce EMCON policy; HarmResponseService calls goHarmShutdown.
--]]

Medusa.Services.BatteryActivationService = {}

local _logger = Medusa.Logger:ns("BatteryActivationService")
local Battery = Medusa.Entities.Battery
local AS = Medusa.Constants.ActivationState

--- One-time DCS erect: forces the deploy animation so subsequent transitions are instant.
function Medusa.Services.BatteryActivationService.erectGroup(groupName)
	local controller = GetGroupController(groupName)
	if not controller then
		return false
	end
	SetControllerOnOff(controller, true)
	ControllerSetROE(controller, "OPEN_FIRE")
	ControllerSetAlarmState(controller, "RED")
	ControllerSetDisperseOnAttack(controller, 0)
	return true
end

--- Releases a battery from IADS control entirely. Sets it weapons free and removes it from all stores.
function Medusa.Services.BatteryActivationService.goAutonomous(battery, batteryStore, geoGrid, unitIdIndex, trackStore)
	Medusa.Services.BatteryActivationService.erectGroup(battery.GroupName)
	Battery.releaseTrack(battery, trackStore)
	if unitIdIndex and battery.Units then
		for j = 1, #battery.Units do
			unitIdIndex[battery.Units[j].UnitId] = nil
		end
	end
	if geoGrid then
		geoGrid:remove(battery.BatteryId)
	end
	if batteryStore then
		batteryStore:remove(battery.BatteryId)
	end
	_logger:info(string.format("battery %s released to autonomous DCS AI control", battery.GroupName))
	return true
end

function Medusa.Services.BatteryActivationService.goHot(battery, now)
	if not Battery.canTransition(battery, AS.STATE_HOT, now) then
		Medusa.Services.MetricsService.inc("medusa_goHot_blocked_total")
		return false
	end
	return Medusa.Services.BatteryActivationService._activateHot(battery, now)
end

function Medusa.Services.BatteryActivationService.forceGoHot(battery, now)
	if battery.ActivationState == AS.STATE_HOT then
		return false
	end
	return Medusa.Services.BatteryActivationService._activateHot(battery, now)
end

function Medusa.Services.BatteryActivationService._activateHot(battery, now)
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		Medusa.Services.MetricsService.inc("medusa_goHot_blocked_total")
		_logger:error(string.format("battery %s has no controller, cannot go HOT", battery.GroupName))
		return false
	end
	SetControllerOnOff(controller, true)
	ControllerSetROE(controller, "OPEN_FIRE")
	ControllerSetAlarmState(controller, "RED")
	if AI and AI.Option and AI.Option.Ground and AI.Option.Ground.id then
		SetControllerOption(controller, AI.Option.Ground.id.ENGAGE_AIR_WEAPONS, true)
	end
	local group = GetGroup(battery.GroupName)
	if group then
		EnableGroupEmissions(group, true)
	end
	Battery.transitionTo(battery, AS.STATE_HOT, now)
	Medusa.Services.MetricsService.inc("medusa_battery_go_hot_total")
	_logger:info(string.format("battery %s going HOT", battery.GroupName))
	return true
end

function Medusa.Services.BatteryActivationService.goCold(battery, now, trackStore)
	if not Battery.canTransition(battery, AS.STATE_COLD, now) then
		return false
	end
	if not Battery.canDeactivate(battery, now) then
		return false
	end
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		_logger:error(string.format("battery %s has no controller, cannot go COLD", battery.GroupName))
		return false
	end
	ControllerSetROE(controller, "WEAPON_HOLD")
	ControllerSetAlarmState(controller, "RED")
	local group = GetGroup(battery.GroupName)
	if group then
		EnableGroupEmissions(group, false)
	end
	Battery.transitionTo(battery, AS.STATE_COLD, now)
	Medusa.Services.MetricsService.inc("medusa_battery_go_cold_total")
	Battery.releaseTrack(battery, trackStore)
	_logger:info(string.format("battery %s going COLD", battery.GroupName))
	return true
end

function Medusa.Services.BatteryActivationService.goHarmShutdown(battery, now, trackStore)
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		_logger:error(string.format("battery %s has no controller, cannot HARM shutdown", battery.GroupName))
		return false
	end
	SetControllerOnOff(controller, false)
	ControllerSetROE(controller, "WEAPON_HOLD")
	ControllerSetAlarmState(controller, "RED")
	local group = GetGroup(battery.GroupName)
	if group then
		EnableGroupEmissions(group, false)
	end
	Battery.transitionTo(battery, AS.STATE_COLD, now)
	Medusa.Services.MetricsService.inc("medusa_battery_go_cold_total")
	Battery.releaseTrack(battery, trackStore)
	_logger:info(string.format("battery %s HARM shutdown (AI off + emissions off)", battery.GroupName))
	return true
end

function Medusa.Services.BatteryActivationService.goGreen(battery, now, trackStore)
	if not Battery.canDeactivate(battery, now) then
		return false
	end
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		return false
	end
	ControllerSetROE(controller, "WEAPON_HOLD")
	ControllerSetAlarmState(controller, "GREEN")
	local group = GetGroup(battery.GroupName)
	if group then
		EnableGroupEmissions(group, false)
	end
	Battery.transitionTo(battery, AS.STATE_COLD, now)
	Battery.releaseTrack(battery, trackStore)
	_logger:info(string.format("battery %s going GREEN (ammo depleted)", battery.GroupName))
	return true
end

function Medusa.Services.BatteryActivationService.goWarm(battery, now)
	if not Battery.canTransition(battery, AS.STATE_WARM, now) then
		return false
	end
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		_logger:error(string.format("battery %s has no controller, cannot go WARM", battery.GroupName))
		return false
	end
	SetControllerOnOff(controller, true)
	ControllerSetROE(controller, "WEAPON_HOLD")
	ControllerSetAlarmState(controller, "RED")
	local group = GetGroup(battery.GroupName)
	if group then
		EnableGroupEmissions(group, true)
	end
	Battery.transitionTo(battery, AS.STATE_WARM, now)
	Medusa.Services.MetricsService.inc("medusa_battery_go_warm_total")
	_logger:info(string.format("battery %s going WARM", battery.GroupName))
	return true
end
