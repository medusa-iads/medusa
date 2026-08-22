require("_header")
require("services.Services")
require("core.Constants")

Medusa.Services.MissionUnitSkillIndex = {}

do
	local Index = Medusa.Services.MissionUnitSkillIndex
	local C = Medusa.Constants
	local DCS_SKILL = {
		Average = C.CrewSkill.AVERAGE,
		Good = C.CrewSkill.GOOD,
		High = C.CrewSkill.HIGH,
		Excellent = C.CrewSkill.EXCELLENT,
	}
	local EMPTY = {}
	local function tableOrEmpty(value)
		return type(value) == "table" and value or EMPTY
	end
	local function indexUnits(byUnitName, units)
		for _, unit in pairs(tableOrEmpty(units)) do
			local skill = type(unit) == "table" and DCS_SKILL[unit.skill] or nil
			if skill and type(unit.name) == "string" then
				byUnitName[unit.name] = skill
			end
		end
	end

	local function indexCountry(byUnitName, country)
		local vehicle = type(country) == "table" and country.vehicle or nil
		local groups = type(vehicle) == "table" and vehicle.group or nil
		for _, group in pairs(tableOrEmpty(groups)) do
			indexUnits(byUnitName, type(group) == "table" and group.units or nil)
		end
	end

	function Index.new(mission)
		local byUnitName = {}
		local coalitions = type(mission) == "table" and mission.coalition or nil
		for _, coalitionData in pairs(tableOrEmpty(coalitions)) do
			local countries = type(coalitionData) == "table" and coalitionData.country or nil
			for _, country in pairs(tableOrEmpty(countries)) do
				indexCountry(byUnitName, country)
			end
		end
		return setmetatable({ _byUnitName = byUnitName }, { __index = Index })
	end

	function Index:get(unitName)
		return self._byUnitName[unitName]
	end
end
