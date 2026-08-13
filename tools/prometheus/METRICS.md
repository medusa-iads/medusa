# MANPAD metric contracts

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
