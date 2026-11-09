package compiledregexp

import (
	"reflect"
	"regexp"
	"strings"
	"testing"
)

var fixturePrograms map[string]*Regexp

func TestGeneratedProgramsMatchStandardLibrary(t *testing.T) {
	if len(fixturePrograms) == 0 {
		t.Fatal("generate regex fixtures before testing: go generate ./internal/secretvalues")
	}
	texts := []string{
		"", "a", "ab", "aaa b aa", "abbbd", "abc", "word sword word", "aaa\naaa",
		"one=first\ntwo=second", "Bearer rufix_test_code_secret_number_001",
		"https://api.internal.example/x [S:abcd1234]", "éé Σσς Kkelvin", "\x00\xffa\xfe", "aééb",
		strings.Repeat("a", 4096) + "b",
	}
	var enumerate func(string, int)
	enumerate = func(prefix string, depth int) {
		texts = append(texts, prefix)
		if depth == 0 {
			return
		}
		for _, r := range []rune{'a', 'b', '\n', 'é'} {
			enumerate(prefix+string(r), depth-1)
		}
	}
	enumerate("", 3)
	for pattern, got := range fixturePrograms {
		want := regexp.MustCompile(pattern)
		if got.String() != pattern || !reflect.DeepEqual(got.SubexpNames(), want.SubexpNames()) {
			t.Fatalf("metadata mismatch for %q", pattern)
		}
		for _, text := range texts {
			if got.MatchString(text) != want.MatchString(text) {
				t.Fatalf("MatchString mismatch pattern=%q input bytes=%d", pattern, len(text))
			}
			for _, limit := range []int{-1, 0, 1, 2} {
				if !reflect.DeepEqual(got.FindAllStringIndex(text, limit), want.FindAllStringIndex(text, limit)) {
					t.Fatalf("match indices mismatch pattern=%q input bytes=%d limit=%d", pattern, len(text), limit)
				}
				if !reflect.DeepEqual(got.FindAllStringSubmatchIndex(text, limit), want.FindAllStringSubmatchIndex(text, limit)) {
					t.Fatalf("capture indices mismatch pattern=%q input bytes=%d limit=%d", pattern, len(text), limit)
				}
			}
			for _, template := range []string{"x", "${1}$$${2}", "${key}:${value}:$0:${missing}"} {
				if got.ReplaceAllString(text, template) != want.ReplaceAllString(text, template) {
					t.Fatalf("replacement mismatch pattern=%q input bytes=%d", pattern, len(text))
				}
				for _, match := range want.FindAllStringSubmatchIndex(text, -1) {
					if string(got.ExpandString(nil, template, text, match)) != string(want.ExpandString(nil, template, text, match)) {
						t.Fatalf("template mismatch pattern=%q", pattern)
					}
				}
			}
		}
	}
}

func TestGeneratedExecutionPaths(t *testing.T) {
	var onepass, bitstate, nfa bool
	for _, re := range fixturePrograms {
		onepass = onepass || re.onepass != nil
		bitstate = bitstate || (re.onepass == nil && re.maxBitStateLen > 0)
		if re.onepass == nil {
			text := strings.Repeat("x", re.maxBitStateLen+1)
			want := regexp.MustCompile(re.String())
			if !reflect.DeepEqual(re.FindAllStringSubmatchIndex(text, -1), want.FindAllStringSubmatchIndex(text, -1)) {
				t.Fatal("NFA path differs from standard regexp")
			}
			nfa = true
		}
	}
	if !onepass || !bitstate || !nfa {
		t.Fatal("fixtures must cover one-pass, bit-state and NFA execution")
	}
}
