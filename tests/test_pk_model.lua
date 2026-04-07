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
