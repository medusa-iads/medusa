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
				MANPADAlertnessDecaySec = 14400,
				MANPADFieldRadioRangeM = 5000,
			},
		},
	},
}
