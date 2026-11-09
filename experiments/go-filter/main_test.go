package main

import "testing"

func TestReplacementsPreserveOrderCapturesAndUTF8(t *testing.T) {
	for _, tc := range []struct{ input, expected string }{
		{"", ""},
		{"Привет, мир", "Привет, мир"},
		{"rufix_test_code_secret_number_001_extended rufix_test_code_secret_number_001", "[EXACT:long] [EXACT:short]"},
		{"https://api.internal.example/x and git.internal.example", "https://api.masked/x and git.masked"},
		{"Bearer rufix_test_code_secret_number_002", "Bearer [REDACTED]"},
		{"Bearer rufix_test_code_secret_number_001", "Bearer [EXACT:short]"},
		{"éapi.internal.exampleé", "éapi.maskedé"},
		{"[S:abcd1234] and $1", "[S:abcd1234] and $1"},
	} {
		got, err := replace(tc.input)
		if err != nil || got != tc.expected {
			t.Errorf("got=%q err=%v want=%q", got, err, tc.expected)
		}
	}
}
