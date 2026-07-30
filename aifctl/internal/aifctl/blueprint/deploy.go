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
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	apiequality "k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
)

const (
	fieldManager                        = "aifctl"
	defaultAIWorkloadFailureGracePeriod = 30 * time.Second
)

var (
	blueprintGroupKind   = schema.GroupKind{Group: "ai-factory.suse.com", Kind: "Blueprint"}
	clusterRepoGroupKind = schema.GroupKind{
		Group: "catalog.cattle.io",
		Kind:  "ClusterRepo",
	}
	clusterRepoGVR = schema.GroupVersionResource{
		Group:    clusterRepoGroupKind.Group,
		Version:  "v1",
		Resource: "clusterrepos",
	}
	jobGroupKind = schema.GroupKind{Group: batchv1.GroupName, Kind: "Job"}
)

// DeployOptions controls package application.
type DeployOptions struct {
	DryRun bool
	Wait   bool
}

// Runner applies and observes a parsed Blueprint package.
type Runner struct {
	Client           dynamic.Interface
	Mapper           meta.RESTMapper
	DefaultNamespace string
	Out              io.Writer
	PollInterval     time.Duration
	// AIWorkloadFailureGracePeriod prevents a momentary top-level Failed phase
	// from aborting a deployment while AI Factory immediately retries Fleet.
	AIWorkloadFailureGracePeriod time.Duration
}

// Deploy applies each package stage in order. When waiting is enabled, every
// ClusterRepo, AIWorkload, and Job in a stage must settle successfully before
// the next stage is applied.
func (r *Runner) Deploy(ctx context.Context, pkg *Package, opts DeployOptions) error {
	if pkg == nil || len(pkg.Stages) == 0 {
		return fmt.Errorf("deployment package has no stages")
	}
	if r.Out == nil {
		r.Out = io.Discard
	}
	if opts.DryRun {
		return r.printPlan(pkg)
	}
	if r.Client == nil {
		return fmt.Errorf("Kubernetes client is required")
	}
	if r.Mapper == nil {
		return fmt.Errorf("Kubernetes REST mapper is required")
	}
	if err := r.preflightExternalChartRepos(ctx, pkg); err != nil {
		return fmt.Errorf("preflight deployment prerequisites: %w", err)
	}

	for _, stage := range pkg.Stages {
		fmt.Fprintf(r.Out, "Applying %s\n", stage.Path)
		refs, err := r.applyStage(ctx, stage)
		if err != nil {
			return fmt.Errorf("apply stage %q: %w", stage.Path, err)
		}
		if opts.Wait && len(refs) > 0 {
			fmt.Fprintf(r.Out, "Waiting for %s\n", stage.Path)
			if err := r.waitForStage(ctx, refs); err != nil {
				return fmt.Errorf("wait for stage %q: %w", stage.Path, err)
			}
		}
	}
	return nil
}

// preflightExternalChartRepos verifies repositories referenced by packaged
// Blueprints but not supplied by the package itself. This keeps a missing
// platform credential or repository from producing a partially applied demo
// whose Helm operations only fail later.
func (r *Runner) preflightExternalChartRepos(ctx context.Context, pkg *Package) error {
	repos, err := requiredExternalChartRepos(pkg)
	if err != nil {
		return err
	}
	for _, name := range repos {
		repo, err := r.Client.Resource(clusterRepoGVR).Get(ctx, name, metav1.GetOptions{})
		if apierrors.IsNotFound(err) {
			return externalChartRepoError(name, "is not installed")
		}
		if err != nil {
			return fmt.Errorf("read required external ClusterRepo %q: %w", name, err)
		}

		ready, readyErr := clusterRepoReady(repo, repo.GetGeneration())
		if readyErr != nil {
			return externalChartRepoError(name, fmt.Sprintf("is not ready: %v", readyErr))
		}
		if !ready {
			return externalChartRepoError(name, "is not ready")
		}
		fmt.Fprintf(r.Out, "Required external ClusterRepo/%s ready\n", name)
	}
	return nil
}

func requiredExternalChartRepos(pkg *Package) ([]string, error) {
	declared := make(map[string]struct{})
	required := make(map[string]struct{})

	for _, stage := range pkg.Stages {
		for _, object := range stage.Objects {
			switch object.GroupVersionKind().GroupKind() {
			case clusterRepoGroupKind:
				declared[object.GetName()] = struct{}{}
			case blueprintGroupKind:
				components, found, err := unstructured.NestedSlice(object.Object, "spec", "components")
				if err != nil {
					return nil, fmt.Errorf("read Blueprint %q spec.components: %w", object.GetName(), err)
				}
				if !found {
					continue
				}
				for index, raw := range components {
					component, ok := raw.(map[string]any)
					if !ok {
						return nil, fmt.Errorf("Blueprint %q spec.components[%d] is not an object", object.GetName(), index)
					}
					name, found, err := unstructured.NestedString(component, "chartRepo")
					if err != nil {
						return nil, fmt.Errorf("read Blueprint %q spec.components[%d].chartRepo: %w", object.GetName(), index, err)
					}
					if found && strings.TrimSpace(name) != "" {
						required[name] = struct{}{}
					}
					vendor, _, err := unstructured.NestedString(component, "vendor")
					if err != nil {
						return nil, fmt.Errorf("read Blueprint %q spec.components[%d].vendor: %w", object.GetName(), index, err)
					}
					// NVIDIA charts can use a custom or public chart repository
					// while still requiring platform credentials for protected
					// workload images.
					if strings.EqualFold(strings.TrimSpace(vendor), "nvidia") {
						required["nvidia"] = struct{}{}
					}
				}
			}
		}
	}

	for name := range declared {
		delete(required, name)
	}
	names := make([]string, 0, len(required))
	for name := range required {
		names = append(names, name)
	}
	sort.Strings(names)
	return names, nil
}

func externalChartRepoError(name, state string) error {
	switch name {
	case "application-collection":
		return fmt.Errorf(
			"required Application Collection repository ClusterRepo/%s %s; these credentials are platform prerequisites, not Blueprint inputs: configure them once with ./aiflab/deploy.sh --skip-base --env-file /path/to/credentials.env or in AI Factory Settings, then rerun the deployment; they are shared by future Blueprints and are not deleted with a Blueprint",
			name, state,
		)
	case "suse-ai-registry":
		return fmt.Errorf(
			"required SUSE Registry repository ClusterRepo/%s %s; configure the platform SUSE Registry credential group in AI Factory Settings or with ./aiflab/deploy.sh --skip-base --env-file /path/to/credentials.env, then rerun the deployment",
			name, state,
		)
	case "nvidia", "nvidia-blueprints":
		return fmt.Errorf(
			"required NVIDIA repository ClusterRepo/%s %s; configure the platform NVIDIA credential group in AI Factory Settings or with ./aiflab/deploy.sh --skip-base --env-file /path/to/credentials.env, then rerun the deployment",
			name, state,
		)
	}
	return fmt.Errorf(
		"required external ClusterRepo %q %s; configure that platform repository before deploying this package",
		name, state,
	)
}

func (r *Runner) printPlan(pkg *Package) error {
	repos, err := requiredExternalChartRepos(pkg)
	if err != nil {
		return err
	}
	if len(repos) > 0 {
		fmt.Fprintf(r.Out, "External ClusterRepo prerequisites (verified before apply): %s\n", strings.Join(repos, ", "))
	}
	for _, stage := range pkg.Stages {
		fmt.Fprintf(r.Out, "Stage %s\n", stage.Path)
		for _, object := range stage.Objects {
			namespace := object.GetNamespace()
			if namespace == "" {
				fmt.Fprintf(r.Out, "  %s/%s\n", object.GetKind(), object.GetName())
				continue
			}
			fmt.Fprintf(r.Out, "  %s/%s namespace=%s\n", object.GetKind(), object.GetName(), namespace)
		}
	}
	return nil
}

type appliedRef struct {
	client     dynamic.ResourceInterface
	groupKind  schema.GroupKind
	namespace  string
	name       string
	generation int64
}

func (r *Runner) applyStage(ctx context.Context, stage Stage) ([]appliedRef, error) {
	refs := make([]appliedRef, 0)
	for _, sourceObject := range stage.Objects {
		object := sourceObject.DeepCopy()
		mapping, err := r.restMapping(object.GroupVersionKind())
		if err != nil {
			return nil, err
		}

		resourceClient, namespace := r.resourceClient(mapping, object)
		payload, err := json.Marshal(object.Object)
		if err != nil {
			return nil, fmt.Errorf("encode %s/%s: %w", object.GetKind(), object.GetName(), err)
		}
		if object.GroupVersionKind().GroupKind() == blueprintGroupKind {
			if err := ensureBlueprintSpecImmutable(ctx, resourceClient, object); err != nil {
				return nil, err
			}
		}
		applied, err := resourceClient.Patch(ctx, object.GetName(), types.ApplyPatchType, payload, metav1.PatchOptions{
			FieldManager: fieldManager,
		})
		if err != nil {
			return nil, fmt.Errorf("server-side apply %s: %w", objectDescription(object), err)
		}
		fmt.Fprintf(r.Out, "%s applied\n", objectDescription(applied))

		groupKind := object.GroupVersionKind().GroupKind()
		if groupKind != clusterRepoGroupKind && groupKind != aiWorkloadGroupKind && groupKind != jobGroupKind {
			continue
		}
		refs = append(refs, appliedRef{
			client:     resourceClient,
			groupKind:  groupKind,
			namespace:  namespace,
			name:       applied.GetName(),
			generation: applied.GetGeneration(),
		})
	}
	return refs, nil
}

func (r *Runner) restMapping(gvk schema.GroupVersionKind) (*meta.RESTMapping, error) {
	mapping, err := r.Mapper.RESTMapping(gvk.GroupKind(), gvk.Version)
	if err == nil {
		return mapping, nil
	}
	if !meta.IsNoMatchError(err) {
		return nil, fmt.Errorf("resolve %s: %w", gvk.String(), err)
	}

	if resetter, ok := r.Mapper.(interface{ Reset() }); ok {
		resetter.Reset()
		mapping, err = r.Mapper.RESTMapping(gvk.GroupKind(), gvk.Version)
		if err == nil {
			return mapping, nil
		}
	}
	return nil, fmt.Errorf("resolve %s: %w", gvk.String(), err)
}

func (r *Runner) resourceClient(mapping *meta.RESTMapping, object *unstructured.Unstructured) (dynamic.ResourceInterface, string) {
	if mapping.Scope.Name() != meta.RESTScopeNameNamespace {
		return r.Client.Resource(mapping.Resource), ""
	}

	namespace := object.GetNamespace()
	if namespace == "" {
		namespace = r.DefaultNamespace
		if namespace == "" {
			namespace = metav1.NamespaceDefault
		}
		object.SetNamespace(namespace)
	}
	return r.Client.Resource(mapping.Resource).Namespace(namespace), namespace
}

func ensureBlueprintSpecImmutable(ctx context.Context, resourceClient dynamic.ResourceInterface, desired *unstructured.Unstructured) error {
	current, err := resourceClient.Get(ctx, desired.GetName(), metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read existing Blueprint %q: %w", desired.GetName(), err)
	}

	// Ask the API server to default and merge the desired spec without
	// persisting it. Comparing that preview with the current object avoids
	// treating admission-added defaults as author changes.
	previewObject := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": desired.GetAPIVersion(),
		"kind":       desired.GetKind(),
		"metadata":   map[string]any{"name": desired.GetName()},
		"spec":       desired.Object["spec"],
	}}
	previewPayload, err := json.Marshal(previewObject.Object)
	if err != nil {
		return fmt.Errorf("encode Blueprint %q spec preview: %w", desired.GetName(), err)
	}
	preview, err := resourceClient.Patch(ctx, desired.GetName(), types.ApplyPatchType, previewPayload, metav1.PatchOptions{
		FieldManager: fieldManager,
		DryRun:       []string{metav1.DryRunAll},
	})
	if err != nil {
		return fmt.Errorf("Blueprint %q spec is immutable; publish a new version, or delete the workloads that reference this demo Blueprint and run its cleanup before redeploying: %w", desired.GetName(), err)
	}

	currentSpec, _, _ := unstructured.NestedMap(current.Object, "spec")
	previewSpec, _, _ := unstructured.NestedMap(preview.Object, "spec")
	if !apiequality.Semantic.DeepEqual(currentSpec, previewSpec) {
		return fmt.Errorf("Blueprint %q spec is immutable; publish a new Blueprint version, or delete the workloads that reference this demo Blueprint and run its cleanup before redeploying", desired.GetName())
	}
	return nil
}

func (r *Runner) waitForStage(ctx context.Context, refs []appliedRef) error {
	interval := r.PollInterval
	if interval <= 0 {
		interval = 2 * time.Second
	}
	failureGracePeriod := r.AIWorkloadFailureGracePeriod
	if failureGracePeriod <= 0 {
		failureGracePeriod = defaultAIWorkloadFailureGracePeriod
	}
	failureFirstSeen := make(map[string]time.Time)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		allReady := true
		for _, ref := range refs {
			object, err := ref.client.Get(ctx, ref.name, metav1.GetOptions{})
			if err != nil {
				return fmt.Errorf("read %s: %w", ref.description(), err)
			}

			var ready bool
			switch ref.groupKind {
			case clusterRepoGroupKind:
				ready, err = clusterRepoReady(object, ref.generation)
			case aiWorkloadGroupKind:
				ready, err = aiWorkloadReady(object, ref.generation)
			case jobGroupKind:
				ready, err = jobReady(object)
			}
			if err != nil {
				var workloadFailure *aiWorkloadFailedError
				if ref.groupKind == aiWorkloadGroupKind && errors.As(err, &workloadFailure) {
					key := ref.description()
					firstSeen, found := failureFirstSeen[key]
					if !found {
						firstSeen = time.Now()
						failureFirstSeen[key] = firstSeen
						fmt.Fprintf(r.Out, "%s reported Failed; allowing %s for AI Factory/Fleet recovery\n", key, failureGracePeriod)
					}
					if time.Since(firstSeen) < failureGracePeriod {
						allReady = false
						continue
					}
				}
				return fmt.Errorf("%s: %w", ref.description(), err)
			}
			key := ref.description()
			if _, recovering := failureFirstSeen[key]; recovering {
				delete(failureFirstSeen, key)
				fmt.Fprintf(r.Out, "%s recovered; continuing to wait\n", key)
			}
			if !ready {
				allReady = false
			}
		}
		if allReady {
			for _, ref := range refs {
				fmt.Fprintf(r.Out, "%s ready\n", ref.description())
			}
			return nil
		}

		select {
		case <-ctx.Done():
			return fmt.Errorf("readiness deadline exceeded: %w", ctx.Err())
		case <-ticker.C:
		}
	}
}

func clusterRepoReady(object *unstructured.Unstructured, expectedGeneration int64) (bool, error) {
	observedGeneration, _, err := unstructured.NestedInt64(object.Object, "status", "observedGeneration")
	if err != nil {
		return false, fmt.Errorf("read status.observedGeneration: %w", err)
	}
	if observedGeneration < expectedGeneration {
		return false, nil
	}

	conditionType, err := clusterRepoDownloadConditionType(object)
	if err != nil {
		return false, err
	}
	conditions, _, err := unstructured.NestedSlice(object.Object, "status", "conditions")
	if err != nil {
		return false, fmt.Errorf("read status.conditions: %w", err)
	}

	// Rancher normally keeps condition types unique. Scan backwards anyway so
	// that, if an older controller left duplicates, only the latest matching
	// download result can declare the repository ready.
	for i := len(conditions) - 1; i >= 0; i-- {
		condition, ok := conditions[i].(map[string]any)
		if !ok || condition["type"] != conditionType {
			continue
		}

		conditionGeneration, found, err := unstructured.NestedInt64(condition, "observedGeneration")
		if err != nil {
			return false, fmt.Errorf("read %s condition observedGeneration: %w", conditionType, err)
		}
		if found && conditionGeneration < expectedGeneration {
			return false, nil
		}

		switch condition["status"] {
		case "True":
			return true, nil
		case "False":
			if clusterRepoConditionTerminal(condition) {
				detail := joinReasonMessage(condition)
				if detail != "" {
					return false, fmt.Errorf("%s condition failed: %s", conditionType, detail)
				}
				return false, fmt.Errorf("%s condition failed", conditionType)
			}
		}
		return false, nil
	}
	return false, nil
}

func clusterRepoDownloadConditionType(object *unstructured.Unstructured) (string, error) {
	ociRepo, _, err := unstructured.NestedString(object.Object, "spec", "ociRepo")
	if err != nil {
		return "", fmt.Errorf("read spec.ociRepo: %w", err)
	}
	url, _, err := unstructured.NestedString(object.Object, "spec", "url")
	if err != nil {
		return "", fmt.Errorf("read spec.url: %w", err)
	}
	if ociRepo != "" || strings.HasPrefix(strings.ToLower(strings.TrimSpace(url)), "oci://") {
		return "OCIDownloaded", nil
	}
	return "Downloaded", nil
}

func clusterRepoConditionTerminal(condition map[string]any) bool {
	reason, _ := condition["reason"].(string)
	switch strings.ToLower(strings.TrimSpace(reason)) {
	case "authenticationfailed", "authorizationfailed", "fatal", "forbidden", "invalid",
		"invalidconfiguration", "invalidurl", "terminal", "unauthorized", "unsupported", "unsupportedscheme":
		return true
	}

	// Rancher commonly reports all download failures with reason=Error. Only
	// fail fast for messages that identify a configuration or authorization
	// problem; network and server errors can recover and should keep polling.
	message, _ := condition["message"].(string)
	message = strings.ToLower(message)
	for _, terminalFragment := range []string{
		"401: unauthorized",
		"403: forbidden",
		"authentication failed",
		"authorization failed",
		"invalid url",
		"malformed url",
		"unsupported protocol scheme",
		"unsupported scheme",
	} {
		if strings.Contains(message, terminalFragment) {
			return true
		}
	}
	return false
}

func aiWorkloadReady(object *unstructured.Unstructured, expectedGeneration int64) (bool, error) {
	observedGeneration, _, err := unstructured.NestedInt64(object.Object, "status", "observedGeneration")
	if err != nil {
		return false, fmt.Errorf("read status.observedGeneration: %w", err)
	}
	if observedGeneration < expectedGeneration {
		return false, nil
	}

	phase, _, err := unstructured.NestedString(object.Object, "status", "phase")
	if err != nil {
		return false, fmt.Errorf("read status.phase: %w", err)
	}
	switch phase {
	case "Failed":
		detail := conditionDetail(object)
		return false, &aiWorkloadFailedError{phase: phase, detail: detail}
	}

	if phase == "Running" {
		return true, nil
	}
	// AI Factory currently exposes clusterStatuses.phase=Failed while Fleet is
	// still applying Helm hooks and pods. Trust the top-level phase here. A
	// Failed result is typed so waitForStage can apply its bounded recovery
	// grace period; Pending or Degraded keeps polling until the caller's
	// explicit deployment timeout.
	return false, nil
}

type aiWorkloadFailedError struct {
	phase  string
	detail string
}

func (e *aiWorkloadFailedError) Error() string {
	if e.detail != "" {
		return fmt.Sprintf("reached %s: %s", e.phase, e.detail)
	}
	return fmt.Sprintf("reached %s", e.phase)
}

func jobReady(object *unstructured.Unstructured) (bool, error) {
	conditions, _, err := unstructured.NestedSlice(object.Object, "status", "conditions")
	if err != nil {
		return false, fmt.Errorf("read status.conditions: %w", err)
	}
	for _, rawCondition := range conditions {
		condition, ok := rawCondition.(map[string]any)
		if !ok || condition["status"] != "True" {
			continue
		}
		switch condition["type"] {
		case "Complete":
			return true, nil
		case "Failed":
			detail := joinReasonMessage(condition)
			if detail != "" {
				return false, fmt.Errorf("failed: %s", detail)
			}
			return false, fmt.Errorf("failed")
		}
	}
	return false, nil
}

func conditionDetail(object *unstructured.Unstructured) string {
	conditions, _, _ := unstructured.NestedSlice(object.Object, "status", "conditions")
	for i := len(conditions) - 1; i >= 0; i-- {
		condition, ok := conditions[i].(map[string]any)
		if !ok {
			continue
		}
		if detail := joinReasonMessage(condition); detail != "" {
			return detail
		}
	}
	return ""
}

func joinReasonMessage(condition map[string]any) string {
	reason, _ := condition["reason"].(string)
	message, _ := condition["message"].(string)
	return strings.Trim(strings.Join([]string{reason, message}, ": "), ": ")
}

func objectDescription(object *unstructured.Unstructured) string {
	if object.GetNamespace() == "" {
		return fmt.Sprintf("%s/%s", object.GetKind(), object.GetName())
	}
	return fmt.Sprintf("%s/%s namespace=%s", object.GetKind(), object.GetName(), object.GetNamespace())
}

func (r appliedRef) description() string {
	if r.namespace == "" {
		return fmt.Sprintf("%s/%s", r.groupKind.Kind, r.name)
	}
	return fmt.Sprintf("%s/%s namespace=%s", r.groupKind.Kind, r.name, r.namespace)
}
