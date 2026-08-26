local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("core.Config")
require("entities.Battery")
require("services.Services")
require("observability.MetricsService")
require("observability.MetricsSnapshot")

local C = Medusa.Constants
local MS = Medusa.Observability.MetricsService
local MSS = Medusa.Observability.MetricsSnapshot

local function view(values)
	return {
		count = function()
			return #values
		end,
		getAll = function()
			return values
		end,
		get = function(_, id)
			for i = 1, #values do
				if values[i].TrackId == id then
					return values[i]
				end
			end
			return nil
		end,
	}
end

local function network(tracks, batteries, doctrine, manpads)
	local empty = view({})
	local trackStore = view(tracks)
	local assets = {
		batteries = function()
			return view(batteries)
		end,
		manpads = function()
			return view(manpads or {})
		end,
		sensors = function()
			return empty
		end,
	}
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
			return doctrine or {
				Posture = C.Posture.HOT_WAR,
				DegradedMode = C.NetworkDegradationPolicy.REVERT_TO_AUTONOMOUS,
				AAA = { AudioRangeM = 6000 },
			}
		end,
		getBorderPolygonsLL = function()
			return {}
		end,
	}
end

local function displayBattery(name, coordination, partitionKey, role)
	return Medusa.Entities.Battery.new({
		BatteryId = name,
		NetworkId = "red",
		GroupId = name,
		GroupName = name,
		Role = role,
		CoordinationState = coordination,
		PartitionKey = partitionKey,
	})
end

TestTrackObservability = {}

function TestTrackObservability:setUp()
	self.registry = MS._registry
	self.callbacks = MS._snapshotCallbacks
	self.context = MS._context
	self.extended = MS._extendedBlock
	self.iadsById = Medusa.Core.IadsById
	self.config = Medusa.Config.Current
	self.coordToLL = coord.LOtoLL
	self.blackBoxCacheOrder = Medusa.Services.BlackBoxService._cacheOrder
	MS._registry = {}
	MS._snapshotCallbacks = {}
	MS._context = nil
	MS._extendedBlock = ""
	Medusa.Core.IadsById = {}
	Medusa.Config.Current = { PrometheusExtendEnabled = true }
	coord.LOtoLL = function()
		return 35, 36
	end
end

function TestTrackObservability:tearDown()
	MS._registry = self.registry
	MS._snapshotCallbacks = self.callbacks
	MS._context = self.context
	MS._extendedBlock = self.extended
	Medusa.Core.IadsById = self.iadsById
	Medusa.Config.Current = self.config
	coord.LOtoLL = self.coordToLL
	Medusa.Services.BlackBoxService._cacheOrder = self.blackBoxCacheOrder
end

function TestTrackObservability:test_extended_metrics_keep_canonical_join_key_and_expose_display_id()
	local track = {
		TrackId = "ULID-1",
		DisplayTrackId = "AW0001",
		NetworkId = 1,
		Position = { x = 100, y = 200, z = 300 },
		Velocity = { x = 10, y = 0, z = 20 },
		TrackIdentification = C.TrackIdentification.UNKNOWN,
		AssessedAircraftType = C.AssessedAircraftType.UNKNOWN,
		HarmAssessment = {
			llr = 1,
			scanCount = 1,
			label = C.HarmAssessmentState.EVALUATING,
			lastFeat = { 500, 0, 0.01, 2, 100, -10, -500, 0 },
		},
		UpdateCount = 1,
		FirstDetectionTime = 0,
	}
	local battery = Medusa.Entities.Battery.new({
		BatteryId = "BATTERY-1",
		NetworkId = "red",
		GroupId = 1,
		GroupName = "SAM-1",
		CurrentTargetTrackId = track.TrackId,
	})
	Medusa.Core.IadsById.red = network({ track }, { battery })
	MSS.register({ "network" })
	MSS.installSnapshot()

	local output = MS.serialize()

	lu.assertStrContains(output, 'medusa_track_lat{network="red",track="ULID-1",display_track="AW0001"}')
	lu.assertStrContains(output, 'medusa_track_info{network="red",track="ULID-1",display_track="AW0001",')
	lu.assertStrContains(output, 'medusa_battery_info{network="red",battery="SAM-1",role="GENERIC_SAM",status="ACTIVE",state="INITIALIZING",target="AW0001",target_track="ULID-1",')
	lu.assertStrContains(output, 'medusa_track_sprt_hdg{network="red",track="ULID-1",display_track="AW0001"} 0.01')
	lu.assertStrContains(output, 'medusa_track_sprt_acc{network="red",track="ULID-1",display_track="AW0001"} 2.00')
end

function TestTrackObservability:test_registering_a_second_network_preserves_first_network_counter_series()
	MSS.register({ "network" })
	MS.inc("medusa_world_events_dropped_total", 0, { network = "PVO", event = "DEATH" })

	MSS.register({ "network" })
	MS.inc("medusa_world_events_dropped_total", 0, { network = "SyADF", event = "DEATH" })

	local output = MS.serialize()
	lu.assertStrContains(output, 'medusa_world_events_dropped_total{network="PVO",event="DEATH"} 0')
	lu.assertStrContains(output, 'medusa_world_events_dropped_total{network="SyADF",event="DEATH"} 0')
end

function TestTrackObservability:test_extended_metrics_expose_battery_control_and_current_partition_membership()
	local autoA = displayBattery("AUTO-A", C.CoordinationState.DEGRADED, "partition-b")
	local autoB = displayBattery("AUTO-B", C.CoordinationState.DEGRADED, "partition-b")
	local coordinated = displayBattery("COORD", C.CoordinationState.COORDINATED, "partition-a")
	local independent = displayBattery("INDEPENDENT-AAA", C.CoordinationState.DEGRADED, "partition-a", C.BatteryRole.AAA)
	local selfDefense = displayBattery("SELF", C.CoordinationState.DEGRADED, "partition-self")
	local goDark = displayBattery("DARK", C.CoordinationState.DEGRADED, "partition-dark")
	local manpad = Medusa.Entities.Battery.new({
		BatteryId = "MANPAD",
		NetworkId = "auto",
		GroupId = "MANPAD",
		GroupName = "MANPAD",
		Role = C.BatteryRole.MANPAD,
		PartitionKey = "partition-b",
		Manpad = {
			SleepWakeState = C.Manpad.SleepWakeState.ASLEEP,
			WakeReason = C.Manpad.WakeReason.NONE,
			AlertCycleCount = 0,
			AudioCueRangeM = C.Manpad.AUDIO_RANGE_MAX_M,
			UnitHeadings = {},
			UnitHeadingCount = 0,
		},
	})
	local autoDoctrine = {
		Posture = C.Posture.HOT_WAR,
		DegradedMode = C.NetworkDegradationPolicy.REVERT_TO_AUTONOMOUS,
		AAA = { AudioRangeM = 6000 },
	}
	local selfDefenseDoctrine = {
		Posture = C.Posture.HOT_WAR,
		DegradedMode = C.NetworkDegradationPolicy.REVERT_TO_SELF_DEFENSE,
		AAA = { AudioRangeM = 6000 },
	}
	local goDarkDoctrine = {
		Posture = C.Posture.HOT_WAR,
		DegradedMode = C.NetworkDegradationPolicy.GO_DARK,
		AAA = { AudioRangeM = 6000 },
	}
	Medusa.Core.IadsById.auto = network({}, { autoA, autoB, coordinated, independent }, autoDoctrine, { manpad })
	Medusa.Core.IadsById.self = network({}, { selfDefense }, selfDefenseDoctrine)
	Medusa.Core.IadsById.dark = network({}, { goDark }, goDarkDoctrine)
	MSS.register({ "network" })
	MSS.installSnapshot()

	local output = MS.serialize()

	lu.assertStrContains(
		output,
		'battery="AUTO-A",role="GENERIC_SAM",status="ACTIVE",state="INITIALIZING",target="UNSET",target_track="",system="UNKNOWN",control="AUTONOMOUS",coordination="DEGRADED"'
	)
	lu.assertStrContains(
		output,
		'battery="COORD",role="GENERIC_SAM",status="ACTIVE",state="INITIALIZING",target="UNSET",target_track="",system="UNKNOWN",control="COORDINATED",coordination="COORDINATED"'
	)
	lu.assertStrContains(
		output,
		'battery="INDEPENDENT-AAA",role="AAA",status="ACTIVE",state="INITIALIZING",target="UNSET",target_track="",system="UNKNOWN",control="INDEPENDENT",coordination="DEGRADED"'
	)
	lu.assertStrContains(
		output,
		'battery="SELF",role="GENERIC_SAM",status="ACTIVE",state="INITIALIZING",target="UNSET",target_track="",system="UNKNOWN",control="SELF_DEFENSE",coordination="DEGRADED"'
	)
	lu.assertStrContains(
		output,
		'battery="DARK",role="GENERIC_SAM",status="ACTIVE",state="INITIALIZING",target="UNSET",target_track="",system="UNKNOWN",control="GO_DARK",coordination="DEGRADED"'
	)
	lu.assertStrContains(output, 'medusa_battery_partition{network="auto",battery="COORD"} 1')
	lu.assertStrContains(output, 'medusa_battery_partition{network="auto",battery="AUTO-A"} 2')
	lu.assertStrContains(output, 'medusa_battery_partition{network="auto",battery="AUTO-B"} 2')
	lu.assertStrContains(output, 'medusa_manpad_partition{network="auto",manpad="MANPAD"} 2')
	lu.assertStrContains(output, 'manpad="MANPAD",state="ASLEEP",wake_reason="NONE",detection_mode="NARROW",can_fire="false",control="INDEPENDENT"')
end

function TestTrackObservability:test_last_chance_metric_exposes_display_id_and_canonical_join_key()
	local track = {
		TrackId = "ULID-1",
		DisplayTrackId = "AW0001",
		NetworkId = 1,
	}
	local battery = Medusa.Entities.Battery.new({
		BatteryId = "BATTERY-1",
		NetworkId = "red",
		GroupId = 1,
		GroupName = "SAM-1",
	})
	battery.LastChanceTrackId = track.TrackId
	Medusa.Core.IadsById.red = network({ track }, { battery })
	MSS.register({ "network" })
	MSS.installSnapshot()

	local output = MS.serialize()

	lu.assertStrContains(output, 'medusa_battery_last_chance{network="red",battery="SAM-1",track="ULID-1",display_track="AW0001"}')
end

function TestTrackObservability:test_harm_metrics_separate_available_and_committed_capacity()
	local battery = displayBattery("HARM-SITE", C.CoordinationState.COORDINATED, "partition-a", C.BatteryRole.LR_SAM)
	battery.HarmDefenseState = C.HarmDefenseState.SELF_DEFENDING
	battery.HarmDefenseThreats = 2
	battery.HarmDefenseAvailableCapacity = 4.5
	battery.HarmDefenseCommittedCapacity = 3
	Medusa.Core.IadsById.red = network({}, { battery })
	MSS.register({ "network" })
	MSS.installSnapshot()

	local output = MS.serialize()

	lu.assertStrContains(output, 'medusa_battery_harm_defenders{network="red",battery="HARM-SITE"} 4.5')
	lu.assertStrContains(output, 'medusa_battery_harm_ratio{network="red",battery="HARM-SITE"} 2.25')
	lu.assertStrContains(output, 'medusa_battery_harm_committed_capacity{network="red",battery="HARM-SITE"} 3.0')
	lu.assertStrContains(output, 'medusa_battery_harm_committed_ratio{network="red",battery="HARM-SITE"} 1.50')
end

function TestTrackObservability:test_ringbuffer_metrics_cover_network_and_mission_buffers()
	local function ring(capacity, entries)
		local value = RingBuffer(capacity, false)
		for i = 1, entries do
			value:push(i)
		end
		return value
	end

	local track = {
		TrackId = "track-1",
		NetworkId = 1,
		PositionHistory = ring(3, 2),
	}
	local iads = network({ track }, {})
	iads._deathQueue = ring(4, 1)
	iads._deathOverflowQueue = ring(3, 2)
	iads._shotQueue = ring(5, 3)
	iads._killQueue = ring(6, 4)
	iads._hitQueue = ring(7, 5)
	iads._terminalEventQueue = ring(8, 6)
	iads._discovery = {
		_birthQueue = ring(9, 7),
		_birthOverflowQueue = ring(10, 8),
	}
	iads._sensorPollingService = { _lastScannedOrder = ring(11, 9) }
	iads._manpadCtx = {
		localSearch = {
			queue = ring(2, 2),
			cacheByBatteryId = {
				first = { Targets = ring(3, 1) },
				second = { Targets = ring(4, 2) },
			},
		},
	}
	iads._aaaCtx = {
		localSearch = {
			queue = ring(3, 1),
			cacheByBatteryId = {
				first = { Targets = ring(5, 4) },
			},
		},
	}
	iads._blackBoxWeaponStore = {
		_tracks = ring(12, 10),
		_cannonCandidates = ring(13, 11),
	}
	Medusa.Services.BlackBoxService._cacheOrder = ring(14, 12)
	Medusa.Core.IadsById.red = iads
	MSS.register({ "network" })
	MSS.installSnapshot()

	local output = MS.serialize()
	local expected = {
		death_primary = { "red", 1, 4 },
		death_overflow = { "red", 2, 3 },
		shot = { "red", 3, 5 },
		kill = { "red", 4, 6 },
		hit = { "red", 5, 7 },
		terminal_impact = { "red", 6, 8 },
		birth_primary = { "red", 7, 9 },
		birth_overflow = { "red", 8, 10 },
		sensor_scan_cache = { "red", 9, 11 },
		track_position_history = { "red", 2, 3 },
		manpad_scan_rotation = { "red", 2, 2 },
		manpad_target_cache = { "red", 3, 7 },
		aaa_scan_rotation = { "red", 1, 3 },
		aaa_target_cache = { "red", 4, 5 },
		blackbox_metadata_cache = { "__mission__", 12, 14 },
		blackbox_weapon_tracks = { "__mission__", 10, 12 },
		blackbox_cannon_candidates = { "__mission__", 11, 13 },
	}
	for buffer, values in pairs(expected) do
		local labels = string.format('network="%s",buffer="%s"', values[1], buffer)
		lu.assertStrContains(output, string.format("medusa_ringbuffer_items{%s} %d", labels, values[2]))
		lu.assertStrContains(output, string.format("medusa_ringbuffer_capacity_items{%s} %d", labels, values[3]))
	end
end
