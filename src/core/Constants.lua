require("_header")

--[[
             ██████╗ ██████╗ ███╗   ██╗███████╗████████╗ █████╗ ███╗   ██╗████████╗███████╗
            ██╔════╝██╔═══██╗████╗  ██║██╔════╝╚══██╔══╝██╔══██╗████╗  ██║╚══██╔══╝██╔════╝
            ██║     ██║   ██║██╔██╗ ██║███████╗   ██║   ███████║██╔██╗ ██║   ██║   ███████╗
            ██║     ██║   ██║██║╚██╗██║╚════██║   ██║   ██╔══██║██║╚██╗██║   ██║   ╚════██║
            ╚██████╗╚██████╔╝██║ ╚████║███████║   ██║   ██║  ██║██║ ╚████║   ██║   ███████║
             ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝   ╚══════╝

    What this module does
    - Defines every enum, threshold, and named constant used across Medusa.
    - Groups values by domain: network, battery state, tracks, engagement, EMCON, HARM, physics, and zones.

    How others use it
    - Nearly every service and entity references these constants for state comparisons and configuration defaults.
--]]

Medusa.Constants = {}

Medusa.Constants.LogLevel = {
	NONE = "NONE",
	ERROR = "ERROR",
	INFO = "INFO",
	DEBUG = "DEBUG",
	TRACE = "TRACE",
}

-- ── Network & C2 ──────────────────────────────────────────────────

Medusa.Constants.Role = {
	GCI = "GCI",
	EWR = "EWR",
	AWACS = "AWACS",
	HQ = "HQ",
}

Medusa.Constants.NetworkConnectivity = {
	CONNECTED = "CONNECTED",
	DEGRADED = "DEGRADED",
	DISCONNECTED = "DISCONNECTED",
}

Medusa.Constants.NetworkDegradationPolicy = {
	REVERT_TO_AUTONOMOUS = "REVERT_TO_AUTONOMOUS",
	GO_DARK = "GO_DARK",
	REVERT_TO_SELF_DEFENSE = "REVERT_TO_SELF_DEFENSE",
}

-- ── Battery & Unit State ──────────────────────────────────────────

Medusa.Constants.ActivationState = {
	INITIALIZING = "INITIALIZING",
	STATE_COLD = "STATE_COLD",
	STATE_WARM = "STATE_WARM",
	STATE_HOT = "STATE_HOT",
}

Medusa.Constants.BatteryOperationalStatus = {
	ACTIVE = "ACTIVE",
	DESTROYED = "DESTROYED",
	SEARCH_ONLY = "SEARCH_ONLY",
	ENGAGEMENT_IMPAIRED = "ENGAGEMENT_IMPAIRED",
	INOPERATIVE = "INOPERATIVE",
	MOVING = "MOVING",
	REARMING = "REARMING",
}

Medusa.Constants.BatteryUnitRole = {
	LAUNCHER = "LAUNCHER",
	SEARCH_RADAR = "SEARCH_RADAR",
	TRACK_RADAR = "TRACK_RADAR",
	COMMAND_POST = "COMMAND_POST",
	TELAR = "TELAR",
	TLAR = "TLAR",
	OTHER = "OTHER",
}

Medusa.Constants.BatteryRole = {
	VLR_SAM = "VLR_SAM",
	LR_SAM = "LR_SAM",
	MR_SAM = "MR_SAM",
	SR_SAM = "SR_SAM",
	AAA = "AAA",
	GENERIC_SAM = "GENERIC_SAM",
}

Medusa.Constants.VLR_THRESHOLD_M = 250000

Medusa.Constants.LAUNCHER_ROLES = {
	[Medusa.Constants.BatteryUnitRole.LAUNCHER] = true,
	[Medusa.Constants.BatteryUnitRole.TELAR] = true,
	[Medusa.Constants.BatteryUnitRole.TLAR] = true,
}

Medusa.Constants.CLUSTER_THRESHOLD_M = 1852 -- 1 NM

Medusa.Constants.SystemTypeDefaults = {
	VLR_SAM = { DefaultActivationState = "STATE_COLD", AmmoDepletedBehavior = "SEARCH_ONLY" },
	LR_SAM = { DefaultActivationState = "STATE_COLD", AmmoDepletedBehavior = "SEARCH_ONLY" },
	MR_SAM = { DefaultActivationState = "STATE_COLD", AmmoDepletedBehavior = "INOPERATIVE" },
	SR_SAM = { DefaultActivationState = "STATE_COLD", AmmoDepletedBehavior = "INOPERATIVE" },
	AAA = { DefaultActivationState = "STATE_COLD", AmmoDepletedBehavior = "INOPERATIVE" },
	GENERIC_SAM = { DefaultActivationState = "STATE_COLD", AmmoDepletedBehavior = "INOPERATIVE" },
}

Medusa.Constants.RadarStatus = {
	ACTIVE = "ACTIVE",
	STANDBY = "STANDBY",
	DARK = "DARK",
	DAMAGED = "DAMAGED",
	NA = "NA",
}

Medusa.Constants.BatteryRadarConfiguration = {
	NONE = "NONE",
	SEARCH_ONLY = "SEARCH_ONLY",
	TRACK_ONLY = "TRACK_ONLY",
	COMBINED = "COMBINED",
}

Medusa.Constants.BatteryRadarDependencyPolicy = {
	REQUIRED = "REQUIRED",
	OPTIONAL_DEGRADED = "OPTIONAL_DEGRADED",
}

Medusa.Constants.UnitOperationalStatus = {
	ACTIVE = "ACTIVE",
	DAMAGED = "DAMAGED",
	DESTROYED = "DESTROYED",
}

Medusa.Constants.TacticalState = {
	IDLE = "IDLE",
	STANDARD_ENGAGING = "STANDARD_ENGAGING",
	LURING_TARGET = "LURING_TARGET",
	LINGERING_ALERT_MONITORING = "LINGERING_ALERT_MONITORING",
	ASSISTING_ENGAGEMENT = "ASSISTING_ENGAGEMENT",
}

Medusa.Constants.AutonomousBehavior = {
	STATE_DARK = "STATE_DARK",
	STATE_WARM = "STATE_WARM",
	STATE_HOT = "STATE_HOT",
	RANDOM_STATE = "RANDOM_STATE",
}

Medusa.Constants.ShootAndScootPolicy = {
	NONE = "NONE",
	AFTER_ENGAGEMENT = "AFTER_ENGAGEMENT",
	TIMED_RELOCATION = "TIMED_RELOCATION",
}

-- ── Track Management ──────────────────────────────────────────────

Medusa.Constants.TrackLifecycleState = {
	ACTIVE = "ACTIVE",
	STALE = "STALE",
	EXPIRED = "EXPIRED",
}

Medusa.Constants.TrackIdentification = {
	UNKNOWN = "UNKNOWN",
	BOGEY = "BOGEY",
	BANDIT = "BANDIT",
	HOSTILE = "HOSTILE",
	FRIENDLY = "FRIENDLY",
	WHITEAIR = "WHITEAIR",
	ARM = "ARM",
}

Medusa.Constants.AssessedAircraftType = {
	UNKNOWN = "UNKNOWN",
	FIXED_WING = "FIXED_WING",
	ROTARY_WING = "ROTARY_WING",
	MISSILE = "MISSILE",
	FIGHTER = "FIGHTER",
	SEAD_AIRCRAFT = "SEAD_AIRCRAFT",
	HARM = "HARM",
}

Medusa.Constants.ManeuverState = {
	STRAIGHT = "STRAIGHT",
	TURNING_LEFT = "TURNING_LEFT",
	TURNING_RIGHT = "TURNING_RIGHT",
	ORBITING = "ORBITING",
	MANEUVERING = "MANEUVERING",
	UNKNOWN = "UNKNOWN",
}

Medusa.Constants.AircraftTypeThreatScore = {
	UNKNOWN = 30,
	FIXED_WING = 50,
	ROTARY_WING = 40,
	MISSILE = 90,
	FIGHTER = 60,
	SEAD_AIRCRAFT = 95,
	HARM = 95,
}

Medusa.Constants.HarmDefenseState = {
	SUPPRESSED = "SUPPRESSED",
	SELF_DEFENDING = "SELF_DEFENDING",
	PD_PROTECTED = "PD_PROTECTED",
	INTERCEPTING = "INTERCEPTING",
}

Medusa.Constants.TRACK_REASSOC_MAX_DIST_M = 5000
Medusa.Constants.TRACK_REASSOC_TTL_SEC = 120
Medusa.Constants.TRACK_UPDATE_EXPIRY_BUCKETS = { 1, 2, 3, 5, 10, 20, 50 }
Medusa.Constants.TRACK_TURN_THRESHOLD_RAD = 0.15
Medusa.Constants.TRACK_ORBIT_THRESHOLD_RAD = 2.5
Medusa.Constants.BANDIT_DWELL_SEC = 30
Medusa.Constants.HEAVY_DWELL_SEC = 180
Medusa.Constants.ROTARY_WING_SPEED_THRESHOLD = 100
Medusa.Constants.MISSILE_SPEED_THRESHOLD = 1000
Medusa.Constants.FIGHTER_MANEUVER_SPEED_THRESHOLD = 200
Medusa.Constants.MANEUVER_SPEED_RATIO_THRESHOLD = 0.3

-- ── Engagement & Targeting ────────────────────────────────────────

Medusa.Constants.ROEState = {
	FREE = "FREE",
	TIGHT = "TIGHT",
	HOLD = "HOLD",
}

Medusa.Constants.CoordinatedEngagementTactics = {
	SHOOT_LOOK_SHOOT = "SHOOT_LOOK_SHOOT",
	SHOOT_IN_DEPTH = "SHOOT_IN_DEPTH",
	SHOOT_SHOOT = "SHOOT_SHOOT",
	SHOOT_SHOOT_FLOOD = "SHOOT_SHOOT_FLOOD",
}

Medusa.Constants.MAX_ASSIGNMENT_BUDGET = 10
Medusa.Constants.PK_MAX_DEFAULT = 0.90
Medusa.Constants.PK_FLOOR = 0.25
Medusa.Constants.PK_ASPECT_BEAM_FLOOR = 0.30
Medusa.Constants.PK_ALTITUDE_TAPER_M = 500
Medusa.Constants.PK_RANGE_DECAY_RATE = 2
Medusa.Constants.SPEED_OF_SOUND_MPS = 340
Medusa.Constants.PK_SIGMA_CAP_M = 40000
Medusa.Constants.PK_FLOOR_ANCHOR_RANGE_M = 20000
Medusa.Constants.PK_OPTIMAL_REFERENCE_M = 80000
Medusa.Constants.PK_OPTIMAL_FRACTION = 0.45
Medusa.Constants.LOOKAHEAD_DEFAULT_SEC = 8
Medusa.Constants.HANDOFF_DWELL_SEC = 20
Medusa.Constants.HANDOFF_PK_IMPROVEMENT = 1.5
Medusa.Constants.SATURATION_PENALTY_ALPHA = 0.3
Medusa.Constants.REASSIGNMENT_EVAL_SEC = 45
Medusa.Constants.LAST_CHANCE_SALVO_COUNT = 2
Medusa.Constants.ROLLING_PK_WINDOW = 10
Medusa.Constants.ROLLING_PK_STEP = 0.02
Medusa.Constants.ROLLING_PK_CEILING = 0.60
Medusa.Constants.ROLLING_PK_DECAY_TAU = 65.1 -- exponential decay time constant: 99% decay in ~300s (5 min)
Medusa.Constants.SAM_AVG_MISSILE_SPEED_MPS = 800
Medusa.Constants.TTK_ALT_FLOOR_M = 1524
Medusa.Constants.TTK_ALT_CEIL_M = 9144
Medusa.Constants.REARM_CHECK_INTERVAL_SEC = 600

-- ── EMCON & Sensors ───────────────────────────────────────────────

Medusa.Constants.SensorType = {
	EWR = "EWR",
	GCI = "GCI",
	SAM_SEARCH = "SAM_SEARCH",
	SAM_TRACK = "SAM_TRACK",
}

Medusa.Constants.EmissionControlPolicy = {
	MINIMIZE = "MINIMIZE",
	PERIODIC_SCAN = "PERIODIC_SCAN",
	COORDINATED_ROTATION = "COORDINATED_ROTATION",
	ALWAYS_ON = "ALWAYS_ON",
	INTELLIGENT_EMCON = "INTELLIGENT_EMCON",
}

Medusa.Constants.SAMAsEWRPolicy = {
	DISABLED = "DISABLED",
	WHEN_NO_EWR = "WHEN_NO_EWR",
	ALWAYS = "ALWAYS",
}

Medusa.Constants.SAM_AS_EWR_ELIGIBLE_ROLES = { LR_SAM = true, MR_SAM = true }

Medusa.Constants.EMCON_DEFAULT_SCAN_DURATION_SEC = 30
Medusa.Constants.EMCON_DEFAULT_QUIET_PERIOD_SEC = 0
Medusa.Constants.EMCON_DEFAULT_ROTATION_GROUPS = 2

Medusa.Constants.EMCON_DEFAULT_POLICY_BY_ROLE = {
	EWR = "ALWAYS_ON",
	GCI = "ALWAYS_ON",
	VLR_SAM = "MINIMIZE",
	LR_SAM = "MINIMIZE",
	MR_SAM = "MINIMIZE",
	SR_SAM = "MINIMIZE",
	AAA = "MINIMIZE",
	GENERIC_SAM = "MINIMIZE",
}

-- ── Physics ──────────────────────────────────────────────────────
Medusa.Constants.GRAVITY_MPS2 = 9.81
Medusa.Constants.PK_INNER_SIGMA_FACTOR = 0.759

-- ── HARM Detection & Response ─────────────────────────────────────

Medusa.Constants.HarmResponseStrategy = {
	IGNORE = "IGNORE",
	SHUTDOWN = "SHUTDOWN",
	SHUTDOWN_UNLESS_PD = "SHUTDOWN_UNLESS_PD",
	SELF_DEFEND = "SELF_DEFEND",
	AUTO_DEFENSE = "AUTO_DEFENSE",
}

Medusa.Constants.HARM_CAPABLE_SYSTEMS = {
	"S-300",
	"Tor",
	"Pantsir",
	"Patriot",
	"NASAMS",
}

Medusa.Constants.HARM_DEFEND_WEIGHT_TLAR = 4
Medusa.Constants.HARM_DEFEND_WEIGHT_LAUNCHER = 1.5

Medusa.Constants.POINT_DEFENSE_SEARCH_RADIUS_M = 15000

Medusa.Constants.HARM_REEVAL_MAX_AGE_SEC = 300
Medusa.Constants.HARM_DEFAULT_THREAT_RADIUS_M = 15000
Medusa.Constants.HARM_SHUTDOWN_SAFETY_MARGIN_SEC = 20
Medusa.Constants.HARM_MAX_RANGE_M = 130000
Medusa.Constants.HARM_DEFAULT_SPEED_MPS = 300

Medusa.Constants.HARM_SPRT_MIN_SCANS = 15
Medusa.Constants.HARM_SPRT_MIN_TRACK_AGE_SEC = 10
Medusa.Constants.HARM_SPRT_MIN_DT_SEC = 0.01
Medusa.Constants.HARM_SPRT_SPEED_GATE = 50
Medusa.Constants.HARM_SPRT_MAX_FEAT_LLR = 3
Medusa.Constants.HARM_SPRT_MAX_SCAN_LLR = 5
Medusa.Constants.HARM_SPRT_THRESH_CONFIRM = 4.554
Medusa.Constants.HARM_SPRT_THRESH_CLEAR = -20
Medusa.Constants.HARM_SPRT_THRESH_SUSPECT = 1.139
Medusa.Constants.HARM_SPRT_THRESH_PROBABLE = 2.733

-- Gaussian class-conditional model: {arm_mean, arm_sigma, nonArm_mean, nonArm_sigma}
-- Tuned for post-boost DCS HARM (Mach 1-4, ballistic/terminal after 10s age gate)
Medusa.Constants.HARM_SPRT_MODEL = {
	{ 800, 300, 300, 120 }, -- Speed (m/s): ARM Mach 1-4, fighters up to Mach 1.4
	{ 0.25, 0.35, 0.02, 0.15 }, -- Dive angle (rad): post-apogee, increasingly steep
	{ 0.008, 0.015, 0.040, 0.050 }, -- Heading rate (rad/s): HARMs fly straight
	{ 10, 25, 0, 10 }, -- Accel (m/s^2): gravity-driven gain in dive, positive
	{ 500, 1350, 8000, 6000 }, -- CPA distance (m): tightened ARM σ for long-range sensitivity
	{ -30, 40, -5, 30 }, -- CPA rate (m/s): HARMs converge on emitter
	{ -600, 300, -50, 200 }, -- Range rate (m/s): Mach 1-4 closure, wide σ
	{ -150, 150, -5, 50 }, -- Altitude rate (m/s): post-apogee, consistently descending
}

-- ── Airspace Zones ────────────────────────────────────────────────

Medusa.Constants.ZoneKind = {
	JEZ = "JEZ",
	FEZ = "FEZ",
	FAEZ = "FAEZ",
	MEZ = "MEZ",
	AMBUSH = "AMBUSH",
	PRIORITY_DEFENSE = "PRIORITY_DEFENSE",
	SERVICE_AREA = "SERVICE_AREA",
	FRIENDLY = "FRIENDLY",
}

Medusa.Constants.ZoneGeometryType = {
	CIRCLE = "CIRCLE",
	RECTANGLE = "RECTANGLE",
	POLYGON = "POLYGON",
	POLYLINE_CLOSED = "POLYLINE_CLOSED",
}

Medusa.Constants.Posture = {
	HOT_WAR = "HOT_WAR",
	WARM_WAR = "WARM_WAR",
	COLD_WAR = "COLD_WAR",
}

-- ── Interceptor Operations ────────────────────────────────────────

Medusa.Constants.GciServicePolicy = {
	CLOSEST_AIRBASE = "CLOSEST_AIRBASE",
	MOST_LETHAL_INTERCEPTOR = "MOST_LETHAL_INTERCEPTOR",
	ROUND_ROBIN = "ROUND_ROBIN",
	AIRBASE_PRIORITY_ORDER = "AIRBASE_PRIORITY_ORDER",
}

Medusa.Constants.InterceptorLaunchAuthorityPolicy = {
	LOCAL_AUTONOMY = "LOCAL_AUTONOMY",
	REQUIRE_GCI_APPROVAL = "REQUIRE_GCI_APPROVAL",
	CENTRALIZED = "CENTRALIZED",
}

Medusa.Constants.InterceptorGroupTask = {
	INTERCEPT = "INTERCEPT",
}

Medusa.Constants.InterceptorGroupStatus = {
	SPAWNING = "SPAWNING",
	ACTIVE = "ACTIVE",
	ENGAGING = "ENGAGING",
	RTB_FUEL = "RTB_FUEL",
	RTB_WINCHESTER = "RTB_WINCHESTER",
	RTB_COMMANDED = "RTB_COMMANDED",
	LANDED = "LANDED",
	REARMING = "REARMING",
	AVAILABLE = "AVAILABLE",
	DESTROYED = "DESTROYED",
}
