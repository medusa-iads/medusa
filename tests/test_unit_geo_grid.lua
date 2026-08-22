local lu = require("luaunit")

require("_header")
require("services.stores.UnitGeoGrid")

TestUnitGeoGrid = {}

function TestUnitGeoGrid:test_query_is_resumable_and_visit_bounded()
	local grid = Medusa.Services.UnitGeoGrid:new(500)
	for i = 1, 70 do
		grid:add(i, { x = i, y = 0, z = 0 })
	end

	local cursor = grid:beginQuery({ x = 0, y = 0, z = 0 }, 500)
	local output = {}
	local seen = {}
	local totalVisited = 0
	local complete = false
	while not complete do
		local count, visited
		count, visited, complete = grid:continueQuery(cursor, 32, output)
		lu.assertTrue(visited <= 32)
		totalVisited = totalVisited + visited
		for i = 1, count do
			seen[output[i]] = true
		end
	end

	lu.assertEquals(totalVisited, 70)
	lu.assertEquals(grid:size(), 70)
	for i = 1, 70 do
		lu.assertTrue(seen[i])
	end
end

function TestUnitGeoGrid:test_move_and_remove_update_membership_without_growth()
	local grid = Medusa.Services.UnitGeoGrid:new(500)
	grid:add(1, { x = 10, y = 0, z = 10 })
	grid:add(2, { x = 20, y = 0, z = 20 })
	grid:update(1, { x = 2000, y = 0, z = 2000 })
	grid:remove(2)

	local cursor = grid:beginQuery({ x = 0, y = 0, z = 0 }, 500)
	local count, visited, complete = grid:continueQuery(cursor, 32, {})

	lu.assertEquals(count, 0)
	lu.assertEquals(visited, 0)
	lu.assertTrue(complete)
	lu.assertEquals(grid:size(), 1)
end

function TestUnitGeoGrid:test_query_tolerates_mutation_between_continuations()
	local grid = Medusa.Services.UnitGeoGrid:new(500)
	for i = 1, 40 do
		grid:add(i, { x = i, y = 0, z = 0 })
	end
	local cursor = grid:beginQuery({ x = 0, y = 0, z = 0 }, 500)
	local output = {}
	local _, visited, complete = grid:continueQuery(cursor, 16, output)
	lu.assertEquals(visited, 16)
	lu.assertFalse(complete)

	grid:remove(17)
	grid:update(18, { x = 2000, y = 0, z = 2000 })

	repeat
		local count
		count, visited, complete = grid:continueQuery(cursor, 16, output)
		lu.assertTrue(count <= 16)
		lu.assertTrue(visited <= 16)
	until complete
	lu.assertEquals(grid:size(), 39)
end

function TestUnitGeoGrid:test_rejects_radius_larger_than_cell_size()
	local grid = Medusa.Services.UnitGeoGrid:new(500)
	lu.assertNil(grid:beginQuery({ x = 0, y = 0, z = 0 }, 501))
end
