local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("core.Config")
require("entities.Entities")
require("entities.Doctrine")

-- == Config.getDoctrine Resolution Tests ==

TestGetDoctrine = {}

local ulidCounter = 0

function TestGetDoctrine:setUp()
	ulidCounter = 0
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
	Medusa.Config.Current = nil
	-- Clear legacy global
	Medusa_MM_Doctrine = nil
end

function TestGetDoctrine:test_inline_table_applies_overrides()
	Medusa.Config:initialize()
	local d = Medusa.Config:getDoctrine({ ROE = "FREE", PkFloor = 0.25 })
	lu.assertEquals(d.ROE, "FREE")
	lu.assertAlmostEquals(d.PkFloor, 0.25, 0.001)
end

function TestGetDoctrine:test_inline_table_emcon_preserved()
	Medusa.Config:initialize()
	local d = Medusa.Config:getDoctrine({
		EMCON = { LR_SAM = "MINIMIZE", MR_SAM = "PERIODIC_SCAN" },
	})
	lu.assertEquals(d.EMCON.LR_SAM, "MINIMIZE")
	lu.assertEquals(d.EMCON.MR_SAM, "PERIODIC_SCAN")
end

function TestGetDoctrine:test_inline_table_all_fields_reach_doctrine()
	Medusa.Config:initialize()
	local input = {
		Name = "Test Doctrine",
		ROE = "FREE",
		HARMResponse = "SHUTDOWN",
		PkFloor = 0.30,
		DefendPk = 0.50,
		LookaheadSec = 15,
		C2DelaySec = 5,
		HoldDownSec = 10,
		EngageTimeoutSec = 120,
		SAMAsEWR = "ALWAYS",
		BatteryTargetDatalink = false,
		AutoDiscoverEwrs = false,
		ShootScoot = "AFTER_ENGAGEMENT",
		EMCON = { LR_SAM = "MINIMIZE" },
		ScanSec = 45,
		QuietPeriodSec = 20,
	}
	local d = Medusa.Config:getDoctrine(input)
	lu.assertEquals(d.Name, "Test Doctrine")
	lu.assertEquals(d.ROE, "FREE")
	lu.assertEquals(d.HARMResponse, "SHUTDOWN")
	lu.assertAlmostEquals(d.PkFloor, 0.30, 0.001)
	lu.assertAlmostEquals(d.DefendPk, 0.50, 0.001)
	lu.assertEquals(d.LookaheadSec, 15)
	lu.assertEquals(d.C2DelaySec, 5)
	lu.assertEquals(d.HoldDownSec, 10)
	lu.assertEquals(d.EngageTimeoutSec, 120)
	lu.assertEquals(d.SAMAsEWR, "ALWAYS")
	lu.assertFalse(d.BatteryTargetDatalink)
	lu.assertFalse(d.AutoDiscoverEwrs)
	lu.assertEquals(d.ShootScoot, "AFTER_ENGAGEMENT")
	lu.assertEquals(d.EMCON.LR_SAM, "MINIMIZE")
	lu.assertEquals(d.ScanSec, 45)
	lu.assertEquals(d.QuietPeriodSec, 20)
end

function TestGetDoctrine:test_nil_input_uses_defaults()
	Medusa.Config:initialize()
	local d = Medusa.Config:getDoctrine(nil)
	lu.assertEquals(d.ROE, "TIGHT")
	lu.assertEquals(d.HARMResponse, "AUTO_DEFENSE")
	lu.assertAlmostEquals(d.PkFloor, 0.25, 0.001)
end

function TestGetDoctrine:test_string_input_resolves_global()
	Medusa.Config:initialize()
	_G["MyDoctrine"] = { ROE = "HOLD", Name = "Global Doctrine" }
	local d = Medusa.Config:getDoctrine("MyDoctrine")
	lu.assertEquals(d.ROE, "HOLD")
	lu.assertEquals(d.Name, "Global Doctrine")
	_G["MyDoctrine"] = nil
end

function TestGetDoctrine:test_string_input_missing_global_uses_defaults()
	Medusa.Config:initialize()
	local d = Medusa.Config:getDoctrine("NonExistentGlobal")
	lu.assertEquals(d.ROE, "TIGHT")
end

function TestGetDoctrine:test_legacy_global_fallback()
	Medusa.Config:initialize()
	Medusa_MM_Doctrine = { ROE = "FREE", ScanSec = 99 }
	local d = Medusa.Config:getDoctrine(nil)
	lu.assertEquals(d.ROE, "FREE")
	lu.assertEquals(d.ScanSec, 99)
	Medusa_MM_Doctrine = nil
end

function TestGetDoctrine:test_inline_table_takes_priority_over_legacy_global()
	Medusa.Config:initialize()
	Medusa_MM_Doctrine = { ROE = "HOLD" }
	local d = Medusa.Config:getDoctrine({ ROE = "FREE" })
	lu.assertEquals(d.ROE, "FREE")
	Medusa_MM_Doctrine = nil
end

-- == Config.getNetworks Doctrine Passthrough Tests ==

TestGetNetworksDoctrine = {}

function TestGetNetworksDoctrine:setUp()
	Medusa.Config.Current = nil
	Medusa_MM_Doctrine = nil
end

function TestGetNetworksDoctrine:test_inline_doctrine_passed_through()
	MEDUSA_CONFIG = {
		Networks = {
			{ name = "TEST", coalition = 1, prefix = "test", doctrine = { ROE = "FREE", PkFloor = 0.30 } },
		},
	}
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
	local nets = Medusa.Config:getNetworks()
	lu.assertEquals(#nets, 1)
	lu.assertNotNil(nets[1].doctrine)
	lu.assertEquals(nets[1].doctrine.ROE, "FREE")
	lu.assertAlmostEquals(nets[1].doctrine.PkFloor, 0.30, 0.001)
	MEDUSA_CONFIG = nil
end

function TestGetNetworksDoctrine:test_missing_doctrine_passes_nil()
	MEDUSA_CONFIG = {
		Networks = {
			{ name = "TEST", coalition = 1, prefix = "test" },
		},
	}
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
	local nets = Medusa.Config:getNetworks()
	lu.assertEquals(#nets, 1)
	lu.assertIsNil(nets[1].doctrine)
	MEDUSA_CONFIG = nil
end

function TestGetNetworksDoctrine:test_full_roundtrip_inline_to_resolved()
	MEDUSA_CONFIG = {
		Networks = {
			{
				name = "PVO",
				coalition = 1,
				prefix = "pvo",
				doctrine = {
					ROE = "TIGHT",
					EMCON = { LR_SAM = "MINIMIZE", MR_SAM = "MINIMIZE" },
					HARMResponse = "ACTIVE_DEFENSE",
					PkFloor = 0.15,
				},
			},
		},
	}
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
	local nets = Medusa.Config:getNetworks()
	local resolved = Medusa.Config:getDoctrine(nets[1].doctrine)
	lu.assertEquals(resolved.ROE, "TIGHT")
	lu.assertEquals(resolved.EMCON.LR_SAM, "MINIMIZE")
	lu.assertEquals(resolved.EMCON.MR_SAM, "MINIMIZE")
	lu.assertEquals(resolved.HARMResponse, "AUTO_DEFENSE")
	lu.assertAlmostEquals(resolved.PkFloor, 0.15, 0.001)
	-- Defaults still applied for unset fields
	lu.assertEquals(resolved.EngageTactics, "SHOOT_IN_DEPTH")
	lu.assertEquals(resolved.SAMAsEWR, "WHEN_NO_EWR")
	MEDUSA_CONFIG = nil
end

function TestGetNetworksDoctrine:test_invalid_enum_falls_back_to_default()
	local doctrine = Medusa.Entities.Doctrine.new({
		HARMResponse = "ACTIVE_DEFENSE",
		ROE = "BANANA",
		EngageTactics = "DISTRIBUTED",
	})
	lu.assertNotEquals(doctrine.HARMResponse, "ACTIVE_DEFENSE")
	lu.assertEquals(doctrine.HARMResponse, "AUTO_DEFENSE")
	lu.assertNotEquals(doctrine.ROE, "BANANA")
	lu.assertEquals(doctrine.ROE, "TIGHT")
	lu.assertNotEquals(doctrine.EngageTactics, "DISTRIBUTED")
	lu.assertEquals(doctrine.EngageTactics, "SHOOT_IN_DEPTH")
end

function TestGetNetworksDoctrine:test_multi_network_independent_doctrines()
	MEDUSA_CONFIG = {
		Networks = {
			{ name = "A", coalition = 1, prefix = "a", doctrine = { ROE = "FREE" } },
			{ name = "B", coalition = 1, prefix = "b", doctrine = { ROE = "HOLD" } },
		},
	}
	Medusa.Config.Current = nil
	Medusa.Config:initialize()
	local nets = Medusa.Config:getNetworks()
	local dA = Medusa.Config:getDoctrine(nets[1].doctrine)
	local dB = Medusa.Config:getDoctrine(nets[2].doctrine)
	lu.assertEquals(dA.ROE, "FREE")
	lu.assertEquals(dB.ROE, "HOLD")
	MEDUSA_CONFIG = nil
end
