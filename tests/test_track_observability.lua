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

local function network(tracks, batteries)
	local empty = view({})
	local trackStore = view(tracks)
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
			return { Posture = C.Posture.HOT_WAR, AAA = { AudioRangeM = 6000 } }
		end,
		getBorderPolygonsLL = function()
			return {}
		end,
	}
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
	lu.assertStrContains(
		output,
		'medusa_battery_info{network="red",battery="SAM-1",role="GENERIC_SAM",status="ACTIVE",state="INITIALIZING",target="AW0001",target_track="ULID-1",'
	)
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

	lu.assertStrContains(
		output,
		'medusa_battery_last_chance{network="red",battery="SAM-1",track="ULID-1",display_track="AW0001"}'
	)
end
