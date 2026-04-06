local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.SensorUnit")

-- == SensorUnit Entity Tests ==

TestSensorUnit = {}

local ulidCounter = 0

function TestSensorUnit:setUp()
	ulidCounter = 0
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
end

local function makeData(overrides)
	local base = {
		NetworkId = "net-1",
		UnitId = 42,
		UnitName = "EWR-Alpha",
		GroupId = 100,
		GroupName = "iads.ewr_alpha.1bde",
	}
	if overrides then
		for k, v in pairs(overrides) do
			base[k] = v
		end
	end
	return base
end

function TestSensorUnit:test_missing_data_errors()
	lu.assertErrorMsgContains("data table is required", function()
		Medusa.Entities.SensorUnit.new(nil)
	end)
end

function TestSensorUnit:test_missing_network_id_errors()
	lu.assertErrorMsgContains("missing required field: NetworkId", function()
		Medusa.Entities.SensorUnit.new({ UnitId = 1, UnitName = "test" })
	end)
end

function TestSensorUnit:test_missing_unit_id_errors()
	lu.assertErrorMsgContains("missing required field: UnitId", function()
		Medusa.Entities.SensorUnit.new({ NetworkId = "net-1", UnitName = "test" })
	end)
end

function TestSensorUnit:test_missing_unit_name_errors()
	lu.assertErrorMsgContains("missing required field: UnitName", function()
		Medusa.Entities.SensorUnit.new({ NetworkId = "net-1", UnitId = 1 })
	end)
end
