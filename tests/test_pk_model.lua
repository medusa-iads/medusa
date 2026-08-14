local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("services.Services")
require("services.PkModel")

TestComputePkRange = {}

-- rOptimal == rMin used to zero out effSigma, causing division by zero
function TestComputePkRange:test_rOptimal_equals_rMin_no_nan()
	local result = Medusa.Services.PkModel.computePkRange(4000, 5000, 3000, 5000)

	lu.assertIsNumber(result)
	lu.assertFalse(result ~= result, "NaN")
	lu.assertFalse(math.abs(result) == math.huge, "inf")
	lu.assertTrue(result >= 0.0 and result <= 1.0)
end

TestComputePkAspect = {}

function TestComputePkAspect:test_headOn_returnsFullFactor()
	local track = {
		Position = { x = 1000, y = 500, z = 0 },
		Velocity = { x = -100, y = 0, z = 0 },
	}

	local result = Medusa.Services.PkModel.computePkAspect(track, { x = 0, y = 0, z = 0 })

	lu.assertAlmostEquals(result, 1, 0.0001)
end

function TestComputePkAspect:test_beam_returnsConfiguredFloor()
	local track = {
		Position = { x = 1000, y = 500, z = 0 },
		Velocity = { x = 0, y = 0, z = 100 },
	}

	local result = Medusa.Services.PkModel.computePkAspect(track, { x = 0, y = 0, z = 0 })

	lu.assertAlmostEquals(result, Medusa.Constants.PK_ASPECT_BEAM_FLOOR, 0.0001)
end
