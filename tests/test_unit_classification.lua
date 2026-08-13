local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Battery")
require("entities.SensorUnit")
require("entities.C2Node")
require("services.Services")
require("services.stores.BatteryStore")
require("services.stores.SensorUnitStore")
require("services.stores.C2NodeStore")
require("services.EntityFactory")

local ulidCounter = 0
local origGetGroupUnits, origGetUnitDesc, origGetUnitID, origGetUnitType, origGetUnitPosition, origGetUnitHeading
local origGetUnitAmmo

local function makeMockUnit(id, name)
	return {
		getID = function()
			return id
		end,
		getName = function()
			return name
		end,
		getPosition = function()
			return { p = { x = 100, y = 50, z = 200 } }
		end,
	}
end

local function makeStores()
	local repository = Medusa.Services.BatteryStore:new()
	return {
		batteries = repository:batteries(),
		manpads = repository:manpads(),
		sensors = Medusa.Services.SensorUnitStore:new(),
		c2Nodes = Medusa.Services.C2NodeStore:new(),
	}
end

local function makeDTO(roles)
	return {
		groupId = 1,
		groupName = "test.group",
		parsed = { roles = roles or {}, echelonPath = {}, isHQ = false },
	}
end

local function setupInventoryTest(attributeSets)
	local units = {}
	local attributesByUnit = {}
	for i = 1, #attributeSets do
		local unit = makeMockUnit(i, "unit-" .. i)
		units[i] = unit
		attributesByUnit[unit] = attributeSets[i]
	end
	GetGroupUnits = function()
		return units
	end
	GetUnitID = function(unit)
		return unit:getID()
	end
	GetUnitType = function(value)
		return type(value) == "table" and value:getName() or value
	end
	GetUnitPosition = function()
		return { x = 100, y = 0, z = 200 }
	end
	GetUnitHeading = function()
		return 0
	end
	GetUnitAmmo = function()
		return {}
	end
	GetUnitDesc = function(unit)
		return { displayName = unit:getName(), attributes = attributesByUnit[unit] }
	end
end

local function setupClassificationTest(attributes, includeLauncher)
	local attributeSets = { attributes }
	if includeLauncher ~= false then
		attributeSets[2] = { ["SAM LL"] = true }
	end
	setupInventoryTest(attributeSets)
end

TestUnitClassification = {}

function TestUnitClassification:setUp()
	ulidCounter = 0
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
	origGetGroupUnits = GetGroupUnits
	origGetUnitDesc = GetUnitDesc
	origGetUnitID = GetUnitID
	origGetUnitType = GetUnitType
	origGetUnitPosition = GetUnitPosition
	origGetUnitHeading = GetUnitHeading
	origGetUnitAmmo = GetUnitAmmo
end

function TestUnitClassification:tearDown()
	GetGroupUnits = origGetGroupUnits
	GetUnitDesc = origGetUnitDesc
	GetUnitID = origGetUnitID
	GetUnitType = origGetUnitType
	GetUnitPosition = origGetUnitPosition
	GetUnitHeading = origGetUnitHeading
	GetUnitAmmo = origGetUnitAmmo
end

function TestUnitClassification:test_classifies_tlar_radar_launcher()
	setupClassificationTest({ ["AA_missile"] = true, ["SAM SR"] = true, ["SAM TR"] = true })
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	local battery = stores.batteries:getAll()[1]
	lu.assertEquals(battery.Units[1].Roles[1], "TLAR")
end

function TestUnitClassification:test_classifies_tlar_ir_guided()
	setupClassificationTest({ ["AA_missile"] = true, ["SR SAM"] = true, ["IR Guided SAM"] = true })
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	local battery = stores.batteries:getAll()[1]
	lu.assertEquals(battery.Units[1].Roles[1], "TLAR")
end

function TestUnitClassification:test_classifies_telar()
	setupClassificationTest({ ["SAM TR"] = true, ["SAM LL"] = true })
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	local battery = stores.batteries:getAll()[1]
	lu.assertEquals(battery.Units[1].Roles[1], "TELAR")
end

function TestUnitClassification:test_classifies_track_radar()
	setupClassificationTest({ ["SAM TR"] = true })
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	local battery = stores.batteries:getAll()[1]
	lu.assertEquals(battery.Units[1].Roles[1], "TRACK_RADAR")
end

function TestUnitClassification:test_classifies_launcher()
	setupClassificationTest({ ["SAM LL"] = true })
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	local battery = stores.batteries:getAll()[1]
	lu.assertEquals(battery.Units[1].Roles[1], "LAUNCHER")
end

function TestUnitClassification:test_classifies_command_post()
	setupClassificationTest({ ["SAM CC"] = true })
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	local battery = stores.batteries:getAll()[1]
	lu.assertEquals(battery.Units[1].Roles[1], "COMMAND_POST")
end

function TestUnitClassification:test_classifies_search_radar()
	setupClassificationTest({ ["SAM SR"] = true })
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	local battery = stores.batteries:getAll()[1]
	lu.assertEquals(battery.Units[1].Roles[1], "SEARCH_RADAR")
end

function TestUnitClassification:test_classifies_other_no_sam_attrs()
	setupClassificationTest({ ["Trucks"] = true })
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	local battery = stores.batteries:getAll()[1]
	lu.assertEquals(battery.Units[1].Roles[1], "OTHER")
end

function TestUnitClassification:test_battery_role_lr_sam()
	setupClassificationTest({ ["LR SAM"] = true, ["SAM TR"] = true })
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	local battery = stores.batteries:getAll()[1]
	lu.assertEquals(battery.Role, "LR_SAM")
end

function TestUnitClassification:test_battery_role_mr_sam()
	setupClassificationTest({ ["MR SAM"] = true, ["SAM TR"] = true })
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	local battery = stores.batteries:getAll()[1]
	lu.assertEquals(battery.Role, "MR_SAM")
end

function TestUnitClassification:test_battery_role_sr_sam()
	setupClassificationTest({ ["SR SAM"] = true, ["SAM TR"] = true })
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	local battery = stores.batteries:getAll()[1]
	lu.assertEquals(battery.Role, "SR_SAM")
end

function TestUnitClassification:test_battery_role_aaa()
	setupClassificationTest({ ["AAA"] = true }, false)
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	local battery = stores.batteries:getAll()[1]
	lu.assertEquals(battery.Role, "AAA")
end

function TestUnitClassification:test_battery_role_defaults_generic()
	setupClassificationTest({ ["Trucks"] = true })
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	local battery = stores.batteries:getAll()[1]
	lu.assertEquals(battery.Role, "GENERIC_SAM")
end

function TestUnitClassification:test_aaa_search_ratio_is_independent_of_unit_order()
	local arrangements = {
		{ { AAA = true }, { AAA = true }, { ["SAM SR"] = true } },
		{ { ["SAM SR"] = true }, { AAA = true }, { AAA = true } },
	}
	for i = 1, #arrangements do
		setupInventoryTest(arrangements[i])
		local stores = makeStores()
		local kind = Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
		lu.assertEquals(kind, "battery")
		lu.assertEquals(stores.batteries:getAll()[1].Role, Medusa.Constants.BatteryRole.AAA)
	end
end

function TestUnitClassification:test_aaa_group_below_search_ratio_is_ewr()
	setupInventoryTest({
		{ AAA = true },
		{ AAA = true },
		{ AAA = true },
		{ ["SAM SR"] = true },
		{ EWR = true },
	})
	local stores = makeStores()
	local kind = Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	lu.assertEquals(kind, "sensor")
	lu.assertEquals(stores.sensors:count(), 2)
end

function TestUnitClassification:test_manpad_wins_tie_with_aaa()
	setupInventoryTest({ { MANPADS = true }, { AAA = true } })
	local stores = makeStores()
	local kind = Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	lu.assertEquals(kind, "manpad")
	lu.assertEquals(stores.manpads:count(), 1)
end

function TestUnitClassification:test_aaa_wins_when_it_outnumbers_manpads()
	setupInventoryTest({ { MANPADS = true }, { AAA = true }, { AAA = true } })
	local stores = makeStores()
	local kind = Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	lu.assertEquals(kind, "battery")
	lu.assertEquals(stores.batteries:getAll()[1].Role, Medusa.Constants.BatteryRole.AAA)
end

function TestUnitClassification:test_track_radar_does_not_count_as_search_radar()
	setupInventoryTest({ { AAA = true }, { ["SAM TR"] = true } })
	local stores = makeStores()
	local kind = Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	lu.assertEquals(kind, "battery")
	lu.assertEquals(stores.batteries:getAll()[1].Role, Medusa.Constants.BatteryRole.AAA)
end

function TestUnitClassification:test_launcher_takes_precedence_over_aaa_inventory()
	setupInventoryTest({
		{ AAA = true },
		{ AAA = true },
		{ ["SAM LL"] = true, ["SR SAM"] = true },
	})
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(makeDTO({ "EWR" }), stores, "net1")
	lu.assertEquals(stores.batteries:getAll()[1].Role, Medusa.Constants.BatteryRole.SR_SAM)
end

function TestUnitClassification:test_multi_role_unit_retains_aaa_and_search_roles()
	setupInventoryTest({ { AAA = true, ["SAM SR"] = true }, { AAA = true } })
	local stores = makeStores()
	Medusa.Services.EntityFactory.createFromDTO(makeDTO(), stores, "net1")
	local battery = stores.batteries:getAll()[1]
	local roles = battery.Units[1].Roles
	local present = {}
	for i = 1, #roles do
		present[roles[i]] = true
	end
	lu.assertTrue(present[Medusa.Constants.BatteryUnitRole.AAA])
	lu.assertTrue(present[Medusa.Constants.BatteryUnitRole.SEARCH_RADAR])
	lu.assertEquals(battery.SystemType, "UNKNOWN")
end
