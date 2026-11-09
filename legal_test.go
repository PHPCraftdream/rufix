package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

var approvedLicenseDocuments = map[string]string{
	"LICENSE-MIT":                     "5569d8a7fa049e62db4ec44421c91e2393da9162156fab247623d55d62695008",
	"LICENSE-APACHE":                  "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4",
	"internal/compiledregexp/LICENSE": "911f8f5782931320f5b8d1160a76365b83aea6447ee6c04fa6d5591467db9dad",
}

const goLicensePointer = "// Use of this source code is governed by a BSD-style\n// license that can be found in the LICENSE file.\n"

var approvedGoNotices = map[string]string{
	"internal/compiledregexp/regexp.go":    "// Copyright 2009 The Go Authors. All rights reserved.\n" + goLicensePointer,
	"internal/compiledregexp/exec.go":      "// Copyright 2011 The Go Authors. All rights reserved.\n" + goLicensePointer,
	"internal/compiledregexp/onepass.go":   "// Copyright 2014 The Go Authors. All rights reserved.\n" + goLicensePointer,
	"internal/compiledregexp/backtrack.go": "// Copyright 2015 The Go Authors. All rights reserved.\n" + goLicensePointer,
}

func TestLicenseCompliance(t *testing.T) {
	output, err := exec.Command("git", "ls-files", "-z").Output()
	if err != nil {
		t.Fatal(err)
	}
	files := strings.Split(strings.TrimSuffix(string(output), "\x00"), "\x00")
	if err := verifyLicenseNotices(os.DirFS("."), files); err != nil {
		t.Fatal(err)
	}
}

func verifyLicenseNotices(tree fs.FS, files []string) error {
	tracked := make(map[string]bool, len(files))
	for _, name := range files {
		if !fs.ValidPath(name) || name == "." || strings.ContainsAny(name, `\:`) {
			return fmt.Errorf("invalid repository path")
		}
		tracked[name] = true
	}
	for name, expected := range approvedLicenseDocuments {
		if !tracked[name] {
			return fmt.Errorf("required license is not tracked: %s", name)
		}
		data, err := fs.ReadFile(tree, name)
		if err != nil {
			return err
		}
		digest := sha256.Sum256(normalizeLicenseLF(data))
		if hex.EncodeToString(digest[:]) != expected {
			return fmt.Errorf("license changed; explicit review required: %s", name)
		}
	}
	for name, notice := range approvedGoNotices {
		if !tracked[name] {
			return fmt.Errorf("registered third-party source is not tracked: %s", name)
		}
		data, err := fs.ReadFile(tree, name)
		if err != nil {
			return err
		}
		if !bytes.HasPrefix(normalizeLicenseLF(data), []byte(notice)) {
			return fmt.Errorf("third-party notice changed or missing: %s", name)
		}
	}
	for _, name := range files {
		if isLicenseDocument(name) {
			if _, ok := approvedLicenseDocuments[name]; !ok {
				return fmt.Errorf("unregistered license or notice document: %s", name)
			}
		}
		// Не читаем локальную skip-worktree карту.
		if path.Ext(name) != ".go" || name == "internal/secretvalues/values.go" {
			continue
		}
		data, err := fs.ReadFile(tree, name)
		if err != nil {
			return err
		}
		file, err := parser.ParseFile(token.NewFileSet(), name, data, parser.ParseComments)
		if err != nil {
			return fmt.Errorf("parse source notices in %s: %w", name, err)
		}
		for _, group := range file.Comments {
			for _, comment := range group.List {
				text := strings.ToLower(comment.Text)
				spdx := strings.Contains(text, "spdx-license-identifier:")
				if !strings.Contains(text, "copyright") && !spdx {
					continue
				}
				if !spdx && strings.Contains(text, "the rufix authors") {
					continue
				}
				expected, ok := approvedGoNotices[name]
				if !ok || !strings.Contains(expected, comment.Text) {
					return fmt.Errorf("unregistered source license notice: %s", name)
				}
			}
		}
	}
	return nil
}

func normalizeLicenseLF(data []byte) []byte {
	return bytes.ReplaceAll(data, []byte("\r\n"), []byte("\n"))
}

func isLicenseDocument(name string) bool {
	base := strings.ToUpper(path.Base(name))
	for _, suffix := range []string{".TXT", ".MD", ".RST"} {
		base = strings.TrimSuffix(base, suffix)
	}
	for _, prefix := range []string{"LICENSE", "LICENCE", "COPYING", "NOTICE"} {
		if base == prefix || strings.HasPrefix(base, prefix+"-") {
			return true
		}
	}
	return false
}

func licenseFixture(t *testing.T) (fstest.MapFS, []string) {
	t.Helper()
	tree := fstest.MapFS{}
	var files []string
	for name := range approvedLicenseDocuments {
		data, err := os.ReadFile(filepath.FromSlash(name))
		if err != nil {
			t.Fatal(err)
		}
		tree[name] = &fstest.MapFile{Data: data}
		files = append(files, name)
	}
	for name, notice := range approvedGoNotices {
		tree[name] = &fstest.MapFile{Data: []byte(notice + "\npackage fixture\n")}
		files = append(files, name)
	}
	return tree, files
}

func TestLicenseVerifierRejectsChanges(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(fstest.MapFS, *[]string)
	}{
		{"missing license", func(tree fstest.MapFS, _ *[]string) {
			delete(tree, "internal/compiledregexp/LICENSE")
		}},
		{"changed BSD terms", func(tree fstest.MapFS, _ *[]string) {
			tree["internal/compiledregexp/LICENSE"].Data = []byte("changed license terms")
		}},
		{"removed source notice", func(tree fstest.MapFS, _ *[]string) {
			tree["internal/compiledregexp/exec.go"].Data = []byte("package fixture\n")
		}},
		{"new foreign source", func(tree fstest.MapFS, files *[]string) {
			name := "internal/newvendor/source.go"
			tree[name] = &fstest.MapFile{Data: []byte("// Copyright 2026 External Authors\npackage fixture\n")}
			*files = append(*files, name)
		}},
		{"unregistered SPDX source", func(tree fstest.MapFS, files *[]string) {
			name := "internal/newvendor/source.go"
			tree[name] = &fstest.MapFile{Data: []byte("// SPDX-License-Identifier: GPL-3.0-only\npackage fixture\n")}
			*files = append(*files, name)
		}},
		{"conflicting SPDX in registered source", func(tree fstest.MapFS, _ *[]string) {
			name := "internal/compiledregexp/exec.go"
			tree[name].Data = []byte(approvedGoNotices[name] + "// SPDX-License-Identifier: GPL-3.0-only\npackage fixture\n")
		}},
		{"new license document", func(tree fstest.MapFS, files *[]string) {
			name := "internal/newvendor/LICENSE"
			tree[name] = &fstest.MapFile{Data: []byte("unreviewed license")}
			*files = append(*files, name)
		}},
		{"untracked required license", func(_ fstest.MapFS, files *[]string) {
			for i, name := range *files {
				if name == "LICENSE-MIT" {
					*files = append((*files)[:i], (*files)[i+1:]...)
					break
				}
			}
		}},
		{"path traversal", func(_ fstest.MapFS, files *[]string) {
			*files = append(*files, "../outside.go")
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tree, files := licenseFixture(t)
			if err := verifyLicenseNotices(tree, files); err != nil {
				t.Fatalf("invalid control fixture: %v", err)
			}
			tc.mutate(tree, &files)
			if err := verifyLicenseNotices(tree, files); err == nil {
				t.Fatal("license violation was accepted")
			}
		})
	}
}

func TestLicenseVerifierAcceptsCRLFAndIgnoresPrivateValues(t *testing.T) {
	tree, files := licenseFixture(t)
	for _, file := range tree {
		file.Data = bytes.ReplaceAll(normalizeLicenseLF(file.Data), []byte("\n"), []byte("\r\n"))
	}
	tree["internal/secretvalues/values.go"] = &fstest.MapFile{Data: []byte("not valid Go: rufix_test_code_secret_number_009")}
	tree["fixture.go"] = &fstest.MapFile{Data: []byte("package fixture\nvar text = \"Copyright 2026 External Authors\"\n")}
	files = append(files, "internal/secretvalues/values.go", "fixture.go")
	if err := verifyLicenseNotices(tree, files); err != nil {
		t.Fatal(err)
	}
}
