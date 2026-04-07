local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("core.Config")

-- Make parser available
require("services.GroupNameParser")

TestGroupNameParser = {}

function TestGroupNameParser:test_when_no_prefix_should_not_be_managed()
	local r = Medusa.Services.GroupNameParser:parse("iads.1div.1bde.1bn.foo_battery", "IADS.")
	lu.assertFalse(r.isManaged)
	-- Without prefix match, last segment is still the label
	lu.assertEquals(r.unitLabel, "foo_battery")
end

function TestGroupNameParser:test_when_prefix_matches_should_be_managed()
	-- Dot-Echelon: highest echelon first, unit last
	local r = Medusa.Services.GroupNameParser:parse("iads.1div.1bde.1bn.foo_battery", "iads")
	lu.assertTrue(r.isManaged)
	lu.assertEquals(r.unitLabel, "foo_battery")
	lu.assertEquals(table.concat(r.echelonPath, ","), "1div,1bde,1bn")
end

function TestGroupNameParser:test_when_role_gci_should_set_sensor_type_and_anchor()
	-- Echelons before role, label after role
	local r = Medusa.Services.GroupNameParser:parse("iads.1bde.1bn.gci.cairo", "iads")
	lu.assertTrue(r.isManaged)
	lu.assertEquals(r.unitLabel, "cairo")
	lu.assertEquals(r.sensorType, Medusa.Constants.Role.GCI)
	lu.assertEquals(r.roles[1], Medusa.Constants.Role.GCI)
	lu.assertEquals(table.concat(r.echelonPath, ","), "1bde,1bn")
end

function TestGroupNameParser:test_when_role_hq_should_mark_is_hq()
	local r = Medusa.Services.GroupNameParser:parse("iads.1div.hq.CommandPost", "iads")
	lu.assertTrue(r.isManaged)
	lu.assertEquals(r.unitLabel, "CommandPost")
	lu.assertTrue(r.isHQ)
	lu.assertEquals(r.roleAnchorEchelon, "1div")
	lu.assertEquals(table.concat(r.echelonPath, ","), "1div")
end

function TestGroupNameParser:test_when_no_roles_should_parse_top_down()
	local r = Medusa.Services.GroupNameParser:parse("iads.3bde.2bn.alpha", "iads")
	lu.assertTrue(r.isManaged)
	lu.assertEquals(r.unitLabel, "alpha")
	lu.assertEquals(table.concat(r.echelonPath, ","), "3bde,2bn")
end

function TestGroupNameParser:test_when_tokens_overridden_should_respect_config()
	MEDUSA_CONFIG = {
		LogLevel = "TRACE",
		Roles = { HQ = "headquarters", GCI = "icr", EWR = "aw" },
		Networks = {
			{ name = "T", coalition = (coalition and coalition.side and coalition.side.RED) or 1, prefix = "net" },
		},
	}
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
	local r = Medusa.Services.GroupNameParser:parse("net.1bn.icr.sphinx", "net")
	lu.assertTrue(r.isManaged)
	lu.assertEquals(r.unitLabel, "sphinx")
	lu.assertEquals(r.sensorType, Medusa.Constants.Role.GCI)
	lu.assertEquals(r.roles[1], Medusa.Constants.Role.GCI)
	lu.assertEquals(table.concat(r.echelonPath, ","), "1bn")
	MEDUSA_CONFIG = nil
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
end

function TestGroupNameParser:test_when_gci_role_present_should_parse_echelon_path_depth_6()
	local r = Medusa.Services.GroupNameParser:parse("iads.6front.5army.4corps.3div.2bde.1bn.gci.alpha", "iads")
	lu.assertTrue(r.isManaged)
	lu.assertEquals(r.unitLabel, "alpha")
	lu.assertEquals(r.roles[1], Medusa.Constants.Role.GCI)
	lu.assertEquals(table.concat(r.echelonPath, ","), "6front,5army,4corps,3div,2bde,1bn")
end

function TestGroupNameParser:test_when_hq_role_present_should_anchor_echelon_before_role()
	local r = Medusa.Services.GroupNameParser:parse("iads.6front.5army.4corps.3div.2bde.hq.cp", "iads")
	lu.assertTrue(r.isManaged)
	lu.assertEquals(r.unitLabel, "cp")
	lu.assertTrue(r.isHQ)
	lu.assertEquals(r.roleAnchorEchelon, "6front")
	lu.assertEquals(table.concat(r.echelonPath, ","), "6front,5army,4corps,3div,2bde")
end

function TestGroupNameParser:test_when_no_roles_should_parse_top_down_depth_6()
	local r = Medusa.Services.GroupNameParser:parse("iads.6front.5army.4corps.3div.2bde.1bn.alpha", "iads")
	lu.assertTrue(r.isManaged)
	lu.assertEquals(r.unitLabel, "alpha")
	lu.assertEquals(table.concat(r.echelonPath, ","), "6front,5army,4corps,3div,2bde,1bn")
end

function TestGroupNameParser:test_when_multiple_roles_should_use_echelon_before_first_and_label_after_last()
	local r = Medusa.Services.GroupNameParser:parse("iads.4corps.3div.2bde.1bn.gci.ewr.foo", "iads")
	lu.assertTrue(r.isManaged)
	lu.assertEquals(r.unitLabel, "foo")
	lu.assertEquals(r.roles[1], Medusa.Constants.Role.GCI)
	lu.assertEquals(r.roles[2], Medusa.Constants.Role.EWR)
	lu.assertEquals(table.concat(r.echelonPath, ","), "4corps,3div,2bde,1bn")
end

function TestGroupNameParser:test_when_label_after_role_has_dots_should_preserve_label()
	local r = Medusa.Services.GroupNameParser:parse("iads.4corps.3div.2bde.1bn.gci.alpha.bravo", "iads")
	lu.assertTrue(r.isManaged)
	lu.assertEquals(r.unitLabel, "alpha.bravo")
	lu.assertEquals(table.concat(r.echelonPath, ","), "4corps,3div,2bde,1bn")
end

function TestGroupNameParser:test_when_tokens_overridden_should_parse_deep_hierarchy()
	MEDUSA_CONFIG = {
		LogLevel = "TRACE",
		Roles = { HQ = "headquarters", GCI = "icr", EWR = "aw" },
		Networks = {
			{ name = "T", coalition = (coalition and coalition.side and coalition.side.RED) or 1, prefix = "net" },
		},
	}
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
	local r = Medusa.Services.GroupNameParser:parse("net.4corps.3div.2bde.1bn.icr.sphinx", "net")
	lu.assertTrue(r.isManaged)
	lu.assertEquals(r.unitLabel, "sphinx")
	lu.assertEquals(r.roles[1], Medusa.Constants.Role.GCI)
	lu.assertEquals(table.concat(r.echelonPath, ","), "4corps,3div,2bde,1bn")
	MEDUSA_CONFIG = nil
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
end

function TestGroupNameParser:test_flat_name_single_segment()
	local r = Medusa.Services.GroupNameParser:parse("red.SA-10 Damascus", "red")
	lu.assertTrue(r.isManaged)
	lu.assertEquals(r.unitLabel, "SA-10 Damascus")
	lu.assertEquals(#r.echelonPath, 0)
end

function TestGroupNameParser:test_flat_ewr_skynet_style()
	local r = Medusa.Services.GroupNameParser:parse("RED EWR North", "RED")
	lu.assertTrue(r.isManaged)
	lu.assertEquals(r.roles[1], Medusa.Constants.Role.EWR)
	lu.assertEquals(r.unitLabel, "EWR North")
	lu.assertEquals(#r.echelonPath, 0)
end

-- Word boundary prefix matching: any non-alphanumeric separator should work
function TestGroupNameParser:test_prefix_word_boundary_underscore()
	local r = Medusa.Services.GroupNameParser:parse("RSAM_SA2", "RSAM")
	lu.assertTrue(r.isManaged)
end

function TestGroupNameParser:test_prefix_word_boundary_asterisk()
	local r = Medusa.Services.GroupNameParser:parse("RSAM*SA2", "RSAM")
	lu.assertTrue(r.isManaged)
end

function TestGroupNameParser:test_prefix_word_boundary_hyphen()
	local r = Medusa.Services.GroupNameParser:parse("RSAM-SA2", "RSAM")
	lu.assertTrue(r.isManaged)
end

function TestGroupNameParser:test_prefix_word_boundary_dot()
	local r = Medusa.Services.GroupNameParser:parse("RSAM.SA2", "RSAM")
	lu.assertTrue(r.isManaged)
end

function TestGroupNameParser:test_prefix_word_boundary_bang()
	local r = Medusa.Services.GroupNameParser:parse("RSAM!SA2", "RSAM")
	lu.assertTrue(r.isManaged)
end

function TestGroupNameParser:test_prefix_word_boundary_space()
	local r = Medusa.Services.GroupNameParser:parse("RSAM SA2", "RSAM")
	lu.assertTrue(r.isManaged)
end

function TestGroupNameParser:test_prefix_word_boundary_dollar()
	local r = Medusa.Services.GroupNameParser:parse("RSAM$SA2", "RSAM")
	lu.assertTrue(r.isManaged)
end

function TestGroupNameParser:test_prefix_word_boundary_ampersand()
	local r = Medusa.Services.GroupNameParser:parse("RSAM&SA2", "RSAM")
	lu.assertTrue(r.isManaged)
end

function TestGroupNameParser:test_prefix_no_match_when_alphanumeric_follows()
	local r = Medusa.Services.GroupNameParser:parse("RSAMBO", "RSAM")
	lu.assertFalse(r.isManaged)
end
