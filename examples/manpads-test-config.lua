MEDUSA_CONFIG = {
	LogLevel = "DEBUG",
	PrometheusEnabled = true,
	PrometheusExtendEnabled = true,
	Networks = {
		{
			name = "MANPADS_TEST",
			coalition = "red",
			prefix = "manpad-test",
			doctrine = {
				Name = "MANPADS Test",
				Posture = "HOT_WAR",
				MANPAD = {
					AlertnessDecaySec = 14400,
					FieldRadioRangeM = 5000,
					AudioRangeM = 6000,
				},
			},
		},
	},
}
