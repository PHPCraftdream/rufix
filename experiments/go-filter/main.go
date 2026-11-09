package main

import (
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"unicode/utf8"
)

const maxInput = 8_388_608

var exact = [][2]string{
	{"rufix_test_code_secret_number_001_extended", "[EXACT:long]"},
	{"rufix_test_code_secret_number_001", "[EXACT:short]"},
}

var rules = [][2]string{
	{`\b((?:[a-z0-9-]+\.)+)internal\.example\b`, "${1}masked"},
	{`((?i:bearer)[ \t]+)[A-Za-z0-9_./+=-]{16,}`, "${1}[REDACTED]"},
}

func replace(input string) (string, error) {
	output := input
	for _, pair := range exact {
		output = strings.ReplaceAll(output, pair[0], pair[1])
	}
	for _, rule := range rules {
		re, err := regexp.Compile(rule[0])
		if err != nil {
			return "", fmt.Errorf("invalid built-in regex")
		}
		output = re.ReplaceAllString(output, rule[1])
	}
	return output, nil
}

func run() error {
	if len(os.Args) != 1 {
		return fmt.Errorf("unexpected arguments")
	}
	input, err := io.ReadAll(io.LimitReader(os.Stdin, maxInput+1))
	if err != nil || !utf8.Valid(input) {
		return fmt.Errorf("read stdin: expected utf-8")
	}
	if len(input) > maxInput {
		return fmt.Errorf("input exceeds 8 MiB")
	}
	output, err := replace(string(input))
	if err != nil {
		return err
	}
	if n, err := io.WriteString(os.Stdout, output); err != nil || n != len(output) {
		return fmt.Errorf("write stdout")
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "rufix-text:", err)
		os.Exit(2)
	}
}
