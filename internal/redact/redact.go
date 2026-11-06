// Package redact replaces secrets and internal hosts found in text with
// placeholders. Exact values from the secrets store become reversible
// "[S:hash8]" placeholders; the data-driven filter set (from the
// skip-worktree values.go) produces irreversible "[REDACTED:<rule>]"
// placeholders and structural masks with optional reverse rules.
package redact

import (
	"crypto/sha256"
	"encoding/hex"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"sync"
)

type exact struct {
	value       string
	placeholder string
}

// Store holds the compiled replacement set for one secrets snapshot.
type Store struct {
	exact []exact
	rest  map[string]string // placeholder -> original value
	hosts []string          // bare protected hosts (restore allowlist seeds)
	rules []compiledRule
	mu    sync.Mutex
	seeds map[string]string // forward replacement -> matched text (AllowlistSeed rules)
}

// NewWithRules builds a Store with the given filter set (data from the
// skip-worktree values.go; the engine ships no rules of its own).
func NewWithRules(vars map[string]string, rules []RuleData) *Store {
	st := &Store{
		rest:  make(map[string]string),
		seeds: make(map[string]string),
		rules: compileRules(rules),
	}
	st.addVars(vars)
	sort.SliceStable(st.exact, func(i, j int) bool { return len(st.exact[i].value) > len(st.exact[j].value) })
	return st
}

func (st *Store) addVars(vars map[string]string) {
	for key, value := range vars {
		if value == "" {
			continue
		}
		if secretKey(key) && len(value) >= 6 {
			st.add(value)
			continue
		}
		if u, err := url.Parse(value); err == nil && u.Host != "" {
			st.add(value)
			st.add(u.Host) // bare host, optionally with port
			if host, _, err := splitHostPort(u.Host); err == nil && host != u.Host {
				st.add(host)
			}
		}
	}
}

func (st *Store) add(value string) {
	if len(value) < 4 || strings.Contains(value, "\n") {
		return
	}
	p := placeholder(value)
	if _, dup := st.rest[p]; dup {
		return
	}
	if isProtectedHost(value) {
		st.hosts = append(st.hosts, value)
	}
	st.exact = append(st.exact, exact{value: value, placeholder: p})
	st.rest[p] = value
}

// splitHostPort is a thin wrapper so the hosts list gets the portless form too.
func splitHostPort(host string) (string, string, error) {
	i := strings.LastIndex(host, ":")
	if i < 0 || strings.Count(host, ":") > 1 { // bare host or IPv6
		return host, "", nil
	}
	return host[:i], host[i+1:], nil
}

// secretKey reports whether a variable name looks like a credential name.
func secretKey(key string) bool {
	k := strings.ToUpper(key)
	for _, part := range strings.FieldsFunc(k, func(r rune) bool { return r == '_' || r == '-' }) {
		switch part {
		case "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PAT", "KEY", "CREDENTIAL", "CREDENTIALS":
			return true
		}
	}
	return false
}

func isProtectedHost(value string) bool {
	return strings.Contains(value, ".") && !strings.ContainsAny(value, " \t\n")
}

func hash8(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])[:8]
}

func placeholder(value string) string { return "[S:" + hash8(value) + "]" }

// Redact applies exact-value replacements first (keeping them reversible),
// then the filter rules in order. Returns the new text and the number of
// replacements.
func (st *Store) Redact(s string) (string, int) {
	count := 0
	for _, e := range st.exact {
		if strings.Contains(s, e.value) {
			count += strings.Count(s, e.value)
			s = strings.ReplaceAll(s, e.value, e.placeholder)
		}
	}
	for _, r := range st.rules {
		if locs := r.re.FindAllStringIndex(s, -1); len(locs) > 0 {
			if r.data.StrictTLD {
				var seed func(repl, matched string)
				if r.data.AllowlistSeed {
					seed = func(repl, matched string) {
						st.mu.Lock()
						st.seeds[repl] = matched
						st.mu.Unlock()
					}
				}
				filtered, n := replaceStrictTLD(s, r.re, r.data.Replace, seed)
				count += n
				s = filtered
				continue
			}
			count += len(locs)
			if r.data.AllowlistSeed {
				s = r.re.ReplaceAllStringFunc(s, func(m string) string {
					repl := r.re.ReplaceAllString(m, r.data.Replace)
					st.mu.Lock()
					st.seeds[repl] = m
					st.mu.Unlock()
					return repl
				})
			} else {
				s = r.re.ReplaceAllString(s, r.data.Replace)
			}
		}
	}
	return s, count
}

// replaceStrictTLD applies re/template but drops matches that are not at the
// end of a domain: a following "." + domain char means the matched name is a
// middle label, not a TLD.
func replaceStrictTLD(s string, re *regexp.Regexp, template string, seed func(repl, matched string)) (string, int) {
	locs := re.FindAllStringIndex(s, -1)
	var b strings.Builder
	last, count := 0, 0
	for _, loc := range locs {
		if isMidLabelTail(s, loc[1]) {
			continue
		}
		b.WriteString(s[last:loc[0]])
		matched := s[loc[0]:loc[1]]
		repl := re.ReplaceAllString(matched, template)
		if seed != nil {
			seed(repl, matched)
		}
		b.WriteString(repl)
		last = loc[1]
		count++
	}
	b.WriteString(s[last:])
	return b.String(), count
}

// isMidLabelTail reports whether position end continues a domain: "." plus a
// domain char (e.g. "XCom.UP" — the matched name is a middle label).
func isMidLabelTail(s string, end int) bool {
	return end < len(s) && s[end] == '.' && end+1 < len(s) && isDomainChar(s[end+1])
}

func isDomainChar(c byte) bool {
	return c == '-' || c == '_' || (c >= '0' && c <= '9') ||
		(c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// HostPlaceholder reports whether s contains something the Bash restore
// allowlist honours: an exact [S:hash] whose value is a protected host, a
// masked pattern of an AllowlistSeed rule (memory-free: RestoreMatch matches
// the masked text even in a fresh process), or an in-process seed.
func (st *Store) HostPlaceholder(s string) bool {
	for _, m := range placeholderRe.FindAllString(s, -1) {
		if v, ok := st.rest[m]; ok && isProtectedHost(v) {
			return true
		}
	}
	for _, r := range st.rules {
		if r.data.AllowlistSeed && r.restoreRe != nil && r.restoreRe.MatchString(s) {
			return true
		}
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	for repl := range st.seeds {
		if strings.Contains(s, repl) {
			return true
		}
	}
	return false
}

// Restore puts the original values back: reverse rules first (e.g.
// *.intra -> *.com), then exact-value placeholders.
func (st *Store) Restore(s string) (string, int) {
	count := 0
	s, n := st.RestoreDomains(s)
	count += n
	for p, v := range st.rest {
		if strings.Contains(s, p) {
			count += strings.Count(s, p)
			s = strings.ReplaceAll(s, p, v)
		}
	}
	return s, count
}

// RestoreDomains applies only the reverse rules (domain masks like
// *.intra -> *.com). Exact [S:hash] placeholders are never touched, so it is
// safe for MCP tool arguments: a domain mask may travel to the target server
// inside a comment or link, a credential placeholder may not.
func (st *Store) RestoreDomains(s string) (string, int) {
	count := 0
	for i := len(st.rules) - 1; i >= 0; i-- {
		r := st.rules[i]
		if r.restoreRe == nil {
			continue
		}
		if r.data.StrictTLD {
			restored, n := replaceStrictTLD(s, r.restoreRe, r.data.RestoreReplace, nil)
			count += n
			s = restored
			continue
		}
		if matches := r.restoreRe.FindAllString(s, -1); len(matches) > 0 {
			count += len(matches)
			s = r.restoreRe.ReplaceAllString(s, r.data.RestoreReplace)
		}
	}
	return s, count
}

// HasDomainMask reports whether s contains a masked pattern of an
// AllowlistSeed rule (a domain mask). Exact [S:hash] placeholders do not
// trigger it.
func (st *Store) HasDomainMask(s string) bool {
	for _, r := range st.rules {
		if r.data.AllowlistSeed && r.restoreRe != nil && r.restoreRe.MatchString(s) {
			return true
		}
	}
	return false
}

// HasPlaceholders reports whether s contains any reversible placeholder.
func (st *Store) HasPlaceholders(s string) bool {
	return placeholderRe.MatchString(s)
}

// Hosts returns the protected bare hosts.
func (st *Store) Hosts() []string { return st.hosts }

// Stats returns counters safe to print: exact protected values, protected
// hosts, filter rules. Never the values themselves.
func (st *Store) Stats() (exact, hosts, rules int) {
	return len(st.exact), len(st.hosts), len(st.rules)
}

var placeholderRe = regexp.MustCompile(`\[S:[0-9a-f]{8}\]`)
