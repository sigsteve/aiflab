/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package blueprint

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testAIWorkloadYAML = `apiVersion: ai-factory.suse.com/v1alpha1
kind: AIWorkload
metadata:
  name: test
  namespace: test
spec:
  displayName: Test
  deployStrategy: FleetBundle
  source:
    sourceType: Blueprint
    blueprint:
      name: test
      version: 1.0.0
  targetNamespace: test
  targetClusters: [local]
`

const testConfigMapYAML = `apiVersion: v1
kind: ConfigMap
metadata:
  name: test
  namespace: test
data:
  value: test
`

func TestLoadDirectoryOrdersStages(t *testing.T) {
	dir := t.TempDir()
	writeTestManifest(t, filepath.Join(dir, "deps", "20-second.yaml"), testConfigMapYAML)
	writeTestManifest(t, filepath.Join(dir, "deps", "10-first.yaml"), testConfigMapYAML)
	writeTestManifest(t, filepath.Join(dir, mainManifestName), testAIWorkloadYAML)
	writeTestManifest(t, filepath.Join(dir, "post-deploy", "20-last.yaml"), testConfigMapYAML)
	writeTestManifest(t, filepath.Join(dir, "post-deploy", "10-before-last.yaml"), testConfigMapYAML)

	pkg, err := Load(dir)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}

	want := []string{
		"10-first.yaml",
		"20-second.yaml",
		mainManifestName,
		"10-before-last.yaml",
		"20-last.yaml",
	}
	if len(pkg.Stages) != len(want) {
		t.Fatalf("len(Stages) = %d, want %d", len(pkg.Stages), len(want))
	}
	for i, stage := range pkg.Stages {
		if got := filepath.Base(stage.Path); got != want[i] {
			t.Errorf("Stages[%d] = %q, want %q", i, got, want[i])
		}
	}
	if !pkg.Stages[2].Main {
		t.Error("blueprint.yaml stage is not marked Main")
	}
}

func TestLoadPreParsesLateStage(t *testing.T) {
	dir := t.TempDir()
	writeTestManifest(t, filepath.Join(dir, mainManifestName), testAIWorkloadYAML)
	badPath := filepath.Join(dir, "post-deploy", "99-invalid.yaml")
	writeTestManifest(t, badPath, "apiVersion: v1\nkind: ConfigMap\nmetadata: [\n")

	_, err := Load(dir)
	if err == nil || !strings.Contains(err.Error(), badPath) {
		t.Fatalf("Load() error = %v, want error naming late stage", err)
	}
}

func TestLoadFileRequiresAIWorkload(t *testing.T) {
	path := filepath.Join(t.TempDir(), "blueprint.yaml")
	writeTestManifest(t, path, testConfigMapYAML)

	_, err := Load(path)
	if err == nil || !strings.Contains(err.Error(), "must include at least one AIWorkload") {
		t.Fatalf("Load() error = %v, want missing AIWorkload error", err)
	}
}

func TestLoadMultiDocumentFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bundle.yaml")
	writeTestManifest(t, path, testConfigMapYAML+"---\n"+testAIWorkloadYAML)

	pkg, err := Load(path)
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if got := len(pkg.Stages[0].Objects); got != 2 {
		t.Fatalf("objects = %d, want 2", got)
	}
}

func TestLoadValidatesBlueprintIdentityFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bundle.yaml")
	manifest := `apiVersion: ai-factory.suse.com/v1alpha1
kind: Blueprint
metadata:
  name: test-1-0-0
spec:
  displayName: Test
  components: []
---
` + testAIWorkloadYAML
	writeTestManifest(t, path, manifest)

	_, err := Load(path)
	if err == nil || !strings.Contains(err.Error(), "missing spec.version") {
		t.Fatalf("Load() error = %v, want missing Blueprint version error", err)
	}
}

func writeTestManifest(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("MkdirAll(%q): %v", path, err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("WriteFile(%q): %v", path, err)
	}
}
