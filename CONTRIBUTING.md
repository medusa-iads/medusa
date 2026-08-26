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
- [uv](https://docs.astral.sh/uv/) 0.10.12 (Python quality tools)
- [Task](https://taskfile.dev) v3+ (build runner and local automated workflows)

**Verify your setup:**
```bash
task test          # runs the Lua test suite
task build         # produces dist/medusa.lua and dist/medusa-thin.lua
task complexity:check  # reports Lua complexity warnings
```

## Lua complexity

`task complexity:check` analyzes production code in `src/`. It reports cyclomatic
complexity, function NLOC, parameter count, and duplicate-code percentage.

The check is advisory. It warns when cyclomatic complexity exceeds 17, function
NLOC exceeds 100, or a function has more than 8 parameters. CI annotates only
changed functions and includes the repository summary in its pull request comment.

## Core design tenets

### 1. Performance is correctness

Runtime performance is part of functional correctness. A feature shall not have a disproportionate effect on mission performance at runtime.

- Each recurring operation shall have a defined work budget.
- Discovery shall cache static DCS values, including sensor ranges, weapon envelopes, unit roles, and ammo descriptors.
- The `Battery` or `SensorUnit` that owns a cached DCS value shall store that value.
- Each other cache shall define its lifetime and invalidation rules.
- A tick shall call DCS only for information that changes at runtime.
- Medusa code shall not compare every item in one set with every item in another set. For example, it shall not compare every battery with every track.
- Code that runs frequently during a tick shall reuse buffers.
- A tick shall not perform unbounded work.
- Spatial lookups shall use `GeoGrid` and the existing spatial services.
- Each spatial lookup shall limit its search distance to the range required by its task.

### 2. Model the IADS, not a DCS database

Medusa shall use only information that a real-world IADS could obtain. Examples include position, velocity, radar cross-section, altitude, heading, and engagement history.

- Medusa shall not hardcode SAM performance data.
- Medusa shall get sensor ranges, weapon envelopes, and unit roles from DCS at runtime.
- When code evaluates a track, it shall treat the detected object's unit name, type name, coalition ID, `getDesc()` result, and group composition as omniscient metadata.
- Code may use omniscient metadata as a surrogate only when DCS does not provide information that a real-world IADS could obtain.
- The contributor shall document why the surrogate is necessary.
- The contributor shall document the real-world information that the surrogate represents.

Runtime discovery lets modded SAMs work without database updates. It also limits maintenance when DCS changes.

### 3. Base randomness on realistic uncertainty

- Random behavior shall represent realistic uncertainty.
- Random behavior shall not exist only to make Medusa unpredictable.
- Random behavior shall not replace available evidence.
- Decision logic shall not use predictable timers or thresholds when the modeled behavior has realistic uncertainty.

For example, some IADS scripts classify a track as a HARM when it climbs and then descends. This fixed rule always produces the same result. Medusa instead uses evidence over time to model a competent but fallible decision. The result and decision time can vary.

### 4. Make mission configuration declarative

- Mission makers shall not have to write imperative code to configure the IADS.
- Each behavior control exposed to mission makers shall be available through a config or doctrine setting.

### 5. Follow the ownership model

- Services shall implement stateless behavior.
- Each public service function shall receive its required entities and stores through function arguments.
- Entities and stores shall own runtime state.
- `IadsNetwork` shall coordinate calls between services.
- Services shall use stores to read and mutate entities.

### 6. Be reliable

A runtime fault shall not stop the DCS mission. Runtime faults include a missing unit, a corrupt store, a failed phase, and a lost radar.

- Medusa shall contain and log each failure.
- Medusa shall use defined degraded behavior when normal operation cannot continue.
- Before Medusa stops after an unrecoverable failure, it shall release controlled units to autonomous DCS AI.

### 7. Keep Medusa focused

- Medusa shall orchestrate the anti-aircraft activities of one or more coalitions in a DCS mission.
- Medusa shall support different threat responses for different factions.
- A proposed feature shall directly support one of these responsibilities.
- Contributors shall treat a feature that does not support one of these responsibilities as outside the scope of Medusa.

## How to write code for Medusa

**Lua 5.1 only.** DCS World uses Lua 5.1. No `goto`, no bitwise operators, no integer dGivision, no `#` on tables with gaps. CI has a guard to check for invalid Lua 5.2 code.

**Use dcs-harness wrappers.** All DCS API calls go through [dcs-harness](https://github.com/YoloWingPixie/dcs-harness) functions (`GetGroupController`, `ControllerSetAlarmState`, etc). Never call DCS APIs directly. Check `dependencies/harness.lua` for available wrappers.

## Code Style

- Modules are namespaced tables (Medusa.Services.TargetAssigner, Medusa.Entities.Battery)
- Entities are plain tables with named fields, not metatabled objects. 
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

## Questions?

Open an issue or start a discussion. We'd rather answer questions early than review a PR that went in the wrong direction.
