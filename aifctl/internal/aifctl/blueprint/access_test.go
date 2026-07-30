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
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

func TestResolveAccessURLsAddsAllocatedHTTPSNodePort(t *testing.T) {
	pkg := testAccessPackage(map[string]string{
		accessURLAnnotation:         "https://kubeflow.192.0.2.15.sslip.io",
		accessServiceAnnotation:     "istio-system/istio",
		accessServicePortAnnotation: "443",
	})
	service := testAccessService("NodePort", int64(443), int64(31020))
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), service)

	urls, err := ResolveAccessURLs(context.Background(), client, pkg)
	if err != nil {
		t.Fatalf("ResolveAccessURLs() error = %v", err)
	}
	if len(urls) != 1 || urls[0] != "https://kubeflow.192.0.2.15.sslip.io:31020" {
		t.Fatalf("URLs = %#v, want exact HTTPS NodePort URL", urls)
	}
}

func TestResolveAccessURLsKeepsDefaultLoadBalancerPortImplicit(t *testing.T) {
	pkg := testAccessPackage(map[string]string{
		accessURLAnnotation:         "https://kubeflow.lab.example.com",
		accessServiceAnnotation:     "istio-system/istio",
		accessServicePortAnnotation: "443",
	})
	service := testAccessService("LoadBalancer", int64(443), int64(0))
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), service)

	urls, err := ResolveAccessURLs(context.Background(), client, pkg)
	if err != nil {
		t.Fatalf("ResolveAccessURLs() error = %v", err)
	}
	if len(urls) != 1 || urls[0] != "https://kubeflow.lab.example.com" {
		t.Fatalf("URLs = %#v, want default HTTPS URL", urls)
	}
}

func TestResolveAccessURLsRejectsPartialAnnotations(t *testing.T) {
	pkg := testAccessPackage(map[string]string{
		accessURLAnnotation: "https://kubeflow.example.com",
	})
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme())

	_, err := ResolveAccessURLs(context.Background(), client, pkg)
	if err == nil || !strings.Contains(err.Error(), "must set") {
		t.Fatalf("ResolveAccessURLs() error = %v, want annotation-contract error", err)
	}
}

func TestResolveAccessURLsRequiresExternallyAddressableService(t *testing.T) {
	pkg := testAccessPackage(map[string]string{
		accessURLAnnotation:         "https://kubeflow.example.com",
		accessServiceAnnotation:     "istio-system/istio",
		accessServicePortAnnotation: "443",
	})
	service := testAccessService("ClusterIP", int64(443), int64(0))
	client := dynamicfake.NewSimpleDynamicClient(runtime.NewScheme(), service)

	_, err := ResolveAccessURLs(context.Background(), client, pkg)
	if err == nil || !strings.Contains(err.Error(), "not externally addressable") {
		t.Fatalf("ResolveAccessURLs() error = %v, want Service type error", err)
	}
}

func testAccessPackage(annotations map[string]string) *Package {
	object := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "ai-factory.suse.com/v1alpha1",
		"kind":       "AIWorkload",
		"metadata": map[string]any{
			"name":        "test",
			"namespace":   "test",
			"annotations": stringMapToAny(annotations),
		},
	}}
	return &Package{Stages: []Stage{{Objects: []*unstructured.Unstructured{object}}}}
}

func testAccessService(serviceType string, port, nodePort int64) *unstructured.Unstructured {
	servicePort := map[string]any{"name": "https", "port": port}
	if nodePort != 0 {
		servicePort["nodePort"] = nodePort
	}
	return &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1",
		"kind":       "Service",
		"metadata": map[string]any{
			"name":      "istio",
			"namespace": "istio-system",
		},
		"spec": map[string]any{
			"type":  serviceType,
			"ports": []any{servicePort},
		},
	}}
}

func stringMapToAny(values map[string]string) map[string]any {
	result := make(map[string]any, len(values))
	for key, value := range values {
		result[key] = value
	}
	return result
}
