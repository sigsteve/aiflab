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
	"context"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/discovery/cached/memory"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/restmapper"
	"k8s.io/client-go/tools/clientcmd"

	"github.com/SUSE/aif/aiflab/aifctl/internal/aifctl/blueprint"
)

const defaultDeployTimeout = 30 * time.Minute

// NewCommand constructs the aifctl command tree.
func NewCommand(out, errOut io.Writer) *cobra.Command {
	root := &cobra.Command{
		Use:          "aifctl",
		Short:        "Operate SUSE AI Factory resources",
		SilenceUsage: true,
	}
	root.SetOut(out)
	root.SetErr(errOut)

	blueprintCommand := &cobra.Command{
		Use:   "blueprint",
		Short: "Deploy Blueprint packages",
	}
	blueprintCommand.AddCommand(newBlueprintDeployCommand(out))
	root.AddCommand(blueprintCommand)
	return root
}

type deployFlags struct {
	from       string
	kubeconfig string
	context    string
	timeout    time.Duration
	noWait     bool
	dryRun     bool
	domain     string
}

func newBlueprintDeployCommand(out io.Writer) *cobra.Command {
	opts := deployFlags{}
	command := &cobra.Command{
		Use:   "deploy --from FILE|DIR",
		Short: "Apply a Blueprint manifest or ordered package directory",
		Long: `Apply a multi-document YAML file, or a directory containing optional
deps/*.yaml stages, a required blueprint.yaml, and optional
post-deploy/*.yaml stages. Directory stages are applied in lexical order.

Before applying anything, aifctl verifies external ClusterRepos referenced by
the packaged Blueprints. Configure platform credentials separately in AI
Factory Settings or with aiflab/deploy.sh --env-file; credentials are never
accepted as Blueprint deployment flags.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if opts.from == "" {
				return fmt.Errorf("--from is required")
			}
			if opts.timeout <= 0 {
				return fmt.Errorf("--timeout must be greater than zero")
			}

			pkg, err := blueprint.Load(opts.from)
			if err != nil {
				return err
			}

			deployOptions := blueprint.DeployOptions{
				DryRun: opts.dryRun,
				Wait:   !opts.noWait,
			}
			if opts.dryRun {
				if pkg.NeedsDomain() {
					domainOverride := requestedDomain(opts.domain)
					if domainOverride == "" {
						fmt.Fprintln(out, "Deployment domain will be derived at apply time as <node-ip>.sslip.io; use --domain to override it")
					} else {
						resolution, err := blueprint.ResolveDomain(cmd.Context(), nil, domainOverride)
						if err != nil {
							return err
						}
						if err := pkg.RenderDomain(resolution.Domain); err != nil {
							return err
						}
						fmt.Fprintf(out, "Resolved deployment domain %s (%s)\n", resolution.Domain, resolution.Source)
					}
				}
				return (&blueprint.Runner{Out: out}).Deploy(cmd.Context(), pkg, deployOptions)
			}

			clientConfig := kubeClientConfig(opts.kubeconfig, opts.context)
			config, err := clientConfig.ClientConfig()
			if err != nil {
				return fmt.Errorf("load Kubernetes configuration: %w", err)
			}
			config = rest.AddUserAgent(config, "aifctl")
			defaultNamespace, _, err := clientConfig.Namespace()
			if err != nil {
				return fmt.Errorf("resolve Kubernetes namespace: %w", err)
			}

			dynamicClient, err := dynamic.NewForConfig(config)
			if err != nil {
				return fmt.Errorf("create Kubernetes client: %w", err)
			}
			discoveryClient, err := discovery.NewDiscoveryClientForConfig(config)
			if err != nil {
				return fmt.Errorf("create Kubernetes discovery client: %w", err)
			}
			mapper := restmapper.NewDeferredDiscoveryRESTMapper(memory.NewMemCacheClient(discoveryClient))

			deployContext, cancel := context.WithTimeout(cmd.Context(), opts.timeout)
			defer cancel()
			if pkg.NeedsDomain() {
				domainOverride := requestedDomain(opts.domain)
				resolution, err := blueprint.ResolveDomain(deployContext, dynamicClient, domainOverride)
				if err != nil {
					return err
				}
				if err := pkg.RenderDomain(resolution.Domain); err != nil {
					return err
				}
				fmt.Fprintf(out, "Resolved deployment domain %s (%s)\n", resolution.Domain, resolution.Source)
			}
			runner := &blueprint.Runner{
				Client:           dynamicClient,
				Mapper:           mapper,
				DefaultNamespace: defaultNamespace,
				Out:              out,
			}
			if err := runner.Deploy(deployContext, pkg, deployOptions); err != nil {
				return err
			}
			if opts.noWait {
				return nil
			}
			accessURLs, err := blueprint.ResolveAccessURLs(deployContext, dynamicClient, pkg)
			if err != nil {
				return err
			}
			for _, accessURL := range accessURLs {
				fmt.Fprintf(out, "Access URL: %s\n", accessURL)
			}
			return nil
		},
	}

	command.Flags().StringVar(&opts.from, "from", "", "multi-document YAML file or Blueprint package directory")
	command.Flags().StringVar(&opts.kubeconfig, "kubeconfig", "", "path to the kubeconfig file")
	command.Flags().StringVar(&opts.context, "context", "", "kubeconfig context to use")
	command.Flags().DurationVar(&opts.timeout, "timeout", defaultDeployTimeout, "overall deployment and readiness timeout")
	command.Flags().BoolVar(&opts.noWait, "no-wait", false, "apply stages without waiting for ClusterRepos, AIWorkloads, or Jobs")
	command.Flags().BoolVar(&opts.dryRun, "dry-run", false, "parse and print the deployment plan without contacting the cluster")
	command.Flags().StringVar(&opts.domain, "domain", "", "base DNS domain for packages that request one (default: <node-ip>.sslip.io; env: AIFLAB_DOMAIN)")
	return command
}

func requestedDomain(flagValue string) string {
	if value := strings.TrimSpace(flagValue); value != "" {
		return value
	}
	return strings.TrimSpace(os.Getenv("AIFLAB_DOMAIN"))
}

func kubeClientConfig(kubeconfig, contextName string) clientcmd.ClientConfig {
	loadingRules := clientcmd.NewDefaultClientConfigLoadingRules()
	if kubeconfig != "" {
		loadingRules.ExplicitPath = kubeconfig
	}
	overrides := &clientcmd.ConfigOverrides{CurrentContext: contextName}
	return clientcmd.NewNonInteractiveDeferredLoadingClientConfig(loadingRules, overrides)
}
