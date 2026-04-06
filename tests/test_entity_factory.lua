local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("services.Services")
require("entities.Entities")
require("entities.Battery")
require("entities.SensorUnit")
require("entities.C2Node")
require("services.stores.SensorUnitStore")
require("services.stores.BatteryStore")
require("services.stores.C2NodeStore")
require("services.EntityFactory")

-- == Helpers ==

local ulidCounter = 0
local origGetGroupUnits

local function makeMockUnit(id, name, desc)
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
		getDesc = function()
			return desc or {}
		end,
	}
end

local function makeStores()
	return {
		sensors = Medusa.Services.SensorUnitStore:new(),
		batteries = Medusa.Services.BatteryStore:new(),
		c2Nodes = Medusa.Services.C2NodeStore:new(),
	}
end

local function makeDTO(overrides)
	local base = {
		groupName = "SAM-SA6-1",
		groupId = 100,
		parsed = {
			isManaged = true,
			roles = {},
			isHQ = false,
			echelonPath = { "Division", "Brigade" },
		},
	}
	if overrides then
		for k, v in pairs(overrides) do
			if k == "parsed" then
				for pk, pv in pairs(v) do
					base.parsed[pk] = pv
				end
			else
				base[k] = v
			end
		end
	end
	return base
end

-- == Tests ==

TestEntityFactory = {}

function TestEntityFactory:setUp()
	ulidCounter = 0
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
	origGetGroupUnits = GetGroupUnits
	-- Default mock: two units with unique IDs; first unit has launcher attributes
	-- so the battery is not skipped by the hasLauncher guard.
	GetGroupUnits = function()
		return {
			makeMockUnit(101, "unit-1", { attributes = { ["SAM LL"] = true } }),
			makeMockUnit(102, "unit-2"),
		}
	end
end

function TestEntityFactory:tearDown()
	GetGroupUnits = origGetGroupUnits
end

function TestEntityFactory:test_battery_classification()
	local stores = makeStores()
	local dto = makeDTO()

	local kind, count = Medusa.Services.EntityFactory.createFromDTO(dto, stores, "net-1")

	lu.assertEquals(kind, "battery")
	lu.assertEquals(count, 1)
	lu.assertEquals(stores.batteries:count(), 1)
end

function TestEntityFactory:test_battery_has_units()
	local stores = makeStores()
	local dto = makeDTO()

	Medusa.Services.EntityFactory.createFromDTO(dto, stores, "net-1")

	local all = stores.batteries:getAll()
	local battery = all[1]
	lu.assertNotNil(battery.Units)
	lu.assertTrue(#battery.Units > 0)
end

function TestEntityFactory:test_battery_fields()
	local stores = makeStores()
	local dto = makeDTO({ groupId = 42, groupName = "SAM-SA10" })

	Medusa.Services.EntityFactory.createFromDTO(dto, stores, "net-1")

	local battery = stores.batteries:getAll()[1]
	lu.assertEquals(battery.NetworkId, "net-1")
	lu.assertEquals(battery.GroupId, 42)
	lu.assertEquals(battery.GroupName, "SAM-SA10")
	lu.assertNotNil(battery.Position)
end

function TestEntityFactory:test_sensor_ewr_classification()
	local stores = makeStores()
	local dto = makeDTO({ parsed = { roles = { "EWR" } } })

	local kind, count = Medusa.Services.EntityFactory.createFromDTO(dto, stores, "net-1")

	lu.assertEquals(kind, "sensor")
	lu.assertTrue(count > 0)
	lu.assertEquals(stores.sensors:count(), count)
end

function TestEntityFactory:test_sensor_gci_classification()
	local stores = makeStores()
	local dto = makeDTO({ parsed = { roles = { "GCI" } } })

	local kind, count = Medusa.Services.EntityFactory.createFromDTO(dto, stores, "net-1")

	lu.assertEquals(kind, "sensor")
	lu.assertTrue(count > 0)

	local all = stores.sensors:getAll()
	lu.assertEquals(all[1].SensorType, "GCI")
end

function TestEntityFactory:test_sensor_ewr_type()
	local stores = makeStores()
	local dto = makeDTO({ parsed = { roles = { "EWR" } } })

	Medusa.Services.EntityFactory.createFromDTO(dto, stores, "net-1")

	local all = stores.sensors:getAll()
	lu.assertEquals(all[1].SensorType, "EWR")
end

function TestEntityFactory:test_sensor_has_hierarchy_path()
	local stores = makeStores()
	local dto = makeDTO({ parsed = { roles = { "EWR" }, echelonPath = { "Corps", "Div" } } })

	Medusa.Services.EntityFactory.createFromDTO(dto, stores, "net-1")

	local all = stores.sensors:getAll()
	lu.assertEquals(all[1].HierarchyPath, "Corps.Div")
end

function TestEntityFactory:test_hq_classification()
	local stores = makeStores()
	local dto = makeDTO({ parsed = { isHQ = true } })

	local kind, count = Medusa.Services.EntityFactory.createFromDTO(dto, stores, "net-1")

	lu.assertEquals(kind, "hq")
	lu.assertEquals(count, 1)
	lu.assertEquals(stores.c2Nodes:count(), 1)
end

function TestEntityFactory:test_hq_fields()
	local stores = makeStores()
	local dto = makeDTO({
		groupName = "HQ-Division",
		parsed = { isHQ = true, echelonPath = { "Division", "Brigade" } },
	})

	Medusa.Services.EntityFactory.createFromDTO(dto, stores, "net-1")

	local node = stores.c2Nodes:getAll()[1]
	lu.assertEquals(node.NetworkId, "net-1")
	lu.assertEquals(node.NodeName, "HQ-Division")
	lu.assertEquals(node.EchelonName, "Division")
	lu.assertNotNil(node.Position)
end

function TestEntityFactory:test_hq_empty_echelon_path()
	local stores = makeStores()
	local dto = makeDTO({ parsed = { isHQ = true, echelonPath = {} } })

	Medusa.Services.EntityFactory.createFromDTO(dto, stores, "net-1")

	local node = stores.c2Nodes:getAll()[1]
	lu.assertIsNil(node.EchelonName)
end

function TestEntityFactory:test_sensor_role_takes_priority_over_hq()
	local stores = makeStores()
	local dto = makeDTO({ parsed = { roles = { "EWR" }, isHQ = true } })

	local kind, _ = Medusa.Services.EntityFactory.createFromDTO(dto, stores, "net-1")

	lu.assertEquals(kind, "sensor")
	lu.assertEquals(stores.sensors:count() > 0, true)
	lu.assertEquals(stores.c2Nodes:count(), 0)
end

function TestEntityFactory:test_sensor_with_nil_units_returns_zero()
	GetGroupUnits = function()
		return nil
	end

	local stores = makeStores()
	local dto = makeDTO({ parsed = { roles = { "EWR" } } })

	local kind, count = Medusa.Services.EntityFactory.createFromDTO(dto, stores, "net-1")

	lu.assertEquals(kind, "sensor")
	lu.assertEquals(count, 0)
	lu.assertEquals(stores.sensors:count(), 0)
end
