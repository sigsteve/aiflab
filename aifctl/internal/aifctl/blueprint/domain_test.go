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
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

func TestPackageRenderDomainReplacesOneBaseDomainConsistently(t *testing.T) {
	object := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "ai-factory.suse.com/v1alpha1",
		"kind":       "Blueprint",
		"metadata":   map[string]any{"name": "test-" + DomainIDPlaceholder},
		"spec": map[string]any{
			"hostname": "kubeflow." + DomainPlaceholder,
			"domain":   DomainPlaceholder,
		},
	}}
	pkg := &Package{Stages: []Stage{{Objects: []*unstructured.Unstructured{object}}}}
	if !pkg.NeedsDomain() {
		t.Fatal("NeedsDomain() = false, want true")
	}

	if err := pkg.RenderDomain("192.0.2.15.sslip.io"); err != nil {
		t.Fatalf("RenderDomain() error = %v", err)
	}
	hostname, _, _ := unstructured.NestedString(object.Object, "spec", "hostname")
	domain, _, _ := unstructured.NestedString(object.Object, "spec", "domain")
	if hostname != "kubeflow.192.0.2.15.sslip.io" {
		t.Errorf("hostname = %q, want rendered Kubeflow hostname", hostname)
	}
	if domain != "192.0.2.15.sslip.io" {
		t.Errorf("domain = %q, want rendered Knative domain", domain)
	}
	if got := object.GetName(); got != "test-a60fd0fc0a7d" {
		t.Errorf("name = %q, want stable domain-derived identity", got)
	}
	if pkg.NeedsDomain() {
		t.Fatal("NeedsDomain() = true after rendering, want false")
	}
}

func TestPackageRenderDomainRejectsInvalidOrUnusedDomain(t *testing.T) {
	pkg := &Package{Stages: []Stage{{Objects: []*unstructured.Unstructured{{
		Object: map[string]any{"apiVersion": "v1", "kind": "ConfigMap", "metadata": map[string]any{"name": "test"}},
	}}}}}
	if err := pkg.RenderDomain("Bad Domain"); err == nil || !strings.Contains(err.Error(), "invalid") {
		t.Fatalf("RenderDomain(invalid) error = %v, want validation error", err)
	}
	if err := pkg.RenderDomain("lab.example.com"); err == nil || !strings.Contains(err.Error(), "does not contain") {
		t.Fatalf("RenderDomain(unused) error = %v, want unused-placeholder error", err)
	}
}

func TestResolveDomainUsesValidExplicitOverrideWithoutACluster(t *testing.T) {
	resolution, err := ResolveDomain(context.Background(), nil, "lab.example.com")
	if err != nil {
		t.Fatalf("ResolveDomain() error = %v", err)
	}
	if resolution.Domain != "lab.example.com" || resolution.Source != "override" {
		t.Fatalf("resolution = %#v, want explicit domain", resolution)
	}

	_, err = ResolveDomain(context.Background(), nil, "UPPER.example.com")
	if err == nil || !strings.Contains(err.Error(), "invalid --domain") {
		t.Fatalf("ResolveDomain(invalid override) error = %v, want validation error", err)
	}
}

func TestResolveDomainPrefersExternalNodeIPv4(t *testing.T) {
	nodeWithoutExternal := testNode("node-a", map[string]string{
		"InternalIP": "10.0.0.10",
	})
	nodeWithExternal := testNode("node-b", map[string]string{
		"ExternalIP": "192.0.2.25",
		"InternalIP": "10.0.0.11",
	})
	client := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(
		runtime.NewScheme(), map[schema.GroupVersionResource]string{nodeResource: "NodeList"},
		nodeWithoutExternal, nodeWithExternal,
	)

	resolution, err := ResolveDomain(context.Background(), client, "")
	if err != nil {
		t.Fatalf("ResolveDomain() error = %v", err)
	}
	if resolution.Domain != "192.0.2.25.sslip.io" || resolution.Source != "node ExternalIP" {
		t.Fatalf("resolution = %#v, want external node domain", resolution)
	}
}

func TestResolveDomainFallsBackToUsableInternalNodeIPv4(t *testing.T) {
	node := testNode("node-a", map[string]string{
		"ExternalIP": "127.0.0.1",
		"InternalIP": "192.168.122.227",
	})
	client := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(
		runtime.NewScheme(), map[schema.GroupVersionResource]string{nodeResource: "NodeList"}, node,
	)

	resolution, err := ResolveDomain(context.Background(), client, "")
	if err != nil {
		t.Fatalf("ResolveDomain() error = %v", err)
	}
	if resolution.Domain != "192.168.122.227.sslip.io" || resolution.Source != "node InternalIP" {
		t.Fatalf("resolution = %#v, want internal node domain", resolution)
	}
}

func TestResolveDomainIgnoresNotReadyNodes(t *testing.T) {
	notReady := testNode("node-a", map[string]string{
		"ExternalIP": "192.0.2.25",
	})
	_ = unstructured.SetNestedSlice(notReady.Object, []any{
		map[string]any{"type": "Ready", "status": "False"},
	}, "status", "conditions")
	ready := testNode("node-b", map[string]string{
		"InternalIP": "192.0.2.26",
	})
	client := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(
		runtime.NewScheme(), map[schema.GroupVersionResource]string{nodeResource: "NodeList"}, notReady, ready,
	)

	resolution, err := ResolveDomain(context.Background(), client, "")
	if err != nil {
		t.Fatalf("ResolveDomain() error = %v", err)
	}
	if resolution.Domain != "192.0.2.26.sslip.io" || resolution.Source != "node InternalIP" {
		t.Fatalf("resolution = %#v, want address from Ready node", resolution)
	}
}

func TestResolveDomainRequiresUsableNodeAddress(t *testing.T) {
	node := testNode("node-a", map[string]string{
		"ExternalIP": "not-an-address",
		"InternalIP": "::1",
	})
	client := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(
		runtime.NewScheme(), map[schema.GroupVersionResource]string{nodeResource: "NodeList"}, node,
	)

	_, err := ResolveDomain(context.Background(), client, "")
	if err == nil || !strings.Contains(err.Error(), "set --domain explicitly") {
		t.Fatalf("ResolveDomain() error = %v, want explicit-domain guidance", err)
	}
}

func testNode(name string, addresses map[string]string) *unstructured.Unstructured {
	addressList := make([]any, 0, len(addresses))
	for addressType, address := range addresses {
		addressList = append(addressList, map[string]any{"type": addressType, "address": address})
	}
	return &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1",
		"kind":       "Node",
		"metadata":   map[string]any{"name": name},
		"status": map[string]any{
			"addresses": addressList,
			"conditions": []any{
				map[string]any{"type": "Ready", "status": "True"},
			},
		},
	}}
}
