# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog (https://keepachangelog.com/en/1.1.0/),
and this project adheres to Semantic Versioning (https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Command-and-control partitions based on mission HQ placement, live command providers, and radar coverage.

### Changed

- HQ groups present when Medusa starts now define fixed hierarchy boundaries. Destroying their command providers can split or degrade the network.
- Root HQ groups now provide the common command link between top-level branches. Losing every root HQ isolates those branches until a selected root HQ unit returns.
- Batteries without radar coverage operate through their configured autonomous or self-defense doctrine instead of receiving coordinated control.
- HARM assessment now samples tracks every two seconds, requires at least five observations.
- HARM defense now considers viable defensive capacity before remaining active and reports committed defense only after defenders are HOT and assigned to an active HARM.
- Point defenders now select protected sites and HARM targets by role, readiness, partition, and distance. One defender may protect more than one nearby site.
- `SAMAsEWR = "WHEN_NO_EWR"` now selects eligible SAM radar providers separately inside each disconnected command partition.

### Fixed

- Batteries no longer cycle rapidly between COLD and HOT when a HARM track becomes stale.
- HARM assessment considers projected paths toward managed radar batteries, including batteries that have stopped emitting.
- HQ groups tagged as EWR or GCI retain both their command and sensor roles.
- A malformed network entry no longer prevents other configured networks from starting.
- User callback and delayed initialization failures no longer stop Medusa's recurring scheduler.
- Sustained DCS event bursts no longer cause unbounded event-queue growth.
- SAM and MANPAD batteries no longer deactivate while a recently observed missile can still be in flight.
- Reused DCS object identifiers no longer preserve stale track or event ownership.
- Large track counts no longer cause unbounded recurring HARM-response work.
- A failed point-defense activation now falls through to AUTO defense or shutdown for the same HARM.
- Close point defenders can engage a HARM even when its path is inside the normal minimum range for aircraft engagements.
- Confirmed HARM defense can replace an ordinary aircraft assignment instead of making the assigned battery unavailable.
- Target assignment handoff no longer releases a confirmed-HARM assignment.
- A track inferred to be a HARM launcher can no longer also be classified as a HARM.
- Temporary sensor controller or position failures no longer permanently remove a live EWR, GCI, or AWACS from the network.
- Malformed or unusually large DCS detection results no longer stop sensor polling or monopolize a network tick.
- Missed death events are reconciled during normal unit refresh, including correct degradation when a battery loses its last search radar.
- Delayed crew-suppression HIT events no longer affect a replacement unit that reused the same DCS identifier.
- Events with a stable unit identifier remain usable when DCS omits the unit name or weapon type.
- SHOT events with missing weapon details still update activity and shot counters, without decrementing ammunition.
- `S_EVENT_UNIT_LOST`, `DEAD`, and `CRASH` now use the same unit-removal behavior.
- Leading or trailing spaces in configured group names no longer prevent discovery.
- Partition splits and rejoins no longer leave obsolete tracks consuming capacity or affecting the new partition.
- Guilt-by-association, hostile-intent, and HARM-launcher inference no longer cross disconnected command partitions.
- HQ loss and restoration remain recoverable when unrelated DCS death events arrive in a large burst.
- A destroyed HQ provider no longer blocks a later managed unit that reuses its DCS unit identifier.

### Removed

- The unused `DefendPk` doctrine option. Normal aircraft kill probability no longer prevents a HARM-defense attempt.


## [1.5.0] - 2026-08-21
### Added

- Damage-based crew suppression for managed AAA and MANPAD groups, with doctrine controls, a configurable group-diameter eligibility limit, bounded HIT processing, group-level weapon hold, recovery, and Prometheus observability.
- Bomb- and missile-impact crew suppression with a mission-shared bounded weapon tracker, cube-root blast-radius policy, exact per-unit proximity, bounded spatial queries, and refreshed positions for all managed battery units.
- Aircraft cannon-burst crew suppression with bounded gravity-aware terrain-point estimation and shared terminal-event evaluation.
- Defender crew skill from mission ground-unit data, with doctrine-controlled fallback and resistance effects on suppression probability and duration.

### Changed

- Updated the vendored dcs-harness dependency to 1.0.1 for validated unit-health snapshots.
- Crew suppression now samples each damage, explosive, or cannon suppression duration from a doctrine-configured range that defaults to 30–120 seconds.
- Cannon suppression now defaults to a 150-metre uncertainty radius for forward-vector impact estimates.
- Cannon suppression DEBUG logs now identify subscription handles, the exact boundary or ballistic-projection rejection stage, and the estimate's distance from the nearest indexed defender visited by the bounded spatial query.

### Fixed

- Radar-capable batteries with `BatteryTargetDatalink` enabled now report detections while WARM, allowing their own periodic or continuous radar scans to produce tracks and trigger doctrine-controlled engagement.
- Re-associated tracks now preserve their identification dwell time, allowing `BANDIT` tracks observed during periodic scans to become `HOSTILE` under `TIGHT` rules of engagement.
- Track re-association now accounts for movement during sensor gaps by checking the last observed position and its constant-velocity projection.
- HARM assessment now retains cumulative evidence across decisions and track re-association, and reverses an existing classification only after evidence crosses the opposing decision threshold.
- HARM assessment now accumulates evidence during its 25-observation decision floor, preventing a short aircraft attack arc from discarding its preceding non-HARM evidence.
- HARM evidence and track-identification promotion now process each sensor observation once, preventing retained tracks from accumulating evidence or changing identification while unobserved.

## [1.4.0] - 2026-08-20
### Added

- Source-derived operator track IDs for tactical displays, Grafana, and human-readable logs while retaining ULIDs as internal identifiers.

## [1.3.1] - 2026-08-19
### Added

- `MANPAD.AudioRangeM` doctrine control for the maximum MANPAD audio-detection range.

### Changed

- MANPAD doctrine controls now use the `MANPAD` subtable, consistent with AAA doctrine controls.

### Fixed

- `AAA.AreaFireChance` is now limited to `0.5`, so the inverted nighttime chance cannot be lower than the daytime chance.

### Deprecated

- Flat `MANPADAlertnessDecaySec` and `MANPADFieldRadioRangeM` doctrine fields remain compatibility aliases for the nested MANPAD fields.

## [1.3.0] - 2026-08-18
### Added

- Managed AAA groups with local visual and audio detection, area and barrage fire, nearby barrage propagation, and radar-directed operation.
- AAA doctrine controls for audio range, area-fire and barrage chances, and the map-wide barrage group limit.
- AAA shell-ammunition tracking, with a 12 km fallback range when DCS omits shell range data.

### Changed

- Release archives now contain Lua artifacts with the Medusa version in their filenames.
- Updated the bundled dcs-harness dependency to 1.0.0 and migrated ground-plane geometry to its DCS Vec2 and Vec3 contracts.
- `EngageTactics` limits now count missile batteries only; AAA assignments do not consume or block missile-battery slots.
- Local MANPAD and independent AAA groups now use a separate spatial index so they do not enlarge long-range IADS candidate queries.
- Radar-directed AAA that loses its search radar now releases its target and point-defense assignments before switching to independent behavior.

### Fixed

- Release-tag builds now stamp the exact tag version in generated artifacts.
- HOT independent AAA is no longer considered an emitter during HARM classification.
- `SHOOT_LOOK_SHOOT` now permits one VLR and one standard missile battery to engage the same track.
- Ground sensor groups now receive their configured ROE, alarm, and emissions state on the first EMCON pass.

## [1.2.0] - 2026-08-12
### Added

- Managed MANPAD groups with autonomous detection and engagement, coordinated wake behavior, ammunition and rearm handling, and tactical-map and Prometheus observability.

### Changed

- Reduced per-tick memory allocation in HARM detection by reusing the feature-cache slot across evaluations

### Fixed

- `MaxEngageRangePct` doctrine cap now applies to ALWAYS_ON batteries self-assigning under EMCON, matching WTA and handoff behavior
- Guilt-by-association no longer promotes STALE tracks without fresh sensor evidence
- Unrecoverable-failure shutdown is now resilient to store corruption and completes the release-to-AI path instead of silently halting
- SEAD-priority assignment now respects the `MaxEngageRangePct` doctrine cap; out-of-range batteries can no longer be force-assigned to HARM/SEAD threats ahead of the greedy assignment loop

## [1.1.3] - 2026-04-09

### Changed

- Add priority-sorted HARM evaluation: tracks ordered by altitude * velocity hash, confirmed HARMs are deprioritized. The top 1/3rd of tracks are now guaranteed to be evaluated, with budget remainder (minimum 1/3rd of the total budget) being used to evaluate remaining tracks.
- Add adaptive SPRT min-scans that reduces the 15-scan floor proportionally to back pressure, so HARMs will be confirmed in fewer steps under high back pressure.
- Fix despawned airborne sensors not removed from store during position update
- Rename "SPRT" to "ARM" in HARM detection log messages

### Fixed

- Despawned airborne sensors (AWACS, EWR) no longer spam "Unit not found" log messages indefinitely

## [1.1.2] - 2026-04-08
### Added

- `AllowDynamicProbing` configuration option (default: off) enables spawning sensor probe groups at runtime to extract detection ranges for unit types not encountered at mission start

### Removed

- HEAVY aircraft type classification; unreliable heuristic based on sustained straight flight that misidentified transiting fighters as bombers

### Fixed

- Dynamically added batteries and probing results now update the maximum engagement range used for spatial queries
- Dynamically spawned batteries now receive detection range data from the probe cache, correcting engagement range calculations for late-spawned SAMs
- HARM ballistic CPA simulation now covers the configured duration regardless of time step size
- Point defense threat search centers on the SHORAD provider's position instead of the protected battery
- VLR_SAM batteries now receive target assignments under SHOOT_LOOK_SHOOT doctrine
- HARM detection no longer force-confirms tracks at the SUSPECT confidence level when scans are exhausted; requires PROBABLE or higher

## [1.1.1] - 2026-04-07
### Fixed

- Emergency shutdown on unrecoverable failure now correctly releases batteries to autonomous AI
- Destroyed or despawned sensor units (EWR, AWACS) are now removed from the sensor store instead of being polled indefinitely
- Batteries with no remaining ammo are now deactivated instead of staying HOT indefinitely
- Doctrine range cap (MaxEngageRangePct) now applied consistently in handoff evaluation and EMCON self-assign, preventing handoffs to out-of-range batteries

## [1.1.0] - 2026-04-07
### Added

- Runtime EMCON control API: `setEMCON`, `getEMCON`, `setScanTiming`, `getScanTiming`, `setRotationGroups`, `getRotationGroups`

### Fixed

- Hostile intent never promoted BANDIT to HOSTILE in WARM_WAR and COLD_WAR postures without border zones

## [1.0.2] - 2026-04-06

### Fixed

- Group names using underscores, hyphens, or other separators after the network prefix were not discovered (e.g., `RSAM_SA2` with prefix `RSAM`)

## [1.0.1] - 2026-04-06
### Added

- Medusa shuts itself down after prolonged unrecoverable failure and releases all batteries to autonomous DCS AI

### Changed

- HARM evaluator no longer copies the full position history buffer each tick, reducing per-tick memory allocation by ~39%

### Fixed

- Rare edge case where NaN kill probability could abort the assignment phase
- Missing position on a track during handoff evaluation silently aborted the maintain phase for that tick

## [1.0.0] - 2026-04-07

### Added
	- Initial Release

[Unreleased]: https://github.com/medusa-iads/medusa/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/medusa-iads/medusa/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/medusa-iads/medusa/compare/v1.3.1...v1.4.0
[1.3.1]: https://github.com/medusa-iads/medusa/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/medusa-iads/medusa/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/medusa-iads/medusa/compare/v1.1.3...v1.2.0
[1.1.3]: https://github.com/medusa-iads/medusa/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/medusa-iads/medusa/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/medusa-iads/medusa/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/medusa-iads/medusa/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/medusa-iads/medusa/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/medusa-iads/medusa/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/medusa-iads/medusa/releases/tag/v1.0.0
