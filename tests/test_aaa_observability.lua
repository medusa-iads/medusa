local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("core.Config")
require("entities.Battery")
require("services.Services")
require("services.MetricsService")
require("services.MetricsSnapshotService")

local C = Medusa.Constants
local MS = Medusa.Services.MetricsService
local MSS = Medusa.Services.MetricsSnapshotService

local function contains(text, value)
	return string.find(text, value, 1, true) ~= nil
end

local function battery(role, ammo)
	return Medusa.Entities.Battery.new({
		BatteryId = role,
		NetworkId = "red",
		GroupId = role,
		GroupName = "RED-" .. role,
		Role = role,
		ActivationState = C.ActivationState.STATE_COLD,
		OperationalStatus = C.BatteryOperationalStatus.ACTIVE,
		TotalAmmoStatus = ammo,
		Position = { x = 100, y = 0, z = 200 },
	})
end

local function view(values)
	return {
		count = function()
			return #values
		end,
		getAll = function()
			return values
		end,
	}
end

local function network(batteries, doctrine)
	local empty = view({})
	local assets = {
		batteries = function()
			return view(batteries)
		end,
		manpads = function()
			return empty
		end,
		sensors = function()
			return empty
		end,
	}
	local trackStore = view({})
	return {
		_rollingPkCount = 0,
		_rollingPkBuffer = {},
		_effectivePkFloor = 0,
		getAssetIndex = function()
			return assets
		end,
		getTrackManager = function()
			return {
				getStore = function()
					return trackStore
				end,
			}
		end,
		getDoctrine = function()
			return doctrine
		end,
		getBorderPolygonsLL = function()
			return {}
		end,
	}
end

TestAaaObservability = {}

function TestAaaObservability:setUp()
	self.registry = MS._registry
	self.callbacks = MS._snapshotCallbacks
	self.context = MS._context
	self.extended = MS._extendedBlock
	self.iadsById = Medusa.Core.IadsById
	self.config = Medusa.Config.Current
	self.coordToLL = coord.LOtoLL
	MS._registry = {}
	MS._snapshotCallbacks = {}
	MS._context = nil
	MS._extendedBlock = ""
	Medusa.Core.IadsById = {}
	Medusa.Config.Current = { PrometheusExtendEnabled = false }
end

function TestAaaObservability:tearDown()
	MS._registry = self.registry
	MS._snapshotCallbacks = self.callbacks
	MS._context = self.context
	MS._extendedBlock = self.extended
	Medusa.Core.IadsById = self.iadsById
	Medusa.Config.Current = self.config
	coord.LOtoLL = self.coordToLL
end

function TestAaaObservability:test_snapshot_exports_bounded_state_and_excludes_gun_rounds_from_missile_ammo()
	local sam = battery(C.BatteryRole.GENERIC_SAM, 6)
	local aaa = battery(C.BatteryRole.AAA, 250)
	aaa.Aaa.ResponseState = C.Aaa.ResponseState.ALERT
	aaa.CrewSuppressionState = C.CrewSuppressionState.SUPPRESSED
	aaa.CrewSuppressionCause = C.CrewSuppressionCause.DAMAGE
	aaa.CrewSuppressionUntil = 1120
	Medusa.Core.IadsById.red = network({ sam, aaa }, {
		Posture = C.Posture.HOT_WAR,
		AAA = { AudioRangeM = 6000 },
	})
	MSS.register({ "network" })
	MSS.installSnapshot()
	local cause = C.CrewSuppressionCause.DAMAGE
	local dropReason = C.CrewSuppressionDropReason.QUEUE_OVERFLOW
	MS.inc("medusa_crew_suppression_applications_total", nil, { network = "red", cause = cause })
	MS.inc("medusa_crew_suppression_dropped_events_total", nil, { network = "red", reason = dropReason })
	MS.observe("medusa_crew_suppression_duration_seconds", 120, { network = "red", cause = cause })

	local output = MS.serialize()

	lu.assertTrue(contains(output, 'medusa_ammo_remaining{network="red"} 6'))
	lu.assertTrue(contains(output, 'medusa_aaa_state{network="red",mode="INDEPENDENT",state="ALERT"} 1'))
	lu.assertTrue(contains(output, 'medusa_aaa_state{network="red",mode="RADAR_DIRECTED",state="AREA_FIRE"} 0'))
	lu.assertTrue(contains(output, 'medusa_aaa_state{network="red",mode="INDEPENDENT",state="BARRAGE_FIRE"} 0'))
	lu.assertTrue(contains(output, 'medusa_aaa_state{network="red",mode="INDEPENDENT",state="BARRAGE_PAUSE"} 0'))
	lu.assertTrue(contains(output, 'medusa_aaa_visual_detections_total{network="red"} 0'))
	lu.assertTrue(contains(output, 'medusa_aaa_barrage_responses_total{network="red"} 0'))
	lu.assertTrue(contains(output, 'medusa_aaa_barrage_bursts_total{network="red"} 0'))
	lu.assertTrue(contains(output, 'medusa_aaa_barrage_infections_total{network="red"} 0'))
	lu.assertTrue(contains(output, 'medusa_crew_suppressed_batteries{network="red"} 1'))
	lu.assertTrue(contains(output, 'medusa_crew_suppression_applications_total{network="red",cause="DAMAGE"} 1'))
	lu.assertTrue(
		contains(output, 'medusa_crew_suppression_dropped_events_total{network="red",reason="QUEUE_OVERFLOW"} 1')
	)
	lu.assertTrue(contains(output, 'medusa_crew_suppression_weapon_outcomes_total{outcome="TRACKER_FULL"} 0'))
	lu.assertEquals(MS._registry.medusa_tick_duration_seconds.quantiles, { 0.5, 0.9, 0.95, 0.99 })
	lu.assertEquals(MS._registry.medusa_crew_suppression_applications_total.label_keys, { "network", "cause" })
	lu.assertEquals(MS._registry.medusa_crew_suppression_dropped_events_total.label_keys, { "network", "reason" })
end

function TestAaaObservability:test_extended_snapshot_exports_aaa_state_headings_and_detection_geometry()
	local aaa = battery(C.BatteryRole.AAA, 250)
	aaa.Aaa.ResponseState = C.Aaa.ResponseState.LOCAL_ACQUISITION
	aaa.Aaa.UnitHeadings = { { hx = 1, hz = 0 } }
	aaa.Aaa.UnitHeadingCount = 1
	Medusa.Core.IadsById.red = network({ aaa }, {
		Posture = C.Posture.HOT_WAR,
		AAA = { AudioRangeM = 6500 },
	})
	Medusa.Config.Current.PrometheusExtendEnabled = true
	coord.LOtoLL = function()
		return 35, 36
	end
	MSS.register({ "network" })
	MSS.installSnapshot()

	local output = MS.serialize()

	lu.assertTrue(
		contains(output, 'medusa_aaa_info{network="red",aaa="RED-AAA",mode="INDEPENDENT",state="LOCAL_ACQUISITION"} 1')
	)
	lu.assertTrue(contains(output, 'medusa_aaa_heading_degrees{network="red",aaa="RED-AAA",heading_index="1"} 90.0'))
	lu.assertTrue(contains(output, 'medusa_aaa_audio_range_meters{network="red"} 6500'))
	lu.assertTrue(contains(output, 'medusa_battery_ammo{network="red",battery="RED-AAA"} 250'))
	lu.assertTrue(contains(output, "medusa_aaa_visual_detection_range_meters 8000"))
	lu.assertTrue(contains(output, "medusa_aaa_visual_detection_half_angle_degrees"))
end
