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
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/validation"
	"k8s.io/client-go/dynamic"
)

const (
	accessURLAnnotation         = "aiflab.suse.com/access-url"
	accessServiceAnnotation     = "aiflab.suse.com/access-service"
	accessServicePortAnnotation = "aiflab.suse.com/access-service-port"
)

var serviceResource = schema.GroupVersionResource{Group: "", Version: "v1", Resource: "services"}

type accessEndpoint struct {
	url              *url.URL
	serviceNamespace string
	serviceName      string
	servicePort      int64
}

// ResolveAccessURLs resolves package access annotations against their backing
// Services. NodePort services receive the allocated node port, so the printed
// URL can be opened without another kubectl query.
func ResolveAccessURLs(ctx context.Context, client dynamic.Interface, pkg *Package) ([]string, error) {
	if client == nil {
		return nil, fmt.Errorf("Kubernetes client is required to resolve access URLs")
	}
	endpoints, err := packageAccessEndpoints(pkg)
	if err != nil {
		return nil, err
	}

	urls := make([]string, 0, len(endpoints))
	for _, endpoint := range endpoints {
		service, err := client.Resource(serviceResource).Namespace(endpoint.serviceNamespace).
			Get(ctx, endpoint.serviceName, metav1.GetOptions{})
		if err != nil {
			return nil, fmt.Errorf("read access Service %s/%s: %w", endpoint.serviceNamespace, endpoint.serviceName, err)
		}
		resolved, err := resolveServiceAccessURL(endpoint, service)
		if err != nil {
			return nil, fmt.Errorf("resolve access Service %s/%s: %w", endpoint.serviceNamespace, endpoint.serviceName, err)
		}
		urls = append(urls, resolved)
	}
	return urls, nil
}

func packageAccessEndpoints(pkg *Package) ([]accessEndpoint, error) {
	if pkg == nil {
		return nil, fmt.Errorf("deployment package is required")
	}
	var endpoints []accessEndpoint
	for _, stage := range pkg.Stages {
		for _, object := range stage.Objects {
			annotations := object.GetAnnotations()
			accessURL := strings.TrimSpace(annotations[accessURLAnnotation])
			serviceRef := strings.TrimSpace(annotations[accessServiceAnnotation])
			servicePort := strings.TrimSpace(annotations[accessServicePortAnnotation])
			if accessURL == "" && serviceRef == "" && servicePort == "" {
				continue
			}
			if accessURL == "" || serviceRef == "" || servicePort == "" {
				return nil, fmt.Errorf("%s must set %s, %s, and %s together",
					objectDescription(object), accessURLAnnotation, accessServiceAnnotation, accessServicePortAnnotation)
			}

			parsedURL, err := url.Parse(accessURL)
			if err != nil || parsedURL.Hostname() == "" || (parsedURL.Scheme != "http" && parsedURL.Scheme != "https") {
				return nil, fmt.Errorf("%s has invalid %s %q", objectDescription(object), accessURLAnnotation, accessURL)
			}
			if parsedURL.User != nil {
				return nil, fmt.Errorf("%s %s must not contain user information", objectDescription(object), accessURLAnnotation)
			}

			serviceParts := strings.Split(serviceRef, "/")
			if len(serviceParts) != 2 || len(validation.IsDNS1123Label(serviceParts[0])) > 0 ||
				len(validation.IsDNS1123Label(serviceParts[1])) > 0 {
				return nil, fmt.Errorf("%s has invalid %s %q; expected namespace/name",
					objectDescription(object), accessServiceAnnotation, serviceRef)
			}
			port, err := strconv.ParseInt(servicePort, 10, 32)
			if err != nil || port < 1 || port > 65535 {
				return nil, fmt.Errorf("%s has invalid %s %q", objectDescription(object), accessServicePortAnnotation, servicePort)
			}
			endpoints = append(endpoints, accessEndpoint{
				url:              parsedURL,
				serviceNamespace: serviceParts[0],
				serviceName:      serviceParts[1],
				servicePort:      port,
			})
		}
	}
	return endpoints, nil
}

func resolveServiceAccessURL(endpoint accessEndpoint, service *unstructured.Unstructured) (string, error) {
	serviceType, _, err := unstructured.NestedString(service.Object, "spec", "type")
	if err != nil {
		return "", fmt.Errorf("read spec.type: %w", err)
	}
	ports, _, err := unstructured.NestedSlice(service.Object, "spec", "ports")
	if err != nil {
		return "", fmt.Errorf("read spec.ports: %w", err)
	}
	var matchedPort map[string]any
	for _, rawPort := range ports {
		port, ok := rawPort.(map[string]any)
		if !ok {
			continue
		}
		portNumber, _, _ := unstructured.NestedInt64(port, "port")
		if portNumber == endpoint.servicePort {
			matchedPort = port
			break
		}
	}
	if matchedPort == nil {
		return "", fmt.Errorf("Service has no port %d", endpoint.servicePort)
	}

	resolvedURL := *endpoint.url
	switch serviceType {
	case "NodePort":
		nodePort, found, err := unstructured.NestedInt64(matchedPort, "nodePort")
		if err != nil {
			return "", fmt.Errorf("read nodePort for Service port %d: %w", endpoint.servicePort, err)
		}
		if !found || nodePort == 0 {
			return "", fmt.Errorf("Service port %d has no allocated nodePort", endpoint.servicePort)
		}
		resolvedURL.Host = net.JoinHostPort(resolvedURL.Hostname(), strconv.FormatInt(nodePort, 10))
	case "LoadBalancer":
		if !isDefaultURLPort(resolvedURL.Scheme, endpoint.servicePort) {
			resolvedURL.Host = net.JoinHostPort(resolvedURL.Hostname(), strconv.FormatInt(endpoint.servicePort, 10))
		}
	default:
		return "", fmt.Errorf("Service type %q is not externally addressable", serviceType)
	}
	return resolvedURL.String(), nil
}

func isDefaultURLPort(scheme string, port int64) bool {
	return (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
}
