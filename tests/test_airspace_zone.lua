local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.AirspaceZone")

-- == AirspaceZone Entity Tests ==

TestAirspaceZone = {}

function TestAirspaceZone:test_missing_geometry_errors()
	lu.assertErrorMsgContains("missing required field: Geometry", function()
		Medusa.Entities.AirspaceZone.new({ ZoneName = "Zone Alpha", NetworkId = "net-1" })
	end)
end

function TestAirspaceZone:test_missing_data_errors()
	lu.assertErrorMsgContains("data table is required", function()
		Medusa.Entities.AirspaceZone.new(nil)
	end)
end

function TestAirspaceZone:test_missing_zone_name_errors()
	lu.assertErrorMsgContains("missing required field: ZoneName", function()
		Medusa.Entities.AirspaceZone.new({ NetworkId = "net-1" })
	end)
end

function TestAirspaceZone:test_missing_network_id_errors()
	lu.assertErrorMsgContains("missing required field: NetworkId", function()
		Medusa.Entities.AirspaceZone.new({ ZoneName = "Zone Alpha" })
	end)
end
