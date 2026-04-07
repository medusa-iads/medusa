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


## [1.1.0] - 2026-04-06
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

[Unreleased]: https://github.com/medusa-iads/medusa/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/medusa-iads/medusa/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/medusa-iads/medusa/releases/tag/v1.0.0
