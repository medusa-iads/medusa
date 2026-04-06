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

function TestDiscoveryService:test_when_birth_event_published_should_enqueue_and_add()
	-- Arrange: service with coalition/prefix
	-- Use BLUE to match mock Group.getByName():getCoalition() = 2
	local svc = Medusa.Services.DiscoveryService:new(
		nil,
		{ coalitionId = (coalition and coalition.side and coalition.side.BLUE) or 2, prefix = "iads" }
	)
	local added = 0
	svc:setListener({
		onAdded = function(dto)
			added = added + 1
		end,
	})
	-- Enable dynamic adds (subscribes to harness bus)
	svc:enableDynamicAdds()

	-- Publish a birth event into the harness bus matching red+iads
	local bus = InitHarnessWorldEventBus()
	-- Build a fake initiator with getName returning a unit that belongs to a group named iads.alpha
	local fakeGroup = Group.getByName("iads.alpha.gci.1bn")
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
	lu.assertEquals(added >= 1, true)
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
