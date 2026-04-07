require("_header")
require("services.Services")
require("services.MetricsService")
require("services.BlackBoxService")
require("services.HarmDetectionService")
require("services.PkModel")
require("core.Constants")

--[[
            ███╗   ███╗███████╗████████╗██████╗ ██╗ ██████╗███████╗    ███████╗███╗   ██╗ █████╗ ██████╗ ███████╗██╗  ██╗ ██████╗ ████████╗
            ████╗ ████║██╔════╝╚══██╔══╝██╔══██╗██║██╔════╝██╔════╝    ██╔════╝████╗  ██║██╔══██╗██╔══██╗██╔════╝██║  ██║██╔═══██╗╚══██╔══╝
            ██╔████╔██║█████╗     ██║   ██████╔╝██║██║     ███████╗    ███████╗██╔██╗ ██║███████║██████╔╝███████╗███████║██║   ██║   ██║
            ██║╚██╔╝██║██╔══╝     ██║   ██╔══██╗██║██║     ╚════██║    ╚════██║██║╚██╗██║██╔══██║██╔═══╝ ╚════██║██╔══██║██║   ██║   ██║
            ██║ ╚═╝ ██║███████╗   ██║   ██║  ██║██║╚██████╗███████║    ███████║██║ ╚████║██║  ██║██║     ███████║██║  ██║╚██████╔╝   ██║
            ╚═╝     ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝ ╚═════╝╚══════╝    ╚══════╝╚═╝  ╚═══╝╚═╝  ╚═╝╚═╝     ╚══════╝╚═╝  ╚═╝ ╚═════╝   ╚═╝

    What this service does
    - Registers all Prometheus metric definitions (gauges, counters, histograms, summaries).
    - Installs a snapshot callback that reads live IADS state and writes gauge values before each serialize.

    How others use it
    - IadsNetwork calls register during initialization to define all metrics.
    - MetricsService triggers the snapshot callback before each serialization cycle.
--]]

Medusa.Services.MetricsSnapshotService = {}
Medusa.Services.MetricsSnapshotService._prevSnapshotMemKb = 0

function Medusa.Services.MetricsSnapshotService.register(netLabel)
	local MetricsService = Medusa.Services.MetricsService

	MetricsService.gauge("medusa_mission_time_seconds", "Seconds since mission start")
	MetricsService.gauge("medusa_mission_info", "Mission metadata", { "mission", "theatre", "start" })
	MetricsService.gauge("medusa_batteries_total", "Total batteries in network", netLabel)
	MetricsService.gauge("medusa_sensors_total", "Total sensors in network", netLabel)
	MetricsService.gauge("medusa_tracks_active", "Active tracks in network", netLabel)
	MetricsService.counter("medusa_ticks_total", "Total ticks processed", netLabel)

	MetricsService.counter("medusa_battery_go_hot_total", "Battery transitions to HOT", netLabel)
	MetricsService.counter("medusa_battery_go_warm_total", "Battery transitions to WARM", netLabel)
	MetricsService.counter("medusa_battery_go_cold_total", "Battery transitions to COLD", netLabel)
	MetricsService.counter("medusa_battery_destroyed_total", "Batteries destroyed", netLabel)
	MetricsService.counter("medusa_shots_fired_total", "Shots fired by IADS batteries", netLabel)
	MetricsService.counter("medusa_kills_total", "Kills scored by IADS batteries", netLabel)
	MetricsService.counter("medusa_tracks_created_total", "Tracks created", netLabel)
	MetricsService.counter("medusa_tracks_expired_total", "Tracks expired and removed", netLabel)
	MetricsService.counter("medusa_engagements_assigned_total", "Engagement assignments made", netLabel)
	MetricsService.counter("medusa_harm_confirmed_total", "Tracks confirmed as HARM", netLabel)
	MetricsService.counter("medusa_harm_shutdowns_total", "Batteries shut down due to HARM", netLabel)
	MetricsService.counter("medusa_last_chance_activated_total", "Last-chance salvo windows activated", netLabel)
	MetricsService.counter("medusa_last_chance_fired_total", "Shots fired during last-chance salvo", netLabel)
	MetricsService.counter("medusa_roe_changes_total", "Runtime ROE changes via API", netLabel)
	MetricsService.counter("medusa_track_promotions_total", "Track identification promotions", netLabel)

	MetricsService.gauge("medusa_rolling_pk", "Network rolling kill probability", netLabel)
	MetricsService.gauge("medusa_effective_pk_floor", "Effective PkFloor after rolling adjustment", netLabel)
	MetricsService.gauge("medusa_batteries_hot", "Batteries in HOT state", netLabel)
	MetricsService.gauge("medusa_batteries_warm", "Batteries in WARM state", netLabel)
	MetricsService.gauge("medusa_batteries_cold", "Batteries in COLD state", netLabel)
	MetricsService.gauge("medusa_engagements_active", "Batteries currently engaging targets", netLabel)
	MetricsService.gauge("medusa_tracks_hostile", "Tracks identified as HOSTILE", netLabel)
	MetricsService.gauge("medusa_tracks_harm", "Tracks assessed as HARM", netLabel)
	MetricsService.gauge("medusa_ammo_remaining", "Total missiles remaining across all batteries", netLabel)
	MetricsService.gauge("medusa_batteries_rearming", "Batteries out of ammo awaiting rearm", netLabel)

	local defaultQuantiles = { 0.5, 0.9, 0.99 }
	MetricsService.summary(
		"medusa_tick_duration_seconds",
		"Total tick processing time",
		defaultQuantiles,
		nil,
		netLabel
	)
	MetricsService.summary(
		"medusa_poll_sensors_duration_seconds",
		"Sensor polling step time",
		defaultQuantiles,
		nil,
		netLabel
	)
	MetricsService.summary(
		"medusa_prune_stale_duration_seconds",
		"Track pruning step time",
		defaultQuantiles,
		nil,
		netLabel
	)
	MetricsService.summary(
		"medusa_classification_duration_seconds",
		"Track classification + aircraft type assessment",
		defaultQuantiles,
		nil,
		netLabel
	)
	MetricsService.summary(
		"medusa_harm_eval_duration_seconds",
		"HARM detection + response + point defense",
		defaultQuantiles,
		nil,
		netLabel
	)
	MetricsService.summary(
		"medusa_assignment_duration_seconds",
		"Target assignment (autonomous + WTA)",
		defaultQuantiles,
		nil,
		netLabel
	)
	MetricsService.summary(
		"medusa_handoff_duration_seconds",
		"Handoffs + deactivations + HARM cleanup",
		defaultQuantiles,
		nil,
		netLabel
	)
	MetricsService.summary("medusa_emcon_duration_seconds", "EMCON policy application", defaultQuantiles, nil, netLabel)
	MetricsService.histogram(
		"medusa_track_age_at_expiry_seconds",
		"Track age when expired",
		{ 5, 15, 30, 60, 120, 300, 600 },
		netLabel
	)
	MetricsService.histogram(
		"medusa_track_updates_at_expiry",
		"Number of sensor updates a track received before expiring",
		Medusa.Constants.TRACK_UPDATE_EXPIRY_BUCKETS,
		netLabel
	)
	-- Pipeline chunk throughput
	local phaseLabel = { "network", "phase" }
	MetricsService.gauge("medusa_chunk_processed", "Items processed in last chunk invocation", phaseLabel)
	MetricsService.gauge("medusa_chunk_queued", "Items remaining in chunk queue", phaseLabel)

	-- Error tracking
	MetricsService.gauge("medusa_tick_failures_consecutive", "Consecutive tick failures", netLabel)
	MetricsService.gauge("medusa_phase_failures_consecutive", "Consecutive phase failures", { "network", "phase" })

	-- Debug/diagnostic metrics
	MetricsService.gauge("medusa_batteries_damaged", "Batteries with degraded operational status", netLabel)
	MetricsService.gauge("medusa_batteries_shutdown", "Batteries in HARM shutdown", netLabel)
	MetricsService.gauge("medusa_batteries_suppressed", "Batteries suppressed by HARMs (went cold)", netLabel)
	MetricsService.gauge("medusa_batteries_self_defending", "Batteries self-defending against HARMs", netLabel)
	MetricsService.gauge(
		"medusa_batteries_pd_protected",
		"Batteries protected by point defense against HARMs",
		netLabel
	)
	MetricsService.gauge("medusa_tracks_unknown", "Tracks identified as UNKNOWN", netLabel)
	MetricsService.gauge("medusa_tracks_bogey", "Tracks identified as BOGEY", netLabel)
	MetricsService.gauge("medusa_tracks_bandit", "Tracks identified as BANDIT", netLabel)
	MetricsService.gauge("medusa_tracks_sprt_evaluating", "Tracks under SPRT HARM evaluation", netLabel)
	MetricsService.counter("medusa_assignment_pairs_evaluated", "Battery-track pairs evaluated", netLabel)
	MetricsService.counter("medusa_detections_total", "Total sensor detections", netLabel)
	MetricsService.counter("medusa_goHot_blocked_total", "goHot calls blocked by holddown or state", netLabel)
	MetricsService.counter("medusa_sensor_empty_polls_total", "Sensor polls returning zero detections", netLabel)

	-- GC / memory metrics
	MetricsService.gauge("medusa_lua_memory_kb", "Lua heap size in kilobytes")
	MetricsService.gauge("medusa_lua_memory_delta_kb", "Lua heap growth since last snapshot in kilobytes")
	MetricsService.gauge("medusa_tick_memory_before_kb", "Lua heap size at tick start in kilobytes")
	MetricsService.gauge("medusa_tick_memory_after_kb", "Lua heap size at tick end in kilobytes")

	MetricsService.info("medusa_damaged_batteries_info", "Names of batteries with degraded status", "names")
	MetricsService.info("medusa_shutdown_batteries_info", "Names of batteries in HARM shutdown", "names")

	-- Serialize duration stays unlabeled: it spans all networks in a single operation
	MetricsService.summary("medusa_serialize_duration_seconds", "Time to serialize all metrics", defaultQuantiles)
end

function Medusa.Services.MetricsSnapshotService.installSnapshot()
	local ms = Medusa.Services.MetricsService

	-- Cache mission metadata at install time (env.mission is accessible now but not during timer callbacks)
	-- selene: allow(undefined_variable)
	local mName = (env and env.mission and (env.mission.sortie or env.mission.filename)) or "unknown"
	local mTheatre = (env and env.mission and env.mission.theatre) or "unknown"
	local mStart = "unknown"
	if env and env.mission then
		local d = env.mission.date
		local t = env.mission.start_time or 0
		if d and d.Year then
			local hours = math.floor(t / 3600)
			local minutes = math.floor((t % 3600) / 60)
			mStart = string.format("%04d-%02d-%02d:%02d-%02d", d.Year, d.Month, d.Day, hours, minutes)
		end
	end
	local missionLabels = { mission = mName, theatre = mTheatre, start = mStart }

	ms.onSnapshot(function()
		local iadsById = Medusa.Core.IadsById
		if not iadsById then
			return
		end
		ms.set("medusa_mission_time_seconds", GetTime())
		ms.set("medusa_mission_info", 1, missionLabels)

		local memNow = collectgarbage("count")
		local MSS = Medusa.Services.MetricsSnapshotService
		ms.set("medusa_lua_memory_kb", memNow)
		ms.set("medusa_lua_memory_delta_kb", memNow - MSS._prevSnapshotMemKb)
		MSS._prevSnapshotMemKb = memNow

		local AS = Medusa.Constants.ActivationState
		local BOS = Medusa.Constants.BatteryOperationalStatus
		local TI = Medusa.Constants.TrackIdentification
		local AAT = Medusa.Constants.AssessedAircraftType
		local allDamagedNames = {}
		local allShutdownNames = {}

		for id, iads in pairs(iadsById) do
			local labels = { network = id }
			local ai = iads:getAssetIndex()
			if ai then
				ms.set("medusa_batteries_total", ai:batteries():count(), labels)
				ms.set("medusa_sensors_total", ai:sensors():count(), labels)

				local batteries = ai:batteries():getAll()
				local hotCount, warmCount, coldCount, engagedCount = 0, 0, 0, 0
				local damagedCount, shutdownCount, rearmingCount = 0, 0, 0
				local suppressedCount, selfDefendCount, pdProtectedCount = 0, 0, 0
				local totalAmmo = 0
				for i = 1, #batteries do
					local b = batteries[i]
					if b.ActivationState == AS.STATE_HOT then
						hotCount = hotCount + 1
					elseif b.ActivationState == AS.STATE_WARM then
						warmCount = warmCount + 1
					elseif b.ActivationState == AS.STATE_COLD then
						coldCount = coldCount + 1
					end
					if b.CurrentTargetTrackId then
						engagedCount = engagedCount + 1
					end
					if
						b.OperationalStatus == BOS.SEARCH_ONLY
						or b.OperationalStatus == BOS.ENGAGEMENT_IMPAIRED
						or b.OperationalStatus == BOS.INOPERATIVE
					then
						damagedCount = damagedCount + 1
						allDamagedNames[#allDamagedNames + 1] = b.GroupName
					end
					if b.HarmShutdownUntil then
						shutdownCount = shutdownCount + 1
						allShutdownNames[#allShutdownNames + 1] = b.GroupName
					end
					totalAmmo = totalAmmo + (b.TotalAmmoStatus or 0)
					if b.RearmCheckTime then
						rearmingCount = rearmingCount + 1
					end
					local HDS = Medusa.Constants.HarmDefenseState
					if b.HarmDefenseState == HDS.SUPPRESSED then
						suppressedCount = suppressedCount + 1
					elseif b.HarmDefenseState == HDS.SELF_DEFENDING then
						selfDefendCount = selfDefendCount + 1
					elseif b.HarmDefenseState == HDS.PD_PROTECTED then
						pdProtectedCount = pdProtectedCount + 1
					end
				end
				ms.set("medusa_batteries_hot", hotCount, labels)
				ms.set("medusa_batteries_warm", warmCount, labels)
				ms.set("medusa_batteries_cold", coldCount, labels)
				ms.set("medusa_engagements_active", engagedCount, labels)
				ms.set("medusa_batteries_damaged", damagedCount, labels)
				ms.set("medusa_batteries_shutdown", shutdownCount, labels)
				ms.set("medusa_batteries_suppressed", suppressedCount, labels)
				ms.set("medusa_batteries_self_defending", selfDefendCount, labels)
				ms.set("medusa_batteries_pd_protected", pdProtectedCount, labels)
				ms.set("medusa_ammo_remaining", totalAmmo, labels)
				ms.set("medusa_batteries_rearming", rearmingCount, labels)

				local rpkVal = 0
				if iads._rollingPkCount >= Medusa.Constants.ROLLING_PK_WINDOW then
					local rpkSum = 0
					for ri = 1, iads._rollingPkCount do
						rpkSum = rpkSum + iads._rollingPkBuffer[ri]
					end
					rpkVal = rpkSum / iads._rollingPkCount
				end
				ms.set("medusa_rolling_pk", rpkVal, labels)
				ms.set("medusa_effective_pk_floor", iads._effectivePkFloor, labels)

				local tm = iads:getTrackManager()
				if tm then
					local trackStore = tm:getStore()
					ms.set("medusa_tracks_active", trackStore:count(), labels)
					local tracks = trackStore:getAll()
					local hostileCount, harmCount = 0, 0
					local unknownCount, bogeyCount, banditCount, sprtCount = 0, 0, 0, 0
					for i = 1, #tracks do
						local t = tracks[i]
						if t.TrackIdentification == TI.HOSTILE then
							hostileCount = hostileCount + 1
						end
						if t.AssessedAircraftType == AAT.HARM then
							harmCount = harmCount + 1
						end
						if t.TrackIdentification == TI.UNKNOWN then
							unknownCount = unknownCount + 1
						elseif t.TrackIdentification == TI.BOGEY then
							bogeyCount = bogeyCount + 1
						elseif t.TrackIdentification == TI.BANDIT then
							banditCount = banditCount + 1
						end
						if
							t.HarmLikelihoodScore
							and t.HarmLikelihoodScore > 0
							and t.AssessedAircraftType ~= AAT.HARM
						then
							sprtCount = sprtCount + 1
						end
					end
					ms.set("medusa_tracks_hostile", hostileCount, labels)
					ms.set("medusa_tracks_harm", harmCount, labels)
					ms.set("medusa_tracks_unknown", unknownCount, labels)
					ms.set("medusa_tracks_bogey", bogeyCount, labels)
					ms.set("medusa_tracks_bandit", banditCount, labels)
					ms.set("medusa_tracks_sprt_evaluating", sprtCount, labels)
				end
			end
		end

		ms.setInfo("medusa_damaged_batteries_info", table.concat(allDamagedNames, ","))
		ms.setInfo("medusa_shutdown_batteries_info", table.concat(allShutdownNames, ","))

		if Medusa.Config:get().PrometheusExtendEnabled then
			local extLines = {}
			local en = 0
			en = en + 1
			extLines[en] = "# HELP medusa_track_detail Per-track detailed state"
			en = en + 1
			extLines[en] = "# TYPE medusa_track_detail gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_track_lat Track latitude (WGS84)"
			en = en + 1
			extLines[en] = "# TYPE medusa_track_lat gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_track_lon Track longitude (WGS84)"
			en = en + 1
			extLines[en] = "# TYPE medusa_track_lon gauge"

			for id, iads in pairs(iadsById) do
				local tm = iads:getTrackManager()
				if tm then
					local trackStore = tm:getStore()
					local tracks = trackStore:getAll()
					local now = GetTime()
					for i = 1, #tracks do
						local t = tracks[i]
						local tid = t.TrackId
						if t.Position then
							en = en + 1
							extLines[en] = string.format(
								'medusa_track_pos_x{network="%s",track="%s"} %s',
								id,
								tid,
								tostring(t.Position.x)
							)
							en = en + 1
							extLines[en] = string.format(
								'medusa_track_pos_y{network="%s",track="%s"} %s',
								id,
								tid,
								tostring(t.Position.y)
							)
							en = en + 1
							extLines[en] = string.format(
								'medusa_track_pos_z{network="%s",track="%s"} %s',
								id,
								tid,
								tostring(t.Position.z)
							)
							local okLL, lat, lon = pcall(coord.LOtoLL, t.Position)
							if okLL and lat and lon then
								en = en + 1
								extLines[en] =
									string.format('medusa_track_lat{network="%s",track="%s"} %.6f', id, tid, lat)
								en = en + 1
								extLines[en] =
									string.format('medusa_track_lon{network="%s",track="%s"} %.6f', id, tid, lon)
							end
						end
						if t.Velocity then
							en = en + 1
							extLines[en] = string.format(
								'medusa_track_vel_x{network="%s",track="%s"} %s',
								id,
								tid,
								tostring(t.Velocity.x)
							)
							en = en + 1
							extLines[en] = string.format(
								'medusa_track_vel_y{network="%s",track="%s"} %s',
								id,
								tid,
								tostring(t.Velocity.y)
							)
							en = en + 1
							extLines[en] = string.format(
								'medusa_track_vel_z{network="%s",track="%s"} %s',
								id,
								tid,
								tostring(t.Velocity.z)
							)
							local spd = math.sqrt(
								t.Velocity.x * t.Velocity.x + t.Velocity.y * t.Velocity.y + t.Velocity.z * t.Velocity.z
							)
							en = en + 1
							extLines[en] =
								string.format('medusa_track_speed{network="%s",track="%s"} %.1f', id, tid, spd)
						end
						en = en + 1
						extLines[en] = string.format(
							'medusa_track_updates{network="%s",track="%s"} %d',
							id,
							tid,
							t.UpdateCount or 0
						)
						if t.FirstDetectionTime then
							en = en + 1
							extLines[en] = string.format(
								'medusa_track_age{network="%s",track="%s"} %.1f',
								id,
								tid,
								now - t.FirstDetectionTime
							)
						end
						if t.HarmLikelihoodScore then
							en = en + 1
							extLines[en] = string.format(
								'medusa_track_harm_score{network="%s",track="%s"} %.3f',
								id,
								tid,
								t.HarmLikelihoodScore
							)
						end
					end
				end
			end

			en = en + 1
			extLines[en] = "# HELP medusa_track_info Per-track classification info"
			en = en + 1
			extLines[en] = "# TYPE medusa_track_info gauge"
			local BBS = Medusa.Services.BlackBoxService
			for id, iads in pairs(iadsById) do
				local tm = iads:getTrackManager()
				if tm then
					local tracks = tm:getStore():getAll()
					for i = 1, #tracks do
						local t = tracks[i]
						local bb = BBS.get(t.NetworkId)
						local typeName = bb and bb.TypeName or ""
						local unitName = bb and bb.UnitName or ""
						en = en + 1
						extLines[en] = string.format(
							'medusa_track_info{network="%s",track="%s",type="%s",unit="%s",identification="%s",aircraft_type="%s",maneuver="%s"} 1',
							id,
							t.TrackId,
							typeName,
							unitName,
							t.TrackIdentification or "UNKNOWN",
							t.AssessedAircraftType or "UNKNOWN",
							t.ManeuverState or "UNKNOWN"
						)
					end
				end
			end

			local HDS = Medusa.Services.HarmDetectionService
			local networkStates = HDS._networkStates
			en = en + 1
			extLines[en] = "# HELP medusa_track_sprt_llr SPRT log-likelihood ratio"
			en = en + 1
			extLines[en] = "# TYPE medusa_track_sprt_llr gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_track_sprt_scans SPRT scan count"
			en = en + 1
			extLines[en] = "# TYPE medusa_track_sprt_scans gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_track_sprt_info SPRT evaluation label"
			en = en + 1
			extLines[en] = "# TYPE medusa_track_sprt_info gauge"
			local featNames = { "spd", "div", "hdg", "acc", "cpa", "cpr", "rng", "alt" }
			local featHelp = {
				"Track ground speed in m/s",
				"Dive angle toward nearest emitter, positive means descending toward it",
				"Heading change rate in rad/s, near zero means flying straight",
				"Acceleration in m/s2, negative means decelerating",
				"Closest point of approach to nearest emitter in meters",
				"Rate of change of CPA in m/s, negative means converging on emitter",
				"Range closure rate toward nearest emitter in m/s, negative means closing",
				"Altitude rate in m/s, negative means descending",
			}
			for fi = 1, 8 do
				en = en + 1
				extLines[en] = string.format("# HELP medusa_track_sprt_%s %s", featNames[fi], featHelp[fi])
				en = en + 1
				extLines[en] = string.format("# TYPE medusa_track_sprt_%s gauge", featNames[fi])
			end
			for id, iads in pairs(iadsById) do
				local tm = iads:getTrackManager()
				if tm then
					local states = networkStates[tm:getStore()]
					if states then
						for trackId, state in pairs(states) do
							en = en + 1
							extLines[en] = string.format(
								'medusa_track_sprt_llr{network="%s",track="%s"} %.3f',
								id,
								trackId,
								state.llr or 0
							)
							en = en + 1
							extLines[en] = string.format(
								'medusa_track_sprt_scans{network="%s",track="%s"} %d',
								id,
								trackId,
								state.scanCount or 0
							)
							en = en + 1
							extLines[en] = string.format(
								'medusa_track_sprt_info{network="%s",track="%s",label="%s"} 1',
								id,
								trackId,
								state.label or "UNKNOWN"
							)
							if state.lastFeat then
								for fi = 1, 8 do
									en = en + 1
									extLines[en] = string.format(
										'medusa_track_sprt_%s{network="%s",track="%s"} %.2f',
										featNames[fi],
										id,
										trackId,
										state.lastFeat[fi] or 0
									)
								end
							end
						end
					end
				end
			end

			-- Battery positions
			en = en + 1
			extLines[en] = "# HELP medusa_battery_pos_x Battery position X"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_pos_x gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_battery_pos_z Battery position Z"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_pos_z gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_battery_lat Battery latitude (WGS84)"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_lat gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_battery_lon Battery longitude (WGS84)"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_lon gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_battery_cluster_lat Launcher cluster latitude (WGS84)"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_cluster_lat gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_battery_cluster_lon Launcher cluster longitude (WGS84)"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_cluster_lon gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_battery_cluster_range_m Launcher cluster max weapon range"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_cluster_range_m gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_battery_info Battery metadata"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_info gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_battery_weapon_range_m Battery weapon range meters"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_weapon_range_m gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_battery_engagement_range_m Battery engagement range meters"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_engagement_range_m gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_battery_shots_fired Per-battery total shots fired"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_shots_fired gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_battery_ammo Per-battery ammo remaining"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_ammo gauge"
			for id, iads in pairs(iadsById) do
				local ai = iads:getAssetIndex()
				if ai then
					local batts = ai:batteries():getAll()
					for i = 1, #batts do
						local b = batts[i]
						local bname = b.GroupName or b.BatteryId
						if b.Position then
							en = en + 1
							extLines[en] = string.format(
								'medusa_battery_pos_x{network="%s",battery="%s"} %.1f',
								id,
								bname,
								b.Position.x
							)
							en = en + 1
							extLines[en] = string.format(
								'medusa_battery_pos_z{network="%s",battery="%s"} %.1f',
								id,
								bname,
								b.Position.z
							)
							local okLL, lat, lon = pcall(coord.LOtoLL, b.Position)
							if okLL and lat and lon then
								en = en + 1
								extLines[en] =
									string.format('medusa_battery_lat{network="%s",battery="%s"} %.6f', id, bname, lat)
								en = en + 1
								extLines[en] =
									string.format('medusa_battery_lon{network="%s",battery="%s"} %.6f', id, bname, lon)
							end
						end
						if b.Clusters then
							for ci = 1, #b.Clusters do
								local cpos = b.Clusters[ci]
								local cOk, cLat, cLon = pcall(coord.LOtoLL, cpos)
								if cOk and cLat and cLon then
									en = en + 1
									extLines[en] = string.format(
										'medusa_battery_cluster_lat{network="%s",battery="%s",cluster="%d"} %.6f',
										id,
										bname,
										ci,
										cLat
									)
									en = en + 1
									extLines[en] = string.format(
										'medusa_battery_cluster_lon{network="%s",battery="%s",cluster="%d"} %.6f',
										id,
										bname,
										ci,
										cLon
									)
									if cpos.rangeMax then
										en = en + 1
										extLines[en] = string.format(
											'medusa_battery_cluster_range_m{network="%s",battery="%s",cluster="%d"} %.0f',
											id,
											bname,
											ci,
											cpos.rangeMax
										)
									end
								end
							end
						end
						en = en + 1
						extLines[en] = string.format(
							'medusa_battery_info{network="%s",battery="%s",role="%s",status="%s",state="%s",target="%s",system="%s"} 1',
							id,
							bname,
							b.Role or "",
							b.OperationalStatus or "",
							b.ActivationState or "",
							b.CurrentTargetTrackId or "",
							b.SystemType or ""
						)
						local primaryWeapon = ""
						if b.Units then
							local bestRange = 0
							for ui = 1, #b.Units do
								local u = b.Units[ui]
								if u.AmmoTypes then
									for ami = 1, #u.AmmoTypes do
										local at = u.AmmoTypes[ami]
										if at.RangeMax and at.RangeMax > bestRange then
											bestRange = at.RangeMax
											primaryWeapon = at.WeaponDisplayName or at.WeaponTypeName or ""
										end
									end
								end
							end
						end
						if b.WeaponRangeMax then
							en = en + 1
							extLines[en] = string.format(
								'medusa_battery_weapon_range_m{network="%s",battery="%s",weapon="%s"} %.0f',
								id,
								bname,
								primaryWeapon,
								b.WeaponRangeMax
							)
						end
						if b.EngagementRangeMax then
							en = en + 1
							extLines[en] = string.format(
								'medusa_battery_engagement_range_m{network="%s",battery="%s",system="%s"} %.0f',
								id,
								bname,
								b.SystemType or "",
								b.EngagementRangeMax
							)
						end
						en = en + 1
						extLines[en] = string.format(
							'medusa_battery_shots_fired{network="%s",battery="%s"} %d',
							id,
							bname,
							b.ShotsFired or 0
						)
						en = en + 1
						extLines[en] = string.format(
							'medusa_battery_ammo{network="%s",battery="%s"} %d',
							id,
							bname,
							b.TotalAmmoStatus or 0
						)
					end
				end
			end

			-- HARM defense state per battery
			en = en + 1
			extLines[en] = "# HELP medusa_battery_harm_defense HARM defense state per battery"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_harm_defense gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_battery_harm_threats Inbound HARMs threatening this battery"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_harm_threats gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_battery_harm_defenders HARM-capable units defending this battery"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_harm_defenders gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_battery_harm_ratio Defender to threat ratio"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_harm_ratio gauge"
			for id, iads in pairs(iadsById) do
				local ai = iads:getAssetIndex()
				if ai then
					local batts = ai:batteries():getAll()
					for i = 1, #batts do
						local b = batts[i]
						if b.HarmDefenseState then
							local bname = b.GroupName or b.BatteryId
							en = en + 1
							extLines[en] = string.format(
								'medusa_battery_harm_defense{network="%s",battery="%s",state="%s"} 1',
								id,
								bname,
								b.HarmDefenseState
							)
							en = en + 1
							extLines[en] = string.format(
								'medusa_battery_harm_threats{network="%s",battery="%s"} %d',
								id,
								bname,
								b.HarmDefenseThreats
							)
							en = en + 1
							extLines[en] = string.format(
								'medusa_battery_harm_defenders{network="%s",battery="%s"} %d',
								id,
								bname,
								b.HarmDefenseDefenders
							)
							en = en + 1
							extLines[en] = string.format(
								'medusa_battery_harm_ratio{network="%s",battery="%s"} %.2f',
								id,
								bname,
								b.HarmDefenseRatio
							)
						end
					end
				end
			end

			-- Last-chance salvo state per battery
			en = en + 1
			extLines[en] = "# HELP medusa_battery_last_chance Last-chance salvo active (1=active, 0=inactive)"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_last_chance gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_battery_last_chance_shots_remaining Missiles remaining in last-chance salvo"
			en = en + 1
			extLines[en] = "# TYPE medusa_battery_last_chance_shots_remaining gauge"
			for id, iads in pairs(iadsById) do
				local ai = iads:getAssetIndex()
				if ai then
					local batts = ai:batteries():getAll()
					for i = 1, #batts do
						local b = batts[i]
						if b.LastChanceTrackId then
							local bname = b.GroupName or b.BatteryId
							en = en + 1
							extLines[en] = string.format(
								'medusa_battery_last_chance{network="%s",battery="%s",track="%s"} 1',
								id,
								bname,
								b.LastChanceTrackId
							)
							en = en + 1
							extLines[en] = string.format(
								'medusa_battery_last_chance_shots_remaining{network="%s",battery="%s"} %d',
								id,
								bname,
								b.LastChanceShotsRemaining or 0
							)
						end
					end
				end
			end

			-- Sensor positions and info
			en = en + 1
			extLines[en] = "# HELP medusa_sensor_lat Sensor latitude (WGS84)"
			en = en + 1
			extLines[en] = "# TYPE medusa_sensor_lat gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_sensor_lon Sensor longitude (WGS84)"
			en = en + 1
			extLines[en] = "# TYPE medusa_sensor_lon gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_sensor_pos_y Sensor altitude MSL meters"
			en = en + 1
			extLines[en] = "# TYPE medusa_sensor_pos_y gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_sensor_info Sensor metadata"
			en = en + 1
			extLines[en] = "# TYPE medusa_sensor_info gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_sensor_detection_range_m Sensor detection range meters"
			en = en + 1
			extLines[en] = "# TYPE medusa_sensor_detection_range_m gauge"
			for id, iads in pairs(iadsById) do
				local ai = iads:getAssetIndex()
				if ai then
					local sensors = ai:sensors():getAll()
					for si = 1, #sensors do
						local s = sensors[si]
						local sname = s.GroupName or "unknown"
						if s.Position then
							local okLL, lat, lon = pcall(coord.LOtoLL, s.Position)
							if okLL and lat and lon then
								en = en + 1
								extLines[en] =
									string.format('medusa_sensor_lat{network="%s",sensor="%s"} %.6f', id, sname, lat)
								en = en + 1
								extLines[en] =
									string.format('medusa_sensor_lon{network="%s",sensor="%s"} %.6f', id, sname, lon)
								en = en + 1
								extLines[en] = string.format(
									'medusa_sensor_pos_y{network="%s",sensor="%s"} %.1f',
									id,
									sname,
									s.Position.y or 0
								)
							end
						end
						en = en + 1
						extLines[en] = string.format(
							'medusa_sensor_info{network="%s",sensor="%s",type="%s",airborne="%s",status="%s",radar="%s"} 1',
							id,
							sname,
							s.SensorType or "EWR",
							s.IsAirborne and "true" or "false",
							s.OperationalStatus or "",
							s.RadarStatus or "DARK"
						)
						if s.DetectionRangeMax and s.DetectionRangeMax > 0 then
							en = en + 1
							extLines[en] = string.format(
								'medusa_sensor_detection_range_m{network="%s",sensor="%s"} %.0f',
								id,
								sname,
								s.DetectionRangeMax
							)
						end
					end
				end
			end

			-- Per-track best and second-best Pk
			en = en + 1
			extLines[en] = "# HELP medusa_track_best_pk Best Pk for this track across all batteries"
			en = en + 1
			extLines[en] = "# TYPE medusa_track_best_pk gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_track_second_pk Second best Pk for this track"
			en = en + 1
			extLines[en] = "# TYPE medusa_track_second_pk gauge"
			local computePk = Medusa.Services.PkModel.computePk
			for id, iads in pairs(iadsById) do
				local ai = iads:getAssetIndex()
				local tm = iads:getTrackManager()
				if ai and tm then
					local batts = ai:batteries():getAll()
					local tracks = tm:getStore():getAll()
					for ti = 1, #tracks do
						local t = tracks[ti]
						if t.Position then
							local bestPk, bestBatt = 0, ""
							local secondPk, secondBatt = 0, ""
							for bi = 1, #batts do
								local b = batts[bi]
								if b.Position and b.EngagementRangeMax and b.EngagementRangeMax > 0 then
									local dist
									if b.Clusters then
										dist = math.huge
										for ci = 1, #b.Clusters do
											local cdx = t.Position.x - b.Clusters[ci].x
											local cdz = t.Position.z - b.Clusters[ci].z
											local cd = math.sqrt(cdx * cdx + cdz * cdz)
											if cd < dist then
												dist = cd
											end
										end
									else
										local dx = t.Position.x - b.Position.x
										local dz = t.Position.z - b.Position.z
										dist = math.sqrt(dx * dx + dz * dz)
									end
									if dist <= b.EngagementRangeMax then
										local pk = computePk(b, t, dist)
										if pk > bestPk then
											secondPk = bestPk
											secondBatt = bestBatt
											bestPk = pk
											bestBatt = b.GroupName or b.BatteryId
										elseif pk > secondPk then
											secondPk = pk
											secondBatt = b.GroupName or b.BatteryId
										end
									end
								end
							end
							en = en + 1
							extLines[en] = string.format(
								'medusa_track_best_pk{network="%s",track="%s",battery="%s"} %.3f',
								id,
								t.TrackId,
								bestBatt,
								bestPk
							)
							en = en + 1
							extLines[en] = string.format(
								'medusa_track_second_pk{network="%s",track="%s",battery="%s"} %.3f',
								id,
								t.TrackId,
								secondBatt,
								secondPk
							)
						end
					end
				end
			end

			-- Border zone polygons and posture
			en = en + 1
			extLines[en] = "# HELP medusa_posture IADS posture (HOT_WAR, WARM_WAR, COLD_WAR)"
			en = en + 1
			extLines[en] = "# TYPE medusa_posture gauge"
			en = en + 1
			extLines[en] = "# HELP medusa_border_zone Border zone polygon vertices as semicolon-separated lat,lon pairs"
			en = en + 1
			extLines[en] = "# TYPE medusa_border_zone gauge"

			for netId, iads in pairs(Medusa.Core.IadsById) do
				local doctrine = iads:getDoctrine() or {}
				local posture = doctrine.Posture or Medusa.Constants.Posture.HOT_WAR
				local adizEnabled = doctrine.ADIZEnabled and "true" or "false"
				local adizNm = doctrine.ADIZBufferNm or 12
				en = en + 1
				extLines[en] = string.format(
					'medusa_posture{network="%s",posture="%s",adiz_enabled="%s",adiz_nm="%.0f"} 1',
					netId,
					posture,
					adizEnabled,
					adizNm
				)

				local llPolys = iads:getBorderPolygonsLL()
				for zi = 1, #llPolys do
					local llPoly = llPolys[zi]
					if #llPoly > 0 then
						local parts = {}
						for vi = 1, #llPoly do
							parts[#parts + 1] = string.format("%.6f,%.6f", llPoly[vi].lat, llPoly[vi].lon)
						end
						en = en + 1
						extLines[en] = string.format(
							'medusa_border_zone{network="%s",zone_idx="%d",vertices="%s"} 1',
							netId,
							zi - 1,
							table.concat(parts, ";")
						)
					end
				end
			end

			ms.setExtended(table.concat(extLines, "\n"))
		else
			ms.setExtended("")
		end
	end)
end
