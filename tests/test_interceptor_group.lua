local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.InterceptorGroup")

-- == InterceptorGroup Entity Tests ==

TestInterceptorGroup = {}

local ulidCounter = 0

function TestInterceptorGroup:setUp()
	ulidCounter = 0
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
end

local function makeData(overrides)
	local base = {
		NetworkId = "net-1",
		GroupId = 100,
		GroupName = "Interceptor-1",
		AircraftType = "MiG-29S",
		HomeAirbaseId = "AB-1",
	}
	if overrides then
		for k, v in pairs(overrides) do
			base[k] = v
		end
	end
	return base
end

function TestInterceptorGroup:test_missing_data_errors()
	lu.assertErrorMsgContains("data table is required", function()
		Medusa.Entities.InterceptorGroup.new(nil)
	end)
end

function TestInterceptorGroup:test_missing_network_id_errors()
	lu.assertErrorMsgContains("missing required field: NetworkId", function()
		Medusa.Entities.InterceptorGroup.new({
			GroupId = 1,
			GroupName = "g",
			AircraftType = "F-16",
			HomeAirbaseId = "AB",
		})
	end)
end

function TestInterceptorGroup:test_missing_group_id_errors()
	lu.assertErrorMsgContains("missing required field: GroupId", function()
		Medusa.Entities.InterceptorGroup.new({
			NetworkId = "n",
			GroupName = "g",
			AircraftType = "F-16",
			HomeAirbaseId = "AB",
		})
	end)
end

function TestInterceptorGroup:test_missing_group_name_errors()
	lu.assertErrorMsgContains("missing required field: GroupName", function()
		Medusa.Entities.InterceptorGroup.new({
			NetworkId = "n",
			GroupId = 1,
			AircraftType = "F-16",
			HomeAirbaseId = "AB",
		})
	end)
end

function TestInterceptorGroup:test_missing_aircraft_type_errors()
	lu.assertErrorMsgContains("missing required field: AircraftType", function()
		Medusa.Entities.InterceptorGroup.new({
			NetworkId = "n",
			GroupId = 1,
			GroupName = "g",
			HomeAirbaseId = "AB",
		})
	end)
end

function TestInterceptorGroup:test_missing_home_airbase_id_errors()
	lu.assertErrorMsgContains("missing required field: HomeAirbaseId", function()
		Medusa.Entities.InterceptorGroup.new({
			NetworkId = "n",
			GroupId = 1,
			GroupName = "g",
			AircraftType = "F-16",
		})
	end)
end
