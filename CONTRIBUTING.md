# Contributing to Medusa

Thanks for your interest in contributing to Medusa. This document covers what you need to know before submitting code.

## Versioning

Medusa uses [Semantic Versioning 2.0.0](https://semver.org/)

## Changelog 

Medusa uses [keep a changelog](https://keepachangelog.com/en/1.1.0/) format for its changelog. All changes should be documented under ## [Unreleased] in CHANGELOG.md as they're made, not at release time. Describe what the user will observe, not implementation details. Use the standard categories: Added, Changed, Deprecated, Removed, Fixed, Security.

## Project structure

```
  -- These get built into the release artifact
  src/core/             IadsNetwork tick loop, Config, Constants, Logger
  src/entities/         Plain data tables: Battery, Track, Doctrine, SensorUnit
  src/services/         Stateless logic: TargetAssigner, TrackClassifier, EmconService, etc.
  src/services/stores/  Collection managers: BatteryStore, TrackStore, SensorUnitStore
  dependencies/         dcs-harness (vendored)
  
  -- These don't
  tests/                LuaUnit tests, one file per module
  scripts/build/        Python build and release scripts
  tools/                StyLua, Selene configs, Prometheus/Grafana dashboards
  ```

## Before you start

- **Check existing issues first.** If you want to work on something, comment on the issue or open one to discuss your approach before writing code. I will not approve a PR that comes in blind without any discussion

## Setting up

**Prerequisites:**
- DCS World for integration testing
- Lua 5.1
- Python 3.13+ (build scripts)
- [Task](https://taskfile.dev) v3+ (build runner and local automated workflows)

**Verify your setup:**
```bash
task test          # 278 tests, 0 failures
task build         # produces dist/medusa.lua and dist/medusa-thin.lua
```

## How to write code for Medusa

**Lua 5.1 only.** DCS World uses Lua 5.1. No `goto`, no bitwise operators, no integer dGivision, no `#` on tables with gaps. CI has a guard to check for invalid Lua 5.2 code.

**Use dcs-harness wrappers.** All DCS API calls go through [dcs-harness](https://github.com/YoloWingPixie/dcs-harness) functions (`GetGroupController`, `ControllerSetAlarmState`, etc). Never call DCS APIs directly. Check `dependencies/harness.lua` for available wrappers.

**No lookup tables.** Medusa does not hardcode SAM performance data. Sensor ranges, weapon envelopes, and unit roles come from DCS APIs at runtime. This is what makes modded SAMs work automatically and also keep Medusa easy to maintain when things out of our control change.

**No omniscient logic.** IADS decisions must only use information a real air defense network could derive from its own sensors: position, velocity, radar cross-section, altitude, and heading. Never use DCS metadata that implies perfect knowledge: unit names, type names, coalition IDs, getDesc() on detected objects, or group composition.

**Cache at init, not per tick.** Static unit properties (sensor ranges, weapon envelopes, unit roles, ammo descriptors) are queried once at discovery and stored on the entity. If you need a DCS API result in a hot path, it should already be on the Battery or SensorUnit. The only per-tick DCS calls should be for information that is dynamic and changeable.

**When solving a problem, ask how it can be solved reliably, but non-deterministically** There are already IADS scripts out there that check if track went up and then down to categorize it as a HARM. This provide a binary yes/no result with 100% predictable performance. Real life IADS are fallible but competent. Medusa should arrive at correct answers 90% of the time in variable amount of time per decision.

**Use GeoGrid for spatial lookups** Never do O(Battery X Track) distance or other types of comparisons where we do check everything of A against everything of B. At least use the spatial services available to only check a subset of batteries against a track.

## Code Style
- Modules are namespaced tables (Medusa.Services.TargetAssigner, Medusa.Entities.Battery)
- Entities are plain tables with named fields, not metatabled objects. 
- Services are stateless modules with public functions that receive stores and entities as
 arguments. 
- State lives on entities and stores, not on services.
- The call graph is explicit: IadsNetwork calls services, services read and mutate entities through stores.
- Functions are short (Well...keep the business and hot path logic under 20-30 LOC please) and do one thing.
- Complex logic is decomposed into named helpers with early returns rather than deep nesting.
- When a loop body has more than two conditions, each condition gets its own helper that returns a value or nil. The parent loop stays flat.
- Don't use module level locals outside of `do ... end` blocks. The build process will concatenate all source files into one release file and Lua has a 200 local variable limit. 
- Do not imitate inheritance unless it improves the readability of the code
- Do not use [mixins](https://en.wikipedia.org/wiki/Mixin) if you do end up using inheritance. 
- Do follow [Data-Oriented Design](https://www.dataorienteddesign.com/dodbook/node2.html) principles.

## Making changes

- **Small, vertical slices.** Each change should produce observable behavior and be independently testable. Target 30-80 lines per atomic change. Build the simplest working version first, then evolve it in a future PR.

- **Test what you change.** Tests live in `tests/` and use LuaUnit. If you change parser behavior or doctrine defaults, update the test assertions to match. Don't delete tests without good reason.

- **[Write tests. Not too many. Mostly integration.](https://kentcdodds.com/blog/write-tests)** Test behavior, not implementation. A good test calls a public function with realistic inputs and checks the output or side effect. A bad test verifies that a constructor stored what it was given. Favor integration tests that exercise real code paths over isolated unit tests that mock internal services. Mock DCS APIs (they don't exist in the test environment), but not Medusa internals. If a test doesn't protect against a plausible bug, it's noise. Focus on edge cases that crash missions: nil positions, pruned tracks, zero-ammo batteries, concurrent HARM shutdowns. Please test your changes with log evidence in actual DCS missions.

- **Run `task ci`** before uploading.

## Submitting a PR

- One concern per PR. Don't bundle a bug fix with a refactor.
- Run `task ci` locally before pushing. Tests, formatting, and lint must all pass.
- PRs are squash-merged. The squash message should follow [Conventional Commits](https://www.conventionalcommits.org/) format (`feat:`, `fix:`, `refactor:`, `docs:`, `ci:`, `test:`, `chore:`), with up to 8 bullet points in the body describing notable changes.
- If your change touches activation, EMCON, or engagement logic, test it in a live DCS mission before opening the PR.
- If your change adds or modifies user-facing behavior, add an entry under `## [Unreleased]` in `CHANGELOG.md`.

## Things to know

- **Dot-Echelon naming reads top-down.** Group names go highest echelon first, unit last: `RED.1div.1bde.1bn.sa10`. The opposite of domain names.

- **`pushTask`, never `setTask`** for ground unit movement. `setTask` wipes the entire task queue and can permanently halt units.

- **`Unit:getSensors()` is buggy.** It can return sensor data from other units in the group. Medusa works around this with sensor probing at init rather than trusting runtime sensor queries.

## Docs site

The docs site is Astro Starlight in `website/`. Content is Markdown in `website/src/content/docs/`. The content config must use `docsLoader()` from `@astrojs/starlight/loaders` (Astro 5 requirement). Run `task docs` to preview locally.

## Questions?

Open an issue or start a discussion. We'd rather answer questions early than review a PR that went in the wrong direction.
