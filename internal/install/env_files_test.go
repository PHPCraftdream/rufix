package install

import (
	"os"
	"strings"
	"testing"
)

func TestHookCommandEnvFiles(t *testing.T) {
	for _, tc := range []struct {
		name string
		opts Options
		want string
	}{
		{"path default", Options{ExeDir: "/tools"}, `"/tools/rufix" hook`},
		{"path opt-in", Options{ExeDir: "/tools", EnvFiles: true}, `"/tools/rufix" hook --env-files`},
		{"PATH default", Options{}, "rufix hook"},
		{"PATH opt-in", Options{EnvFiles: true}, "rufix hook --env-files"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := command(tc.opts); got != tc.want {
				t.Errorf("command=%q want=%q", got, tc.want)
			}
		})
	}
}

func TestInstallEnvFilesOptInAndReset(t *testing.T) {
	path := settingsPath(t, "")
	for _, enabled := range []bool{true, false} {
		options := opts(path)
		options.EnvFiles = enabled
		if _, err := Install(options); err != nil {
			t.Fatal(err)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		want := 0
		if enabled {
			want = 2
		}
		if got := strings.Count(string(data), "--env-files"); got != want {
			t.Errorf("enabled=%v flag count=%d want=%d", enabled, got, want)
		}
	}
}
