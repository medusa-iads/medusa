# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog (https://keepachangelog.com/en/1.1.0/),
and this project adheres to Semantic Versioning (https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Removed

### Deprecated


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

[Unreleased]: https://github.com/medusa-iads/medusa/compare/v1.4.0...HEAD
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
