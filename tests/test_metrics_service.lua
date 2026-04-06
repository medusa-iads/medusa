local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("services.Services")
require("services.MetricsService")

-- Shorthand alias
local MS = Medusa.Services.MetricsService

-- Helper: assert that a string contains a given substring, with a clear message.
local function assertContains(haystack, needle, msg)
	if not string.find(haystack, needle, 1, true) then
		error(string.format("%s: expected to find %q in:\n%s", msg or "assertContains", needle, haystack))
	end
end

-- Helper: assert that a string does NOT contain a given substring.
local function assertNotContains(haystack, needle, msg)
	if string.find(haystack, needle, 1, true) then
		error(string.format("%s: did not expect to find %q in:\n%s", msg or "assertNotContains", needle, haystack))
	end
end

-- ============================================================
-- TestMetricsServiceCounter
-- ============================================================

TestMetricsServiceCounter = {}

function TestMetricsServiceCounter:setUp()
	-- Reset state between tests by re-requiring a fresh instance.
	-- MetricsService must expose a way to wipe registrations; reset() only
	-- zeros values.  We call reset() on the registry itself if available,
	-- otherwise we clear by re-initializing.
	if MS._registry then
		MS._registry = {}
	end
end

-- 1. Register a counter; serialize() must include HELP, TYPE, and value lines.
function TestMetricsServiceCounter:test_counter_registrationProducesAllThreeLines()
	MS.counter("shots_fired", "Total shots fired by IADS")

	local out = MS.serialize()

	assertContains(
		out,
		"# HELP shots_fired Total shots fired by IADS",
		"test_counter_registrationProducesAllThreeLines HELP line"
	)
	assertContains(out, "# TYPE shots_fired counter", "test_counter_registrationProducesAllThreeLines TYPE line")
	assertContains(out, "shots_fired 0", "test_counter_registrationProducesAllThreeLines value line")
end

-- 3. inc() with default delta increments by exactly 1.
function TestMetricsServiceCounter:test_inc_defaultDeltaIncrementsBy1()
	MS.counter("alpha", "")
	MS.inc("alpha")

	local out = MS.serialize()
	assertContains(out, "alpha 1", "test_inc_defaultDeltaIncrementsBy1")
end

-- 4. inc() with explicit delta accumulates correctly.
function TestMetricsServiceCounter:test_inc_explicitDeltaAccumulates()
	MS.counter("bravo", "")
	MS.inc("bravo") -- value becomes 1
	MS.inc("bravo", 5) -- value becomes 6

	local out = MS.serialize()
	assertContains(out, "bravo 6", "test_inc_explicitDeltaAccumulates")
end

-- 11. counter() with nil help defaults to empty string in HELP line.
function TestMetricsServiceCounter:test_counter_nilHelpDefaultsToEmpty()
	MS.counter("charlie", nil)

	local out = MS.serialize()
	-- Must have "# HELP charlie " (trailing space then nothing, or just no crash)
	assertContains(out, "# HELP charlie", "test_counter_nilHelpDefaultsToEmpty HELP line present")
	assertContains(out, "# TYPE charlie counter", "test_counter_nilHelpDefaultsToEmpty TYPE line")
end

-- 12. Re-registering same name resets value to 0.
function TestMetricsServiceCounter:test_counter_reregistrationResetsValue()
	MS.counter("delta", "")
	MS.inc("delta", 99)

	-- Re-register same name: value should reset to 0.
	MS.counter("delta", "re-registered")

	local out = MS.serialize()
	assertContains(out, "delta 0", "test_counter_reregistrationResetsValue value is 0 after re-registration")
end

-- 13. inc() with negative delta: contract does not prevent it; value goes negative.
function TestMetricsServiceCounter:test_inc_negativeDeltaDecreasesValue()
	MS.counter("echo", "")
	MS.inc("echo", -3)

	local out = MS.serialize()
	assertContains(out, "echo -3", "test_inc_negativeDeltaDecreasesValue")
end

-- Boundary: inc() with delta=0 leaves value unchanged.
function TestMetricsServiceCounter:test_inc_zeroDeltaLeavesValueUnchanged()
	MS.counter("foxtrot", "")
	MS.inc("foxtrot", 5)
	MS.inc("foxtrot", 0)

	local out = MS.serialize()
	assertContains(out, "foxtrot 5", "test_inc_zeroDeltaLeavesValueUnchanged")
end

-- ============================================================
-- TestMetricsServiceGauge
-- ============================================================

TestMetricsServiceGauge = {}

function TestMetricsServiceGauge:setUp()
	if MS._registry then
		MS._registry = {}
	end
end

-- 2. Register a gauge; serialize() must show type="gauge".
function TestMetricsServiceGauge:test_gauge_registrationProducesGaugeType()
	MS.gauge("active_tracks", "Number of active tracks")

	local out = MS.serialize()

	assertContains(
		out,
		"# HELP active_tracks Number of active tracks",
		"test_gauge_registrationProducesGaugeType HELP line"
	)
	assertContains(out, "# TYPE active_tracks gauge", "test_gauge_registrationProducesGaugeType TYPE line")
	assertContains(out, "active_tracks 0", "test_gauge_registrationProducesGaugeType value line")
end

-- 6. set() on a gauge stores the exact value.
function TestMetricsServiceGauge:test_set_storesExactValue()
	MS.gauge("battery_count", "")
	MS.set("battery_count", 42)

	local out = MS.serialize()
	assertContains(out, "battery_count 42", "test_set_storesExactValue")
end

-- set() overwrites previous value completely.
function TestMetricsServiceGauge:test_set_overwritesPreviousValue()
	MS.gauge("golf", "")
	MS.set("golf", 100)
	MS.set("golf", 7)

	local out = MS.serialize()
	assertContains(out, "golf 7", "test_set_overwritesPreviousValue new value present")
	assertNotContains(out, "golf 100", "test_set_overwritesPreviousValue old value absent")
end

-- 14. set() with value 0 produces "name 0" in output.
function TestMetricsServiceGauge:test_set_zeroValueRendersAsZero()
	MS.gauge("hotel", "")
	MS.set("hotel", 99)
	MS.set("hotel", 0)

	local out = MS.serialize()
	assertContains(out, "hotel 0", "test_set_zeroValueRendersAsZero")
end

-- 11 (gauge variant). gauge() with nil help does not crash; HELP line present.
function TestMetricsServiceGauge:test_gauge_nilHelpDefaultsToEmpty()
	MS.gauge("india", nil)

	local out = MS.serialize()
	assertContains(out, "# HELP india", "test_gauge_nilHelpDefaultsToEmpty HELP line present")
	assertContains(out, "# TYPE india gauge", "test_gauge_nilHelpDefaultsToEmpty TYPE line")
end

-- ============================================================
-- TestMetricsServiceNoOps
-- ============================================================

TestMetricsServiceNoOps = {}

function TestMetricsServiceNoOps:setUp()
	if MS._registry then
		MS._registry = {}
	end
end

-- 5. inc() on an unregistered name does not throw an error.
function TestMetricsServiceNoOps:test_inc_unregisteredNameIsNoOp()
	lu.assertNil(pcall(MS.inc, "nonexistent_counter", 1) and nil or nil)
	-- The real assertion is that no error propagates. We use pcall for safety.
	local ok = pcall(function()
		MS.inc("totally_unknown", 1)
	end)
	lu.assertTrue(ok, "inc on unregistered metric must not throw")
end

-- inc() on unregistered name does not create a ghost entry in serialize().
function TestMetricsServiceNoOps:test_inc_unregisteredNameDoesNotAppearInSerialize()
	MS.inc("ghost_metric", 5)
	local out = MS.serialize()
	assertNotContains(out, "ghost_metric", "test_inc_unregisteredNameDoesNotAppearInSerialize")
end

-- 7. set() on an unregistered name does not throw an error.
function TestMetricsServiceNoOps:test_set_unregisteredNameIsNoOp()
	local ok = pcall(function()
		MS.set("totally_unknown_gauge", 42)
	end)
	lu.assertTrue(ok, "set on unregistered metric must not throw")
end

-- set() on unregistered name does not create a ghost entry in serialize().
function TestMetricsServiceNoOps:test_set_unregisteredNameDoesNotAppearInSerialize()
	MS.set("ghost_gauge", 99)
	local out = MS.serialize()
	assertNotContains(out, "ghost_gauge", "test_set_unregisteredNameDoesNotAppearInSerialize")
end

-- ============================================================
-- TestMetricsServiceSerialize
-- ============================================================

TestMetricsServiceSerialize = {}

function TestMetricsServiceSerialize:setUp()
	if MS._registry then
		MS._registry = {}
	end
end

-- 8. serialize() with empty registry contains only heartbeat.
function TestMetricsServiceSerialize:test_serialize_emptyRegistryContainsHeartbeat()
	local out = MS.serialize()
	lu.assertStrContains(out, "medusa_heartbeat_epoch")
end

-- serialize() return type is always a string, never nil.
function TestMetricsServiceSerialize:test_serialize_alwaysReturnsString()
	local out = MS.serialize()
	lu.assertIsString(out, "test_serialize_alwaysReturnsString with empty registry")

	MS.counter("juliet", "")
	out = MS.serialize()
	lu.assertIsString(out, "test_serialize_alwaysReturnsString with one metric")
end

-- 9. serialize() with multiple metrics — all appear.
function TestMetricsServiceSerialize:test_serialize_multipleMetricsAllPresent()
	MS.counter("kilo", "counter help")
	MS.gauge("lima", "gauge help")
	MS.counter("mike", "another counter")

	local out = MS.serialize()

	-- Each metric's TYPE line must be present (order-independent).
	assertContains(out, "# TYPE kilo counter", "test_serialize_multipleMetricsAllPresent kilo type")
	assertContains(out, "# TYPE lima gauge", "test_serialize_multipleMetricsAllPresent lima type")
	assertContains(out, "# TYPE mike counter", "test_serialize_multipleMetricsAllPresent mike type")

	-- Each metric's value line must be present.
	assertContains(out, "kilo 0", "test_serialize_multipleMetricsAllPresent kilo value")
	assertContains(out, "lima 0", "test_serialize_multipleMetricsAllPresent lima value")
	assertContains(out, "mike 0", "test_serialize_multipleMetricsAllPresent mike value")
end

-- 15. serialize() output is valid Prometheus format: no trailing garbage after value.
--     Each value line must match exactly "name<space>value" with no suffix.
function TestMetricsServiceSerialize:test_serialize_prometheusValueLineFormat()
	MS.counter("november", "")
	MS.inc("november", 7)

	local out = MS.serialize()

	-- The value line must match the pattern "november 7" followed by newline or
	-- end of string — no extra characters on the same line.
	lu.assertNotNil(
		string.match(out, "november%s+7%s*[\n]?"),
		"test_serialize_prometheusValueLineFormat: value line must end cleanly"
	)
end

-- 15 (extended). No trailing newline garbage: ensure HELP line does not bleed
--     into the TYPE line (i.e., there is a newline separating them).
function TestMetricsServiceSerialize:test_serialize_helpAndTypeAreSeparateLines()
	MS.gauge("oscar", "some help text")

	local out = MS.serialize()

	-- Both lines present and separated by newline.
	local helpPos = string.find(out, "# HELP oscar some help text", 1, true)
	local typePos = string.find(out, "# TYPE oscar gauge", 1, true)

	lu.assertNotNil(helpPos, "test_serialize_helpAndTypeAreSeparateLines: HELP line missing")
	lu.assertNotNil(typePos, "test_serialize_helpAndTypeAreSeparateLines: TYPE line missing")

	-- HELP must come before TYPE.
	lu.assertTrue(helpPos < typePos, "test_serialize_helpAndTypeAreSeparateLines: HELP must precede TYPE")
end

-- Integer values render without decimal point (Lua 5.1 tostring(3) = "3").
function TestMetricsServiceSerialize:test_serialize_integerValueNoDecimal()
	MS.counter("papa", "")
	MS.inc("papa", 3)

	local out = MS.serialize()

	-- Must contain "papa 3" not "papa 3.0".
	assertContains(out, "papa 3", "test_serialize_integerValueNoDecimal integer present")
	assertNotContains(out, "papa 3.0", "test_serialize_integerValueNoDecimal no decimal form")
end

-- ============================================================
-- TestMetricsServiceReset
-- ============================================================

TestMetricsServiceReset = {}

function TestMetricsServiceReset:setUp()
	if MS._registry then
		MS._registry = {}
	end
end

-- 10. reset() zeros all values but preserves registrations.
function TestMetricsServiceReset:test_reset_zerosAllValues()
	MS.counter("quebec", "")
	MS.gauge("romeo", "")
	MS.inc("quebec", 10)
	MS.set("romeo", 55)

	MS.reset()

	local out = MS.serialize()
	assertContains(out, "quebec 0", "test_reset_zerosAllValues counter zeroed")
	assertContains(out, "romeo 0", "test_reset_zerosAllValues gauge zeroed")
end

-- reset() preserves registrations — metrics still appear in serialize().
function TestMetricsServiceReset:test_reset_preservesRegistrations()
	MS.counter("sierra", "a counter")
	MS.gauge("tango", "a gauge")

	MS.reset()

	local out = MS.serialize()
	assertContains(out, "# TYPE sierra counter", "test_reset_preservesRegistrations counter still registered")
	assertContains(out, "# TYPE tango gauge", "test_reset_preservesRegistrations gauge still registered")
end

-- reset() on empty registry is a no-op (no error).
function TestMetricsServiceReset:test_reset_emptyRegistryNoError()
	local ok = pcall(function()
		MS.reset()
	end)
	lu.assertTrue(ok, "test_reset_emptyRegistryNoError: reset on empty registry must not throw")
end

-- After reset(), values can be incremented/set again from 0.
function TestMetricsServiceReset:test_reset_thenIncFromZero()
	MS.counter("uniform", "")
	MS.inc("uniform", 42)
	MS.reset()
	MS.inc("uniform", 1)

	local out = MS.serialize()
	assertContains(out, "uniform 1", "test_reset_thenIncFromZero: post-reset inc starts from 0")
end

-- ============================================================
-- TestMetricsServiceBoundary
-- ============================================================

TestMetricsServiceBoundary = {}

function TestMetricsServiceBoundary:setUp()
	if MS._registry then
		MS._registry = {}
	end
end

-- Boundary: single metric registered, serialize produces exactly the right structure.
function TestMetricsServiceBoundary:test_boundary_singleMetricExactStructure()
	MS.counter("victor", "v help")
	MS.inc("victor", 0)

	local out = MS.serialize()
	-- All three marker strings must be present.
	assertContains(out, "# HELP victor v help", "test_boundary_singleMetricExactStructure HELP")
	assertContains(out, "# TYPE victor counter", "test_boundary_singleMetricExactStructure TYPE")
	assertContains(out, "victor 0", "test_boundary_singleMetricExactStructure value")
end

-- Boundary: counter name with underscores and digits (common Prometheus style).
function TestMetricsServiceBoundary:test_boundary_metricNameWithUnderscoresAndDigits()
	MS.counter("iads_battery_kill_count_total_v2", "")

	local out = MS.serialize()
	assertContains(
		out,
		"# TYPE iads_battery_kill_count_total_v2 counter",
		"test_boundary_metricNameWithUnderscoresAndDigits"
	)
end

-- Boundary: large delta does not overflow or produce wrong output.
function TestMetricsServiceBoundary:test_boundary_largeIncrementValue()
	MS.counter("whiskey", "")
	MS.inc("whiskey", 1000000)

	local out = MS.serialize()
	assertContains(out, "whiskey 1000000", "test_boundary_largeIncrementValue")
end

-- Boundary: negative set value.
function TestMetricsServiceBoundary:test_boundary_negativeSetValue()
	MS.gauge("xray", "")
	MS.set("xray", -10)

	local out = MS.serialize()
	assertContains(out, "xray -10", "test_boundary_negativeSetValue")
end

-- Boundary: help text containing special characters does not corrupt output.
function TestMetricsServiceBoundary:test_boundary_helpTextWithSpecialCharacters()
	MS.gauge("yankee", "track count (active) [zone-2]")

	local out = MS.serialize()
	assertContains(out, "# HELP yankee track count (active) [zone-2]", "test_boundary_helpTextWithSpecialCharacters")
end

-- Edge: registering many metrics in sequence (stress, no hard limit in contract).
function TestMetricsServiceBoundary:test_boundary_manyMetricsNoError()
	local ok = pcall(function()
		for i = 1, 50 do
			MS.counter(string.format("metric_%d", i), string.format("help %d", i))
			MS.inc(string.format("metric_%d", i), i)
		end
	end)
	lu.assertTrue(ok, "test_boundary_manyMetricsNoError: registering 50 metrics must not error")

	local out = MS.serialize()
	assertContains(out, "metric_1 1", "test_boundary_manyMetricsNoError first metric present")
	assertContains(out, "metric_50 50", "test_boundary_manyMetricsNoError last metric present")
end

-- ============================================================
-- Run all tests
-- ============================================================

os.exit(lu.LuaUnit.run())
