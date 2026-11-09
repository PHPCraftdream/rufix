package main

var fixturePatterns = []string{
	``, `a`, `abc`, `a*`, `a+?`, `a|ab`, `ab|a`, `(a)?b`, `(a*)(b*)`,
	`^|$`, `(?m)^([^=]+)=(.*)$`, `(?s)a.*b`, `(?U)a.*b`, `\Ba\B`, `\bword\b`,
	`(?P<key>[a-z]+)=(?P<value>[^\n]*)`, `(?i)kelvin|é|σ`, `\p{Greek}+`,
	`[[:alpha:]]+`, `[\x00-\x{10ffff}]`, `(?:ab){1,3}`, `a(?:b|c)*d`,
	`\A(?P<value>[a-z]+)\z`, `\A(?:a|b|c)+\z`, `(?i)\Aabc\z`,
	`(?i)(bearer\s+)[A-Za-z0-9_\-.+/=]{16,}`,
	`(?i)\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+)internal\.example\b`,
	`\[S:[0-9a-f]{8}\]`,
}
