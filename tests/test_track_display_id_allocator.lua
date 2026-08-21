local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("services.Services")
require("services.TrackDisplayIdAllocator")

local Allocator = Medusa.Services.TrackDisplayIdAllocator

TestTrackDisplayIdAllocator = {}

function TestTrackDisplayIdAllocator:test_allocates_source_prefixes_with_four_octal_digits()
	local allocator = Allocator:new()
	local source = Medusa.Constants.TrackSource

	lu.assertEquals(allocator:allocate(source.AWACS), "AW0001")
	lu.assertEquals(allocator:allocate(source.EARLY_WARNING_RADAR), "AE0001")
	lu.assertEquals(allocator:allocate(source.SAM_BATTERY), "AB0001")
	lu.assertEquals(allocator:allocate(source.SHIPBORNE_RADAR), "AS0001")
	lu.assertEquals(allocator:allocate(source.AIRBORNE_DATALINK), "AC0001")
end

function TestTrackDisplayIdAllocator:test_allocates_full_octal_range_and_rejects_active_pool_exhaustion()
	local allocator = Allocator:new()
	local source = Medusa.Constants.TrackSource.AWACS
	local displayId
	for _ = 1, Allocator.MAX_NUMBER do
		displayId = allocator:allocate(source)
	end

	lu.assertEquals(displayId, "AW7777")
	lu.assertErrorMsgContains("display ID pool exhausted", function()
		allocator:allocate(source)
	end)
end

function TestTrackDisplayIdAllocator:test_does_not_reuse_released_id_before_exhaustion()
	local allocator = Allocator:new()
	local source = Medusa.Constants.TrackSource.EARLY_WARNING_RADAR
	local released = allocator:allocate(source)
	lu.assertTrue(allocator:release(released))

	lu.assertEquals(allocator:allocate(source), "AE0002")
	for _ = 3, Allocator.MAX_NUMBER do
		allocator:allocate(source)
	end
	lu.assertEquals(allocator:allocate(source), released)
end

function TestTrackDisplayIdAllocator:test_reuses_the_oldest_currently_unused_id_first()
	local allocator = Allocator:new()
	local source = Medusa.Constants.TrackSource.SAM_BATTERY
	local ids = {}
	for i = 1, Allocator.MAX_NUMBER do
		ids[i] = allocator:allocate(source)
	end

	allocator:release(ids[20])
	allocator:release(ids[10])

	lu.assertEquals(allocator:allocate(source), ids[20])
	lu.assertEquals(allocator:allocate(source), ids[10])
end

function TestTrackDisplayIdAllocator:test_rejects_unknown_source()
	local allocator = Allocator:new()
	lu.assertErrorMsgContains("invalid track source", function()
		allocator:allocate("RADAR")
	end)
end

function TestTrackDisplayIdAllocator:test_rejects_reserved_or_non_octal_ids()
	local allocator = Allocator:new()
	lu.assertErrorMsgContains("invalid track display ID", function()
		allocator:release("AW0000")
	end)
	lu.assertErrorMsgContains("invalid track display ID", function()
		allocator:release("AW0008")
	end)
end
