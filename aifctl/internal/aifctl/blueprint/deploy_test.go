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
	"context"
	"encoding/json"
	"errors"
	"io"
	"reflect"
	"strings"
	"testing"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	ktesting "k8s.io/client-go/testing"
)

func TestRequiredExternalChartReposExcludesPackagedRepositories(t *testing.T) {
	blueprint := blueprintObject("test-1-0-0", "Test", "1.0.0")
	_ = unstructured.SetNestedSlice(blueprint.Object, []any{
		map[string]any{"chartRepo": "z-external", "chartName": "one"},
		map[string]any{"chartRepo": "application-collection", "chartName": "two"},
		map[string]any{"chartRepo": "packaged", "chartName": "three"},
		map[string]any{"chartRepo": "z-external", "chartName": "four"},
		map[string]any{"chartRepo": "packaged", "chartName": "gpu", "vendor": "nvidia"},
	}, "spec", "components")
	packagedRepo := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "catalog.cattle.io/v1",
		"kind":       "ClusterRepo",
		"metadata":   map[string]any{"name": "packaged"},
	}}
	pkg := &Package{Stages: []Stage{{Objects: []*unstructured.Unstructured{blueprint, packagedRepo}}}}

	got, err := requiredExternalChartRepos(pkg)
	if err != nil {
		t.Fatalf("requiredExternalChartRepos() error = %v", err)
	}
	want := []string{"application-collection", "nvidia", "z-external"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("requiredExternalChartRepos() = %v, want %v", got, want)
	}
}

func TestDeployStopsBeforeWriteWhenExternalRepoIsMissing(t *testing.T) {
	blueprint := blueprintObject("test-1-0-0", "Test", "1.0.0")
	_ = unstructured.SetNestedSlice(blueprint.Object, []any{
		map[string]any{"chartRepo": "application-collection", "chartName": "postgresql"},
	}, "spec", "components")
	pkg := &Package{Stages: []Stage{{Path: "blueprint.yaml", Objects: []*unstructured.Unstructured{blueprint}}}}
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme())
	patches := 0
	client.PrependReactor("patch", "*", func(ktesting.Action) (bool, runtime.Object, error) {
		patches++
		return false, nil, nil
	})
	runner := &Runner{
		Client: client,
		Mapper: meta.NewDefaultRESTMapper(nil),
		Out:    io.Discard,
	}

	err := runner.Deploy(context.Background(), pkg, DeployOptions{})
	if err == nil || !strings.Contains(err.Error(), "credentials are platform prerequisites") {
		t.Fatalf("Deploy() error = %v, want actionable Application Collection prerequisite", err)
	}
	if patches != 0 {
		t.Fatalf("patch calls = %d, want zero writes before prerequisite failure", patches)
	}
}

func TestPreflightExternalChartReposAcceptsReadyRepo(t *testing.T) {
	repo := clusterRepoWithStatus("oci://registry.example.test/charts", 2, []any{
		map[string]any{"type": "OCIDownloaded", "status": "True"},
	})
	repo.SetAPIVersion("catalog.cattle.io/v1")
	repo.SetKind("ClusterRepo")
	repo.SetName("application-collection")
	repo.SetGeneration(2)
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), repo)
	blueprint := blueprintObject("test-1-0-0", "Test", "1.0.0")
	_ = unstructured.SetNestedSlice(blueprint.Object, []any{
		map[string]any{"chartRepo": "application-collection", "chartName": "postgresql"},
	}, "spec", "components")
	pkg := &Package{Stages: []Stage{{Objects: []*unstructured.Unstructured{blueprint}}}}
	runner := &Runner{Client: client, Out: io.Discard}

	if err := runner.preflightExternalChartRepos(context.Background(), pkg); err != nil {
		t.Fatalf("preflightExternalChartRepos() error = %v", err)
	}
}

func TestPreflightExternalChartReposRejectsStaleRepo(t *testing.T) {
	repo := clusterRepoWithStatus("oci://registry.example.test/charts", 1, []any{
		map[string]any{"type": "OCIDownloaded", "status": "True"},
	})
	repo.SetAPIVersion("catalog.cattle.io/v1")
	repo.SetKind("ClusterRepo")
	repo.SetName("application-collection")
	repo.SetGeneration(2)
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), repo)
	blueprint := blueprintObject("test-1-0-0", "Test", "1.0.0")
	_ = unstructured.SetNestedSlice(blueprint.Object, []any{
		map[string]any{"chartRepo": "application-collection", "chartName": "postgresql"},
	}, "spec", "components")
	pkg := &Package{Stages: []Stage{{Objects: []*unstructured.Unstructured{blueprint}}}}
	runner := &Runner{Client: client, Out: io.Discard}

	err := runner.preflightExternalChartRepos(context.Background(), pkg)
	if err == nil || !strings.Contains(err.Error(), "is not ready") {
		t.Fatalf("preflightExternalChartRepos() error = %v, want stale repository error", err)
	}
}

func TestPreflightExternalChartReposPreservesAccessError(t *testing.T) {
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme())
	client.PrependReactor("get", "clusterrepos", func(ktesting.Action) (bool, runtime.Object, error) {
		return true, nil, apierrors.NewForbidden(
			schema.GroupResource{Group: clusterRepoGVR.Group, Resource: clusterRepoGVR.Resource},
			"application-collection",
			errors.New("access denied"),
		)
	})
	blueprint := blueprintObject("test-1-0-0", "Test", "1.0.0")
	_ = unstructured.SetNestedSlice(blueprint.Object, []any{
		map[string]any{"chartRepo": "application-collection", "chartName": "postgresql"},
	}, "spec", "components")
	pkg := &Package{Stages: []Stage{{Objects: []*unstructured.Unstructured{blueprint}}}}
	runner := &Runner{Client: client, Out: io.Discard}

	err := runner.preflightExternalChartRepos(context.Background(), pkg)
	if err == nil || !strings.Contains(err.Error(), "forbidden") || strings.Contains(err.Error(), "not installed") {
		t.Fatalf("preflightExternalChartRepos() error = %v, want preserved forbidden error", err)
	}
}

func TestApplyStageUsesNonForcingServerSideApply(t *testing.T) {
	gv := schema.GroupVersion{Group: aiWorkloadGroupKind.Group, Version: "v1alpha1"}
	gvk := gv.WithKind(aiWorkloadGroupKind.Kind)
	gvr := gv.WithResource("aiworkloads")
	mapper := meta.NewDefaultRESTMapper([]schema.GroupVersion{gv})
	mapper.AddSpecific(gvk, gvr, gv.WithResource("aiworkload"), meta.RESTScopeNamespace)

	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme())
	var patchOptionsForce *bool
	var patchType types.PatchType
	client.PrependReactor("patch", "aiworkloads", func(action ktesting.Action) (bool, runtime.Object, error) {
		patchAction := action.(ktesting.PatchActionImpl)
		patchOptionsForce = patchAction.GetPatchOptions().Force
		patchType = patchAction.GetPatchType()
		result := &unstructured.Unstructured{}
		if err := json.Unmarshal(patchAction.GetPatch(), &result.Object); err != nil {
			return true, nil, err
		}
		result.SetGeneration(4)
		return true, result, nil
	})

	workload := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": gv.String(),
		"kind":       aiWorkloadGroupKind.Kind,
		"metadata": map[string]any{
			"name":      "test",
			"namespace": "test",
		},
	}}
	runner := &Runner{Client: client, Mapper: mapper, Out: io.Discard}
	refs, err := runner.applyStage(context.Background(), Stage{Objects: []*unstructured.Unstructured{workload}})
	if err != nil {
		t.Fatalf("applyStage() error = %v", err)
	}
	if patchType != types.ApplyPatchType {
		t.Errorf("patch type = %q, want %q", patchType, types.ApplyPatchType)
	}
	if patchOptionsForce != nil {
		t.Errorf("PatchOptions.Force = %v, want nil", *patchOptionsForce)
	}
	if len(refs) != 1 || refs[0].generation != 4 {
		t.Fatalf("refs = %#v, want one generation-4 ref", refs)
	}
}

func TestApplyStageCollectsClusterRepoReadinessRef(t *testing.T) {
	gv := schema.GroupVersion{Group: clusterRepoGroupKind.Group, Version: "v1"}
	gvk := gv.WithKind(clusterRepoGroupKind.Kind)
	gvr := gv.WithResource("clusterrepos")
	mapper := meta.NewDefaultRESTMapper([]schema.GroupVersion{gv})
	mapper.AddSpecific(gvk, gvr, gv.WithResource("clusterrepo"), meta.RESTScopeRoot)

	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme())
	client.PrependReactor("patch", "clusterrepos", func(action ktesting.Action) (bool, runtime.Object, error) {
		patchAction := action.(ktesting.PatchActionImpl)
		result := &unstructured.Unstructured{}
		if err := json.Unmarshal(patchAction.GetPatch(), &result.Object); err != nil {
			return true, nil, err
		}
		result.SetGeneration(7)
		return true, result, nil
	})

	repo := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": gv.String(),
		"kind":       clusterRepoGroupKind.Kind,
		"metadata":   map[string]any{"name": "test-charts"},
		"spec":       map[string]any{"url": "https://charts.example.test"},
	}}
	runner := &Runner{Client: client, Mapper: mapper, Out: io.Discard}
	refs, err := runner.applyStage(context.Background(), Stage{Objects: []*unstructured.Unstructured{repo}})
	if err != nil {
		t.Fatalf("applyStage() error = %v", err)
	}
	if len(refs) != 1 {
		t.Fatalf("refs = %#v, want one ClusterRepo ref", refs)
	}
	if refs[0].groupKind != clusterRepoGroupKind || refs[0].namespace != "" || refs[0].generation != 7 {
		t.Fatalf("ref = %#v, want cluster-scoped ClusterRepo generation 7", refs[0])
	}
}

func TestEnsureBlueprintSpecImmutableRejectsAnySpecChange(t *testing.T) {
	gv := schema.GroupVersion{Group: blueprintGroupKind.Group, Version: "v1alpha1"}
	gvr := gv.WithResource("blueprints")
	current := blueprintObject("test-1-0-0", "Test", "1.0.0")
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), current)
	client.PrependReactor("patch", "blueprints", func(action ktesting.Action) (bool, runtime.Object, error) {
		patchAction := action.(ktesting.PatchActionImpl)
		result := &unstructured.Unstructured{}
		if err := json.Unmarshal(patchAction.GetPatch(), &result.Object); err != nil {
			return true, nil, err
		}
		return true, result, nil
	})
	resourceClient := client.Resource(gvr)

	tests := []struct {
		name        string
		displayName string
		version     string
		mutate      func(*unstructured.Unstructured)
	}{
		{name: "display name", displayName: "Renamed", version: "1.0.0"},
		{name: "version", displayName: "Test", version: "2.0.0"},
		{
			name:        "component values",
			displayName: "Test",
			version:     "1.0.0",
			mutate: func(object *unstructured.Unstructured) {
				_ = unstructured.SetNestedSlice(object.Object, []any{map[string]any{
					"chartRepo": "application-collection", "chartName": "postgresql", "chartVersion": "0.5.5",
				}}, "spec", "components")
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			desired := blueprintObject("test-1-0-0", tt.displayName, tt.version)
			if tt.mutate != nil {
				tt.mutate(desired)
			}
			err := ensureBlueprintSpecImmutable(context.Background(), resourceClient, desired)
			if err == nil || !strings.Contains(err.Error(), "spec is immutable") {
				t.Fatalf("ensureBlueprintSpecImmutable() error = %v, want immutable spec error", err)
			}
		})
	}
}

func TestEnsureBlueprintSpecImmutableAllowsIdenticalSpec(t *testing.T) {
	gv := schema.GroupVersion{Group: blueprintGroupKind.Group, Version: "v1alpha1"}
	gvr := gv.WithResource("blueprints")
	current := blueprintObject("test-1-0-0", "Test", "1.0.0")
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), current)
	client.PrependReactor("patch", "blueprints", func(action ktesting.Action) (bool, runtime.Object, error) {
		patchAction := action.(ktesting.PatchActionImpl)
		result := &unstructured.Unstructured{}
		if err := json.Unmarshal(patchAction.GetPatch(), &result.Object); err != nil {
			return true, nil, err
		}
		return true, result, nil
	})

	err := ensureBlueprintSpecImmutable(context.Background(), client.Resource(gvr), current.DeepCopy())
	if err != nil {
		t.Fatalf("ensureBlueprintSpecImmutable() error = %v, want nil", err)
	}
}

func TestAIWorkloadReadinessUsesObservedGeneration(t *testing.T) {
	workload := workloadWithStatus(2, "Running", nil)
	ready, err := aiWorkloadReady(workload, 3)
	if err != nil || ready {
		t.Fatalf("stale aiWorkloadReady() = (%v, %v), want (false, nil)", ready, err)
	}

	ready, err = aiWorkloadReady(workload, 2)
	if err != nil || !ready {
		t.Fatalf("current aiWorkloadReady() = (%v, %v), want (true, nil)", ready, err)
	}
}

func TestWaitForStageAllowsTransientAIWorkloadFailureToRecover(t *testing.T) {
	gv := schema.GroupVersion{Group: aiWorkloadGroupKind.Group, Version: "v1alpha1"}
	gvr := gv.WithResource("aiworkloads")
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme())

	failed := workloadWithStatus(2, "Failed", nil)
	running := workloadWithStatus(2, "Running", nil)
	getCalls := 0
	client.PrependReactor("get", "aiworkloads", func(ktesting.Action) (bool, runtime.Object, error) {
		getCalls++
		if getCalls == 1 {
			return true, failed.DeepCopy(), nil
		}
		return true, running.DeepCopy(), nil
	})

	runner := &Runner{
		Out:                          io.Discard,
		PollInterval:                 time.Millisecond,
		AIWorkloadFailureGracePeriod: 100 * time.Millisecond,
	}
	refs := []appliedRef{{
		client:     client.Resource(gvr).Namespace("test"),
		groupKind:  aiWorkloadGroupKind,
		namespace:  "test",
		name:       "test",
		generation: 2,
	}}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	if err := runner.waitForStage(ctx, refs); err != nil {
		t.Fatalf("waitForStage() error = %v, want transient failure to recover", err)
	}
	if getCalls < 2 {
		t.Fatalf("get calls = %d, want at least two observations", getCalls)
	}
}

func TestWaitForStageReturnsSustainedAIWorkloadFailure(t *testing.T) {
	gv := schema.GroupVersion{Group: aiWorkloadGroupKind.Group, Version: "v1alpha1"}
	gvr := gv.WithResource("aiworkloads")
	failed := workloadWithStatus(2, "Failed", []any{map[string]any{
		"reason": "InstallFailed", "message": "chart remained broken",
	}})
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme())
	client.PrependReactor("get", "aiworkloads", func(ktesting.Action) (bool, runtime.Object, error) {
		return true, failed.DeepCopy(), nil
	})

	runner := &Runner{
		Out:                          io.Discard,
		PollInterval:                 time.Millisecond,
		AIWorkloadFailureGracePeriod: 5 * time.Millisecond,
	}
	refs := []appliedRef{{
		client:     client.Resource(gvr).Namespace("test"),
		groupKind:  aiWorkloadGroupKind,
		namespace:  "test",
		name:       "test",
		generation: 2,
	}}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	err := runner.waitForStage(ctx, refs)
	if err == nil || !strings.Contains(err.Error(), "InstallFailed: chart remained broken") {
		t.Fatalf("waitForStage() error = %v, want sustained failure detail", err)
	}
}

func TestClusterRepoReadinessRequiresCurrentHTTPDownload(t *testing.T) {
	repo := clusterRepoWithStatus("https://charts.example.test", 2, []any{
		map[string]any{"type": "Downloaded", "status": "True"},
	})

	ready, err := clusterRepoReady(repo, 3)
	if err != nil || ready {
		t.Fatalf("stale clusterRepoReady() = (%v, %v), want (false, nil)", ready, err)
	}

	ready, err = clusterRepoReady(repo, 2)
	if err != nil || !ready {
		t.Fatalf("current clusterRepoReady() = (%v, %v), want (true, nil)", ready, err)
	}
}

func TestClusterRepoReadinessRequiresOCIDownloadCondition(t *testing.T) {
	repo := clusterRepoWithStatus("oci://registry.example.test/charts", 4, []any{
		map[string]any{"type": "Downloaded", "status": "True"},
	})

	ready, err := clusterRepoReady(repo, 4)
	if err != nil || ready {
		t.Fatalf("clusterRepoReady(wrong condition) = (%v, %v), want (false, nil)", ready, err)
	}

	_ = unstructured.SetNestedSlice(repo.Object, []any{
		map[string]any{"type": "OCIDownloaded", "status": "True"},
	}, "status", "conditions")
	ready, err = clusterRepoReady(repo, 4)
	if err != nil || !ready {
		t.Fatalf("clusterRepoReady(OCI ready) = (%v, %v), want (true, nil)", ready, err)
	}
}

func TestClusterRepoReadinessRejectsStaleConditionGeneration(t *testing.T) {
	repo := clusterRepoWithStatus("https://charts.example.test", 5, []any{
		map[string]any{"type": "Downloaded", "status": "True", "observedGeneration": int64(4)},
	})

	ready, err := clusterRepoReady(repo, 5)
	if err != nil || ready {
		t.Fatalf("clusterRepoReady() = (%v, %v), want (false, nil) for stale condition", ready, err)
	}
}

func TestClusterRepoReadinessOnlyFailsClearlyTerminalCondition(t *testing.T) {
	transient := clusterRepoWithStatus("https://charts.example.test", 2, []any{
		map[string]any{
			"type": "Downloaded", "status": "False", "reason": "Error", "message": "dial tcp: i/o timeout",
		},
	})
	ready, err := clusterRepoReady(transient, 2)
	if err != nil || ready {
		t.Fatalf("clusterRepoReady(transient) = (%v, %v), want (false, nil)", ready, err)
	}

	terminal := clusterRepoWithStatus("oci://registry.example.test/charts", 2, []any{
		map[string]any{
			"type": "OCIDownloaded", "status": "False", "reason": "Error", "message": "error 403: Forbidden",
		},
	})
	ready, err = clusterRepoReady(terminal, 2)
	if ready || err == nil || !strings.Contains(err.Error(), "Error: error 403: Forbidden") {
		t.Fatalf("clusterRepoReady(terminal) = (%v, %v), want detailed failure", ready, err)
	}
}

func TestClusterRepoReadinessUsesLatestMatchingCondition(t *testing.T) {
	repo := clusterRepoWithStatus("https://charts.example.test", 2, []any{
		map[string]any{"type": "Downloaded", "status": "True"},
		map[string]any{"type": "Downloaded", "status": "False", "reason": "Refreshing"},
	})

	ready, err := clusterRepoReady(repo, 2)
	if err != nil || ready {
		t.Fatalf("clusterRepoReady() = (%v, %v), want latest condition to keep waiting", ready, err)
	}
}

func TestAIWorkloadReadinessWaitsForDegradedClusterFailure(t *testing.T) {
	workload := workloadWithStatus(2, "Degraded", nil)
	_ = unstructured.SetNestedSlice(workload.Object, []any{map[string]any{
		"clusterId": "downstream-1",
		"phase":     "Failed",
		"message":   "chart failed",
	}}, "status", "clusterStatuses")

	ready, err := aiWorkloadReady(workload, 2)
	if ready || err != nil {
		t.Fatalf("aiWorkloadReady() = (%v, %v), want (false, nil) until top-level phase is terminal", ready, err)
	}
}

func TestAIWorkloadReadinessWaitsForCurrentPendingClusterFailure(t *testing.T) {
	workload := workloadWithStatus(2, "Pending", nil)
	_ = unstructured.SetNestedSlice(workload.Object, []any{map[string]any{
		"clusterId": "local",
		"phase":     "Failed",
		"message":   "nested chart authentication failed",
	}}, "status", "clusterStatuses")

	ready, err := aiWorkloadReady(workload, 2)
	if ready || err != nil {
		t.Fatalf("aiWorkloadReady() = (%v, %v), want (false, nil) until top-level phase is terminal", ready, err)
	}
}

func TestAIWorkloadReadinessIgnoresStalePendingClusterFailure(t *testing.T) {
	workload := workloadWithStatus(1, "Pending", nil)
	_ = unstructured.SetNestedSlice(workload.Object, []any{map[string]any{
		"clusterId": "local",
		"phase":     "Failed",
		"message":   "failure from an older generation",
	}}, "status", "clusterStatuses")

	ready, err := aiWorkloadReady(workload, 2)
	if ready || err != nil {
		t.Fatalf("aiWorkloadReady() = (%v, %v), want (false, nil) for stale status", ready, err)
	}
}

func TestAIWorkloadReadinessWaitsForDegradedRollout(t *testing.T) {
	workload := workloadWithStatus(2, "Degraded", nil)
	_ = unstructured.SetNestedSlice(workload.Object, []any{
		map[string]any{"clusterId": "ready", "phase": "Running"},
		map[string]any{"clusterId": "progressing", "phase": "Pending"},
	}, "status", "clusterStatuses")

	ready, err := aiWorkloadReady(workload, 2)
	if ready || err != nil {
		t.Fatalf("aiWorkloadReady() = (%v, %v), want (false, nil) while rollout progresses", ready, err)
	}
}

func TestJobReadiness(t *testing.T) {
	complete := objectWithConditions([]any{map[string]any{"type": "Complete", "status": "True"}})
	ready, err := jobReady(complete)
	if err != nil || !ready {
		t.Fatalf("jobReady(complete) = (%v, %v), want (true, nil)", ready, err)
	}

	failed := objectWithConditions([]any{map[string]any{
		"type": "Failed", "status": "True", "reason": "BackoffLimitExceeded", "message": "retry limit reached",
	}})
	ready, err = jobReady(failed)
	if ready || err == nil || !strings.Contains(err.Error(), "BackoffLimitExceeded") {
		t.Fatalf("jobReady(failed) = (%v, %v), want detailed failure", ready, err)
	}
}

func blueprintObject(name, displayName, version string) *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": blueprintGroupKind.Group + "/v1alpha1",
		"kind":       blueprintGroupKind.Kind,
		"metadata":   map[string]any{"name": name},
		"spec": map[string]any{
			"displayName": displayName,
			"version":     version,
		},
	}}
}

func workloadWithStatus(observedGeneration int64, phase string, conditions []any) *unstructured.Unstructured {
	status := map[string]any{
		"observedGeneration": observedGeneration,
		"phase":              phase,
	}
	if conditions != nil {
		status["conditions"] = conditions
	}
	return &unstructured.Unstructured{Object: map[string]any{"status": status}}
}

func clusterRepoWithStatus(url string, observedGeneration int64, conditions []any) *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]any{
		"spec": map[string]any{"url": url},
		"status": map[string]any{
			"observedGeneration": observedGeneration,
			"conditions":         conditions,
		},
	}}
}

func objectWithConditions(conditions []any) *unstructured.Unstructured {
	return &unstructured.Unstructured{Object: map[string]any{
		"status": map[string]any{"conditions": conditions},
	}}
}
