# Local-defense metric contracts

`ManpadService` records MANPAD runtime metrics. `MetricsSnapshotService` owns metric registration, current-state collection, and Prometheus exposition. All metrics reset with the mission-script process. The tactical display treats a missing extended series as unavailable data, not as zero.

| Metric | Purpose | Type and unit | Labels | Consumer and lifecycle |
|---|---|---|---|---|
| `medusa_manpad_state` | Count managed MANPAD groups in each sleep/wake state | Gauge, groups | `network`, `state` | Grafana MANPAD State panel; all five state series are set on each snapshot |
| `medusa_manpad_activations_total` | Count ALERT-to-HOT transitions | Counter, activations | `network` | Grafana MANPAD Activity panel; increments after DCS accepts activation and resets with the mission |
| `medusa_manpad_visual_detections_total` | Count wakes triggered by directional visual detection | Counter, wakes | `network` | Grafana MANPAD Activity panel; increments once per visual-triggered wake and resets with the mission |
| `medusa_manpad_audio_wakes_total` | Count wakes triggered by omnidirectional audio proximity | Counter, wakes | `network` | Grafana MANPAD Activity panel; increments once per audio-triggered wake and resets with the mission |
| `medusa_manpad_neighbor_wakes_total` | Count previously ASLEEP groups that received a new delayed wake schedule because a nearby MANPAD group entered HOT | Counter, wakes | `network` | Grafana MANPAD Activity panel; increments once per successful schedule and resets with the mission |
| `medusa_manpad_position_refreshes_total` | Count successful cached position and heading refreshes | Counter, refreshes | `network` | Operational metric; increments after the GeoGrid update and resets with the mission |
| `medusa_manpad_winchester_total` | Count groups that exhaust their cached ammunition | Counter, groups | `network` | Grafana MANPAD Activity panel; increments on the positive-to-zero ammunition transition and resets with the mission |
| `medusa_manpad_autonomous_scans_total` | Count completed autonomous DCS world searches | Counter, searches | `network` | Grafana MANPAD Activity panel; increments only when a group consumes one scan token and resets with the mission |
| `medusa_manpad_autonomous_cache_reuses_total` | Count evaluations that reused a fresh positive or negative autonomous scan result | Counter, reuses | `network` | Grafana MANPAD Activity panel; excludes the first processing pass after each scan and resets with the mission |
| `medusa_manpad_autonomous_scan_queue_depth` | Expose the number of live MANPAD groups in the round-robin scan rotation | Gauge, groups | `network` | Set on each MANPAD evaluation; stale group identifiers are removed when the live group set changes |
| `medusa_manpad_autonomous_scan_duration_seconds` | Measure one autonomous DCS world search and its bounded result collection | Summary, seconds | `network`, `quantile` | Grafana performance panel; each network retains at most 1,000 observations for p50, p90, and p99 |
| `medusa_manpad_eval_duration_seconds` | Measure one network MANPAD evaluation phase | Summary, seconds | `network`, `quantile` | Grafana performance panel; includes cache refresh and all group evaluations and retains at most 1,000 observations per network |
| `medusa_manpad_latitude_degrees` | Expose the cached group latitude | Gauge, degrees | `network`, `manpad` | Tactical display while extended telemetry is enabled; replaced on each snapshot |
| `medusa_manpad_longitude_degrees` | Expose the cached group longitude | Gauge, degrees | `network`, `manpad` | Tactical display while extended telemetry is enabled; replaced on each snapshot |
| `medusa_manpad_info` | Expose the current sleep/wake state, retained wake reason, authoritative detection mode, and fire readiness | Gauge, dimensionless | `network`, `manpad`, `state`, `wake_reason`, `detection_mode`, `can_fire` | Tactical display while extended telemetry is enabled; the active state series has value 1 |
| `medusa_manpad_heading_degrees` | Expose each cached ammo-bearing unit heading clockwise from north | Gauge, degrees | `network`, `manpad`, `heading_index` | Tactical display while extended telemetry is enabled; replaced on each snapshot |
| `medusa_manpad_narrow_detection_range_meters` | Expose the authoritative narrow-cone range | Gauge, meters | None | Tactical display while extended telemetry is enabled; derived from `Medusa.Constants.Manpad.NARROW_RANGE_M` |
| `medusa_manpad_wide_detection_range_meters` | Expose the authoritative wide-cone range | Gauge, meters | None | Tactical display while extended telemetry is enabled; derived from the narrow range and `Medusa.Constants.Manpad.WIDE_RANGE_FACTOR` |
| `medusa_manpad_narrow_detection_half_angle_degrees` | Expose the authoritative narrow-cone half-angle | Gauge, degrees | None | Tactical display while extended telemetry is enabled; derived from `Medusa.Constants.Manpad.COS_NARROW` |
| `medusa_manpad_wide_detection_half_angle_degrees` | Expose the authoritative wide-cone half-angle | Gauge, degrees | None | Tactical display while extended telemetry is enabled; derived from `Medusa.Constants.Manpad.COS_WIDE` |

For `G` exported MANPAD groups and `U` cached ammo-bearing unit headings, this change adds `4 + 3G + U` active extended series. The autonomous scheduler adds eight standard series per network: two counters, one gauge, three summary quantiles, one summary sum, and one summary count. Group state changes cause series churn in `medusa_manpad_info`. The `manpad` label follows the tactical display's existing mission-asset naming contract. Extended telemetry remains opt-in because the repository has no fixed mission asset limit or active-series budget.

`wake_reason` is a closed label with the values `NONE`, `IADS`, `AUDIO`, `VISUAL`, `NEIGHBOR`, `REARM`, and `RECOVERY`. The value returns to `NONE` when the group returns to `ASLEEP`.

`can_fire` is `true` only when the group is HOT, its DCS activation state is HOT, its operational status is ACTIVE, and its cached ammunition is greater than zero. Otherwise, the value is `false`.

The tactical display anchors every cached unit heading at the cached group position. Medusa does not retain an individual position for each MANPAD soldier.

## AAA

`AaaService` owns AAA event updates. `MetricsSnapshotService` owns registration, current-state collection, and exposition. Grafana consumes standard metrics, which reset or are replaced with the mission. The tactical display consumes extended metrics only while extended telemetry is enabled. The state metric uses the bounded `network`, `mode`, and `state` labels. Other standard metrics use `network`. Extended tactical metrics use mission group names and remain opt-in.

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
| `medusa_aaa_position_refreshes_total` | Count successful cached position and heading refreshes | Counter, refreshes | `network` |
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
