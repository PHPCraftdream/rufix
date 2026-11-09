package redact

import "strings"

func nextPlaceholder(s string) (string, string) {
	for {
		i := strings.Index(s, "[S:")
		if i < 0 {
			return "", ""
		}
		s = s[i:]
		if len(s) >= 12 && s[11] == ']' {
			valid := true
			for j := 3; j < 11; j++ {
				c := s[j]
				if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
					valid = false
					break
				}
			}
			if valid {
				return s[:12], s[12:]
			}
		}
		s = s[3:]
	}
}
