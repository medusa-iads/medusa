local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("core.Core")
require("services.Services")
require("services.MetricsService")
require("services.ApiService")

local function makeMockIads(doctrineOverride)
	local doctrine = doctrineOverride or {}
	return {
		getDoctrine = function(_self)
			return doctrine
		end,
	}
end

local function registerNetwork(name, doctrineOverride)
	local iads = makeMockIads(doctrineOverride)
	Medusa.Core.IadsById = Medusa.Core.IadsById or {}
	Medusa.Core.IadsById[tostring(name)] = iads
	return iads
end

local API = Medusa.Services.ApiService
local Const = Medusa.Constants

local ALL_ROLES = {}
for role, _ in pairs(Const.EMCON_DEFAULT_POLICY_BY_ROLE) do
	ALL_ROLES[#ALL_ROLES + 1] = role
end

local function resetIadsById()
	Medusa.Core.IadsById = {}
end

TestSetEMCON = {}

function TestSetEMCON:setUp()
	resetIadsById()
end

function TestSetEMCON:test_blanket_sets_all_roles()
	registerNetwork("alpha")
	lu.assertTrue(API.setEMCON("alpha", "MINIMIZE"))
	local d = Medusa.Core.IadsById["alpha"]:getDoctrine()
	for _, role in ipairs(ALL_ROLES) do
		lu.assertEquals(d.EMCON[role], "MINIMIZE")
	end
end

function TestSetEMCON:test_per_role_only_sets_that_role()
	registerNetwork("bravo")
	API.setEMCON("bravo", "ALWAYS_ON")
	API.setEMCON("bravo", "MINIMIZE", "LR_SAM")
	local d = Medusa.Core.IadsById["bravo"]:getDoctrine()
	lu.assertEquals(d.EMCON["LR_SAM"], "MINIMIZE")
	lu.assertEquals(d.EMCON["EWR"], "ALWAYS_ON")
end

function TestSetEMCON:test_sam_group_sets_all_sams()
	registerNetwork("charlie")
	API.setEMCON("charlie", "ALWAYS_ON")
	API.setEMCON("charlie", "MINIMIZE", "SAM")
	local d = Medusa.Core.IadsById["charlie"]:getDoctrine()
	lu.assertEquals(d.EMCON["LR_SAM"], "MINIMIZE")
	lu.assertEquals(d.EMCON["SR_SAM"], "MINIMIZE")
	lu.assertEquals(d.EMCON["AAA"], "MINIMIZE")
	lu.assertEquals(d.EMCON["EWR"], "ALWAYS_ON")
	lu.assertEquals(d.EMCON["GCI"], "ALWAYS_ON")
end

function TestSetEMCON:test_radar_group_sets_ewr_and_gci()
	registerNetwork("delta")
	API.setEMCON("delta", "MINIMIZE")
	API.setEMCON("delta", "ALWAYS_ON", "RADAR")
	local d = Medusa.Core.IadsById["delta"]:getDoctrine()
	lu.assertEquals(d.EMCON["EWR"], "ALWAYS_ON")
	lu.assertEquals(d.EMCON["GCI"], "ALWAYS_ON")
	lu.assertEquals(d.EMCON["LR_SAM"], "MINIMIZE")
end

function TestSetEMCON:test_rejects_invalid_policy()
	registerNetwork("echo")
	lu.assertFalse(API.setEMCON("echo", "BANANA"))
end

function TestSetEMCON:test_rejects_invalid_role()
	registerNetwork("foxtrot")
	lu.assertFalse(API.setEMCON("foxtrot", "MINIMIZE", "PLATOON"))
end

function TestSetEMCON:test_missing_network_returns_false()
	lu.assertFalse(API.setEMCON("GHOST", "MINIMIZE"))
end

TestGetEMCON = {}

function TestGetEMCON:setUp()
	resetIadsById()
end

function TestGetEMCON:test_returns_set_value()
	registerNetwork("golf")
	API.setEMCON("golf", "PERIODIC_SCAN", "MR_SAM")
	lu.assertEquals(API.getEMCON("golf", "MR_SAM"), "PERIODIC_SCAN")
end

function TestGetEMCON:test_falls_back_to_default()
	registerNetwork("hotel", {})
	lu.assertEquals(API.getEMCON("hotel", "EWR"), "ALWAYS_ON")
	lu.assertEquals(API.getEMCON("hotel", "LR_SAM"), "MINIMIZE")
end

function TestGetEMCON:test_missing_network_returns_nil()
	lu.assertNil(API.getEMCON("GHOST", "EWR"))
end

function TestGetEMCON:test_nil_role_returns_nil()
	registerNetwork("india")
	lu.assertNil(API.getEMCON("india", nil))
end

TestSetScanTiming = {}

function TestSetScanTiming:setUp()
	resetIadsById()
end

function TestSetScanTiming:test_valid_values_written()
	registerNetwork("juliet")
	lu.assertTrue(API.setScanTiming("juliet", 45, 15))
	local d = Medusa.Core.IadsById["juliet"]:getDoctrine()
	lu.assertEquals(d.ScanSec, 45)
	lu.assertEquals(d.QuietPeriodSec, 15)
end

function TestSetScanTiming:test_zero_scan_rejected()
	registerNetwork("kilo")
	lu.assertFalse(API.setScanTiming("kilo", 0, 5))
end

function TestSetScanTiming:test_negative_rejected()
	registerNetwork("lima")
	lu.assertFalse(API.setScanTiming("lima", -1, 5))
	lu.assertFalse(API.setScanTiming("lima", 30, -1))
end

function TestSetScanTiming:test_missing_network_returns_false()
	lu.assertFalse(API.setScanTiming("GHOST", 30, 0))
end

TestGetScanTiming = {}

function TestGetScanTiming:setUp()
	resetIadsById()
end

function TestGetScanTiming:test_defaults_when_unset()
	registerNetwork("mike", {})
	local scan, quiet = API.getScanTiming("mike")
	lu.assertEquals(scan, 30)
	lu.assertEquals(quiet, 0)
end

function TestGetScanTiming:test_returns_set_values()
	registerNetwork("november")
	API.setScanTiming("november", 60, 10)
	local scan, quiet = API.getScanTiming("november")
	lu.assertEquals(scan, 60)
	lu.assertEquals(quiet, 10)
end

function TestGetScanTiming:test_missing_network_returns_nil()
	local scan, quiet = API.getScanTiming("GHOST")
	lu.assertNil(scan)
	lu.assertNil(quiet)
end

TestSetRotationGroups = {}

function TestSetRotationGroups:setUp()
	resetIadsById()
end

function TestSetRotationGroups:test_valid_integer_written()
	registerNetwork("oscar")
	lu.assertTrue(API.setRotationGroups("oscar", 3))
	lu.assertEquals(Medusa.Core.IadsById["oscar"]:getDoctrine().EmconRotateGroups, 3)
end

function TestSetRotationGroups:test_rejects_zero()
	registerNetwork("papa")
	lu.assertFalse(API.setRotationGroups("papa", 0))
end

function TestSetRotationGroups:test_rejects_float()
	registerNetwork("quebec")
	lu.assertFalse(API.setRotationGroups("quebec", 2.5))
end

function TestSetRotationGroups:test_rejects_negative()
	registerNetwork("romeo")
	lu.assertFalse(API.setRotationGroups("romeo", -1))
end

function TestSetRotationGroups:test_missing_network_returns_false()
	lu.assertFalse(API.setRotationGroups("GHOST", 3))
end

TestGetRotationGroups = {}

function TestGetRotationGroups:setUp()
	resetIadsById()
end

function TestGetRotationGroups:test_default_when_unset()
	registerNetwork("sierra", {})
	lu.assertEquals(API.getRotationGroups("sierra"), 2)
end

function TestGetRotationGroups:test_returns_set_value()
	registerNetwork("tango")
	API.setRotationGroups("tango", 4)
	lu.assertEquals(API.getRotationGroups("tango"), 4)
end

function TestGetRotationGroups:test_missing_network_returns_nil()
	lu.assertNil(API.getRotationGroups("GHOST"))
end
