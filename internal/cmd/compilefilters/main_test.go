package main

import (
	"bytes"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"rufix/internal/redact"
)

func TestSourceIsDeterministicAndPrecompiled(t *testing.T) {
	patterns := map[string]struct{}{`\A([a-z]+)\z`: {}, `(a)?b`: {}, ``: {}}
	first, err := source(patterns, "programs")
	if err != nil {
		t.Fatal(err)
	}
	second, err := source(patterns, "programs")
	if err != nil || !bytes.Equal(first, second) {
		t.Fatal("generation is not deterministic")
	}
	if _, err := parser.ParseFile(token.NewFileSet(), "generated.go", first, parser.AllErrors); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(first, []byte("onepass:")) || !bytes.Contains(first, []byte("syntax.Inst{")) {
		t.Fatal("compiled program or one-pass metadata missing")
	}
	for _, forbidden := range []string{"MustCompile(", "Compile(", "syntax.Parse(", "syntax.Compile("} {
		if bytes.Contains(first, []byte(forbidden)) {
			t.Fatalf("runtime compilation in generated source: %s", forbidden)
		}
	}
}

func TestGenerateBothDirectionsAndFixtures(t *testing.T) {
	output := filepath.Join(t.TempDir(), "filters_generated.go")
	n, err := generate(output, []redact.RuleData{
		{Match: "first", RestoreMatch: "second"},
		{Match: "first"},
	})
	if err != nil || n != 2 {
		t.Fatalf("count=%d err=%v", n, err)
	}
	for _, name := range []string{output, filepath.Join(filepath.Dir(output), "fixtures_generated_test.go")} {
		data, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := parser.ParseFile(token.NewFileSet(), name, data, parser.AllErrors); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := generate(output, nil); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, []byte("regexp/syntax")) || bytes.Contains(data, []byte("first")) {
		t.Error("empty generation must remove stale programs and unused imports")
	}
}

func TestInvalidRegexDoesNotOverwriteOrLeak(t *testing.T) {
	for _, rules := range [][]redact.RuleData{
		{{Match: "(rufix_test_code_secret_number_008"}},
		{{Match: "valid", RestoreMatch: "(rufix_test_code_secret_number_008"}},
	} {
		output := filepath.Join(t.TempDir(), "filters_generated.go")
		if err := os.WriteFile(output, []byte("previous"), 0o600); err != nil {
			t.Fatal(err)
		}
		_, err := generate(output, rules)
		if err == nil || strings.Contains(err.Error(), "rufix_test_code_secret_number_008") {
			t.Fatal("invalid regex must fail without exposing its text")
		}
		data, err := os.ReadFile(output)
		if err != nil || string(data) != "previous" {
			t.Fatal("failed generation changed the existing output")
		}
	}
}
