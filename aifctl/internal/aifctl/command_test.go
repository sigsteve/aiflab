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

package aifctl

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBlueprintDeployDryRunDoesNotNeedKubeconfig(t *testing.T) {
	manifest := `apiVersion: ai-factory.suse.com/v1alpha1
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
	path := filepath.Join(t.TempDir(), "test.yaml")
	if err := os.WriteFile(path, []byte(manifest), 0o600); err != nil {
		t.Fatalf("WriteFile(): %v", err)
	}

	var out bytes.Buffer
	command := NewCommand(&out, &out)
	command.SetArgs([]string{"blueprint", "deploy", "--from", path, "--dry-run", "--kubeconfig", "/does/not/exist"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute() error = %v", err)
	}
	if got := out.String(); !strings.Contains(got, "AIWorkload/test namespace=test") {
		t.Fatalf("dry-run output = %q, want planned AIWorkload", got)
	}
}

func TestBlueprintDeployDryRunExplainsAutomaticDomainWithoutKubeconfig(t *testing.T) {
	manifest := strings.Replace(testAIWorkloadYAMLForCommand, "metadata:\n", `metadata:
  annotations:
    aiflab.suse.com/access-url: https://kubeflow.__AIFLAB_DOMAIN__
`, 1)
	path := filepath.Join(t.TempDir(), "test.yaml")
	if err := os.WriteFile(path, []byte(manifest), 0o600); err != nil {
		t.Fatalf("WriteFile(): %v", err)
	}

	var out bytes.Buffer
	command := NewCommand(&out, &out)
	command.SetArgs([]string{"blueprint", "deploy", "--from", path, "--dry-run", "--kubeconfig", "/does/not/exist"})
	if err := command.Execute(); err != nil {
		t.Fatalf("Execute() error = %v", err)
	}
	if got := out.String(); !strings.Contains(got, "derived at apply time as <node-ip>.sslip.io") {
		t.Fatalf("dry-run output = %q, want automatic-domain guidance", got)
	}
}

const testAIWorkloadYAMLForCommand = `apiVersion: ai-factory.suse.com/v1alpha1
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
