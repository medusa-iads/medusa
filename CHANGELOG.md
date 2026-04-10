# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog (https://keepachangelog.com/en/1.1.0/),
and this project adheres to Semantic Versioning (https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Fixed

### Removed

### Deprecated


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

[Unreleased]: https://github.com/medusa-iads/medusa/compare/v1.1.3...HEAD
[1.1.3]: https://github.com/medusa-iads/medusa/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/medusa-iads/medusa/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/medusa-iads/medusa/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/medusa-iads/medusa/compare/v1.0.2...v1.1.0
[1.0.2]: https://github.com/medusa-iads/medusa/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/medusa-iads/medusa/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/medusa-iads/medusa/releases/tag/v1.0.0
