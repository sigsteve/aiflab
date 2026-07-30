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
	"crypto/sha256"
	"fmt"
	"net/netip"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/client-go/dynamic"
)

// DomainPlaceholder lets a structured deployment package request a single,
// cluster-aware base domain without teaching aifctl about an individual Helm
// chart's values. Packages can use the token anywhere in a string, for example
// kubeflow.__AIFLAB_DOMAIN__ and __AIFLAB_DOMAIN__.
const (
	DomainPlaceholder   = "__AIFLAB_DOMAIN__"
	DomainIDPlaceholder = "__AIFLAB_DOMAIN_ID__"
)

var nodeResource = schema.GroupVersionResource{Group: "", Version: "v1", Resource: "nodes"}

// DomainResolution describes the base domain rendered into a package.
type DomainResolution struct {
	Domain string
	Source string
}

// NeedsDomain reports whether any object in the package contains the domain
// placeholder.
func (p *Package) NeedsDomain() bool {
	if p == nil {
		return false
	}
	for _, stage := range p.Stages {
		for _, object := range stage.Objects {
			if containsDomainPlaceholder(object.Object) {
				return true
			}
		}
	}
	return false
}

// RenderDomain replaces every domain placeholder in memory. Source manifests
// remain unchanged, which keeps a package portable between clusters.
func (p *Package) RenderDomain(domain string) error {
	if p == nil {
		return fmt.Errorf("deployment package is required")
	}
	domain = strings.TrimSpace(domain)
	if err := validateDomain(domain); err != nil {
		return err
	}
	domainID := fmt.Sprintf("%x", sha256.Sum256([]byte(domain)))[:12]

	replacements := 0
	for _, stage := range p.Stages {
		for _, object := range stage.Objects {
			replacements += replaceDomainPlaceholders(object.Object, domain, domainID)
		}
	}
	if replacements == 0 {
		return fmt.Errorf("deployment package does not contain %s", DomainPlaceholder)
	}
	return nil
}

// ResolveDomain validates an explicit domain or derives <node-ip>.sslip.io.
// External node addresses are preferred over internal addresses, matching how
// a NodePort is normally reached from outside a cluster.
func ResolveDomain(ctx context.Context, client dynamic.Interface, override string) (DomainResolution, error) {
	override = strings.TrimSpace(override)
	if override != "" {
		if err := validateDomain(override); err != nil {
			return DomainResolution{}, fmt.Errorf("invalid --domain value: %w", err)
		}
		return DomainResolution{Domain: override, Source: "override"}, nil
	}
	if client == nil {
		return DomainResolution{}, fmt.Errorf("Kubernetes client is required to derive a deployment domain")
	}

	nodes, err := client.Resource(nodeResource).List(ctx, metav1.ListOptions{})
	if err != nil {
		return DomainResolution{}, fmt.Errorf("list Kubernetes nodes for domain discovery: %w", err)
	}
	address, addressType := preferredNodeIPv4(nodes)
	if address == "" {
		return DomainResolution{}, fmt.Errorf("no usable node ExternalIP or InternalIP found; set --domain explicitly")
	}
	return DomainResolution{
		Domain: address + ".sslip.io",
		Source: "node " + addressType,
	}, nil
}

func preferredNodeIPv4(nodes *unstructured.UnstructuredList) (string, string) {
	if nodes == nil {
		return "", ""
	}
	for _, addressType := range []string{"ExternalIP", "InternalIP"} {
		for i := range nodes.Items {
			if !nodeReady(&nodes.Items[i]) {
				continue
			}
			addresses, _, _ := unstructured.NestedSlice(nodes.Items[i].Object, "status", "addresses")
			for _, rawAddress := range addresses {
				address, ok := rawAddress.(map[string]any)
				if !ok || address["type"] != addressType {
					continue
				}
				value, _ := address["address"].(string)
				if usableIPv4(value) {
					return value, addressType
				}
			}
		}
	}
	return "", ""
}

func nodeReady(node *unstructured.Unstructured) bool {
	if node == nil {
		return false
	}
	conditions, _, _ := unstructured.NestedSlice(node.Object, "status", "conditions")
	for _, rawCondition := range conditions {
		condition, ok := rawCondition.(map[string]any)
		if ok && condition["type"] == "Ready" {
			return condition["status"] == "True"
		}
	}
	return false
}

func usableIPv4(value string) bool {
	address, err := netip.ParseAddr(strings.TrimSpace(value))
	if err != nil || !address.Is4() {
		return false
	}
	return !address.IsUnspecified() && !address.IsLoopback() &&
		!address.IsMulticast() && !address.IsLinkLocalUnicast()
}

func validateDomain(domain string) error {
	if domain == "" {
		return fmt.Errorf("domain must not be empty")
	}
	if problems := validation.IsDNS1123Subdomain(domain); len(problems) > 0 {
		return fmt.Errorf("domain %q is invalid: %s", domain, strings.Join(problems, "; "))
	}
	return nil
}

func containsDomainPlaceholder(value any) bool {
	switch typed := value.(type) {
	case string:
		return strings.Contains(typed, DomainPlaceholder) || strings.Contains(typed, DomainIDPlaceholder)
	case map[string]any:
		for _, child := range typed {
			if containsDomainPlaceholder(child) {
				return true
			}
		}
	case []any:
		for _, child := range typed {
			if containsDomainPlaceholder(child) {
				return true
			}
		}
	}
	return false
}

func replaceDomainPlaceholders(value any, domain, domainID string) int {
	replacements := 0
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			switch childValue := child.(type) {
			case string:
				count := strings.Count(childValue, DomainPlaceholder) + strings.Count(childValue, DomainIDPlaceholder)
				if count > 0 {
					rendered := strings.ReplaceAll(childValue, DomainPlaceholder, domain)
					typed[key] = strings.ReplaceAll(rendered, DomainIDPlaceholder, domainID)
					replacements += count
				}
			default:
				replacements += replaceDomainPlaceholders(childValue, domain, domainID)
			}
		}
	case []any:
		for index, child := range typed {
			switch childValue := child.(type) {
			case string:
				count := strings.Count(childValue, DomainPlaceholder) + strings.Count(childValue, DomainIDPlaceholder)
				if count > 0 {
					rendered := strings.ReplaceAll(childValue, DomainPlaceholder, domain)
					typed[index] = strings.ReplaceAll(rendered, DomainIDPlaceholder, domainID)
					replacements += count
				}
			default:
				replacements += replaceDomainPlaceholders(childValue, domain, domainID)
			}
		}
	}
	return replacements
}
