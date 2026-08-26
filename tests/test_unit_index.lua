local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("services.Services")
require("services.stores.UnitIndex")

TestUnitIndex = {}

function TestUnitIndex:setUp()
	self.index = Medusa.Services.UnitIndex:new()
	self.kinds = Medusa.Constants.UnitOwnerKind
end

function TestUnitIndex:test_one_identity_resolves_every_medusa_owner_by_exact_name()
	local batteryOwner = {}
	local sensorOwner = {}
	local providerOwner = {}
	local identity = {
		UnitId = 100039,
		UnitName = "pt.east.ewr.local-1",
		GroupId = 120,
		GroupName = "pt.east.ewr.local",
	}
	for kind, owner in pairs({
		[self.kinds.BATTERY_UNIT] = batteryOwner,
		[self.kinds.SENSOR] = sensorOwner,
		[self.kinds.COMMAND_PROVIDER] = providerOwner,
	}) do
		identity.OwnerKind = kind
		identity.Owner = owner
		self.index:register(identity)
	end

	local resolved, source = self.index:resolve(39, "pt.east.ewr.local-1")

	lu.assertEquals(source, "unit-name")
	lu.assertEquals(resolved.GroupId, 120)
	lu.assertEquals(resolved.GroupName, "pt.east.ewr.local")
	lu.assertIs(self.index:getOwner(resolved, self.kinds.BATTERY_UNIT), batteryOwner)
	lu.assertIs(self.index:getOwner(resolved, self.kinds.SENSOR), sensorOwner)
	lu.assertIs(self.index:getOwner(resolved, self.kinds.COMMAND_PROVIDER), providerOwner)
	local cached, cachedSource = self.index:resolve(39)
	lu.assertIs(cached, resolved)
	lu.assertEquals(cachedSource, "cached-unit-id")
end

function TestUnitIndex:test_each_identity_retains_only_its_latest_event_id_alias()
	local owner = {}
	self.index:register({
		UnitId = 100039,
		UnitName = "pt.east.ewr.local-1",
		GroupId = 120,
		GroupName = "pt.east.ewr.local",
		OwnerKind = self.kinds.SENSOR,
		Owner = owner,
	})

	self.index:resolve(39, "pt.east.ewr.local-1")
	self.index:resolve(49, "pt.east.ewr.local-1")

	lu.assertNil(self.index:resolve(39))
	lu.assertNotNil(self.index:resolve(49))
	lu.assertNotNil(self.index:resolve(100039))
end

function TestUnitIndex:test_conflicting_id_and_name_do_not_resolve()
	self.index:register({
		UnitId = 39,
		UnitName = "pt.east.hq.command-1",
		GroupId = 121,
		GroupName = "pt.east.hq.command",
		OwnerKind = self.kinds.COMMAND_PROVIDER,
		Owner = {},
	})
	self.index:register({
		UnitId = 40,
		UnitName = "pt.east.ewr.local-1",
		GroupId = 120,
		GroupName = "pt.east.ewr.local",
		OwnerKind = self.kinds.SENSOR,
		Owner = {},
	})

	local resolved, source = self.index:resolve(39, "pt.east.ewr.local-1")

	lu.assertNil(resolved)
	lu.assertEquals(source, "identity-conflict")
end

function TestUnitIndex:test_identity_lives_until_its_last_owner_is_removed()
	local sensorOwner = {}
	local providerOwner = {}
	local data = {
		UnitId = 39,
		UnitName = "pt.east.ewr.local-1",
		GroupId = 120,
		GroupName = "pt.east.ewr.local",
		OwnerKind = self.kinds.SENSOR,
		Owner = sensorOwner,
	}
	self.index:register(data)
	data.OwnerKind = self.kinds.COMMAND_PROVIDER
	data.Owner = providerOwner
	self.index:register(data)

	lu.assertTrue(self.index:unregister(self.kinds.SENSOR, sensorOwner))
	local retained = self.index:resolve(39)
	lu.assertNotNil(retained)
	lu.assertNil(self.index:getOwner(retained, self.kinds.SENSOR))
	lu.assertIs(self.index:getOwner(retained, self.kinds.COMMAND_PROVIDER), providerOwner)

	lu.assertTrue(self.index:unregister(self.kinds.COMMAND_PROVIDER, providerOwner))
	lu.assertNil(self.index:resolve(39))
	lu.assertNil(self.index:resolve(nil, "pt.east.ewr.local-1"))
end

function TestUnitIndex:test_rebind_moves_only_the_selected_owner_id()
	local providerOwner = {}
	self.index:register({
		UnitId = 41,
		UnitName = "pt.east.hq.command-1",
		GroupId = 121,
		GroupName = "pt.east.hq.command",
		OwnerKind = self.kinds.COMMAND_PROVIDER,
		Owner = providerOwner,
	})

	lu.assertTrue(self.index:replaceUnitId(self.kinds.COMMAND_PROVIDER, providerOwner, 51))

	lu.assertNil(self.index:resolve(41))
	local resolved = self.index:resolve(51)
	lu.assertIs(self.index:getOwner(resolved, self.kinds.COMMAND_PROVIDER), providerOwner)
end

function TestUnitIndex:test_exact_group_name_moves_to_the_current_numeric_group_id()
	local providerOwner = {}
	local sensorOwner = {}
	self.index:register({
		UnitId = 41,
		UnitName = "iads.child.hq.gci.command#1",
		GroupId = 210,
		GroupName = "iads.child.hq.gci.command",
		OwnerKind = self.kinds.COMMAND_PROVIDER,
		Owner = providerOwner,
	})
	self.index:register({
		UnitId = 51,
		UnitName = "iads.child.hq.gci.command#1",
		GroupId = 211,
		GroupName = "iads.child.hq.gci.command",
		OwnerKind = self.kinds.SENSOR,
		Owner = sensorOwner,
	})

	local identity = self.index:resolve(51)
	lu.assertEquals(identity.GroupId, 211)
	lu.assertEquals(identity.GroupName, "iads.child.hq.gci.command")
end
