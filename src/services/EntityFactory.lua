require("_header")
require("services.Services")
require("core.Logger")
require("entities.Battery")
require("entities.SensorUnit")
require("entities.C2Node")

--[[
            ███████╗███╗   ██╗████████╗██╗████████╗██╗   ██╗    ███████╗ █████╗  ██████╗████████╗ ██████╗ ██████╗ ██╗   ██╗
            ██╔════╝████╗  ██║╚══██╔══╝██║╚══██╔══╝╚██╗ ██╔╝    ██╔════╝██╔══██╗██╔════╝╚══██╔══╝██╔═══██╗██╔══██╗╚██╗ ██╔╝
            █████╗  ██╔██╗ ██║   ██║   ██║   ██║    ╚████╔╝     █████╗  ███████║██║        ██║   ██║   ██║██████╔╝ ╚████╔╝
            ██╔══╝  ██║╚██╗██║   ██║   ██║   ██║     ╚██╔╝      ██╔══╝  ██╔══██║██║        ██║   ██║   ██║██╔══██╗  ╚██╔╝
            ███████╗██║ ╚████║   ██║   ██║   ██║      ██║       ██║     ██║  ██║╚██████╗   ██║   ╚██████╔╝██║  ██║   ██║
            ╚══════╝╚═╝  ╚═══╝   ╚═╝   ╚═╝   ╚═╝      ╚═╝       ╚═╝     ╚═╝  ╚═╝ ╚═════╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝   ╚═╝

    What this service does
    - Converts discovered group DTOs into Battery, SensorUnit, or C2Node entities.
    - Classifies individual unit roles (launcher, search radar, track radar, TELAR, TLAR) from DCS attributes.
    - Reads ammo data, weapon ranges, and HARM-capable system counts during battery creation.

    How others use it
    - IadsNetwork's discovery listener calls createFromDTO to populate the battery, sensor, and C2 stores.
--]]

Medusa.Services.EntityFactory = {}

local logger = Medusa.Logger:ns("EntityFactory")
local BUR = Medusa.Constants.BatteryUnitRole
local Role = Medusa.Constants.Role
local launcherRoles = Medusa.Constants.LAUNCHER_ROLES

local function classifyDTO(dto)
	local roles = dto.parsed.roles
	for i = 1, #roles do
		if roles[i] == Role.GCI or roles[i] == Role.EWR or roles[i] == Role.AWACS then
			return "sensor"
		end
	end
	if dto.parsed.isHQ then
		return "hq"
	end
	return "battery"
end

local function getUnitName(unit)
	local ok, name = pcall(unit.getName, unit)
	if ok then
		return name
	end
	return nil
end

local function classifyUnitRole(desc)
	if not desc or not desc.attributes then
		return Medusa.Constants.BatteryUnitRole.OTHER
	end
	local a = desc.attributes

	-- TLAR: self-contained radar + launcher (SA-15 Tor, SA-8 Osa)
	if a["AA_missile"] and a["SAM SR"] and a["SAM TR"] then
		return BUR.TLAR
	end
	-- TLAR: IR-guided self-contained (SA-13, SA-9)
	if a["AA_missile"] and a["SR SAM"] and a["IR Guided SAM"] then
		return BUR.TLAR
	end
	if a["SAM TR"] and a["SAM LL"] then
		return BUR.TELAR
	end
	if a["SAM TR"] then
		return BUR.TRACK_RADAR
	end
	if a["SAM LL"] then
		return BUR.LAUNCHER
	end
	if a["SAM CC"] then
		return BUR.COMMAND_POST
	end
	if a["SAM SR"] then
		return BUR.SEARCH_RADAR
	end
	if a["EWR"] then
		return BUR.SEARCH_RADAR
	end
	return BUR.OTHER
end

local function classifyBatteryRole(desc)
	if not desc or not desc.attributes then
		return nil
	end
	local a = desc.attributes
	local BR = Medusa.Constants.BatteryRole

	if a["LR SAM"] then
		return BR.LR_SAM
	end
	if a["MR SAM"] then
		return BR.MR_SAM
	end
	if a["SR SAM"] then
		return BR.SR_SAM
	end
	if a["AAA"] then
		return BR.AAA
	end
	if a["SAM"] then
		return BR.GENERIC_SAM
	end
	return nil
end

-- selene: allow(undefined_variable)
local _weaponRangeOverrides = (type(MEDUSA_CONFIG) == "table" and type(MEDUSA_CONFIG.WeaponRangeOverrides) == "table")
		and MEDUSA_CONFIG.WeaponRangeOverrides
	or nil

local function resolveWeaponRange(typeName, dcsRange)
	if not _weaponRangeOverrides or not typeName then
		return dcsRange
	end
	for key, range in pairs(_weaponRangeOverrides) do
		if string.find(typeName, key, 1, true) then
			return range
		end
	end
	return dcsRange
end

function Medusa.Services.EntityFactory.extractAmmo(unitName)
	local ammoTable = GetUnitAmmo(unitName)
	if not ammoTable or #ammoTable == 0 then
		return nil, 0
	end

	-- Prefer missiles; fall back to guns if no missiles (e.g., Pantsir out of SAMs)
	local missiles = {}
	local guns = {}
	for i = 1, #ammoTable do
		local entry = ammoTable[i]
		if entry.count and entry.count > 0 and entry.desc then
			local dcsRange = math.max(entry.desc.rangeMaxAltMax or 0, entry.desc.rangeMaxAltMin or 0)
			local rangeMax = resolveWeaponRange(entry.desc.typeName, dcsRange)
			local ammoEntry = {
				WeaponTypeName = entry.desc.typeName,
				WeaponDisplayName = entry.desc.displayName,
				Count = entry.count,
				RangeMax = rangeMax,
				RangeMin = entry.desc.rangeMin,
				AltMax = entry.desc.altMax,
				AltMin = entry.desc.altMin,
				Nmax = entry.desc.Nmax,
			}
			if entry.desc.missileCategory then
				missiles[#missiles + 1] = ammoEntry
			elseif dcsRange > 0 then
				guns[#guns + 1] = ammoEntry
			end
		end
	end

	local ammoTypes = #missiles > 0 and missiles or guns
	local totalCount = 0
	for i = 1, #ammoTypes do
		totalCount = totalCount + ammoTypes[i].Count
	end

	if #ammoTypes == 0 then
		return nil, 0
	end
	return ammoTypes, totalCount
end

local function createSensors(dto, stores, networkId)
	local units = GetGroupUnits(dto.groupName)
	if not units or #units == 0 then
		logger:error(string.format("no units in sensor group '%s'", dto.groupName))
		return "sensor", 0
	end

	local sensorType = "EWR"
	local isAwacs = false
	for i = 1, #dto.parsed.roles do
		if dto.parsed.roles[i] == Role.GCI then
			sensorType = "GCI"
			break
		elseif dto.parsed.roles[i] == Role.AWACS then
			sensorType = "AWACS"
			isAwacs = true
			break
		end
	end

	-- AWACS groups must be aircraft with the AWACS attribute
	if isAwacs then
		local firstUnit = units[1]
		local desc = GetUnitDesc(firstUnit)
		if not desc or not desc.attributes or not desc.attributes["AWACS"] then
			logger:error(string.format("AWACS group '%s' does not have AWACS attribute, skipping", dto.groupName))
			return "sensor", 0
		end
	end

	local hierarchyPath = dto.parsed.echelonPath and table.concat(dto.parsed.echelonPath, ".") or nil
	local count = 0

	for i = 1, #units do
		local unitId = GetUnitID(units[i])
		if unitId then
			local unitName = getUnitName(units[i])
			local unitTypeName = unitName and GetUnitType(unitName) or nil
			local position = GetUnitPosition(units[i])
			local sensor = Medusa.Entities.SensorUnit.new({
				NetworkId = networkId,
				UnitId = unitId,
				UnitName = unitName or string.format("%s-%d", dto.groupName, i),
				UnitTypeName = unitTypeName,
				GroupId = dto.groupId,
				GroupName = dto.groupName,
				SensorType = sensorType,
				Position = position,
				HierarchyPath = hierarchyPath,
				IsAirborne = isAwacs,
			})
			stores.sensors:add(sensor)
			count = count + 1
		end
	end

	return "sensor", count
end

local function createHQ(dto, stores, networkId)
	local position = nil
	local units = GetGroupUnits(dto.groupName)
	if units and units[1] then
		position = GetUnitPosition(units[1])
	end

	local echelonName = nil
	if dto.parsed.echelonPath and #dto.parsed.echelonPath > 0 then
		echelonName = dto.parsed.echelonPath[1]
	end

	local node = Medusa.Entities.C2Node.new({
		NetworkId = networkId,
		NodeName = dto.groupName,
		EchelonName = echelonName,
		Position = position,
	})
	stores.c2Nodes:add(node)
	return "hq", 1
end

local function createBatteryUnit(unit, batteryRole)
	local unitName = getUnitName(unit)
	local unitTypeName = unitName and GetUnitType(unitName) or nil
	local desc = GetUnitDesc(unit)
	local role = classifyUnitRole(desc)
	local resolvedBatteryRole = batteryRole or classifyBatteryRole(desc)

	local ammoTypes, ammoCount = nil, 0
	if launcherRoles[role] and unitName then
		ammoTypes, ammoCount = Medusa.Services.EntityFactory.extractAmmo(unitName)
	end

	local batteryUnit = Medusa.Entities.Battery.newUnit({
		UnitId = GetUnitID(unit),
		UnitName = unitName,
		UnitTypeName = unitTypeName,
		DisplayName = desc and desc.displayName or nil,
		Roles = { role },
		AmmoCount = ammoCount,
		AmmoTypes = ammoTypes,
	})
	logger:debug(string.format("[%s] role=%s, ammo=%d", unitTypeName or "unknown", role, ammoCount))
	return batteryUnit, resolvedBatteryRole
end

local function matchesHarmCapableSystem(typeName, harmSystems)
	if not typeName or not harmSystems then
		return nil
	end
	for i = 1, #harmSystems do
		local key = harmSystems[i]
		if string.find(typeName, key, 1, true) then
			return key
		end
	end
	return nil
end

function Medusa.Services.EntityFactory.computeHarmCapableCount(battery, harmSystems)
	if not battery.Units or not harmSystems or #harmSystems == 0 then
		return 0
	end
	local tlarRole = BUR.TLAR
	local llRole = BUR.LAUNCHER
	local count = 0

	-- Collect which system keys each role category matches
	local srKeys = {}
	local trKeys = {}
	local llKeys = {}

	for i = 1, #battery.Units do
		local unit = battery.Units[i]
		local matched = matchesHarmCapableSystem(unit.UnitTypeName, harmSystems)
		if matched then
			local roles = unit.Roles
			for j = 1, #roles do
				local r = roles[j]
				if r == tlarRole then
					count = count + Medusa.Constants.HARM_DEFEND_WEIGHT_TLAR
				elseif r == BUR.SEARCH_RADAR then
					srKeys[matched] = true
				elseif r == BUR.TRACK_RADAR then
					trKeys[matched] = true
				elseif r == BUR.TELAR then
					trKeys[matched] = true
					llKeys[matched] = (llKeys[matched] or 0) + Medusa.Constants.HARM_DEFEND_WEIGHT_LAUNCHER
				elseif r == llRole then
					llKeys[matched] = (llKeys[matched] or 0) + Medusa.Constants.HARM_DEFEND_WEIGHT_LAUNCHER
				end
			end
		end
	end

	-- Composite batteries: all required components must share the same key
	for key, llCount in pairs(llKeys) do
		if srKeys[key] and trKeys[key] then
			count = count + llCount
		end
	end

	return count
end

local function logBatteryCreation(battery)
	if not battery.WeaponRangeMax then
		return
	end
	logger:info(
		string.format(
			"battery %s: role=%s, weaponRange=%dm (%.1fnm), ammo=%d",
			battery.GroupName,
			battery.Role,
			battery.WeaponRangeMax,
			battery.WeaponRangeMax / 1852,
			battery.TotalAmmoStatus
		)
	)
end

local function hasLauncher(battery)
	for i = 1, #battery.Units do
		local roles = battery.Units[i].Roles
		if roles then
			for j = 1, #roles do
				if launcherRoles[roles[j]] then
					return true
				end
			end
		end
	end
	return false
end

local function classifySystemType(units)
	if not units or #units == 0 then
		return "UNKNOWN"
	end
	local counts = {}
	local OTHER = Medusa.Constants.BatteryUnitRole.OTHER
	for i = 1, #units do
		local roles = units[i].Roles
		if not (roles and roles[1] == OTHER) then
			local dn = units[i].DisplayName or units[i].UnitTypeName or ""
			local key = dn:match("[Ss][Aa]%-(%d+)")
			if key then
				key = "SA-" .. key
			else
				key = dn:match("[Hh][Qq]%-(%d+)")
				if key then
					key = "HQ-" .. key
				else
					key = dn:match("^(%a%a%a+)")
				end
			end
			if key then
				counts[key] = (counts[key] or 0) + 1
			end
		end
	end
	local best, bestCount = "UNKNOWN", 0
	for k, v in pairs(counts) do
		if v > bestCount then
			best, bestCount = k, v
		end
	end
	return best
end

--- Detects when launchers in a group are spread > 1 NM apart and clusters them.
--- Returns nil for tight groups (no clustering needed), or a table with cluster
--- centroids, overall centroid, and spread radius for distributed groups.
local function clusterLaunchers(dcsUnits, batteryUnits)
	local threshold = Medusa.Constants.CLUSTER_THRESHOLD_M
	-- Build a set of launcher UnitIds from batteryUnits (which may have gaps vs dcsUnits)
	local launcherInfo = {}
	for i = 1, #batteryUnits do
		local roles = batteryUnits[i].Roles
		if roles then
			for j = 1, #roles do
				if launcherRoles[roles[j]] then
					local maxRange = 0
					if batteryUnits[i].AmmoTypes then
						for k = 1, #batteryUnits[i].AmmoTypes do
							local r = batteryUnits[i].AmmoTypes[k].RangeMax or 0
							if r > maxRange then
								maxRange = r
							end
						end
					end
					launcherInfo[batteryUnits[i].UnitId] = maxRange
					break
				end
			end
		end
	end
	-- Iterate DCS unit handles directly to get positions for launchers
	local launchers = {}
	for i = 1, #dcsUnits do
		local uid = GetUnitID(dcsUnits[i])
		if uid and launcherInfo[uid] then
			local pos = GetUnitPosition(dcsUnits[i])
			if pos then
				launchers[#launchers + 1] = { pos = pos, rangeMax = launcherInfo[uid] }
			end
		end
	end
	if #launchers < 2 then
		return nil
	end
	local maxDist2 = 0
	for i = 1, #launchers do
		for j = i + 1, #launchers do
			local dx = launchers[i].pos.x - launchers[j].pos.x
			local dz = launchers[i].pos.z - launchers[j].pos.z
			local d2 = dx * dx + dz * dz
			if d2 > maxDist2 then
				maxDist2 = d2
			end
		end
	end
	if maxDist2 < threshold * threshold then
		return nil
	end
	local clustered = {}
	local clusters = {}
	for i = 1, #launchers do
		if not clustered[i] then
			local cx, cz, count = launchers[i].pos.x, launchers[i].pos.z, 1
			local clusterRange = launchers[i].rangeMax
			clustered[i] = true
			for j = i + 1, #launchers do
				if not clustered[j] then
					local dx = launchers[i].pos.x - launchers[j].pos.x
					local dz = launchers[i].pos.z - launchers[j].pos.z
					if dx * dx + dz * dz < threshold * threshold then
						cx = cx + launchers[j].pos.x
						cz = cz + launchers[j].pos.z
						count = count + 1
						if launchers[j].rangeMax > clusterRange then
							clusterRange = launchers[j].rangeMax
						end
						clustered[j] = true
					end
				end
			end
			clusters[#clusters + 1] = { x = cx / count, y = 0, z = cz / count, rangeMax = clusterRange }
		end
	end
	if #clusters < 2 then
		return nil
	end
	local allX, allZ = 0, 0
	for i = 1, #launchers do
		allX = allX + launchers[i].pos.x
		allZ = allZ + launchers[i].pos.z
	end
	local centroid = { x = allX / #launchers, y = 0, z = allZ / #launchers }
	local maxSpread2 = 0
	for i = 1, #clusters do
		local dx = clusters[i].x - centroid.x
		local dz = clusters[i].z - centroid.z
		local d2 = dx * dx + dz * dz
		if d2 > maxSpread2 then
			maxSpread2 = d2
		end
	end
	return { clusters = clusters, centroid = centroid, spreadRadius = math.sqrt(maxSpread2) }
end

local function createBattery(dto, stores, networkId, harmSystems)
	local units = GetGroupUnits(dto.groupName)
	local position = nil
	if units and units[1] then
		position = GetUnitPosition(units[1])
	end

	local battery = Medusa.Entities.Battery.new({
		NetworkId = networkId,
		GroupId = dto.groupId,
		GroupName = dto.groupName,
		Position = position,
	})

	local batteryRole = nil
	battery.Units = {}
	if units then
		for i = 1, #units do
			local unitId = GetUnitID(units[i])
			if unitId then
				local batteryUnit, resolvedRole = createBatteryUnit(units[i], batteryRole)
				batteryRole = resolvedRole
				battery.Units[#battery.Units + 1] = batteryUnit
			end
		end
	end

	local BUR_TELAR = Medusa.Constants.BatteryUnitRole.TELAR
	local BUR_CP = Medusa.Constants.BatteryUnitRole.COMMAND_POST
	for ui = 1, #battery.Units do
		local roles = battery.Units[ui].Roles
		if roles then
			for ri = 1, #roles do
				if roles[ri] == BUR_TELAR then
					battery.HasTelar = true
				elseif roles[ri] == BUR_CP then
					battery.HasCommandPost = true
				end
			end
		end
	end

	if not hasLauncher(battery) then
		logger:debug(string.format("skipping group '%s': no launcher units", dto.groupName))
		return "skipped", 0
	end

	local clusterResult = clusterLaunchers(units, battery.Units)
	if clusterResult then
		battery.Clusters = clusterResult.clusters
		battery.Position = clusterResult.centroid
		battery.ClusterSpreadRadius = clusterResult.spreadRadius
		logger:info(
			string.format(
				"battery %s: %d launcher clusters detected (spread=%.0fm)",
				dto.groupName,
				#clusterResult.clusters,
				clusterResult.spreadRadius
			)
		)
	end

	battery.Role = batteryRole or Medusa.Constants.BatteryRole.GENERIC_SAM
	battery.SystemType = classifySystemType(battery.Units)
	local defaults = Medusa.Constants.SystemTypeDefaults[battery.Role]
	if defaults then
		battery.AmmoDepletedBehavior = defaults.AmmoDepletedBehavior
	end
	Medusa.Entities.Battery.recomputeEnvelope(battery)
	if
		battery.Role == Medusa.Constants.BatteryRole.LR_SAM
		and battery.WeaponRangeMax
		and battery.WeaponRangeMax > Medusa.Constants.VLR_THRESHOLD_M
	then
		battery.Role = Medusa.Constants.BatteryRole.VLR_SAM
		local vlrDefaults = Medusa.Constants.SystemTypeDefaults[battery.Role]
		if vlrDefaults then
			battery.AmmoDepletedBehavior = vlrDefaults.AmmoDepletedBehavior
		end
	end
	if not battery.WeaponRangeMax or battery.WeaponRangeMax <= 0 then
		logger:info(
			string.format(
				"battery %s has launchers but no weapon range (DCS descriptor may be missing range data)",
				battery.GroupName
			)
		)
	end
	battery.HarmCapableUnitCount = Medusa.Services.EntityFactory.computeHarmCapableCount(battery, harmSystems)
	logger:debug(string.format("battery %s: HarmCapableUnitCount=%d", battery.GroupName, battery.HarmCapableUnitCount))
	stores.batteries:add(battery)
	logBatteryCreation(battery)
	return "battery", 1
end

local function hasOnlyRadarUnits(groupName)
	local units = GetGroupUnits(groupName)
	if not units or #units == 0 then
		return false
	end
	local hasRadar = false
	local foundLauncher = false
	for i = 1, #units do
		local desc = GetUnitDesc(units[i])
		local role = classifyUnitRole(desc)
		if role == BUR.LAUNCHER or role == BUR.TLAR or role == BUR.TELAR then
			foundLauncher = true
			break
		end
		if role == BUR.SEARCH_RADAR then
			hasRadar = true
		end
	end
	return hasRadar and not foundLauncher
end

function Medusa.Services.EntityFactory.createFromDTO(dto, stores, networkId, harmSystems, doctrine)
	local classification = classifyDTO(dto)

	if classification == "sensor" then
		return createSensors(dto, stores, networkId)
	elseif classification == "hq" then
		createHQ(dto, stores, networkId)
		-- HQ groups with search radars also become sensors
		if (not doctrine or doctrine.AutoDiscoverEwrs ~= false) and hasOnlyRadarUnits(dto.groupName) then
			local _, sensorCount = createSensors(dto, stores, networkId)
			if sensorCount > 0 then
				logger:info(string.format("HQ '%s' also registered %d sensor(s)", dto.groupName, sensorCount))
			end
		end
		return "hq", 1
	end

	-- AutoDiscoverEwrs: groups with radars but no launchers become sensors
	if (not doctrine or doctrine.AutoDiscoverEwrs ~= false) and hasOnlyRadarUnits(dto.groupName) then
		logger:info(string.format("auto-discovered EWR group '%s' (radars, no launchers)", dto.groupName))
		return createSensors(dto, stores, networkId)
	end

	return createBattery(dto, stores, networkId, harmSystems)
end
