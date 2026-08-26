# Track identifier metric contract

Extended per-track metrics retain the canonical ULID in the `track` label. They expose the operator-facing identifier in the `display_track` label. `medusa_battery_info` uses the display ID in `target` and the canonical ULID in `target_track`. It also exposes the closed `control` and `coordination` labels for the tactical display. Consumers shall use canonical labels for joins and display labels for legends, tables, and tooltips.

HARM diagnostics expose the feature definitions used by the Medusa 1.3.0 likelihood model.

| Metric | Purpose | Type and unit | Labels | Consumer and lifecycle |
|---|---|---|---|---|
| `medusa_track_sprt_hdg` | Expose horizontal heading rate | Gauge, radians per second | `network`, `track`, `display_track` | HARM diagnostics; exists while the track assessment is live |
| `medusa_track_sprt_acc` | Expose three-dimensional speed change | Gauge, metres per second squared | `network`, `track`, `display_track` | HARM diagnostics; exists while the track assessment is live |

The mission exporter writes each snapshot to a non-`.prom` temporary file. It closes that file before replacing `medusa_metrics.prom`, so Node Exporter reads the previous complete snapshot or the next complete snapshot rather than a truncated file.

| Prefix | Originating source |
|---|---|
| `AW` | AWACS |
| `AE` | Early Warning Radar group |
| `AB` | SAM battery |
| `AS` | Shipborne radar |
| `AC` | Other airborne datalink participant |

The display ID has a four-digit octal suffix from `0001` through `7777`. If display metadata is unavailable, operator surfaces use `UNSET` instead of exposing the canonical ULID. Adding a display label does not increase the number of active series because each canonical track has one display ID. The label-schema change causes one replacement series per affected metric during an upgrade. Old series remain until Prometheus marks them stale. Extended telemetry remains opt-in.

# Partition and world-event metric contracts

`IadsNetwork` owns partition-refresh and bounded world-event metrics. The `event` label uses a closed domain, and `network` is bounded by the configured network set. These standard metrics do not include an asset, unit, track, or partition identifier. Counters and summaries reset with the mission. Queue-depth gauges are set on every steady-state network tick.

| Metric | Purpose | Type and unit | Labels | Consumer and lifecycle |
|---|---|---|---|---|
| `medusa_partition_refresh_attempts_total` | Count partition bootstrap and scheduled refresh starts | Counter, attempts | `network` | Capacity diagnostics; increments before each bounded snapshot build |
| `medusa_partition_refresh_failures_total` | Count bootstrap, capture, or processing failures that retain the prior snapshot | Counter, failures | `network` | Reliability diagnostics; increments once per failed operation |
| `medusa_partition_provider_overflow_total` | Count battery coverage evaluations with more than 128 intersecting providers | Counter, evaluations | `network` | Coverage-capacity diagnostics; increments after staging each completed evaluation, including a later publication failure |
| `medusa_world_events_dropped_total` | Count death, shot, kill, and birth records not retained by their bounded overflow policy | Counter, events | `network`, `event` | Overflow diagnostics; `event` is `DEATH`, `SHOT`, `KILL`, or `BIRTH` |
| `medusa_world_event_queue_depth` | Expose queued death, shot, kill, and birth records | Gauge, events | `network`, `event` | Backlog diagnostics; all four series are set on each steady-state network tick |
| `medusa_ammo_reconciliation_queue_depth` | Expose battery-unit ammunition identities awaiting bounded reconciliation | Gauge, identities | `network` | Backlog diagnostics; set on each steady-state network tick |
| `medusa_ringbuffer_items` | Expose current entries in every persistent RingBuffer category | Gauge, items | `network`, `buffer` | Performance-dashboard gauges; replaced before every metrics serialization |
| `medusa_ringbuffer_capacity_items` | Expose current capacity in every persistent RingBuffer category | Gauge, items | `network`, `buffer` | Performance-dashboard utilization; replaced before every metrics serialization |

The `buffer` label has fourteen per-network values: `death_primary`, `death_overflow`, `shot`, `kill`, `hit`, `terminal_impact`, `birth_primary`, `birth_overflow`, `sensor_scan_cache`, `track_position_history`, `manpad_scan_rotation`, `manpad_target_cache`, `aaa_scan_rotation`, and `aaa_target_cache`. It has three mission-wide values under `network="__mission__"`: `blackbox_metadata_cache`, `blackbox_weapon_tracks`, and `blackbox_cannon_candidates`. Track histories and target caches are aggregated by category. Temporary rings used to replace one logical buffer are not separate categories.

For `N` active networks, the RingBuffer contracts add `28N + 6` bounded series. The remaining partition and event contracts create at most twelve scalar series per network. Event overflow invokes its event-specific retention, invalidation, or diagnostic policy; the counter does not claim that DCS will redeliver an event.

## Tactical C2 state

Extended tactical telemetry projects current battery control and partition state. The projection does not add state to a battery and does not expose the partition incarnation key. It sorts the current partition keys and assigns the snapshot-local display values `P1` through `P65`. A value of `0` means `UNASSIGNED`. The display identifier can change after a split, merge, sustainment transition, or membership change.

| Metric | Purpose | Type and unit | Labels | Consumer and lifecycle |
|---|---|---|---|---|
| `medusa_battery_info` | Expose battery metadata, control mode, and coordination state | Gauge, dimensionless | `network`, `battery`, `role`, `status`, `state`, `target`, `target_track`, `system`, `control`, `coordination` | Tactical display while extended telemetry is enabled; the active metadata series has value 1 |
| `medusa_battery_partition` | Expose the current snapshot-local partition display identifier | Gauge, partition ordinal | `network`, `battery` | Tactical display while extended telemetry is enabled; replaced on each snapshot |
| `medusa_battery_harm_defenders` | Expose viable HARM-defense capacity available to attempt protection | Gauge, defense points | `network`, `battery` | Extended HARM diagnostics; capacity may be fractional |
| `medusa_battery_harm_ratio` | Expose available defense capacity divided by the current threat count | Gauge, ratio | `network`, `battery` | Extended HARM diagnostics; zero when no HARM threatens the battery |
| `medusa_battery_harm_committed_capacity` | Expose viable defense capacity that is HOT and assigned to a current threatening HARM | Gauge, defense points | `network`, `battery` | Extended HARM diagnostics; a defense success claim uses this value |
| `medusa_battery_harm_committed_ratio` | Expose committed defense capacity divided by the current threat count | Gauge, ratio | `network`, `battery` | Extended HARM diagnostics; zero when no HARM threatens the battery |
| `medusa_manpad_partition` | Expose the current snapshot-local MANPAD partition display identifier | Gauge, partition ordinal | `network`, `manpad` | Tactical display while extended telemetry is enabled; replaced on each snapshot |

`control` is one of `COORDINATED`, `AUTONOMOUS`, `SELF_DEFENSE`, `GO_DARK`, `INDEPENDENT`, or `UNKNOWN`. `coordination` is `COORDINATED` or `DEGRADED`. The tactical display shows both values as text and uses a separate partition-colored halo, so the existing activation-state and AAA-response colors retain their meaning. For `B` networked batteries and `M` MANPAD groups, the partition gauges add exactly `B + M` active extended series. Control or coordination changes replace one active `medusa_battery_info` series. The repository bounds the combined battery population at 512.

# Local-defense metric contracts

`ManpadService` records MANPAD runtime metrics. `MetricsSnapshot` owns metric registration, current-state collection, and Prometheus exposition. All metrics reset with the mission-script process. The tactical display treats a missing extended series as unavailable data, not as zero.

| Metric | Purpose | Type and unit | Labels | Consumer and lifecycle |
|---|---|---|---|---|
| `medusa_manpad_state` | Count managed MANPAD groups in each sleep/wake state | Gauge, groups | `network`, `state` | Grafana MANPAD State panel; all five state series are set on each snapshot |
| `medusa_manpad_activations_total` | Count ALERT-to-HOT transitions | Counter, activations | `network` | Grafana MANPAD Activity panel; increments after every required activation wrapper returns true and resets with the mission |
| `medusa_manpad_visual_detections_total` | Count wakes triggered by directional visual detection | Counter, wakes | `network` | Grafana MANPAD Activity panel; increments once per visual-triggered wake and resets with the mission |
| `medusa_manpad_audio_wakes_total` | Count wakes triggered by omnidirectional audio proximity | Counter, wakes | `network` | Grafana MANPAD Activity panel; increments once per audio-triggered wake and resets with the mission |
| `medusa_manpad_neighbor_wakes_total` | Count previously ASLEEP groups that received a new delayed wake schedule because a nearby MANPAD group entered HOT | Counter, wakes | `network` | Grafana MANPAD Activity panel; increments once per successful schedule and resets with the mission |
| `medusa_manpad_position_refreshes_total` | Count successful cached MANPAD heading refreshes performed with a unit-position refresh | Counter, refreshes | `network` | Operational metric; increments after the unit and group spatial indexes update and resets with the mission |
| `medusa_manpad_winchester_total` | Count groups that exhaust their cached ammunition | Counter, groups | `network` | Grafana MANPAD Activity panel; increments on the positive-to-zero ammunition transition and resets with the mission |
| `medusa_manpad_autonomous_scans_total` | Count completed autonomous DCS world searches | Counter, searches | `network` | Grafana MANPAD Activity panel; increments only when a group consumes one scan token and resets with the mission |
| `medusa_manpad_autonomous_cache_reuses_total` | Count evaluations that reused a fresh positive or negative autonomous scan result | Counter, reuses | `network` | Grafana MANPAD Activity panel; excludes the first processing pass after each scan and resets with the mission |
| `medusa_manpad_autonomous_scan_queue_depth` | Expose the number of live MANPAD groups in the round-robin scan rotation | Gauge, groups | `network` | Set on each MANPAD evaluation; stale group identifiers are removed when the live group set changes |
| `medusa_manpad_autonomous_scan_duration_seconds` | Measure one autonomous DCS world search and its bounded result collection | Summary, seconds | `network`, `quantile` | Grafana performance panel; each network retains at most 1,000 observations for p50, p90, and p99 |
| `medusa_manpad_eval_duration_seconds` | Measure one network MANPAD evaluation phase | Summary, seconds | `network`, `quantile` | Grafana performance panel; includes cache refresh and all group evaluations and retains at most 1,000 observations per network |
| `medusa_manpad_latitude_degrees` | Expose the cached group latitude | Gauge, degrees | `network`, `manpad` | Tactical display while extended telemetry is enabled; replaced on each snapshot |
| `medusa_manpad_longitude_degrees` | Expose the cached group longitude | Gauge, degrees | `network`, `manpad` | Tactical display while extended telemetry is enabled; replaced on each snapshot |
| `medusa_manpad_info` | Expose the current sleep/wake state, retained wake reason, authoritative detection mode, fire readiness, and independent control mode | Gauge, dimensionless | `network`, `manpad`, `state`, `wake_reason`, `detection_mode`, `can_fire`, `control` | Tactical display while extended telemetry is enabled; the active state series has value 1 |
| `medusa_manpad_heading_degrees` | Expose each cached ammo-bearing unit heading clockwise from north | Gauge, degrees | `network`, `manpad`, `heading_index` | Tactical display while extended telemetry is enabled; replaced on each snapshot |
| `medusa_manpad_narrow_detection_range_meters` | Expose the authoritative narrow-cone range | Gauge, meters | None | Tactical display while extended telemetry is enabled; derived from `Medusa.Constants.Manpad.NARROW_RANGE_M` |
| `medusa_manpad_wide_detection_range_meters` | Expose the authoritative wide-cone range | Gauge, meters | None | Tactical display while extended telemetry is enabled; derived from the narrow range and `Medusa.Constants.Manpad.WIDE_RANGE_FACTOR` |
| `medusa_manpad_narrow_detection_half_angle_degrees` | Expose the authoritative narrow-cone half-angle | Gauge, degrees | None | Tactical display while extended telemetry is enabled; derived from `Medusa.Constants.Manpad.COS_NARROW` |
| `medusa_manpad_wide_detection_half_angle_degrees` | Expose the authoritative wide-cone half-angle | Gauge, degrees | None | Tactical display while extended telemetry is enabled; derived from `Medusa.Constants.Manpad.COS_WIDE` |

For `G` exported MANPAD groups and `U` cached ammo-bearing unit headings, local-defense telemetry adds `4 + 4G + U` active extended series, including the partition gauge. The autonomous scheduler adds eight standard series per network: two counters, one gauge, three summary quantiles, one summary sum, and one summary count. Group state changes cause series churn in `medusa_manpad_info`. The `manpad` label follows the tactical display's existing mission-asset naming contract. Extended telemetry remains opt-in.

`wake_reason` is a closed label with the values `NONE`, `IADS`, `AUDIO`, `VISUAL`, `NEIGHBOR`, `REARM`, and `RECOVERY`. The value returns to `NONE` when the group returns to `ASLEEP`.

`can_fire` is `true` only when the group is HOT, its DCS activation state is HOT, its operational status is ACTIVE, and its cached ammunition is greater than zero. Otherwise, the value is `false`.

The tactical display anchors every cached unit heading at the cached group position. Medusa retains each managed unit position for bounded spatial evaluation, but the tactical display does not expose those individual positions.

## AAA

`AaaService` owns AAA event updates. `MetricsSnapshot` owns registration, current-state collection, and exposition. Grafana consumes standard metrics, which reset or are replaced with the mission. The tactical display consumes extended metrics only while extended telemetry is enabled. The state metric uses the bounded `network`, `mode`, and `state` labels. Other standard metrics use `network`. Extended tactical metrics use mission group names and remain opt-in.

| Metric | Purpose | Type and unit | Labels |
|---|---|---|---|
| `medusa_aaa_state` | Count AAA groups by operating mode and response state | Gauge, groups | `network`, `mode`, `state` |
| `medusa_aaa_visual_detections_total` | Count successful visual detections | Counter, detections | `network` |
| `medusa_aaa_audio_attempts_total` | Count audio detection rolls | Counter, attempts | `network` |
| `medusa_aaa_audio_detections_total` | Count successful audio detections | Counter, detections | `network` |
| `medusa_aaa_area_fire_responses_total` | Count area-fire responses | Counter, responses | `network` |
| `medusa_aaa_barrage_responses_total` | Count barrage responses started | Counter, responses | `network` |
| `medusa_aaa_barrage_bursts_total` | Count 10-15-second barrage bursts started | Counter, bursts | `network` |
| `medusa_aaa_barrage_infections_total` | Count AAA groups activated by nearby barrage fire | Counter, groups | `network` |
| `medusa_aaa_local_acquisition_responses_total` | Count local-acquisition responses | Counter, responses | `network` |
| `medusa_aaa_position_refreshes_total` | Count successful cached AAA heading refreshes performed with a unit-position refresh | Counter, refreshes | `network` |
| `medusa_aaa_local_searches_total` | Count completed local DCS world searches | Counter, searches | `network` |
| `medusa_aaa_local_search_cache_reuses_total` | Count evaluations that reused cached local-search results | Counter, reuses | `network` |
| `medusa_aaa_local_search_queue_depth` | Expose the local-search rotation depth | Gauge, groups | `network` |
| `medusa_aaa_local_search_duration_seconds` | Measure one local DCS world search | Summary, seconds | `network`, `quantile` |
| `medusa_aaa_eval_duration_seconds` | Measure one network AAA evaluation phase | Summary, seconds | `network`, `quantile` |
| `medusa_aaa_info` | Expose the current operating mode and response state | Gauge, dimensionless | `network`, `aaa`, `mode`, `state` |
| `medusa_aaa_heading_degrees` | Expose each cached AAA gun heading clockwise from north | Gauge, degrees | `network`, `aaa`, `heading_index` |
| `medusa_aaa_visual_detection_range_meters` | Expose the visual detection range | Gauge, meters | None |
| `medusa_aaa_visual_detection_half_angle_degrees` | Expose the visual detection half-angle | Gauge, degrees | None |
| `medusa_aaa_audio_range_meters` | Expose the configured audio detection range | Gauge, meters | `network` |

For `N` active networks, `G` exported AAA groups, and `U` cached gun headings, AAA adds `2 + N + G + U` active extended series. Changes to `mode` or `state` replace the active `medusa_aaa_info` series. The tactical display draws independent AAA visual sectors and audio ranges from these metrics.

Counters reset with the mission. State gauges are replaced on each snapshot. Local-search and evaluation summaries retain at most 1,000 observations per network. Extended heading, state, and detection-geometry metrics exist only while extended telemetry is enabled.

# Crew-suppression metric contracts

`BlackBoxService` owns mission-wide weapon-tracker metrics. `IadsNetwork` owns per-network impact-queue and managed-unit refresh metrics. `CrewSuppressionService` owns application, recovery, duration, and dropped-event metrics. All series reset with the mission.

`medusa_tick_duration_seconds` exports p50, p90, p95, and p99. Use p95 from equivalent suppression-disabled and suppression-enabled mission runs to verify the performance requirement.

| Metric | Purpose | Type and unit | Labels | Consumer and lifecycle |
|---|---|---|---|---|
| `medusa_battery_unit_position_refreshes_total` | Count successful managed battery-unit position refreshes | Counter, refreshes | `network` | Operational capacity and movement diagnostics; increments after cached position and applicable spatial indexes update |
| `medusa_crew_suppression_weapons_tracked` | Expose the current number of weapon candidates in the mission-wide tracker | Gauge, weapons | None | Capacity diagnostics; set after each bounded tracker update |
| `medusa_crew_suppression_weapon_outcomes_total` | Count bounded weapon-tracker outcomes | Counter, outcomes | `outcome` | Tracker diagnostics; the closed values are `TRACKED`, `TRACKER_FULL`, `UNTRACKABLE`, `EXPIRED`, `IMPACT_HIT`, `IMPACT_TERRAIN`, and `NO_TERRAIN_INTERSECTION` |
| `medusa_crew_suppression_impact_queue_depth` | Expose explosive impacts awaiting per-network proximity evaluation | Gauge, impacts | `network` | Queue-capacity diagnostics; set after each bounded impact-processing phase |
| `medusa_crew_suppression_applications_total` | Count crew-suppression applications and reapplications | Counter, applications | `network`, `cause` | Action diagnostics; `cause` is the closed value `DAMAGE` or `EXPLOSIVE` |
| `medusa_crew_suppression_recoveries_total` | Count completed crew-suppression recoveries | Counter, recoveries | `network`, `cause` | Recovery diagnostics; increments when a battery clears crew suppression |
| `medusa_crew_suppression_duration_seconds` | Measure the effective suppression duration at application time | Histogram, seconds | `network`, `cause`, `le` | Duration diagnostics; uses the registered fixed duration buckets and resets with the mission |
| `medusa_crew_suppression_dropped_events_total` | Count rejected or expired suppression inputs | Counter, events | `network`, `reason` | Boundary and capacity diagnostics; `reason` uses `CrewSuppressionDropReason` and never includes unit or weapon names |

For `N` active networks, the standard crew-suppression metrics add one tracker gauge, seven initialized tracker-outcome counter series, and bounded per-network series. Mission group names, unit names, weapon names, and impact identifiers are excluded from metric labels.
