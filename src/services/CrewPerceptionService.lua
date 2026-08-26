require("_header")
require("services.Services")
require("core.Constants")
require("entities.Battery")

--[[
    CREW PERCEPTION SERVICE

    What this service does
    - Models whether a ground group can see or hear an aircraft.
    - Refreshes mobile group positions and unit headings used by visual detection.

    How others use it
    - MANPAD and AAA services apply their own response policy after a detection.
--]]

Medusa.Services.CrewPerceptionService = {}

local D = Medusa.Constants.LocalAircraftDetection

Medusa.Services.CrewPerceptionService.PRIMARY_PROFILE = {
	RangeM = D.PRIMARY_RANGE_M,
	CosHalfAngle = D.PRIMARY_COS_HALF_ANGLE,
}

function Medusa.Services.CrewPerceptionService.headingBearingDegrees(heading)
	local bearing = math.deg(math.atan2(heading.hx, heading.hz))
	if bearing < 0 then
		bearing = bearing + 360
	end
	return bearing
end

function Medusa.Services.CrewPerceptionService.rebuildHeadings(battery, observerState, unitRole)
	local headings = observerState.UnitHeadings or {}
	observerState.UnitHeadings = headings
	local written = 0
	local units = battery.Units or {}
	for i = 1, #units do
		local unit = units[i]
		unit.HeadingIndex = nil
		if Medusa.Entities.Battery.unitHasRole(unit, unitRole) and unit.UnitName then
			local headingDegrees = GetUnitHeading(unit.UnitName)
			if headingDegrees then
				local radians = math.rad(headingDegrees)
				written = written + 1
				unit.HeadingDegrees = headingDegrees
				unit.HeadingIndex = written
				local heading = headings[written]
				if not heading then
					heading = {}
					headings[written] = heading
				end
				heading.hx = math.cos(radians)
				heading.hz = math.sin(radians)
			end
		end
	end
	for i = #headings, written + 1, -1 do
		headings[i] = nil
	end
	observerState.UnitHeadingCount = written
end

local function refreshUnitHeading(battery, unit)
	local observerState
	local unitRole
	if battery.Role == Medusa.Constants.BatteryRole.AAA then
		observerState = battery.Aaa
		unitRole = Medusa.Constants.BatteryUnitRole.AAA
	elseif battery.Role == Medusa.Constants.BatteryRole.MANPAD then
		observerState = battery.Manpad
		unitRole = Medusa.Constants.BatteryUnitRole.MANPAD
	end
	if not observerState or not Medusa.Entities.Battery.unitHasRole(unit, unitRole) then
		return false
	end
	local headingDegrees = GetUnitHeading(unit.UnitName)
	if not headingDegrees then
		return false
	end
	local index = unit.HeadingIndex
	if not index then
		index = (observerState.UnitHeadingCount or 0) + 1
		unit.HeadingIndex = index
		observerState.UnitHeadingCount = index
	end
	local headings = observerState.UnitHeadings
	local heading = headings[index]
	if not heading then
		heading = {}
		headings[index] = heading
	end
	local radians = math.rad(headingDegrees)
	unit.HeadingDegrees = headingDegrees
	heading.hx = math.cos(radians)
	heading.hz = math.sin(radians)
	return true
end

function Medusa.Services.CrewPerceptionService.hears(observerPosition, targetPosition, rangeM)
	if not observerPosition or not targetPosition or not rangeM or rangeM <= 0 then
		return false
	end
	local dx = targetPosition.x - observerPosition.x
	local dy = targetPosition.y - observerPosition.y
	local dz = targetPosition.z - observerPosition.z
	return dx * dx + dy * dy + dz * dz <= rangeM * rangeM
end

function Medusa.Services.CrewPerceptionService.canSee(observerPosition, targetPosition, observerState, profiles)
	if not observerPosition or not targetPosition then
		return false
	end
	if targetPosition.y - observerPosition.y > D.RELATIVE_ALTITUDE_CEILING_M then
		return false
	end

	local dx = targetPosition.x - observerPosition.x
	local dz = targetPosition.z - observerPosition.z
	local distanceSquared = dx * dx + dz * dz
	local maxRange = 0
	for i = 1, #profiles do
		if profiles[i].RangeM > maxRange then
			maxRange = profiles[i].RangeM
		end
	end
	if distanceSquared > maxRange * maxRange then
		return false
	end
	if distanceSquared < 1 then
		return true
	end

	local inverseDistance = 1 / math.sqrt(distanceSquared)
	local targetX = dx * inverseDistance
	local targetZ = dz * inverseDistance
	local headings = observerState.UnitHeadings or {}
	local headingCount = observerState.UnitHeadingCount or 0
	for i = 1, headingCount do
		local heading = headings[i]
		local dot = heading.hx * targetX + heading.hz * targetZ
		for j = 1, #profiles do
			local profile = profiles[j]
			if distanceSquared <= profile.RangeM * profile.RangeM and dot >= profile.CosHalfAngle then
				return true
			end
		end
	end
	return false
end

local function nextBatteryAfter(batteries, batteryId)
	local first = nil
	local nextBattery = nil
	for i = 1, #batteries do
		local battery = batteries[i]
		if not first or battery.BatteryId < first.BatteryId then
			first = battery
		end
		if batteryId and battery.BatteryId > batteryId and (not nextBattery or battery.BatteryId < nextBattery.BatteryId) then
			nextBattery = battery
		end
	end
	return nextBattery or first
end

function Medusa.Services.CrewPerceptionService.refreshOne(ctx)
	if #ctx.batteries == 0 then
		return ctx.cursorBatteryId, false
	end
	local battery = nextBatteryAfter(ctx.batteries, ctx.cursorBatteryId)
	local cursorBatteryId = battery.BatteryId
	local observerState = battery[ctx.stateField]
	local lastRefresh = observerState.LastPositionRefreshTime
	if lastRefresh and ctx.now - lastRefresh < D.POSITION_REFRESH_MIN_INTERVAL_SEC then
		return cursorBatteryId, false
	end

	local units = battery.Units or {}
	local position = nil
	for i = 1, #units do
		if Medusa.Entities.Battery.unitHasRole(units[i], ctx.unitRole) and units[i].UnitName then
			position = GetUnitPosition(units[i].UnitName)
			if position then
				break
			end
		end
	end
	if not position then
		return cursorBatteryId, false
	end

	battery.Position = position
	ctx.geoGrid:updatePosition(battery.BatteryId, position, ctx.geoGridType)
	observerState.LastPositionRefreshTime = ctx.now
	Medusa.Services.CrewPerceptionService.rebuildHeadings(battery, observerState, ctx.unitRole)
	return cursorBatteryId, true
end

--- Visits at most ctx.budget observer units and returns position-refresh counts by owner type.
function Medusa.Services.CrewPerceptionService.refreshUnitPositions(ctx)
	local visited = 0
	local refreshed = 0
	local aaaRefreshed = 0
	local manpadRefreshed = 0
	while visited < ctx.budget do
		local battery, unit = ctx.batteryRepository:nextUnitForPositionRefresh()
		if not unit then
			break
		end
		visited = visited + 1
		local lastRefresh = unit.LastPositionRefreshTime
		if unit.UnitName and (not lastRefresh or ctx.now - lastRefresh >= D.POSITION_REFRESH_MIN_INTERVAL_SEC) then
			local health = GetUnitHealth(unit.UnitName)
			if health and health.IsAlive == false then
				ctx.onUnitConfirmedDead(battery, unit)
			else
				local position = GetUnitPosition(unit.UnitName)
				unit.LastPositionRefreshTime = ctx.now
				if position then
					unit.Position = position
					local headingRefreshed = refreshUnitHeading(battery, unit)
					ctx.spatialIndex:syncSuppressibleUnit(unit)
					if battery.PositionAnchorUnitId == unit.UnitId then
						battery.Position = position
						ctx.spatialIndex:syncBattery(battery)
					end
					refreshed = refreshed + 1
					if headingRefreshed and battery.Role == Medusa.Constants.BatteryRole.AAA then
						aaaRefreshed = aaaRefreshed + 1
					elseif headingRefreshed and battery.Role == Medusa.Constants.BatteryRole.MANPAD then
						manpadRefreshed = manpadRefreshed + 1
					end
				end
			end
		end
	end
	return visited, refreshed, aaaRefreshed, manpadRefreshed
end
