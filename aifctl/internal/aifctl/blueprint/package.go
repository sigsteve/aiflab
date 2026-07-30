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
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	utilyaml "k8s.io/apimachinery/pkg/util/yaml"
)

const mainManifestName = "blueprint.yaml"

var aiWorkloadGroupKind = schema.GroupKind{
	Group: "ai-factory.suse.com",
	Kind:  "AIWorkload",
}

// Package is a fully parsed deployment source. Stages are ordered and are
// applied one at a time so readiness in one stage can gate the next.
type Package struct {
	Stages []Stage
}

// Stage is one YAML file in a deployment package.
type Stage struct {
	Path    string
	Main    bool
	Objects []*unstructured.Unstructured
}

// Load parses a multi-document YAML file or a convention-based directory. A
// directory contains optional deps/*.yaml files, a required blueprint.yaml,
// and optional post-deploy/*.yaml files. Every file is parsed before Load
// returns, ensuring malformed late stages cannot produce a partial deployment.
func Load(source string) (*Package, error) {
	if source == "" {
		return nil, fmt.Errorf("--from is required")
	}

	info, err := os.Stat(source)
	if err != nil {
		return nil, fmt.Errorf("inspect deployment source %q: %w", source, err)
	}

	var specs []stageSpec
	if info.IsDir() {
		specs, err = directoryStages(source)
	} else if info.Mode().IsRegular() {
		specs = []stageSpec{{path: source, main: true}}
	} else {
		return nil, fmt.Errorf("deployment source %q is neither a regular file nor a directory", source)
	}
	if err != nil {
		return nil, err
	}

	pkg := &Package{Stages: make([]Stage, 0, len(specs))}
	for _, spec := range specs {
		objects, parseErr := parseManifest(spec.path)
		if parseErr != nil {
			return nil, parseErr
		}
		pkg.Stages = append(pkg.Stages, Stage{
			Path:    spec.path,
			Main:    spec.main,
			Objects: objects,
		})
	}

	for _, stage := range pkg.Stages {
		if stage.Main && !containsAIWorkload(stage.Objects) {
			return nil, fmt.Errorf("main manifest %q must include at least one AIWorkload", stage.Path)
		}
	}

	return pkg, nil
}

type stageSpec struct {
	path string
	main bool
}

func directoryStages(dir string) ([]stageSpec, error) {
	mainPath := filepath.Join(dir, mainManifestName)
	info, err := os.Stat(mainPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("deployment directory %q must contain %s", dir, mainManifestName)
		}
		return nil, fmt.Errorf("inspect main manifest %q: %w", mainPath, err)
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("main manifest %q is not a regular file", mainPath)
	}

	deps, err := manifestFiles(filepath.Join(dir, "deps"))
	if err != nil {
		return nil, err
	}
	postDeploy, err := manifestFiles(filepath.Join(dir, "post-deploy"))
	if err != nil {
		return nil, err
	}

	stages := make([]stageSpec, 0, len(deps)+1+len(postDeploy))
	for _, path := range deps {
		stages = append(stages, stageSpec{path: path})
	}
	stages = append(stages, stageSpec{path: mainPath, main: true})
	for _, path := range postDeploy {
		stages = append(stages, stageSpec{path: path})
	}
	return stages, nil
}

func manifestFiles(dir string) ([]string, error) {
	info, err := os.Stat(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("inspect manifest directory %q: %w", dir, err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("manifest path %q must be a directory", dir)
	}

	paths, err := filepath.Glob(filepath.Join(dir, "*.yaml"))
	if err != nil {
		return nil, fmt.Errorf("list YAML manifests in %q: %w", dir, err)
	}
	sort.Strings(paths)
	return paths, nil
}

func parseManifest(path string) ([]*unstructured.Unstructured, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open manifest %q: %w", path, err)
	}
	defer file.Close()

	decoder := utilyaml.NewYAMLOrJSONDecoder(file, 4096)
	var objects []*unstructured.Unstructured
	for document := 1; ; document++ {
		object := &unstructured.Unstructured{}
		if err := decoder.Decode(object); err != nil {
			if err == io.EOF {
				break
			}
			return nil, fmt.Errorf("parse %q document %d: %w", path, document, err)
		}
		if len(object.Object) == 0 {
			continue
		}
		if err := validateObject(path, document, object); err != nil {
			return nil, err
		}
		objects = append(objects, object)
	}
	if len(objects) == 0 {
		return nil, fmt.Errorf("manifest %q contains no Kubernetes resources", path)
	}
	return objects, nil
}

func validateObject(path string, document int, object *unstructured.Unstructured) error {
	if object.GetAPIVersion() == "" {
		return fmt.Errorf("%q document %d is missing apiVersion", path, document)
	}
	if object.GetKind() == "" {
		return fmt.Errorf("%q document %d is missing kind", path, document)
	}
	if object.GetName() == "" {
		return fmt.Errorf("%q document %d (%s) is missing metadata.name", path, document, object.GetKind())
	}
	if _, err := schema.ParseGroupVersion(object.GetAPIVersion()); err != nil {
		return fmt.Errorf("%q document %d has invalid apiVersion %q: %w", path, document, object.GetAPIVersion(), err)
	}
	if object.GroupVersionKind().GroupKind() == blueprintGroupKind {
		for _, field := range []string{"displayName", "version"} {
			value, _, err := unstructured.NestedString(object.Object, "spec", field)
			if err != nil {
				return fmt.Errorf("%q document %d Blueprint has invalid spec.%s: %w", path, document, field, err)
			}
			if value == "" {
				return fmt.Errorf("%q document %d Blueprint is missing spec.%s", path, document, field)
			}
		}
	}
	return nil
}

func containsAIWorkload(objects []*unstructured.Unstructured) bool {
	for _, object := range objects {
		if object.GroupVersionKind().GroupKind() == aiWorkloadGroupKind {
			return true
		}
	}
	return false
}
