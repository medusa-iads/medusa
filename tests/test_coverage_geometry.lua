local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("services.Services")
require("services.CoverageGeometry")

local CoverageGeometry = Medusa.Services.CoverageGeometry

TestCoverageGeometry = {}

function TestCoverageGeometry:test_zero_providers_is_insufficient()
	local class = CoverageGeometry.evaluate({ x = 0, z = 0, radius = 100 }, {})

	lu.assertEquals(class, Medusa.Constants.CoverageClass.INSUFFICIENT)
end

function TestCoverageGeometry:test_containing_provider_clamps_to_one_hundred_percent()
	local class = CoverageGeometry.evaluate({ x = 0, z = 0, radius = 100 }, { { x = 0, z = 0, radius = 200 } })

	lu.assertEquals(class, Medusa.Constants.CoverageClass.SUFFICIENT)
end

function TestCoverageGeometry:test_tangent_provider_has_zero_coverage()
	local class = CoverageGeometry.evaluate({ x = 0, z = 0, radius = 100 }, { { x = 200, z = 0, radius = 100 } })

	lu.assertEquals(class, Medusa.Constants.CoverageClass.INSUFFICIENT)
end

function TestCoverageGeometry:test_exactly_half_is_insufficient()
	local class = CoverageGeometry.evaluate(
		{ x = 0, z = 0, radius = 100 },
		{ { x = 80.79455075990342, z = 0, radius = 100 } }
	)

	lu.assertEquals(class, Medusa.Constants.CoverageClass.INSUFFICIENT)
end

function TestCoverageGeometry:test_more_than_half_is_sufficient()
	local class = CoverageGeometry.evaluate({ x = 0, z = 0, radius = 100 }, { { x = 80, z = 0, radius = 100 } })

	lu.assertEquals(class, Medusa.Constants.CoverageClass.SUFFICIENT)
end

function TestCoverageGeometry:test_any_valid_amount_above_half_is_sufficient()
	local class = CoverageGeometry.evaluate(
		{ x = 0, z = 0, radius = 100 },
		{ { x = 80.79455055990342, z = 0, radius = 100 } }
	)

	lu.assertEquals(class, Medusa.Constants.CoverageClass.SUFFICIENT)
end

function TestCoverageGeometry:test_disjoint_provider_areas_are_not_joined_by_a_convex_hull()
	local class = CoverageGeometry.evaluate({ x = 0, z = 0, radius = 100 }, {
		{ x = -40, z = 0, radius = 40 },
		{ x = 40, z = 0, radius = 40 },
	})

	lu.assertEquals(class, Medusa.Constants.CoverageClass.INSUFFICIENT)
end

function TestCoverageGeometry:test_duplicate_providers_do_not_double_count()
	local provider = { x = 0, z = 0, radius = 80 }
	local class = CoverageGeometry.evaluate({ x = 0, z = 0, radius = 100 }, { provider, provider })

	lu.assertEquals(class, Medusa.Constants.CoverageClass.SUFFICIENT)
end

function TestCoverageGeometry:test_invalid_input_is_insufficient()
	local class = CoverageGeometry.evaluate({ x = 0 / 0, z = 0, radius = 100 }, { { x = 0, z = 0, radius = 100 } })

	lu.assertEquals(class, Medusa.Constants.CoverageClass.INSUFFICIENT)
end

function TestCoverageGeometry:test_provider_overflow_is_conservatively_insufficient()
	local providers = {}
	for i = 1, Medusa.Constants.C2.PROVIDER_CAPACITY + 1 do
		providers[i] = { x = 0, z = 0, radius = 100 }
	end
	local class, overflow = CoverageGeometry.evaluate({ x = 0, z = 0, radius = 100 }, providers)

	lu.assertEquals(class, Medusa.Constants.CoverageClass.INSUFFICIENT)
	lu.assertTrue(overflow)
end

function TestCoverageGeometry:test_accepts_128_provider_circles()
	local providers = {}
	for i = 1, 128 do
		providers[i] = { x = 0, z = 0, radius = 100 }
	end

	local class, overflow = CoverageGeometry.evaluate({ x = 0, z = 0, radius = 100 }, providers)

	lu.assertEquals(class, Medusa.Constants.CoverageClass.SUFFICIENT)
	lu.assertFalse(overflow)
end
