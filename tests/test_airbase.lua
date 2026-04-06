local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Airbase")

-- == Airbase Entity Tests ==

TestAirbase = {}

local ulidCounter = 0

function TestAirbase:setUp()
	ulidCounter = 0
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
end

function TestAirbase:test_missing_data_errors()
	lu.assertErrorMsgContains("data table is required", function()
		Medusa.Entities.Airbase.new(nil)
	end)
end

function TestAirbase:test_missing_network_id_errors()
	lu.assertErrorMsgContains("missing required field: NetworkId", function()
		Medusa.Entities.Airbase.new({ AirbaseName = "test" })
	end)
end

function TestAirbase:test_missing_airbase_name_errors()
	lu.assertErrorMsgContains("missing required field: AirbaseName", function()
		Medusa.Entities.Airbase.new({ NetworkId = "net-1" })
	end)
end

