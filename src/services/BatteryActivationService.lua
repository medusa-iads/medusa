require("_header")
require("services.Services")
require("observability.MetricsService")
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

--- Reports whether the emission wrapper returned true for groupName.
local function setEmissions(groupName, enabled)
	local group = GetGroup(groupName)
	return group ~= nil and EnableGroupEmissions(group, enabled) == true
end

--- Records that at least one operation wrapper returned false and reports failure to the caller.
local function commandFailure(groupName, operation)
	_logger:error(string.format("group %s had a false wrapper result during %s", groupName, operation))
	return false
end

--- Marks battery readiness unknown after a command sequence with mixed or failed wrapper results.
local function markReadinessUnknown(battery)
	battery.ActivationState = AS.INITIALIZING
	battery.LastStateChangeTime = nil
end

--- Clears target ownership after a failed readiness sequence and reports the wrapper failure.
local function readinessFailure(battery, trackStore, operation)
	markReadinessUnknown(battery)
	Battery.releaseTrack(battery, trackStore)
	return commandFailure(battery.GroupName, operation)
end

--- Requests the one-time DCS erect sequence and reports whether every wrapper returned true.
function Medusa.Services.BatteryActivationService.erectGroup(groupName)
	local controller = GetGroupController(groupName)
	if not controller then
		return false
	end
	local onOffOk = SetControllerOnOff(controller, true)
	local roeOk = ControllerSetROE(controller, "OPEN_FIRE")
	local alarmOk = ControllerSetAlarmState(controller, "RED")
	local disperseOk = ControllerSetDisperseOnAttack(controller, 0)
	if onOffOk ~= true or roeOk ~= true or alarmOk ~= true or disperseOk ~= true then
		return commandFailure(groupName, "erect")
	end
	return true
end

--- Releases battery to autonomous DCS control only after every erect wrapper returns true.
function Medusa.Services.BatteryActivationService.goAutonomous(battery, batteryRepository, geoGrid, trackStore)
	if not Medusa.Services.BatteryActivationService.erectGroup(battery.GroupName) then
		return readinessFailure(battery, trackStore, "autonomous release")
	end
	Battery.releaseTrack(battery, trackStore)
	if geoGrid then
		geoGrid:remove(battery.BatteryId)
	end
	if batteryRepository then
		batteryRepository:remove(battery.BatteryId)
	end
	_logger:info(string.format("battery %s released to autonomous DCS AI control", battery.GroupName))
	return true
end

--- Requests the normal HOT transition when suppression and hold-down policy allow it.
function Medusa.Services.BatteryActivationService.goHot(battery, now)
	if Battery.isCrewSuppressed(battery) then
		Medusa.Observability.MetricsService.inc("medusa_goHot_blocked_total")
		return false
	end
	if not Battery.canTransition(battery, AS.STATE_HOT, now) then
		Medusa.Observability.MetricsService.inc("medusa_goHot_blocked_total")
		return false
	end
	return Medusa.Services.BatteryActivationService._activateHot(battery, now)
end

--- Requests an emergency HOT transition without the normal state-change hold-down.
function Medusa.Services.BatteryActivationService.forceGoHot(battery, now)
	if Battery.isCrewSuppressed(battery) then
		Medusa.Observability.MetricsService.inc("medusa_goHot_blocked_total")
		return false
	end
	if battery.ActivationState == AS.STATE_HOT then
		return false
	end
	return Medusa.Services.BatteryActivationService._activateHot(battery, now)
end

--- Issues the ordered HOT command sequence and commits HOT only after every wrapper returns true.
function Medusa.Services.BatteryActivationService._activateHot(battery, now)
	if Battery.isCrewSuppressed(battery) then
		Medusa.Observability.MetricsService.inc("medusa_goHot_blocked_total")
		return false
	end
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		Medusa.Observability.MetricsService.inc("medusa_goHot_blocked_total")
		_logger:error(string.format("battery %s has no controller, cannot go HOT", battery.GroupName))
		return false
	end
	local onOffOk = SetControllerOnOff(controller, true)
	local roeOk = ControllerSetROE(controller, "OPEN_FIRE")
	local alarmOk = ControllerSetAlarmState(controller, "RED")
	local optionOk = true
	local groundOptionIds = AI and AI.Option and AI.Option.Ground and AI.Option.Ground.id
	if groundOptionIds and type(groundOptionIds.ENGAGE_AIR_WEAPONS) == "number" then
		optionOk = SetControllerOption(controller, groundOptionIds.ENGAGE_AIR_WEAPONS, true) == true
	end
	local emissionsOk = setEmissions(battery.GroupName, true)
	if onOffOk ~= true or roeOk ~= true or alarmOk ~= true or not optionOk or not emissionsOk then
		markReadinessUnknown(battery)
		Medusa.Observability.MetricsService.inc("medusa_goHot_blocked_total")
		return commandFailure(battery.GroupName, "HOT transition")
	end
	Battery.transitionTo(battery, AS.STATE_HOT, now)
	Medusa.Observability.MetricsService.inc("medusa_battery_go_hot_total")
	_logger:info(string.format("battery %s going HOT", battery.GroupName))
	return true
end

--- Stops battery engagement and commits COLD only after every suppression wrapper returns true.
function Medusa.Services.BatteryActivationService.goCrewSuppressed(battery, now, trackStore)
	Battery.releaseTrack(battery, trackStore)
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		markReadinessUnknown(battery)
		return false
	end
	local roeOk = ControllerSetROE(controller, "WEAPON_HOLD")
	local alarmOk = ControllerSetAlarmState(controller, "RED")
	local emissionsOk = setEmissions(battery.GroupName, false)
	if roeOk ~= true or alarmOk ~= true or not emissionsOk then
		markReadinessUnknown(battery)
		return commandFailure(battery.GroupName, "crew-suppression")
	end
	Battery.transitionTo(battery, AS.STATE_COLD, now)
	return true
end

--- Requests COLD and releases the assignment only after every wrapper returns true.
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
		return readinessFailure(battery, trackStore, "COLD transition")
	end
	local roeOk = ControllerSetROE(controller, "WEAPON_HOLD")
	local alarmOk = ControllerSetAlarmState(controller, "RED")
	local emissionsOk = setEmissions(battery.GroupName, false)
	if roeOk ~= true or alarmOk ~= true or not emissionsOk then
		return readinessFailure(battery, trackStore, "COLD transition")
	end
	Battery.transitionTo(battery, AS.STATE_COLD, now)
	Medusa.Observability.MetricsService.inc("medusa_battery_go_cold_total")
	Battery.releaseTrack(battery, trackStore)
	_logger:info(string.format("battery %s going COLD", battery.GroupName))
	return true
end

--- Requests the ordered HARM shutdown and commits COLD only after every wrapper returns true.
function Medusa.Services.BatteryActivationService.goHarmShutdown(battery, now, trackStore)
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		_logger:error(string.format("battery %s has no controller, cannot HARM shutdown", battery.GroupName))
		return readinessFailure(battery, trackStore, "HARM shutdown")
	end
	local onOffOk = SetControllerOnOff(controller, false)
	local roeOk = ControllerSetROE(controller, "WEAPON_HOLD")
	local alarmOk = ControllerSetAlarmState(controller, "RED")
	local emissionsOk = setEmissions(battery.GroupName, false)
	if onOffOk ~= true or roeOk ~= true or alarmOk ~= true or not emissionsOk then
		return readinessFailure(battery, trackStore, "HARM shutdown")
	end
	Battery.transitionTo(battery, AS.STATE_COLD, now)
	Medusa.Observability.MetricsService.inc("medusa_battery_go_cold_total")
	Battery.releaseTrack(battery, trackStore)
	_logger:info(string.format("battery %s HARM shutdown (AI off + emissions off)", battery.GroupName))
	return true
end

--- Requests GREEN after ammunition loss and commits COLD only after every wrapper returns true.
function Medusa.Services.BatteryActivationService.goGreen(battery, now, trackStore)
	if not Battery.canDeactivate(battery, now) then
		return false
	end
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		return readinessFailure(battery, trackStore, "GREEN transition")
	end
	local roeOk = ControllerSetROE(controller, "WEAPON_HOLD")
	local alarmOk = ControllerSetAlarmState(controller, "GREEN")
	local emissionsOk = setEmissions(battery.GroupName, false)
	if roeOk ~= true or alarmOk ~= true or not emissionsOk then
		return readinessFailure(battery, trackStore, "GREEN transition")
	end
	Battery.transitionTo(battery, AS.STATE_COLD, now)
	Battery.releaseTrack(battery, trackStore)
	_logger:info(string.format("battery %s going GREEN (ammo depleted)", battery.GroupName))
	return true
end

--- Requests WARM and commits WARM only after every wrapper returns true.
function Medusa.Services.BatteryActivationService.goWarm(battery, now)
	if Battery.isCrewSuppressed(battery) then
		return false
	end
	if not Battery.canTransition(battery, AS.STATE_WARM, now) then
		return false
	end
	local controller = GetGroupController(battery.GroupName)
	if not controller then
		_logger:error(string.format("battery %s has no controller, cannot go WARM", battery.GroupName))
		return false
	end
	local onOffOk = SetControllerOnOff(controller, true)
	local roeOk = ControllerSetROE(controller, "WEAPON_HOLD")
	local alarmOk = ControllerSetAlarmState(controller, "RED")
	local emissionsOk = setEmissions(battery.GroupName, true)
	if onOffOk ~= true or roeOk ~= true or alarmOk ~= true or not emissionsOk then
		markReadinessUnknown(battery)
		return commandFailure(battery.GroupName, "WARM transition")
	end
	Battery.transitionTo(battery, AS.STATE_WARM, now)
	Medusa.Observability.MetricsService.inc("medusa_battery_go_warm_total")
	_logger:info(string.format("battery %s going WARM", battery.GroupName))
	return true
end

--- Requests the ordered sensor-group command sequence and reports whether every wrapper returned true.
function Medusa.Services.BatteryActivationService.setSensorState(groupName, desiredState)
	local controller = GetGroupController(groupName)
	if not controller then
		return false
	end
	local succeeded
	if desiredState == AS.STATE_WARM then
		local onOffOk = SetControllerOnOff(controller, true)
		local roeOk = ControllerSetROE(controller, "OPEN_FIRE")
		local alarmOk = ControllerSetAlarmState(controller, "RED")
		local emissionsOk = setEmissions(groupName, true)
		succeeded = onOffOk == true and roeOk == true and alarmOk == true and emissionsOk
	elseif desiredState == AS.STATE_COLD then
		local roeOk = ControllerSetROE(controller, "WEAPON_HOLD")
		local alarmOk = ControllerSetAlarmState(controller, "GREEN")
		local onOffOk = SetControllerOnOff(controller, false)
		local emissionsOk = setEmissions(groupName, false)
		succeeded = roeOk == true and alarmOk == true and onOffOk == true and emissionsOk
	else
		return false
	end
	if not succeeded then
		return commandFailure(groupName, "sensor-state transition")
	end
	return true
end
