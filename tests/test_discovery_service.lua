local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Config")
require("core.Constants")
require("services.GroupNameParser")
require("services.DiscoveryService")

TestDiscoveryService = {}

local function make_provider(entries)
	return {
		list = function(coalitionId)
			local out = {}
			for _, e in ipairs(entries) do
				if e.coalitionId == coalitionId then
					out[#out + 1] = e
				end
			end
			return out
		end,
	}
end

TestDiscoveryRegistration = {}

function TestDiscoveryRegistration:setUp()
	self.originalBus = HarnessWorldEventBus
end

function TestDiscoveryRegistration:tearDown()
	HarnessWorldEventBus = self.originalBus
end

function TestDiscoveryRegistration:test_failed_subscription_can_be_retried()
	local svc = Medusa.Services.DiscoveryService:new(nil, { coalitionId = 1, prefix = "iads" })
	HarnessWorldEventBus = {
		sub = function()
			return nil
		end,
	}

	lu.assertFalse(svc:enableDynamicAdds())
	lu.assertNil(svc._birthQueue)

	HarnessWorldEventBus = CreateHarnessWorldEventBus()
	lu.assertTrue(svc:enableDynamicAdds())
	lu.assertNotNil(svc._birthQueue)
end

function TestDiscoveryService:test_when_birth_event_published_should_enqueue_and_add()
	-- Arrange: service with coalition/prefix
	-- Use BLUE to match mock Group.getByName():getCoalition() = 2
	local svc = Medusa.Services.DiscoveryService:new(
		nil,
		{ coalitionId = (coalition and coalition.side and coalition.side.BLUE) or 2, prefix = "iads" }
	)
	local added
	svc:setListener({
		onAdded = function(dto)
			added = dto
		end,
	})
	-- Enable dynamic adds (subscribes to harness bus)
	svc:enableDynamicAdds()

	-- Publish a birth event into the harness bus matching red+iads
	local bus = InitHarnessWorldEventBus()
	-- Build a fake initiator with getName returning a unit that belongs to a group named iads.alpha
	local groupName = "  iads.alpha.gci.1bn  "
	local fakeGroup = Group.getByName(groupName)
	local fakeUnit = Unit.getByName("unit.iads.alpha")
	-- Ensure unit.getGroup returns our fake group
	function fakeUnit:getGroup()
		return fakeGroup
	end
	-- Seed harness cache so GetUnit("unit.iads.alpha") returns our fake unit without touching _G
	_HarnessInternal = _HarnessInternal or {}
	_HarnessInternal.cache = _HarnessInternal.cache or {}
	_HarnessInternal.cache.units = _HarnessInternal.cache.units or {}
	_HarnessInternal.cache.units["unit.iads.alpha"] = fakeUnit

	-- Event structure as DCS would send
	local evt = { id = world.event.S_EVENT_BIRTH, initiator = fakeUnit }
	bus:publish(evt)

	-- Act: process queued events
	local n = svc:processDynamicAdds(4)

	-- Assert: at least one add happened
	lu.assertEquals(n >= 1, true)
	lu.assertNotNil(added)
	lu.assertEquals(added.groupName, groupName)
	lu.assertEquals(added.parsed.sensorType, Medusa.Constants.Role.GCI)
end

function TestDiscoveryService:test_when_added_should_emit_onAdded()
	local provider = make_provider({
		{
			groupId = 1,
			groupName = "iads.alpha.gci.1bn",
			coalitionId = (coalition and coalition.side and coalition.side.RED) or 1,
			category = "ground",
		},
	})
	local svc = Medusa.Services.DiscoveryService:new(
		provider,
		{ coalitionId = (coalition and coalition.side and coalition.side.RED) or 1, prefix = "iads" }
	)
	local events = {}
	svc:setListener({
		onAdded = function(dto)
			events[#events + 1] = { type = "added", id = dto.groupId, role = dto.parsed.sensorType }
		end,
	})
	local a = svc:scanOnce()
	lu.assertEquals(a, 1)
	lu.assertEquals(events[1].type, "added")
	lu.assertEquals(events[1].role, Medusa.Constants.Role.GCI)
end

function TestDiscoveryService:test_scan_accepts_outer_whitespace_and_preserves_the_dcs_group_name()
	local groupName = "  iads.east.ewr.local  "
	local svc = Medusa.Services.DiscoveryService:new(
		make_provider({
			{ groupId = 2, groupName = groupName, coalitionId = 1, category = "ground" },
		}),
		{ coalitionId = 1, prefix = "iads" }
	)
	local added
	svc:setListener({
		onAdded = function(dto)
			added = dto
		end,
	})

	lu.assertEquals(svc:scanOnce(), 1)
	lu.assertEquals(added.groupName, groupName)
	lu.assertEquals(added.parsed.sensorType, Medusa.Constants.Role.EWR)
	lu.assertEquals(table.concat(added.parsed.echelonPath, ","), "east")
end

function TestDiscoveryService:test_scan_reports_failed_provider_snapshot()
	local svc = Medusa.Services.DiscoveryService:new({
		list = function()
			return nil
		end,
	}, { coalitionId = 1, prefix = "iads" })

	local added, succeeded = svc:scanOnce()

	lu.assertEquals(added, 0)
	lu.assertFalse(succeeded)
end

function TestDiscoveryService:test_rejected_group_is_not_retained_as_known()
	local provider = make_provider({
		{ groupId = 7, groupName = "iads.alpha.gci.rejected", coalitionId = 1, category = "ground" },
	})
	local svc = Medusa.Services.DiscoveryService:new(provider, { coalitionId = 1, prefix = "iads" })
	svc:setListener({
		onAdded = function()
			return false
		end,
	})

	lu.assertEquals(svc:scanOnce(), 0)
	lu.assertNil(svc._knownById[7])
	lu.assertNil(svc._knownIdByName["iads.alpha.gci.rejected"])
end

function TestDiscoveryService:test_when_removed_should_not_emit_onRemoved_in_add_only_scan()
	local entries = {
		{
			groupId = 1,
			groupName = "iads.alpha.gci.1bn",
			coalitionId = (coalition and coalition.side and coalition.side.RED) or 1,
			category = "ground",
		},
	}
	local provider = make_provider(entries)
	local svc = Medusa.Services.DiscoveryService:new(
		provider,
		{ coalitionId = (coalition and coalition.side and coalition.side.RED) or 1, prefix = "iads" }
	)
	local removed = 0
	svc:setListener({
		onRemoved = function()
			removed = removed + 1
		end,
	})
	svc:scanOnce()
	-- drop the group
	provider.list = function()
		return {}
	end
	local a = svc:scanOnce()
	lu.assertEquals(a, 0)
	lu.assertEquals(removed, 0)
end

function TestDiscoveryService:test_when_rescanned_should_not_duplicate_adds()
	local entries = {
		{
			groupId = 5,
			groupName = "iads.beta.ewr.2bn",
			coalitionId = (coalition and coalition.side and coalition.side.RED) or 1,
			category = "ground",
		},
	}
	local provider = make_provider(entries)
	local svc = Medusa.Services.DiscoveryService:new(
		provider,
		{ coalitionId = (coalition and coalition.side and coalition.side.RED) or 1, prefix = "iads" }
	)
	local added = 0
	svc:setListener({
		onAdded = function()
			added = added + 1
		end,
	})

	local a1 = svc:scanOnce()
	lu.assertEquals(a1, 1)
	lu.assertEquals(added, 1)

	local a2 = svc:scanOnce()
	lu.assertEquals(a2, 0)
	lu.assertEquals(added, 1)
end

function TestDiscoveryService:test_same_id_rescan_reports_rediscovery_without_a_duplicate_add()
	local provider = make_provider({
		{
			groupId = 6,
			groupName = "iads.beta.ewr.restore",
			coalitionId = (coalition and coalition.side and coalition.side.RED) or 1,
			category = "ground",
		},
	})
	local svc = Medusa.Services.DiscoveryService:new(
		provider,
		{ coalitionId = (coalition and coalition.side and coalition.side.RED) or 1, prefix = "iads" }
	)
	local added = 0
	local rediscovered = 0
	svc:setListener({
		onAdded = function()
			added = added + 1
		end,
		onRediscovered = function()
			rediscovered = rediscovered + 1
		end,
	})

	lu.assertEquals(svc:scanOnce(), 1)
	lu.assertEquals(svc:scanOnce(), 0)
	lu.assertEquals(added, 1)
	lu.assertEquals(rediscovered, 1)
end

function TestDiscoveryService:test_reused_id_with_a_new_name_replaces_the_cached_identity()
	local entries = {
		{
			groupId = 7,
			groupName = "iads.alpha.ewr.first",
			coalitionId = (coalition and coalition.side and coalition.side.RED) or 1,
			category = "ground",
		},
	}
	local svc = Medusa.Services.DiscoveryService:new(make_provider(entries), {
		coalitionId = (coalition and coalition.side and coalition.side.RED) or 1,
		prefix = "iads",
	})
	local names = {}
	svc:setListener({
		onAdded = function(dto)
			names[#names + 1] = dto.groupName
		end,
	})

	lu.assertEquals(svc:scanOnce(), 1)
	entries[1].groupName = "iads.alpha.ewr.replacement"
	lu.assertEquals(svc:scanOnce(), 1)

	lu.assertEquals(names, { "iads.alpha.ewr.first", "iads.alpha.ewr.replacement" })
	lu.assertEquals(svc._knownById[7].groupName, "iads.alpha.ewr.replacement")
	lu.assertNil(svc._knownIdByName["iads.alpha.ewr.first"])
end

function TestDiscoveryService:test_absent_group_identity_is_retired_and_can_be_added_again()
	local entries = {
		{
			groupId = 8,
			groupName = "iads.alpha.ewr.transient",
			coalitionId = (coalition and coalition.side and coalition.side.RED) or 1,
			category = "ground",
		},
	}
	local provider = make_provider(entries)
	local svc = Medusa.Services.DiscoveryService:new(provider, {
		coalitionId = (coalition and coalition.side and coalition.side.RED) or 1,
		prefix = "iads",
	})

	lu.assertEquals(svc:scanOnce(), 1)
	provider.list = function()
		return {}
	end
	lu.assertEquals(svc:scanOnce(), 0)
	lu.assertNil(svc._knownById[8])
	provider.list = make_provider(entries).list
	lu.assertEquals(svc:scanOnce(), 1)
end

function TestDiscoveryService:test_overflow_queue_recovers_a_birth_rejected_by_the_primary_queue()
	local recovered = {
		groupId = 900,
		groupName = "iads.alpha.gci.recovered",
		coalitionId = 1,
		category = "ground",
	}
	local svc = Medusa.Services.DiscoveryService:new(make_provider({ recovered }), {
		coalitionId = 1,
		prefix = "iads",
	})
	local added = 0
	svc._processDiscoveredGroup = function(_, groupName)
		if groupName == recovered.groupName then
			added = added + 1
		end
	end
	lu.assertTrue(svc:enableDynamicAdds())
	for id = 1, Medusa.Constants.WorldEventQueue.BIRTH_CAPACITY do
		lu.assertTrue(svc._birthQueue:enqueue({ _groupName = string.format("iads.pending.%d", id) }))
	end
	lu.assertTrue(svc._birthQueue:enqueue({ _groupName = recovered.groupName }))

	for _ = 1, Medusa.Constants.WorldEventQueue.BIRTH_CAPACITY do
		svc:processDynamicAdds(1)
	end
	local processed = svc:processDynamicAdds(1)

	lu.assertEquals(processed, 1)
	lu.assertEquals(added, 1)
	svc:disableDynamicAdds()
end

function TestDiscoveryService:test_birth_work_remains_bounded_when_both_queues_fill()
	local svc = Medusa.Services.DiscoveryService:new(make_provider({}), { coalitionId = 1, prefix = "iads" })
	lu.assertTrue(svc:enableDynamicAdds())
	local capacity = Medusa.Constants.WorldEventQueue.BIRTH_CAPACITY
		+ Medusa.Constants.WorldEventQueue.BIRTH_OVERFLOW_CAPACITY
	for id = 1, capacity do
		lu.assertTrue(svc._birthQueue:enqueue({ _groupName = string.format("iads.pending.%d", id) }))
	end

	lu.assertFalse(svc._birthQueue:enqueue({ _groupName = "iads.dropped" }))
	lu.assertEquals(svc:pendingDynamicAdds(), capacity)
	lu.assertEquals(svc:processDynamicAdds(2), 2)
	lu.assertEquals(svc:pendingDynamicAdds(), capacity - 2)
end
