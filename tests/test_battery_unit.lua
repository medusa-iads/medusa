local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Battery")

-- == BatteryUnit Entity Tests ==

TestBatteryUnit = {}

function TestBatteryUnit:test_missing_data_errors()
	lu.assertErrorMsgContains("data table is required", function()
		Medusa.Entities.Battery.newUnit(nil)
	end)
end

function TestBatteryUnit:test_missing_unit_id_errors()
	lu.assertErrorMsgContains("missing required field: UnitId", function()
		Medusa.Entities.Battery.newUnit({})
	end)
end

