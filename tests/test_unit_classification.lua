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

-- == Helpers ==

local ulidCounter = 0
local origGetGroupUnits, origGetUnitDesc, origGetUnitID, origGetUnitType, origGetUnitPosition, origGetUnitAmmo

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
	return {
		batteries = Medusa.Services.BatteryStore:new(),
		sensors = Medusa.Services.SensorUnitStore:new(),
		c2Nodes = Medusa.Services.C2NodeStore:new(),
	}
end

local function makeDTO()
	return {
		groupId = 1,
		groupName = "test.group",
		parsed = { roles = {}, echelonPath = {}, isHQ = false },
	}
end

local launcherUnit = makeMockUnit(2, "launcher-unit")

local function setupClassificationTest(attributes)
	local testUnit = makeMockUnit(1, "test-unit")
	GetGroupUnits = function()
		return { testUnit, launcherUnit }
	end
	local nextId = 0
	GetUnitID = function()
		nextId = nextId + 1
		return nextId
	end
	GetUnitType = function()
		return "TestType"
	end
	GetUnitPosition = function()
		return { x = 100, y = 0, z = 200 }
	end
	GetUnitAmmo = function()
		return {}
	end
	GetUnitDesc = function(unit)
		if unit == launcherUnit then
			return { attributes = { ["SAM LL"] = true } }
		end
		return { attributes = attributes }
	end
end

-- == Tests ==

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
	origGetUnitAmmo = GetUnitAmmo
end

function TestUnitClassification:tearDown()
	GetGroupUnits = origGetGroupUnits
	GetUnitDesc = origGetUnitDesc
	GetUnitID = origGetUnitID
	GetUnitType = origGetUnitType
	GetUnitPosition = origGetUnitPosition
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
	setupClassificationTest({ ["AAA"] = true })
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
